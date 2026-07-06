module multithreaded_recording;

import gpu;
import std::io;
import std::thread;
import std::time;
import std::core::mem;
import std::core::mem::allocator;

const char[*] QUAD_VERT_SPIRV = $embed("shaders/quad.vert.spv");
const char[*] QUAD_FRAG_SPIRV = $embed("shaders/quad.frag.spv");

const uint TARGET_SIZE = 512;
const uint CHUNKS = 32;
const uint DRAWS_PER_CHUNK = 2048;
const uint MAX_WORKERS = 8;
const usz READBACK_BYTES = (usz)TARGET_SIZE * TARGET_SIZE * 4;

<* Deterministic tint so any chunk/draw mis-wiring changes pixels. *>
fn gpu::Vec4f color_for(uint chunk, uint draw) {
    return {
        (float)((chunk * 37 + draw * 11) % 256) / 255.0f,
        (float)((chunk * 73 + draw * 29) % 256) / 255.0f,
        (float)((chunk * 151 + draw * 53) % 256) / 255.0f,
        1.0f,
    };
}

<* Draw `draw` of chunk `chunk`: a small quad inside the chunk's horizontal
   band, tiled left to right. rect = {x0, y0, x1, y1} in NDC. *>
fn gpu::Vec4f rect_for(uint chunk, uint draw) {
    float band_h = 2.0f / CHUNKS;
    float y0 = -1.0f + chunk * band_h;
    float tile_w = 2.0f / DRAWS_PER_CHUNK;
    float x0 = -1.0f + draw * tile_w;
    return { x0, y0, x0 + tile_w, y0 + band_h };
}

