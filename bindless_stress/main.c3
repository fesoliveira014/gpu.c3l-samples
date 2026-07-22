module bindless_stress;

import gpu;
import sample_device;
import std::io;
import std::time;
import std::core::mem;

const char[*] VERIFY_COMP_SPIRV = $embed("shaders/verify.comp.spv");

const uint TEXTURE_COUNT = 8192;
// Spare slots keep churn away from exact-capacity allocation behavior.
const uint CAPACITY_SLACK = CHURN_SLICE + 64;
const uint UPLOAD_BATCH = 16;
const uint CHURN_FRAMES = 24;
const uint CHURN_SLICE = 256;

<* Self-identifying payload: low/high index bytes, a salt, opaque alpha. *>
fn char[4] payload_for(uint index, uint salt) {
    return {
        (char)(index & 0xFF),
        (char)((index >> 8) & 0xFF),
        (char)(salt & 0xFF),
        (char)0xFF,
    };
}

fn gpu::TextureHandle? create_stress_texture(gpu::Device* device) {
    gpu::TextureDesc desc = {
        .width     = 1,
        .height    = 1,
        .format    = gpu::Format.RGBA8_UNORM,
        .usage     = { .sampled, .transfer_dst },
        .access     = { .graphics, .compute },
    };
    return gpu::create_texture(device, &desc);
}

fn double ms(NanoDuration d) => (double)(long)d / 1_000_000.0;

fn int main(String[] args) {
    if (catch err = run()) {
        io::printfn("bindless_stress: FAIL (%s)", err);
        return 1;
    }
    io::printn("bindless_stress: PASS");
    return 0;
}

struct Fleet {
    gpu::TextureHandle[] textures;
    gpu::TextureView[]   views;
    gpu::TextureIndex[]  indices;
    uint[]               salts;
}

<* Upload payloads for texture slice [first, first+count) in one command list. *>
fn void? upload_slice(
    gpu::Device* device,
    Fleet* fleet,
    gpu::GpuSpan staging_span,
    uint first,
    uint count,
) {
    gpu::GpuSpan upload_span = staging_span.checked_subspan(0, (usz)count * 4)!;
    char* texels = (char*)gpu::get_span_mapping(device, upload_span)!.ptr;
    for (uint i = 0; i < count; i++) {
        char[4] p = payload_for(first + i, fleet.salts[first + i]);
        texels[i * 4]     = p[0];
        texels[i * 4 + 1] = p[1];
        texels[i * 4 + 2] = p[2];
        texels[i * 4 + 3] = p[3];
    }
    gpu::flush_mapped_span(device, upload_span)!;

    gpu::Queue compute_queue = gpu::get_queue(device, gpu::QueueKind.COMPUTE)!;

    gpu::CommandList cmd = gpu::begin_commands(compute_queue)!;
    defer (void)gpu::discard_commands(&cmd);
    for (uint i = 0; i < count; i++) {
        gpu::TextureHandle tex = fleet.textures[first + i];
        gpu::TextureBarrier to_dst = {
            .texture = tex,
            .before  = { .layout = gpu::TextureLayout.UNDEFINED },
            .after   = {
                .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
                .stages = { .transfer },
                .access = { .write },
            },
        };
        gpu::cmd_texture_barrier(&cmd, &to_dst)!;
        gpu::GpuSpan slice = upload_span.checked_subspan((usz)i * 4, 4)!;
        gpu::BufferTextureCopyDesc upload = { .src = slice, .texture = tex };
        gpu::cmd_copy_buffer_to_texture(&cmd, &upload)!;
        gpu::TextureBarrier to_read = {
            .texture = tex,
            .before  = {
                .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
                .stages = { .transfer },
                .access = { .write },
            },
            .after   = gpu::sampled_at({ .compute }),
        };
        gpu::cmd_texture_barrier(&cmd, &to_read)!;
    }
    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::CompletionPoint completion = gpu::submit(compute_queue, &submit)!;
    gpu::wait_completion(completion)!;
}

