module bindless_texture_compute;

import gpu;
import std::io;

const char[*] HEAP_WRITE_SPIRV  = $embed("shaders/heap_write.comp.spv");
const char[*] HEAP_SAMPLE_SPIRV = $embed("shaders/heap_sample.comp.spv");

const uint TEX_SIZE = 16;

fn int main() {
    if (catch err = run()) {
        io::printfn("bindless_texture_compute: FAIL (%s)", err);
        return 1;
    }
    io::printn("bindless_texture_compute: PASS");
    return 0;
}

fn void? run() {
    gpu::DeviceDesc device_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .application_name  = "bindless_texture_compute",
    };
    gpu::Device device = gpu::create_device_from_desc(&device_desc)!;
    defer (void)gpu::destroy_device(&device);

    gpu::TextureDesc tex_desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = TEX_SIZE,
        .height     = TEX_SIZE,
        .format     = gpu::Format.RGBA8_UNORM,
        .usage      = { .sampled, .storage },
        .access     = { .compute },
        .debug_name = "heap_target",
    };
    gpu::TextureHandle texture = gpu::create_texture(&device, &tex_desc)!;
    defer (void)gpu::destroy_texture(&device, texture);

    gpu::TextureView tex_view = gpu::create_texture_view(&device, texture, null)!;
    defer (void)gpu::destroy_texture_view(&device, tex_view);
    gpu::TextureIndex tex_index = tex_view.index;

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::Sampler sampler = gpu::intern_sampler(&device, &sampler_desc)!;
    gpu::SamplerIndex smp_index = gpu::publish_sampler(&device, sampler)!;

    gpu::AllocationDesc out_desc = {
        .size         = TEX_SIZE * TEX_SIZE * 16,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .compute },
        .debug_name   = "sample_output",
    };
    gpu::GpuAllocation output = gpu::allocate_memory(&device, &out_desc)!;
    defer (void)gpu::free_allocation(&device, &output);
    gpu::GpuSpan output_span = gpu::get_allocation_span(&device, output)!;

    gpu::ShaderDesc write_shader_desc = {
        .stage = gpu::ShaderStage.COMPUTE, .spirv = HEAP_WRITE_SPIRV[..], .entry_point = "main",
    };
    gpu::ShaderCode write_shader = gpu::prepare_shader_code(&write_shader_desc)!;
    gpu::ShaderDesc sample_shader_desc = {
        .stage = gpu::ShaderStage.COMPUTE, .spirv = HEAP_SAMPLE_SPIRV[..], .entry_point = "main",
    };
    gpu::ShaderCode sample_shader = gpu::prepare_shader_code(&sample_shader_desc)!;

    gpu::ComputePipelineDesc write_pipe_desc = { .shader = write_shader, .push_constant_size = gpu::RootPush::size };
    gpu::PipelineHandle write_pipe = gpu::create_compute_pipeline(&device, &write_pipe_desc)!;
    defer (void)gpu::destroy_pipeline(&device, write_pipe);
    gpu::ComputePipelineDesc sample_pipe_desc = { .shader = sample_shader, .push_constant_size = gpu::RootPush::size };
    gpu::PipelineHandle sample_pipe = gpu::create_compute_pipeline(&device, &sample_pipe_desc)!;
    defer (void)gpu::destroy_pipeline(&device, sample_pipe);

    gpu::AllocationDesc roots_desc = {
        .size         = WriteRoot::size + SampleRoot::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .compute },
        .debug_name   = "bindless_roots",
    };
    gpu::GpuAllocation roots_allocation = gpu::allocate_memory(&device, &roots_desc)!;
    defer (void)gpu::free_allocation(&device, &roots_allocation);
    gpu::GpuSpan roots_span = gpu::get_allocation_span(&device, roots_allocation)!;

    gpu::GpuSpan write_root_span = roots_span.checked_subspan(0, WriteRoot::size)!;
    WriteRoot* write_root = (WriteRoot*)gpu::get_span_mapping(&device, write_root_span)!.ptr;
    write_root.texture_index = tex_index;
    write_root.width         = TEX_SIZE;
    write_root.height        = TEX_SIZE;

    gpu::GpuSpan sample_root_span = roots_span.checked_subspan(WriteRoot::size, SampleRoot::size)!;
    SampleRoot* sample_root = (SampleRoot*)gpu::get_span_mapping(&device, sample_root_span)!.ptr;
    sample_root.output_gpu    = gpu::get_span_address(&device, output_span)!;
    sample_root.texture_index = tex_index;
    sample_root.sampler_index = smp_index;
    sample_root.width         = TEX_SIZE;
    sample_root.height        = TEX_SIZE;
    gpu::flush_mapped_span(&device, roots_span)!;

    gpu::Queue compute_queue = gpu::get_queue(&device, gpu::QueueKind.COMPUTE)!;

    gpu::CommandList cmd = gpu::begin_commands(compute_queue)!;
    defer (void)gpu::discard_commands(&cmd);

    gpu::TextureBarrier to_general = {
        .texture       = texture,
        .before        = gpu::TextureUse.UNDEFINED,
        .after         = gpu::TextureUse.STORAGE_COMPUTE,
    };
    gpu::cmd_texture_barrier(&cmd, &to_general)!;

    const uint GROUPS = (TEX_SIZE + HEAP_TILE - 1) / HEAP_TILE;
    gpu::cmd_bind_pipeline(&cmd, write_pipe)!;
    gpu::cmd_dispatch(
        commands: &cmd,
        root:     gpu::get_span_address(&device, write_root_span)!,
        groups:   { GROUPS, GROUPS, 1 },
    )!;

    gpu::TextureBarrier write_to_sample = {
        .texture       = texture,
        .before        = gpu::TextureUse.STORAGE_COMPUTE,
        .after         = gpu::TextureUse.SAMPLED_COMPUTE,
    };
    gpu::cmd_texture_barrier(&cmd, &write_to_sample)!;

    gpu::cmd_bind_pipeline(&cmd, sample_pipe)!;
    gpu::cmd_dispatch(
        commands: &cmd,
        root:     gpu::get_span_address(&device, sample_root_span)!,
        groups:   { GROUPS, GROUPS, 1 },
    )!;

    gpu::Barrier out_bar = {
        .before = { .compute = true },
        .after = { .host = true },
    };
    gpu::cmd_barrier(&cmd, &out_bar)!;

    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::CompletionPoint completion = gpu::submit(compute_queue, &submit)!;
    defer (void)gpu::wait_completion(completion, ulong::max);
    gpu::wait_completion(completion, ulong::max)!;
    gpu::invalidate_mapped_span(&device, output_span)!;

    float* texels = (float*)gpu::get_span_mapping(&device, output_span)!.ptr;
    for (uint y = 0; y < TEX_SIZE; y++) {
        for (uint x = 0; x < TEX_SIZE; x++) {
            float* texel = &texels[(y * TEX_SIZE + x) * 4];
            if (quantize_unorm8(texel[0]) != x
                || quantize_unorm8(texel[1]) != y
                || quantize_unorm8(texel[2]) != (x ^ y)
                || quantize_unorm8(texel[3]) != 255) {
                io::printfn("mismatch at (%d, %d): %f %f %f %f", x, y, texel[0], texel[1], texel[2], texel[3]);
                return gpu::INVALID_RESOURCE_STATE~;
            }
        }
    }
}

fn uint quantize_unorm8(float value) {
    return (uint)(value * 255.0f + 0.5f);
}
