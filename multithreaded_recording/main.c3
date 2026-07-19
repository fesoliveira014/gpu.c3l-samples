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

<* Roots are precomputed in a CPU_WRITE allocation so recording measures cmd_draw. *>
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
    gpu::Queue                  queue;
    gpu::TextureHandle          target;
    gpu::PipelineHandle         pipeline;
    gpu::GpuAddress             roots_base;
    uint                        first_chunk;
    uint                        stride;
    gpu::ExecutableCommandList[CHUNKS] lists;
    uint                        list_count;
    bool                        failed;
}

fn int record_worker(void* arg) {
    WorkerArgs* args = (WorkerArgs*)arg;
    @pool_init(&allocators::LIBC_ALLOCATOR, 64 * 1024) {
        for (uint chunk = args.first_chunk; chunk < CHUNKS; chunk += args.stride) {
            gpu::CommandList? list = gpu::begin_commands(args.queue);
            if (catch list) { args.failed = true; return 1; }
            if (catch record_chunk(&list, args.target, args.pipeline, args.roots_base, chunk)) {
                (void)gpu::discard_commands(&list);
                args.failed = true;
                return 1;
            }
            gpu::ExecutableCommandList? executable = gpu::end_commands(&list);
            if (catch executable) {
                (void)gpu::discard_commands(&list);
                args.failed = true;
                return 1;
            }
            args.lists[args.list_count++] = executable;
        }
    };
    return 0;
}

fn double ms(NanoDuration d) => (double)(long)d / 1_000_000.0;

