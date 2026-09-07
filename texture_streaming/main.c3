module texture_streaming;

import gpu;
import sample_device;
import std::io;

const char[*] PROBE_SPIRV = $embed("shaders/probe.comp.spv");

const uint TEX_SIZE = 8;
const usz TEXEL_BYTES = 4;
const usz TEXTURE_BYTES = TEX_SIZE * TEX_SIZE * TEXEL_BYTES;
const uint GENERATION_COUNT = 2;
const uint PROBE_COUNT = 3;
const usz PROBE_RESULT_BYTES = gpu::Vec4f::size;

struct Probe {
    gpu::Device*           device;
    gpu::CommandAllocator* allocator;
    gpu::PipelineHandle    pipeline;
    gpu::GpuSpan           root_span;
    gpu::GpuSpan           output_span;
}

fn int main() {
    if (catch err = run()) {
        io::printfn("texture_streaming: FAIL (%s)", err);
        return 1;
    }
    io::printn("texture_streaming: PASS");
    return 0;
}

fn char[4] generation_color(uint generation, uint slot) {
    if (generation == 0) return { (char)(32 * (slot + 1)), 0, (char)(255 - 32 * slot), 255 };
    return { 0, (char)(32 * (slot + 1)), 64, 255 };
}

fn void? run() {
    gpu::RuntimeDesc runtime_desc = {
        .contract_validation      = gpu::ContractValidation.FULL,
        .enable_vulkan_validation = true,
        .application_name         = "texture_streaming",
    };
    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer (void)gpu::destroy_runtime(&runtime);
    gpu::Device device = sample_device::create_device(&runtime)!;
    defer (void)gpu::destroy_device(&device);
    gpu::Queue compute_queue = gpu::get_queue(&device, gpu::QueueKind.COMPUTE)!;
    gpu::CommandAllocator allocator = gpu::create_command_allocator(&device, compute_queue)!;
    defer (void)gpu::destroy_command_allocator(&allocator);

    gpu::TextureIndexRange range = gpu::reserve_texture_indices(&device, SLOT_COUNT)!;
    io::printfn("reserved %d texture slots at index %d", range.count, range.base.value);
    if (range.count != SLOT_COUNT) return gpu::INVALID_RESOURCE_STATE~;

    gpu::TextureDesc tex_desc = {
        .width  = TEX_SIZE,
        .height = TEX_SIZE,
        .format = gpu::Format.RGBA8_UNORM,
        .usage  = { .sampled, .transfer_dst },
        .access = { .compute },
    };
    gpu::TextureHandle[SLOT_COUNT][GENERATION_COUNT] textures;
    for (uint g = 0; g < GENERATION_COUNT; g++) {
        for (uint i = 0; i < SLOT_COUNT; i++) {
            textures[g][i] = gpu::create_texture(&device, &tex_desc)!;
        }
    }
    defer {
        for (uint g = 0; g < GENERATION_COUNT; g++) {
            for (uint i = 0; i < SLOT_COUNT; i++) (void)gpu::destroy_texture(&device, textures[g][i]);
        }
    }

    check_general_region(&device, textures[0][0], range)!;

    gpu::AllocationDesc staging_desc = {
        .size         = GENERATION_COUNT * SLOT_COUNT * TEXTURE_BYTES,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .compute },
        .debug_name   = "streaming_staging",
    };
    gpu::MappedGpuSpan staging = gpu::allocate_mapped_memory(&device, &staging_desc)!;
    gpu::GpuAllocation staging_allocation = staging.span.allocation();
    defer (void)gpu::free_allocation(&device, &staging_allocation);
    for (uint g = 0; g < GENERATION_COUNT; g++) {
        for (uint i = 0; i < SLOT_COUNT; i++) {
            char[4] color = generation_color(g, i);
            usz base = (usz)(g * SLOT_COUNT + i) * TEXTURE_BYTES;
            for (usz t = 0; t < TEX_SIZE * TEX_SIZE; t++) {
                staging.bytes[base + t * TEXEL_BYTES : TEXEL_BYTES][..] = color[..];
            }
        }
    }
    gpu::flush_mapped_span(&device, staging.span)!;
    upload_textures(
        device:    &device,
        allocator: &allocator,
        staging:   staging.span,
        textures:  &textures,
    )!;

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::SamplerIndex sampler = gpu::intern_sampler(&device, &sampler_desc)!;

    gpu::AllocationDesc output_desc = {
        .size         = SLOT_COUNT * PROBE_RESULT_BYTES,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .compute },
        .debug_name   = "streaming_output",
    };
    gpu::MappedGpuSpan output = gpu::allocate_mapped_memory(&device, &output_desc)!;
    gpu::GpuAllocation output_allocation = output.span.allocation();
    defer (void)gpu::free_allocation(&device, &output_allocation);

    gpu::AllocationDesc root_desc = {
        .size         = StreamRoot::size,
        .memory_class = gpu::MemoryClass.CPU_WRITE_GPU_LOCAL,
        .access       = { .compute },
        .debug_name   = "streaming_root",
    };
    gpu::MappedGpuSpan root = gpu::allocate_mapped_memory(&device, &root_desc)!;
    gpu::GpuAllocation root_allocation = root.span.allocation();
    defer (void)gpu::free_allocation(&device, &root_allocation);
    gpu::AllocationInfo root_info = gpu::get_allocation_info(&device, root_allocation)!;
    io::printfn(
        "root record in CPU_WRITE_GPU_LOCAL: device_local=%s coherent=%s",
        root_info.device_local,
        root_info.coherent,
    );
    StreamRoot* root_record = (StreamRoot*)root.bytes.ptr;
    *root_record = {
        .output_gpu    = output.address,
        .base          = range.base,
        .sampler_index = sampler,
        .count         = SLOT_COUNT,
    };
    gpu::flush_mapped_span(&device, root.span)!;

    gpu::ComputePipelineDesc pipe_desc = {
        .shader = { .spirv = PROBE_SPIRV[..], .entry_point = "main" },
    };
    gpu::PipelineHandle pipeline = gpu::create_compute_pipeline(&device, &pipe_desc)!;
    defer (void)gpu::destroy_pipeline(&device, pipeline);

    Probe probe = {
        .device      = &device,
        .allocator   = &allocator,
        .pipeline    = pipeline,
        .root_span   = root.span,
        .output_span = output.span,
    };

    gpu::TextureView[SLOT_COUNT] views;
    for (uint i = 0; i < SLOT_COUNT; i++) {
        views[i] = gpu::create_texture_view_at(
            device:  &device,
            slot:    slot_index(range, i),
            texture: textures[0][i],
            desc:    null,
        )!;
        if (views[i].index.value != range.base.value + i) return gpu::INVALID_RESOURCE_STATE~;
    }
    uint[SLOT_COUNT] expected = { 0, 0, 0, 0 };
    probe_slots(&probe, &expected, "generation A published into reserved slots")!;

    for (uint i = 0; i < SLOT_COUNT; i++) {
        gpu::update_texture_view(
            device:  &device,
            view:    &views[i],
            texture: textures[1][i],
            desc:    null,
        )!;
        if (views[i].index.value != range.base.value + i) return gpu::INVALID_RESOURCE_STATE~;
    }
    expected = { 1, 1, 1, 1 };
    probe_slots(&probe, &expected, "generation B swapped in place, root unchanged")!;

    gpu::destroy_texture_view(&device, views[0])!;
    check_general_region(&device, textures[0][0], range)!;
    views[0] = gpu::create_texture_view_at(
        device:  &device,
        slot:    range.base,
        texture: textures[0][0],
        desc:    null,
    )!;
    expected = { 0, 1, 1, 1 };
    probe_slots(&probe, &expected, "slot 0 republished after destroy")!;

    for (uint i = 0; i < SLOT_COUNT; i++) gpu::destroy_texture_view(&device, views[i])!;
    gpu::release_texture_indices(&device, range)!;
    io::printn("reservation released");
}