fn void? dispatch_verify(
    gpu::GpuSpan root_span,
    gpu::Device* device,
    Fleet* fleet,
    gpu::PipelineHandle pipeline,
    gpu::GpuSpan index_span,
    gpu::GpuAddress index_address,
    gpu::GpuAddress out_address,
    gpu::SamplerIndex sampler,
) {
    uint* index_data = (uint*)gpu::get_span_mapping(device, index_span)!.ptr;
    for (uint i = 0; i < TEXTURE_COUNT; i++) index_data[i] = (uint)fleet.indices[i];
    gpu::flush_mapped_span(device, index_span)!;

    StressRoot* root = (StressRoot*)gpu::get_span_mapping(device, root_span)!.ptr;
    root.indices_gpu  = index_address;
    root.output_gpu   = out_address;
    root.heap_sampler = sampler;
    root.count        = TEXTURE_COUNT;
    gpu::flush_mapped_span(device, root_span)!;
    gpu::GpuAddress root_address = gpu::get_span_address(device, root_span)!;

    gpu::Queue compute_queue = gpu::get_queue(device, gpu::QueueKind.COMPUTE)!;

    gpu::CommandList cmd = gpu::begin_commands(compute_queue)!;
    defer (void)gpu::discard_commands(&cmd);
    gpu::cmd_bind_pipeline(&cmd, pipeline)!;
    gpu::cmd_dispatch(
        commands: &cmd,
        root:     root_address,
        groups:   { (TEXTURE_COUNT + VERIFY_WORKGROUP - 1) / VERIFY_WORKGROUP, 1, 1 },
    )!;
    gpu::Barrier host_read = {
        .before = { .compute = true },
        .after = { .host = true },
    };
    gpu::cmd_barrier(&cmd, &host_read)!;
    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::CompletionPoint completion = gpu::submit(compute_queue, &submit)!;
    defer (void)gpu::wait_completion(completion, ulong::max);
    gpu::wait_completion(completion)!;
}

fn void? check_results(gpu::Device* device, Fleet* fleet, gpu::GpuSpan out_span) {
    float* results = (float*)gpu::get_span_mapping(device, out_span)!.ptr;
    for (uint i = 0; i < TEXTURE_COUNT; i++) {
        char[4] expect = payload_for(i, fleet.salts[i]);
        for (uint c = 0; c < 4; c++) {
            float got = results[i * 4 + c];
            float want = (float)expect[c] / 255.0f;
            float diff = got > want ? got - want : want - got;
            // Half a UNORM step of tolerance.
            if (diff > 0.5f / 255.0f) {
                io::printfn("mismatch: texture %d channel %d got %f want %f", i, c, got, want);
                return gpu::INVALID_ARGUMENT~;
            }
        }
    }
}

