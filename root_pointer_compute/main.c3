module root_pointer_compute;

import gpu;
import std::io;

const char[*] ROOT_POINTER_SPIRV = $embed("shaders/root_pointer.comp.spv");

const uint COUNT = 256;

fn int main() {
    if (catch err = run()) {
        io::printfn("root_pointer_compute: FAIL (%s)", err);
        return 1;
    }
    io::printn("root_pointer_compute: PASS");
    return 0;
}

fn void? dispatch_compute(
    gpu::Device* device,
    gpu::GpuSpan input,
    gpu::GpuSpan output,
    gpu::PipelineHandle pipeline,
) {
    gpu::AllocationDesc root_desc = {
        .size         = ComputeRoot::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .compute },
        .debug_name   = "compute_root",
    };
    gpu::GpuAllocation root_allocation = gpu::allocate_memory(device, &root_desc)!;
    defer gpu::free_allocation(device, &root_allocation)!!;
    gpu::GpuSpan root_span = gpu::get_allocation_span(device, root_allocation)!;
    ComputeRoot* root = (ComputeRoot*)gpu::get_span_mapping(device, root_span)!.ptr;
    root.input_gpu  = gpu::get_span_address(device, input)!;
    root.output_gpu = gpu::get_span_address(device, output)!;
    root.count      = COUNT;
    gpu::flush_mapped_span(device, root_span)!;

    gpu::Queue compute_queue = gpu::get_queue(device, gpu::QueueKind.COMPUTE)!;

    gpu::CommandList cmd = gpu::begin_commands(compute_queue)!;
    defer (void)gpu::discard_commands(&cmd);
    gpu::cmd_dispatch(
        commands: &cmd,
        pipeline: pipeline,
        root:     gpu::get_span_address(device, root_span)!,
        groups:   { (COUNT + ROOT_POINTER_WORKGROUP - 1) / ROOT_POINTER_WORKGROUP, 1, 1 },
    )!;
    gpu::BufferBarrier bar = {
        .span = output,
        .before_stage = gpu::Stage.COMPUTE_SHADER, .after_stage = gpu::Stage.HOST,
        .before_hazard = gpu::Hazard.SHADER_WRITE, .after_hazard = gpu::Hazard.HOST_READ,
    };
    gpu::cmd_buffer_barrier(&cmd, &bar)!;
    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::CompletionPoint completion = gpu::submit(compute_queue, &submit)!;
    defer (void)gpu::wait_completion(completion, ulong::max);
    gpu::wait_completion(completion, ulong::max)!;
    gpu::invalidate_mapped_span(device, output)!;

    float* out_data = (float*)gpu::get_span_mapping(device, output)!.ptr;
    for (uint i = 0; i < COUNT; i++) {
        if (out_data[i] != (float)i * 2.0) return gpu::INVALID_RESOURCE_STATE~;
    }
}

fn void? run() {
    gpu::DeviceDesc device_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .application_name  = "root_pointer_compute",
    };
    gpu::Device device = gpu::create_device_from_desc(&device_desc)!;
    defer gpu::destroy_device(&device)!!;

    gpu::AllocationDesc input_desc = {
        .size         = COUNT * float::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .compute },
        .debug_name   = "input",
    };
    gpu::GpuAllocation input = gpu::allocate_memory(&device, &input_desc)!;
    defer gpu::free_allocation(&device, &input)!!;
    gpu::GpuSpan input_span = gpu::get_allocation_span(&device, input)!;

    gpu::AllocationDesc output_desc = {
        .size         = COUNT * float::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .compute },
        .debug_name   = "output",
    };
    gpu::GpuAllocation output = gpu::allocate_memory(&device, &output_desc)!;
    defer gpu::free_allocation(&device, &output)!!;
    gpu::GpuSpan output_span = gpu::get_allocation_span(&device, output)!;

    float* in_data = (float*)gpu::get_span_mapping(&device, input_span)!.ptr;
    for (uint i = 0; i < COUNT; i++) in_data[i] = (float)i;
    gpu::flush_mapped_span(&device, input_span)!;

    gpu::ShaderDesc shader_desc = {
        .stage = gpu::ShaderStage.COMPUTE, .spirv = ROOT_POINTER_SPIRV[..],
        .entry_point = "main", .debug_name = "root_pointer",
    };
    gpu::ShaderHandle shader = gpu::create_shader(&device, &shader_desc)!;
    defer gpu::destroy_shader(&device, shader)!!;

    gpu::ComputePipelineDesc pipe_desc = { .shader = shader, .push_constant_size = gpu::RootPush::size, .debug_name = "root_pointer" };
    gpu::PipelineHandle pipeline = gpu::create_compute_pipeline(&device, &pipe_desc)!;
    defer gpu::destroy_pipeline(&device, pipeline)!!;

    dispatch_compute(
        device:   &device,
        input:    input_span,
        output:   output_span,
        pipeline: pipeline,
    )!;
}