fn gpu::TextureIndex slot_index(gpu::TextureIndexRange range, uint offset) {
    return { .value = range.base.value + offset };
}

fn bool inside_range(gpu::TextureIndexRange range, gpu::TextureIndex index) {
    return index.value >= range.base.value && index.value < range.base.value + range.count;
}

fn void? check_general_region(gpu::Device* device, gpu::TextureHandle texture, gpu::TextureIndexRange range) {
    gpu::TextureView[PROBE_COUNT] probes;
    for (uint i = 0; i < PROBE_COUNT; i++) {
        probes[i] = gpu::create_texture_view(device, texture, null)!;
    }
    defer {
        for (uint i = 0; i < PROBE_COUNT; i++) (void)gpu::destroy_texture_view(device, probes[i]);
    }
    for (uint i = 0; i < PROBE_COUNT; i++) {
        if (inside_range(range, probes[i].index)) {
            io::printfn("general view landed inside the reservation at %d", probes[i].index.value);
            return gpu::INVALID_RESOURCE_STATE~;
        }
    }
    io::printfn("%d general views stayed outside the reservation", PROBE_COUNT);
}

fn void? upload_textures(
    gpu::Device* device,
    gpu::CommandAllocator* allocator,
    gpu::GpuSpan staging,
    gpu::TextureHandle[SLOT_COUNT][GENERATION_COUNT]* textures,
) {
    gpu::CommandList cmd = gpu::begin_commands(allocator)!;
    defer (void)gpu::discard_commands(&cmd);
    gpu::TextureState transfer_dst = {
        .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
        .stages = { .transfer },
        .access = { .write },
    };
    for (uint g = 0; g < GENERATION_COUNT; g++) {
        for (uint i = 0; i < SLOT_COUNT; i++) {
            gpu::TextureHandle texture = (*textures)[g][i];
            gpu::TextureBarrier to_dst = gpu::texture_transition(
                texture: texture,
                before:  { .layout = gpu::TextureLayout.UNDEFINED },
                after:   transfer_dst,
            )!;
            gpu::cmd_texture_barrier(&cmd, &to_dst)!;
            gpu::BufferTextureCopyDesc copy = {
                .src     = staging.checked_subspan((usz)(g * SLOT_COUNT + i) * TEXTURE_BYTES, TEXTURE_BYTES)!,
                .texture = texture,
            };
            gpu::cmd_copy_buffer_to_texture(&cmd, &copy)!;
            gpu::TextureBarrier to_sampled = gpu::texture_transition(
                texture: texture,
                before:  transfer_dst,
                after:   gpu::sampled_at({ .compute }),
            )!;
            gpu::cmd_texture_barrier(&cmd, &to_sampled)!;
        }
    }
    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::CompletionPoint done = gpu::submit(allocator.queue, &submit)!;
    gpu::wait_completion(done, ulong::max)!;
}