<* Roots are precomputed into a persistent buffer (the frame arena is 1 MiB
   fixed — gpu.c3l#28); recording is pure cmd_draw work. *>
fn void? record_chunk(gpu::CommandList* list, gpu::TextureHandle target, gpu::PipelineHandle pipeline, gpu::GpuAddress roots_base, uint chunk) {
    gpu::ColorTargetDesc[1] colors = {{
        .texture  = target,
        .load_op  = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    }};
    gpu::RenderPassDesc pass = { .colors = colors[..], .width = TARGET_SIZE, .height = TARGET_SIZE };
    gpu::cmd_begin_render_pass(list, &pass)!;
    for (uint draw = 0; draw < DRAWS_PER_CHUNK; draw++) {
        ulong index = (ulong)chunk * DRAWS_PER_CHUNK + draw;
        gpu::GpuAddress root = (gpu::GpuAddress)((ulong)roots_base + index * QuadRoot::size);
        gpu::cmd_draw(
            commands:       list,
            pipeline:       pipeline,
            vertex_root:    root,
            fragment_root:  root,
            vertex_count:   6,
            instance_count: 1,
        )!;
    }
    gpu::cmd_end_render_pass(list)!;
}

struct WorkerArgs {
    gpu::Device*                device;
    gpu::RecordingContextHandle ctx;
    gpu::TextureHandle          target;
    gpu::PipelineHandle         pipeline;
    gpu::GpuAddress             roots_base;
    uint                        first_chunk;
    uint                        stride;
    gpu::CommandList[CHUNKS]    lists;
    uint                        list_count;
    bool                        failed;
}

fn int record_worker(void* arg) {
    WorkerArgs* args = (WorkerArgs*)arg;
    @pool_init(&allocators::LIBC_ALLOCATOR, 64 * 1024) {
        for (uint chunk = args.first_chunk; chunk < CHUNKS; chunk += args.stride) {
            gpu::CommandList? list = gpu::begin_commands(args.device, gpu::QueueKind.GRAPHICS, args.ctx);
            if (catch list) { args.failed = true; return 1; }
            if (catch record_chunk(&list, args.target, args.pipeline, args.roots_base, chunk)) {
                args.failed = true;
                return 1;
            }
            if (catch gpu::end_commands(args.device, &list)) { args.failed = true; return 1; }
            args.lists[args.list_count++] = list;
        }
    };
    return 0;
}

fn double ms(NanoDuration d) => (double)(long)d / 1_000_000.0;

fn int main(String[] args) {
    if (catch err = run()) {
        io::printfn("multithreaded_recording: FAIL (%s)", err);
        return 1;
    }
    io::printn("multithreaded_recording: PASS");
    return 0;
}

<* One full run: clear preamble + CHUNKS band lists + submit + readback.
   `workers` == 0 records everything on the calling thread. Returns record
   wall time; the image lands in `out`. *>
fn NanoDuration? run_once(gpu::Device* device, gpu::TextureHandle target, gpu::PipelineHandle pipeline, gpu::GpuAddress roots_base, gpu::RecordingContextHandle[] contexts, uint workers, char[] out, bool* target_seen) {
    gpu::begin_frame(device)!;

    gpu::CommandList preamble = gpu::begin_commands(device, gpu::QueueKind.GRAPHICS)!;
    // Readback round-trips the layout back to COLOR_ATTACHMENT, so only the
    // first run needs a transition out of UNDEFINED.
    if (!*target_seen) {
        gpu::TextureBarrier to_attach = {
            .texture       = target,
            .before_stage  = gpu::Stage.HOST,
            .after_stage   = gpu::Stage.COLOR_ATTACHMENT,
            .before_hazard = gpu::Hazard.HOST_WRITE,
            .after_hazard  = gpu::Hazard.COLOR_WRITE,
            .old_layout    = gpu::TextureLayout.UNDEFINED,
            .new_layout    = gpu::TextureLayout.COLOR_ATTACHMENT,
        };
        gpu::cmd_texture_barrier(&preamble, &to_attach)!;
    }
    gpu::ColorTargetDesc[1] clear_colors = {{
        .texture  = target,
        .load_op  = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear    = { .rgba = { 0, 0, 0, 1 } },
    }};
    gpu::RenderPassDesc clear_pass = { .colors = clear_colors[..], .width = TARGET_SIZE, .height = TARGET_SIZE };
    gpu::cmd_begin_render_pass(&preamble, &clear_pass)!;
    gpu::cmd_end_render_pass(&preamble)!;
    gpu::end_commands(device, &preamble)!;
    *target_seen = true;

    gpu::CommandList[CHUNKS + 1] all_lists;
    all_lists[0] = preamble;

    Clock clk = clock::now();
    NanoDuration record_time;
    if (workers == 0) {
        for (uint chunk = 0; chunk < CHUNKS; chunk++) {
            gpu::CommandList list = gpu::begin_commands(device, gpu::QueueKind.GRAPHICS)!;
            record_chunk(&list, target, pipeline, roots_base, chunk)!;
            gpu::end_commands(device, &list)!;
            all_lists[1 + chunk] = list;
        }
        record_time = clk.mark();
    } else {
        WorkerArgs[MAX_WORKERS] wargs;
        Thread[MAX_WORKERS] threads;
        for (uint w = 0; w < workers; w++) {
            wargs[w] = {
                .device      = device,
                .ctx         = contexts[w],
                .target      = target,
                .pipeline    = pipeline,
                .roots_base  = roots_base,
                .first_chunk = w,
                .stride      = workers,
            };
            threads[w].create(&record_worker, &wargs[w])!;
        }
        for (uint w = 0; w < workers; w++) threads[w].join()!;
        record_time = clk.mark();
        for (uint w = 0; w < workers; w++) {
            if (wargs[w].failed) return gpu::INVALID_ARGUMENT~;
        }
        // Chunk order in the submit does not affect pixels (disjoint bands),
        // but keep it deterministic anyway: chunk index = w + i*workers.
        for (uint w = 0; w < workers; w++) {
            for (uint i = 0; i < wargs[w].list_count; i++) {
                all_lists[1 + w + i * workers] = wargs[w].lists[i];
            }
        }
    }

    gpu::SubmitDesc submit = { .command_lists = all_lists[..] };
    gpu::submit(device, &submit)!;
    gpu::wait_queue_idle(device, gpu::QueueKind.GRAPHICS)!;

    gpu::readback_texture_data(
        device:      device,
        src:         target,
        mip:         0,
        out_data:    out,
        from_stage:  gpu::Stage.COLOR_ATTACHMENT,
        from_hazard: gpu::Hazard.COLOR_WRITE,
        from_layout: gpu::TextureLayout.COLOR_ATTACHMENT,
    )!;
    gpu::end_frame(device)!;
    return record_time;
}

struct RunResult {
    NanoDuration serial;
    NanoDuration threaded;
}

<* Full serial + threaded pass on one device; faults unless the two
   readbacks are byte-identical. *>
fn RunResult? run_on_device(bool validation) {
    gpu::DeviceDesc device_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = validation,
        .frames_in_flight  = 2,
        .application_name  = "multithreaded_recording",
    };
    gpu::Device device = gpu::create_device(&device_desc)!;
    defer (void)gpu::destroy_device(&device);

    gpu::TextureDesc target_desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = TARGET_SIZE,
        .height     = TARGET_SIZE,
        .format     = gpu::Format.RGBA8_UNORM,
        .usage      = { .color_attach, .transfer_src },
        .debug_name = "mtrec_target",
    };
    gpu::TextureHandle target = gpu::create_texture(&device, &target_desc)!;
    defer (void)gpu::destroy_texture(&device, target);

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = QUAD_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle vert = gpu::create_shader(&device, &vert_sd)!;
    defer (void)gpu::destroy_shader(&device, vert);
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = QUAD_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle frag = gpu::create_shader(&device, &frag_sd)!;
    defer (void)gpu::destroy_shader(&device, frag);

    gpu::Format[1] color_formats = { gpu::Format.RGBA8_UNORM };
    gpu::GraphicsPipelineDesc pipe_desc = {
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .color_formats   = color_formats[..],
        .debug_name      = "mtrec_quads",
    };
    gpu::PipelineHandle pipeline = gpu::create_graphics_pipeline(&device, &pipe_desc)!;
    defer (void)gpu::destroy_pipeline(&device, pipeline);

    uint workers = MAX_WORKERS;
    gpu::RecordingContextHandle[MAX_WORKERS] contexts;
    for (uint w = 0; w < workers; w++) contexts[w] = gpu::create_recording_context(&device)!;
    defer {
        for (uint w = 0; w < workers; w++) (void)gpu::destroy_recording_context(&device, contexts[w]);
    }

    gpu::BufferDesc roots_desc = {
        .size        = (usz)CHUNKS * DRAWS_PER_CHUNK * QuadRoot::size,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .debug_name  = "mtrec_roots",
    };
    gpu::BufferHandle roots_buf = gpu::create_buffer(&device, &roots_desc)!;
    defer (void)gpu::destroy_buffer(&device, roots_buf);
    gpu::GpuSpan roots_span = gpu::get_buffer_span(&device, roots_buf)!;
    QuadRoot* roots = (QuadRoot*)roots_span.cpu;
    for (uint chunk = 0; chunk < CHUNKS; chunk++) {
        for (uint draw = 0; draw < DRAWS_PER_CHUNK; draw++) {
            QuadRoot* root = &roots[(usz)chunk * DRAWS_PER_CHUNK + draw];
            root.rect  = rect_for(chunk, draw);
            root.color = color_for(chunk, draw);
        }
    }
    gpu::flush_buffer(&device, roots_buf, 0, 0)!;

    char[] serial_image = mem::new_array(char, READBACK_BYTES);
    defer mem::free(serial_image.ptr);
    char[] threaded_image = mem::new_array(char, READBACK_BYTES);
    defer mem::free(threaded_image.ptr);

    bool target_seen = false;
    NanoDuration serial_time = run_once(
        device:      &device,
        target:      target,
        pipeline:    pipeline,
        roots_base:  roots_span.gpu,
        contexts:    contexts[..],
        workers:     0,
        out:         serial_image,
        target_seen: &target_seen,
    )!;
    NanoDuration threaded_time = run_once(
        device:      &device,
        target:      target,
        pipeline:    pipeline,
        roots_base:  roots_span.gpu,
        contexts:    contexts[..],
        workers:     workers,
        out:         threaded_image,
        target_seen: &target_seen,
    )!;

    if (!mem::equals(serial_image, threaded_image)) {
        io::printn("multithreaded_recording: image mismatch between serial and threaded runs");
        return gpu::INVALID_ARGUMENT~;
    }
    return { .serial = serial_time, .threaded = threaded_time };
}

fn void? run() {
    // Gate: correctness under validation. The validation layer locks every
    // vkCmd*, so its timings say nothing about scaling.
    run_on_device(true)!;
    // Advisory timing without validation — real recording scaling.
    RunResult timed = run_on_device(false)!;

    io::printfn("multithreaded_recording: %d lists x %d draws, %d workers", CHUNKS, DRAWS_PER_CHUNK, MAX_WORKERS);
    io::printfn("  serial record   %.2f ms", ms(timed.serial));
    io::printfn("  threaded record %.2f ms", ms(timed.threaded));
    io::printfn("  speedup         %.2fx (advisory, validation off)", ms(timed.serial) / ms(timed.threaded));
    io::printn("  readback: byte-identical (both devices)");
}