fn void? run() {
    gpu::RuntimeDesc runtime_desc = {
        .backend                      = gpu::BackendKind.VULKAN,
        .contract_validation          = gpu::ContractValidation.FULL,
        .track_resource_lifetimes     = true,
        .enable_vulkan_validation     = true,
        .texture_heap_capacity        = TEXTURE_COUNT + CAPACITY_SLACK,
        .texture_capacity             = TEXTURE_COUNT + CAPACITY_SLACK,
        .application_name             = "bindless_stress",
    };
    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer (void)gpu::destroy_runtime(&runtime);
    gpu::Device device = sample_device::create_strict_device(&runtime)!;
    defer (void)gpu::destroy_device(&device);

    Fleet fleet = {
        .textures = mem::new_array(gpu::TextureHandle, TEXTURE_COUNT),
        .views    = mem::new_array(gpu::TextureView, TEXTURE_COUNT),
        .indices  = mem::new_array(gpu::TextureIndex, TEXTURE_COUNT),
        .salts    = mem::new_array(uint, TEXTURE_COUNT),
    };
    defer {
        mem::free(fleet.salts.ptr);
        mem::free(fleet.indices.ptr);
        mem::free(fleet.views.ptr);
        mem::free(fleet.textures.ptr);
    }

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::SamplerIndex sampler = gpu::intern_sampler(&device, &sampler_desc)!;

    gpu::AllocationDesc staging_desc = {
        .size         = UPLOAD_BATCH * 4,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .compute },
        .debug_name   = "stress_staging",
    };
    gpu::GpuAllocation staging = gpu::allocate_memory(&device, &staging_desc)!;
    defer (void)gpu::free_allocation(&device, &staging);
    gpu::GpuSpan staging_span = gpu::get_allocation_span(&device, staging)!;

    gpu::AllocationDesc index_desc = {
        .size         = TEXTURE_COUNT * 4,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .compute },
        .debug_name   = "stress_indices",
    };
    gpu::GpuAllocation index_allocation = gpu::allocate_memory(&device, &index_desc)!;
    defer (void)gpu::free_allocation(&device, &index_allocation);
    gpu::GpuSpan index_span = gpu::get_allocation_span(&device, index_allocation)!;
    gpu::GpuAddress index_address = gpu::get_span_address(&device, index_span)!;

    gpu::AllocationDesc out_desc = {
        .size         = TEXTURE_COUNT * 16,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .compute },
        .debug_name   = "stress_results",
    };
    gpu::GpuAllocation out_allocation = gpu::allocate_memory(&device, &out_desc)!;
    defer (void)gpu::free_allocation(&device, &out_allocation);
    gpu::GpuSpan out_span = gpu::get_allocation_span(&device, out_allocation)!;
    gpu::GpuAddress out_address = gpu::get_span_address(&device, out_span)!;

    gpu::AllocationDesc root_desc = {
        .size         = StressRoot::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .compute },
        .debug_name   = "stress_root",
    };
    gpu::GpuAllocation root_allocation = gpu::allocate_memory(&device, &root_desc)!;
    defer (void)gpu::free_allocation(&device, &root_allocation);
    gpu::GpuSpan root_span = gpu::get_allocation_span(&device, root_allocation)!;

    gpu::ShaderDesc comp_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = VERIFY_COMP_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode shader = gpu::prepare_shader_code(&comp_sd)!;
    gpu::ComputePipelineDesc pipe_desc = { .shader = shader };
    gpu::PipelineHandle pipeline = gpu::create_compute_pipeline(&device, &pipe_desc)!;
    defer (void)gpu::destroy_pipeline(&device, pipeline);

    Clock clk = clock::now();
    for (uint i = 0; i < TEXTURE_COUNT; i++) {
        fleet.textures[i] = create_stress_texture(&device)!;
        fleet.views[i]    = gpu::create_texture_view(&device, fleet.textures[i], null)!;
        fleet.indices[i]  = fleet.views[i].index;
        fleet.salts[i]    = 0xAB;
    }
    NanoDuration create_time = clk.mark();

    for (uint first = 0; first < TEXTURE_COUNT; first += UPLOAD_BATCH) {
        upload_slice(
            device:       &device,
            fleet:        &fleet,
            staging_span: staging_span,
            first:        first,
            count:        UPLOAD_BATCH,
        )!;
    }
    NanoDuration upload_time = clk.mark();

    dispatch_verify(
        root_span:     root_span,
        device:        &device,
        fleet:         &fleet,
        pipeline:      pipeline,
        index_span:    index_span,
        index_address: index_address,
        out_address:   out_address,
        sampler:       sampler,
    )!;
    NanoDuration fill_verify_time = clk.mark();
    gpu::invalidate_mapped_span(&device, out_span)!;
    check_results(&device, &fleet, out_span)!;

    uint cursor = 0;
    clk = clock::now();
    for (uint frame = 0; frame < CHURN_FRAMES; frame++) {
        for (uint i = 0; i < CHURN_SLICE; i++) {
            uint slot = (cursor + i) % TEXTURE_COUNT;
            gpu::destroy_texture_view(&device, fleet.views[slot])!;
            gpu::destroy_texture(&device, fleet.textures[slot])!;
            fleet.textures[slot] = create_stress_texture(&device)!;
            fleet.views[slot]    = gpu::create_texture_view(&device, fleet.textures[slot], null)!;
            fleet.indices[slot]  = fleet.views[slot].index;
            fleet.salts[slot]    = frame;
        }
        for (uint first = cursor; first < cursor + CHURN_SLICE; first += UPLOAD_BATCH) {
            upload_slice(
                device:       &device,
                fleet:        &fleet,
                staging_span: staging_span,
                first:        first,
                count:        UPLOAD_BATCH,
            )!;
        }

        dispatch_verify(
            root_span:     root_span,
            device:        &device,
            fleet:         &fleet,
            pipeline:      pipeline,
            index_span:    index_span,
            index_address: index_address,
            out_address:   out_address,
            sampler:       sampler,
        )!;
        gpu::invalidate_mapped_span(&device, out_span)!;
        check_results(&device, &fleet, out_span)!;
        cursor = (cursor + CHURN_SLICE) % TEXTURE_COUNT;
    }
    NanoDuration churn_time = clk.mark();

    for (uint i = 0; i < TEXTURE_COUNT; i++) {
        gpu::destroy_texture_view(&device, fleet.views[i])!;
        gpu::destroy_texture(&device, fleet.textures[i])!;
    }

    io::printfn("bindless_stress: %d textures, heap capacity %d", TEXTURE_COUNT, TEXTURE_COUNT + CAPACITY_SLACK);
    io::printfn("  create fleet    %.1f ms", ms(create_time));
    io::printfn("  upload payloads %.1f ms", ms(upload_time));
    io::printfn("  verify dispatch %.1f ms", ms(fill_verify_time));
    io::printfn("  churn           %.1f ms/frame (%d frames x %d slots)", ms(churn_time) / CHURN_FRAMES, CHURN_FRAMES, CHURN_SLICE);
}