fn void? read_color_target(
    gpu::Device* device,
    gpu::Queue queue,
    gpu::TextureHandle target,
    gpu::CompletionPoint producer_completion,
    char[] out,
) {
    defer (void)gpu::wait_completion(producer_completion, ulong::max);

    gpu::AllocationDesc readback_desc = {
        .size         = out.len,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "color_readback",
    };
    gpu::GpuAllocation readback_allocation = gpu::allocate_memory(device, &readback_desc)!;
    defer (void)gpu::free_allocation(device, &readback_allocation);
    gpu::GpuSpan readback_span = gpu::get_allocation_span(device, readback_allocation)!;

    gpu::CommandList commands = gpu::begin_commands(queue)!;
    defer (void)gpu::discard_commands(&commands);
    gpu::TextureBarrier to_source = {
        .texture       = target,
        .before_stage  = gpu::Stage.COLOR_ATTACHMENT,
        .after_stage   = gpu::Stage.TRANSFER,
        .before_hazard = gpu::Hazard.COLOR_WRITE,
        .after_hazard  = gpu::Hazard.TRANSFER_READ,
        .old_layout    = gpu::TextureLayout.COLOR_ATTACHMENT,
        .new_layout    = gpu::TextureLayout.TRANSFER_SRC,
    };
    gpu::cmd_texture_barrier(&commands, &to_source)!;
    gpu::TextureBufferCopyDesc copy = { .texture = target, .dst = readback_span };
    gpu::cmd_copy_texture_to_buffer(&commands, &copy)!;
    gpu::BufferBarrier to_host = {
        .span          = readback_span,
        .before_stage  = gpu::Stage.TRANSFER,
        .after_stage   = gpu::Stage.HOST,
        .before_hazard = gpu::Hazard.TRANSFER_WRITE,
        .after_hazard  = gpu::Hazard.HOST_READ,
    };
    gpu::cmd_buffer_barrier(&commands, &to_host)!;
    gpu::TextureBarrier restore = {
        .texture       = target,
        .before_stage  = gpu::Stage.TRANSFER,
        .after_stage   = gpu::Stage.COLOR_ATTACHMENT,
        .before_hazard = gpu::Hazard.TRANSFER_READ,
        .after_hazard  = gpu::Hazard.COLOR_WRITE,
        .old_layout    = gpu::TextureLayout.TRANSFER_SRC,
        .new_layout    = gpu::TextureLayout.COLOR_ATTACHMENT,
    };
    gpu::cmd_texture_barrier(&commands, &restore)!;

    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&commands)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::CompletionPoint[1] waits = { producer_completion };
    gpu::SubmitDesc submit = {
        .command_lists    = lists[..],
        .completion_waits = waits[..],
    };
    gpu::CompletionPoint completion = gpu::submit(queue, &submit)!;
    defer (void)gpu::wait_completion(completion, ulong::max);
    gpu::wait_completion(completion, ulong::max)!;
    gpu::invalidate_mapped_span(device, readback_span)!;
    char[] mapping = gpu::get_span_mapping(device, readback_span)!;
    mem::copy(out.ptr, mapping.ptr, out.len);
}

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
fn NanoDuration? run_once(
    gpu::Device* device,
    gpu::TextureHandle target,
    gpu::PipelineHandle pipeline,
    gpu::GpuAddress roots_base,
    uint workers,
    char[] out,
    bool* target_seen,
) {
    gpu::Queue queue = gpu::get_queue(device, gpu::QueueKind.GRAPHICS)!;

    gpu::CommandList preamble = gpu::begin_commands(queue)!;
    defer (void)gpu::discard_commands(&preamble);
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
    gpu::ExecutableCommandList[1] preamble_lists = {
        gpu::end_commands(&preamble)!,
    };
    defer (void)gpu::discard_executable_commands(&preamble_lists[0]);
    gpu::SubmitDesc preamble_submit = { .command_lists = preamble_lists[..] };
    gpu::CompletionPoint preamble_completion = gpu::submit(queue, &preamble_submit)!;
    defer (void)gpu::wait_completion(preamble_completion, ulong::max);
    *target_seen = true;

    gpu::ExecutableCommandList[CHUNKS] all_lists;
    uint list_count;
    defer {
        for (uint i = 0; i < list_count; i++) {
            (void)gpu::discard_executable_commands(&all_lists[i]);
        }
    }

    Clock clk = clock::now();
    NanoDuration record_time;
    if (workers == 0) {
        for (uint chunk = 0; chunk < CHUNKS; chunk++) {
            gpu::CommandList list = gpu::begin_commands(queue)!;
            defer (void)gpu::discard_commands(&list);
            record_chunk(&list, target, pipeline, roots_base, chunk)!;
            all_lists[chunk] = gpu::end_commands(&list)!;
            list_count++;
        }
        record_time = clk.mark();
    } else {
        WorkerArgs[] wargs = mem::new_array(WorkerArgs, MAX_WORKERS);
        defer mem::free(wargs.ptr);
        Thread[MAX_WORKERS] threads;
        uint threads_created;
        uint threads_joined;
        defer {
            for (uint w = threads_joined; w < threads_created; w++) {
                (void)threads[w].join();
            }
            for (uint w = 0; w < threads_created; w++) {
                for (uint i = 0; i < wargs[w].list_count; i++) {
                    (void)gpu::discard_executable_commands(&wargs[w].lists[i]);
                }
            }
        }
        for (uint w = 0; w < workers; w++) {
            wargs[w] = {
                .queue       = queue,
                .target      = target,
                .pipeline    = pipeline,
                .roots_base  = roots_base,
                .first_chunk = w,
                .stride      = workers,
            };
            threads[w].create(&record_worker, &wargs[w])!;
            threads_created++;
        }
        for (uint w = 0; w < workers; w++) {
            threads[w].join()!;
            threads_joined++;
        }
        record_time = clk.mark();
        bool failed = false;
        for (uint w = 0; w < workers; w++) failed = failed || wargs[w].failed;
        if (failed) return gpu::INVALID_ARGUMENT~;
        // Chunk order in the submit does not affect pixels (disjoint bands),
        // but keep it deterministic anyway: chunk index = w + i*workers.
        for (uint w = 0; w < workers; w++) {
            for (uint i = 0; i < wargs[w].list_count; i++) {
                all_lists[w + i * workers] = wargs[w].lists[i];
                wargs[w].lists[i] = {};
                list_count++;
            }
        }
    }

    gpu::SubmitDesc submit = { .command_lists = all_lists[..] };
    gpu::CompletionPoint completion = gpu::submit(queue, &submit)!;

    read_color_target(
        device:              device,
        queue:               queue,
        target:              target,
        producer_completion: completion,
        out:                 out,
    )!;
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
        .application_name  = "multithreaded_recording",
    };
    gpu::Device device = gpu::create_device_from_desc(&device_desc)!;
    defer (void)gpu::destroy_device(&device);

    gpu::TextureDesc target_desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = TARGET_SIZE,
        .height     = TARGET_SIZE,
        .format     = gpu::Format.RGBA8_UNORM,
        .usage      = { .color_attach, .transfer_src },
        .access     = { .graphics },
        .debug_name = "mtrec_target",
    };
    gpu::TextureHandle target = gpu::create_texture(&device, &target_desc)!;
    defer (void)gpu::destroy_texture(&device, target);

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = QUAD_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode vert = gpu::prepare_shader_code(&vert_sd)!;
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = QUAD_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode frag = gpu::prepare_shader_code(&frag_sd)!;

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

    gpu::AllocationDesc roots_desc = {
        .size         = (usz)CHUNKS * DRAWS_PER_CHUNK * QuadRoot::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "mtrec_roots",
    };
    gpu::GpuAllocation roots_allocation = gpu::allocate_memory(&device, &roots_desc)!;
    defer (void)gpu::free_allocation(&device, &roots_allocation);
    gpu::GpuSpan roots_span = gpu::get_allocation_span(&device, roots_allocation)!;
    QuadRoot* roots = (QuadRoot*)gpu::get_span_mapping(&device, roots_span)!.ptr;
    for (uint chunk = 0; chunk < CHUNKS; chunk++) {
        for (uint draw = 0; draw < DRAWS_PER_CHUNK; draw++) {
            QuadRoot* root = &roots[(usz)chunk * DRAWS_PER_CHUNK + draw];
            root.rect  = rect_for(chunk, draw);
            root.color = color_for(chunk, draw);
        }
    }
    gpu::flush_mapped_span(&device, roots_span)!;
    gpu::GpuAddress roots_address = gpu::get_span_address(&device, roots_span)!;

    char[] serial_image = mem::new_array(char, READBACK_BYTES);
    defer mem::free(serial_image.ptr);
    char[] threaded_image = mem::new_array(char, READBACK_BYTES);
    defer mem::free(threaded_image.ptr);

    bool target_seen = false;
    NanoDuration serial_time = run_once(
        device:      &device,
        target:      target,
        pipeline:    pipeline,
        roots_base:  roots_address,
        workers:     0,
        out:         serial_image,
        target_seen: &target_seen,
    )!;
    NanoDuration threaded_time = run_once(
        device:      &device,
        target:      target,
        pipeline:    pipeline,
        roots_base:  roots_address,
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
