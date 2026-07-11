module bindless_stress;

import gpu;
import std::io;
import std::time;
import std::core::mem;

const char[*] VERIFY_COMP_SPIRV = $embed("shaders/verify.comp.spv");

const uint TEXTURE_COUNT = 8192;
// Same-frame retires are timeline-gated and only drain on a later frame, so
// a churn frame consumes CHURN_SLICE fresh slots before any recycling.
const uint CAPACITY_SLACK = CHURN_SLICE + 64;
// A command list tracks at most 16 distinct pending texture layouts.
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
        .dimension = gpu::TextureDimension.TEX_2D,
        .width     = 1,
        .height    = 1,
        .format    = gpu::Format.RGBA8_UNORM,
        // Graphics uploads while compute samples; share across possible distinct queue families.
        .usage     = { .sampled, .transfer_dst, .shared_queues },
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
    gpu::TextureIndex[]  indices;
    uint[]               salts;
}

<* Upload payloads for texture slice [first, first+count) in one command list. *>
fn void? upload_slice(gpu::Device* device, Fleet* fleet, gpu::GpuSpan staging_span, uint first, uint count) {
    char* texels = (char*)staging_span.cpu;
    for (uint i = 0; i < count; i++) {
        char[4] p = payload_for(first + i, fleet.salts[first + i]);
        texels[i * 4]     = p[0];
        texels[i * 4 + 1] = p[1];
        texels[i * 4 + 2] = p[2];
        texels[i * 4 + 3] = p[3];
    }
    gpu::flush_buffer(device, staging_span.buffer, staging_span.offset, (usz)count * 4)!;

    gpu::CommandList cmd = gpu::begin_commands(device, gpu::QueueKind.GRAPHICS)!;
    for (uint i = 0; i < count; i++) {
        gpu::TextureHandle tex = fleet.textures[first + i];
        gpu::TextureBarrier to_dst = {
            .texture       = tex,
            .before_stage  = gpu::Stage.HOST,
            .after_stage   = gpu::Stage.TRANSFER,
            .before_hazard = gpu::Hazard.HOST_WRITE,
            .after_hazard  = gpu::Hazard.TRANSFER_WRITE,
            .old_layout    = gpu::TextureLayout.UNDEFINED,
            .new_layout    = gpu::TextureLayout.TRANSFER_DST,
        };
        gpu::cmd_texture_barrier(&cmd, &to_dst)!;
        gpu::GpuSpan slice = staging_span.checked_subspan((usz)i * 4, 4)!;
        gpu::BufferTextureCopyDesc upload = { .src = slice, .texture = tex };
        gpu::cmd_copy_buffer_to_texture(&cmd, &upload)!;
        gpu::TextureBarrier to_read = {
            .texture       = tex,
            .before_stage  = gpu::Stage.TRANSFER,
            .after_stage   = gpu::Stage.COMPUTE_SHADER,
            .before_hazard = gpu::Hazard.TRANSFER_WRITE,
            .after_hazard  = gpu::Hazard.SHADER_READ,
            .old_layout    = gpu::TextureLayout.TRANSFER_DST,
            .new_layout    = gpu::TextureLayout.SHADER_READ,
        };
        gpu::cmd_texture_barrier(&cmd, &to_read)!;
    }
    gpu::end_commands(&cmd)!;
    gpu::CommandList[1] lists = { cmd };
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::submit(device, &submit)!;
    gpu::wait_queue_idle(device, gpu::QueueKind.GRAPHICS)!;
}