fn void? probe_slots(Probe* probe, uint[SLOT_COUNT]* expected_generation, String label) {
    gpu::CommandList cmd = gpu::begin_commands(probe.allocator)!;
    defer (void)gpu::discard_commands(&cmd);
    gpu::cmd_bind_pipeline(&cmd, probe.pipeline)!;
    gpu::cmd_dispatch(
        commands: &cmd,
        root:     gpu::get_span_address(probe.device, probe.root_span)!,
        groups:   { 1, 1, 1 },
    )!;
    gpu::Barrier to_host = { .before = { .compute = true }, .after = { .host = true } };
    gpu::cmd_barrier(&cmd, &to_host)!;
    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::CompletionPoint done = gpu::submit(probe.allocator.queue, &submit)!;
    gpu::wait_completion(done, ulong::max)!;
    gpu::invalidate_mapped_span(probe.device, probe.output_span)!;

    gpu::Vec4f* results = (gpu::Vec4f*)gpu::get_span_mapping(probe.device, probe.output_span)!.ptr;
    for (uint i = 0; i < SLOT_COUNT; i++) {
        char[4] want = generation_color((*expected_generation)[i], i);
        gpu::Vec4f got = results[i];
        for (uint c = 0; c < 4; c++) {
            if (quantize_unorm8(got[c]) != want[c]) {
                io::printfn(
                    "%s: slot %d channel %d = %f, expected %d",
                    label,
                    i,
                    c,
                    got[c],
                    want[c],
                );
                return gpu::INVALID_RESOURCE_STATE~;
            }
        }
    }
    io::printfn("%s: OK", label);
}

fn uint quantize_unorm8(float value) => (uint)(value * 255.0f + 0.5f);
