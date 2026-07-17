module root_pointer_compute;

import gpu;
import std::io;

const char[*] ROOT_POINTER_SPIRV = $embed("shaders/root_pointer.comp.spv");

const uint COUNT = 256;

struct FrameWork {
    gpu::Device*        device;
    gpu::BufferHandle   input;
    gpu::BufferHandle   output;
    gpu::PipelineHandle pipeline;
}

fn int main() {
    if (catch err = run()) {
        io::printfn("root_pointer_compute: FAIL (%s)", err);
        return 1;
    }
    io::printn("root_pointer_compute: PASS");
    return 0;
}

fn void? run_frame(gpu::FrameToken* frame, FrameWork* work) {
    gpu::GpuSpan root_span = gpu::alloc_frame_span(frame, ComputeRoot::size, 16)!;
    ComputeRoot* root = (ComputeRoot*)root_span.cpu;
    root.input_gpu  = gpu::get_buffer_address(work.device, work.input)!;
    root.output_gpu = gpu::get_buffer_address(work.device, work.output)!;
    root.count      = COUNT;

    gpu::Queue compute_queue = gpu::get_queue(work.device, gpu::QueueKind.COMPUTE)!;

    gpu::CommandList cmd = gpu::begin_commands(compute_queue)!;
    gpu::cmd_dispatch(
        commands: &cmd,
        pipeline: work.pipeline,
        root:     root_span.gpu,
        groups:   { (COUNT + ROOT_POINTER_WORKGROUP - 1) / ROOT_POINTER_WORKGROUP, 1, 1 },
    )!;
    gpu::BufferBarrier bar = {
        .buffer = work.output, .offset = 0, .size = COUNT * float::size,
        .before_stage = gpu::Stage.COMPUTE_SHADER, .after_stage = gpu::Stage.HOST,
        .before_hazard = gpu::Hazard.SHADER_WRITE, .after_hazard = gpu::Hazard.HOST_READ,
    };
    gpu::cmd_buffer_barrier(&cmd, &bar)!;
    gpu::ExecutableCommandList cmd_executable = gpu::end_commands(&cmd)!;

    gpu::ExecutableCommandList[1] lists = { cmd_executable };
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::CompletionPoint completion = gpu::submit(compute_queue, &submit)!;
    gpu::wait_completion(completion, ulong::max)!;

    gpu::GpuSpan out_span = gpu::get_buffer_span(work.device, work.output)!;
    float* out_data = (float*)out_span.cpu;
    for (uint i = 0; i < COUNT; i++) {
        if (out_data[i] != (float)i * 2.0) return gpu::INVALID_RESOURCE_STATE~;
    }
}

fn void? run() {
    gpu::DeviceDesc device_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .frames_in_flight  = 2,
        .application_name  = "root_pointer_compute",
    };
    gpu::Device device = gpu::create_device_from_desc(&device_desc)!;
    defer gpu::destroy_device(&device)!!;

    gpu::BufferDesc io_desc = {
        .size        = COUNT * float::size,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .access      = { .compute },
        .debug_name  = "io",
    };
    gpu::BufferHandle input = gpu::create_buffer(&device, &io_desc)!;
    defer gpu::destroy_buffer(&device, input)!!;
    gpu::BufferHandle output = gpu::create_buffer(&device, &io_desc)!;
    defer gpu::destroy_buffer(&device, output)!!;

    gpu::GpuSpan in_span = gpu::get_buffer_span(&device, input)!;
    float* in_data = (float*)in_span.cpu;
    for (uint i = 0; i < COUNT; i++) in_data[i] = (float)i;

    gpu::ShaderDesc shader_desc = {
        .stage = gpu::ShaderStage.COMPUTE, .spirv = ROOT_POINTER_SPIRV[..],
        .entry_point = "main", .debug_name = "root_pointer",
    };
    gpu::ShaderHandle shader = gpu::create_shader(&device, &shader_desc)!;
    defer gpu::destroy_shader(&device, shader)!!;

    gpu::ComputePipelineDesc pipe_desc = { .shader = shader, .push_constant_size = gpu::RootPush::size, .debug_name = "root_pointer" };
    gpu::PipelineHandle pipeline = gpu::create_compute_pipeline(&device, &pipe_desc)!;
    defer gpu::destroy_pipeline(&device, pipeline)!!;

    FrameWork work = {
        .device   = &device,
        .input    = input,
        .output   = output,
        .pipeline = pipeline,
    };
    gpu::FrameToken retry_frame;
    fault frame_fault = @catch(gpu::@with_frame(&retry_frame, &device, run_frame, &work));
    if (frame_fault) {
        if (retry_frame.is_valid()) gpu::end_frame(&retry_frame)!;
        return frame_fault~;
    }
}