fn void? dispatch_verify(gpu::FrameToken* frame, gpu::Device* device, Fleet* fleet, gpu::PipelineHandle pipeline, gpu::GpuSpan index_span, gpu::GpuSpan out_span, gpu::SamplerIndex sampler) {
    uint* index_data = (uint*)index_span.cpu;
    for (uint i = 0; i < TEXTURE_COUNT; i++) index_data[i] = (uint)fleet.indices[i];
    gpu::flush_buffer(device, index_span.buffer, 0, 0)!;

    gpu::GpuSpan root_span = gpu::alloc_frame_span(frame, StressRoot::size, 16)!;
    StressRoot* root = (StressRoot*)root_span.cpu;
    root.indices_gpu  = index_span.gpu;
    root.output_gpu   = out_span.gpu;
    root.heap_sampler = sampler;
    root.count        = TEXTURE_COUNT;

    gpu::CommandList cmd = gpu::begin_commands(device, gpu::QueueKind.COMPUTE)!;
    gpu::cmd_dispatch(
        commands: &cmd,
        pipeline: pipeline,
        root:     root_span.gpu,
        groups:   { (TEXTURE_COUNT + VERIFY_WORKGROUP - 1) / VERIFY_WORKGROUP, 1, 1 },
    )!;
    gpu::BufferBarrier host_read = {
        .buffer = out_span.buffer, .offset = out_span.offset, .size = out_span.size,
        .before_stage = gpu::Stage.COMPUTE_SHADER, .after_stage = gpu::Stage.HOST,
        .before_hazard = gpu::Hazard.SHADER_WRITE, .after_hazard = gpu::Hazard.HOST_READ,
    };
    gpu::cmd_buffer_barrier(&cmd, &host_read)!;
    gpu::end_commands(&cmd)!;
    gpu::CommandList[1] lists = { cmd };
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::submit(device, &submit)!;
    gpu::wait_queue_idle(device, gpu::QueueKind.COMPUTE)!;
}

fn void? check_results(Fleet* fleet, gpu::GpuSpan out_span) {
    float* results = (float*)out_span.cpu;
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
    gpu::DeviceDesc device_desc = {
        .backend                     = gpu::BackendKind.VULKAN,
        .enable_validation           = true,
        .frames_in_flight            = 2,
        .texture_descriptor_capacity = TEXTURE_COUNT + CAPACITY_SLACK,
        .texture_capacity            = TEXTURE_COUNT + CAPACITY_SLACK,
        .application_name            = "bindless_stress",
    };
    gpu::Device device = gpu::create_device(&device_desc)!;
    defer (void)gpu::destroy_device(&device);

    Fleet fleet = {
        .textures = mem::new_array(gpu::TextureHandle, TEXTURE_COUNT),
        .indices  = mem::new_array(gpu::TextureIndex, TEXTURE_COUNT),
        .salts    = mem::new_array(uint, TEXTURE_COUNT),
    };
    defer {
        mem::free(fleet.salts.ptr);
        mem::free(fleet.indices.ptr);
        mem::free(fleet.textures.ptr);
    }

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::SamplerIndex sampler = gpu::create_sampler(&device, &sampler_desc)!;
    defer (void)gpu::destroy_sampler(&device, sampler);

    gpu::BufferDesc staging_desc = {
        .size        = UPLOAD_BATCH * 4,
        .usage       = { .transfer_src },
        .memory_kind = gpu::MemoryKind.STAGING,
        .debug_name  = "stress_staging",
    };
    gpu::BufferHandle staging = gpu::create_buffer(&device, &staging_desc)!;
    defer (void)gpu::destroy_buffer(&device, staging);
    gpu::GpuSpan staging_span = gpu::get_buffer_span(&device, staging)!;

    gpu::BufferDesc index_desc = {
        .size        = TEXTURE_COUNT * 4,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .debug_name  = "stress_indices",
    };
    gpu::BufferHandle index_buf = gpu::create_buffer(&device, &index_desc)!;
    defer (void)gpu::destroy_buffer(&device, index_buf);
    gpu::GpuSpan index_span = gpu::get_buffer_span(&device, index_buf)!;

    gpu::BufferDesc out_desc = {
        .size        = TEXTURE_COUNT * 16,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.READBACK,
        .debug_name  = "stress_results",
    };
    gpu::BufferHandle out_buf = gpu::create_buffer(&device, &out_desc)!;
    defer (void)gpu::destroy_buffer(&device, out_buf);
    gpu::GpuSpan out_span = gpu::get_buffer_span(&device, out_buf)!;

    gpu::ShaderDesc comp_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = VERIFY_COMP_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle shader = gpu::create_shader(&device, &comp_sd)!;
    defer (void)gpu::destroy_shader(&device, shader);
    gpu::ComputePipelineDesc pipe_desc = { .shader = shader, .push_constant_size = gpu::RootPush::size };
    gpu::PipelineHandle pipeline = gpu::create_compute_pipeline(&device, &pipe_desc)!;
    defer (void)gpu::destroy_pipeline(&device, pipeline);

    // Fill: create the fleet, then upload payloads in batches.
    Clock clk = clock::now();
    for (uint i = 0; i < TEXTURE_COUNT; i++) {
        fleet.textures[i] = create_stress_texture(&device)!;
        fleet.indices[i]  = gpu::create_texture_descriptor(&device, fleet.textures[i], null)!;
        fleet.salts[i]    = 0xAB;
    }
    NanoDuration create_time = clk.mark();

    gpu::FrameToken frame_token = gpu::begin_frame(&device)!;
    for (uint first = 0; first < TEXTURE_COUNT; first += UPLOAD_BATCH) {
        upload_slice(&device, &fleet, staging_span, first, UPLOAD_BATCH)!;
    }
    NanoDuration upload_time = clk.mark();

    dispatch_verify(
        frame:      &frame_token,
        device:     &device,
        fleet:      &fleet,
        pipeline:   pipeline,
        index_span: index_span,
        out_span:   out_span,
        sampler:    sampler,
    )!;
    NanoDuration fill_verify_time = clk.mark();
    gpu::invalidate_buffer(&device, out_buf, 0, 0)!;
    check_results(&fleet, out_span)!;
    gpu::end_frame(&frame_token)!;

    // Churn: rolling destroy/recreate slices across frames; verify every frame.
    uint cursor = 0;
    clk = clock::now();
    for (uint frame = 0; frame < CHURN_FRAMES; frame++) {
        frame_token = gpu::begin_frame(&device)!;
        for (uint i = 0; i < CHURN_SLICE; i++) {
            uint slot = (cursor + i) % TEXTURE_COUNT;
            gpu::destroy_texture_descriptor(&device, fleet.indices[slot])!;
            gpu::destroy_texture(&device, fleet.textures[slot])!;
            fleet.textures[slot] = create_stress_texture(&device)!;
            fleet.indices[slot]  = gpu::create_texture_descriptor(&device, fleet.textures[slot], null)!;
            fleet.salts[slot]    = frame;
        }
        for (uint first = cursor; first < cursor + CHURN_SLICE; first += UPLOAD_BATCH) {
            upload_slice(&device, &fleet, staging_span, first, UPLOAD_BATCH)!;
        }

        dispatch_verify(
            frame:      &frame_token,
            device:     &device,
            fleet:      &fleet,
            pipeline:   pipeline,
            index_span: index_span,
            out_span:   out_span,
            sampler:    sampler,
        )!;
        gpu::invalidate_buffer(&device, out_buf, 0, 0)!;
        check_results(&fleet, out_span)!;
        gpu::end_frame(&frame_token)!;
        cursor = (cursor + CHURN_SLICE) % TEXTURE_COUNT;
    }
    NanoDuration churn_time = clk.mark();

    for (uint i = 0; i < TEXTURE_COUNT; i++) {
        gpu::destroy_texture_descriptor(&device, fleet.indices[i])!;
        gpu::destroy_texture(&device, fleet.textures[i])!;
    }

    io::printfn("bindless_stress: %d textures, heap capacity %d", TEXTURE_COUNT, TEXTURE_COUNT + CAPACITY_SLACK);
    io::printfn("  create fleet    %.1f ms", ms(create_time));
    io::printfn("  upload payloads %.1f ms", ms(upload_time));
    io::printfn("  verify dispatch %.1f ms", ms(fill_verify_time));
    io::printfn("  churn           %.1f ms/frame (%d frames x %d slots)", ms(churn_time) / CHURN_FRAMES, CHURN_FRAMES, CHURN_SLICE);
}
