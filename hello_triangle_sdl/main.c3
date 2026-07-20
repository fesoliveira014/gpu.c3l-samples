module hello_triangle_sdl;

import gpu;
import sample_args;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;

const char[*] TRIANGLE_VERT_SPIRV = $embed("../offscreen_triangle/shaders/offscreen.vert.spv");
const char[*] TRIANGLE_FRAG_SPIRV = $embed("../offscreen_triangle/shaders/offscreen.frag.spv");

const uint TEX_SIZE = 16;
const usz UPLOAD_BYTES_PER_SLOT = 64;

struct FrameWork {
    gpu::Device*                 device;
    sample_window::SampleWindow* window;
    gpu::SwapchainHandle         swapchain;
    gpu::SwapchainInfo*          swapchain_info;
    gpu::PipelineHandle          pipeline;
    gpu::TextureHandle           checker;
    gpu::TextureIndex            tex_index;
    gpu::SamplerIndex            smp_index;
    gpu::GpuSpan                 staging_span;
    sample_frame_upload::FrameUploadRing* upload_ring;
    sample_args::Options*        options;
    bool*                        checker_uploaded;
    gpu::CompletionPoint*         last_graphics;
    long                         frame;
    bool                         rendered;
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("hello_triangle_sdl: FAIL (%s)", err);
        return 1;
    }
    io::printn("hello_triangle_sdl: PASS");
    return 0;
}

fn void? render_frame(FrameWork* ctx) {
    gpu::AcquiredImage? acquired = gpu::acquire_next_image(ctx.device, ctx.swapchain);
    if (catch err = acquired) {
        if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
        if (err == gpu::SWAPCHAIN_OUT_OF_DATE) *ctx.swapchain_info = sample_window::recover_swapchain(ctx.device, ctx.swapchain, ctx.window)!;
        return;
    }

    sample_frame_upload::FrameUploadBatch upload_batch =
        sample_frame_upload::begin_frame_upload(ctx.upload_ring)!;
    defer catch {
        if (upload_batch.ring != null) {
            (void)sample_frame_upload::cancel_frame_upload(&upload_batch);
        }
    };

    if (ctx.frame == 0) {
        // Swapchain-owned images must reject destroy_texture.
        fault owned_fault = @catch(gpu::destroy_texture(ctx.device, acquired.texture));
        if (owned_fault != gpu::INVALID_ARGUMENT) return gpu::INVALID_RESOURCE_STATE~;
    }

    gpu::Queue graphics_queue = gpu::get_queue(ctx.device, gpu::QueueKind.GRAPHICS)!;

    gpu::CommandList cmd = gpu::begin_commands(graphics_queue)!;
    defer (void)gpu::discard_commands(&cmd);

    if (!*ctx.checker_uploaded) {
        gpu::TextureBarrier to_dst = gpu::texture_transition(
            texture: ctx.checker,
            before:  gpu::TextureUse.UNDEFINED,
            after:   gpu::TextureUse.TRANSFER_DESTINATION,
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_dst)!;
        gpu::BufferTextureCopyDesc upload = { .src = ctx.staging_span, .texture = ctx.checker };
        gpu::cmd_copy_buffer_to_texture(&cmd, &upload)!;
        gpu::TextureBarrier to_read = gpu::texture_transition(
            texture: ctx.checker,
            before:  gpu::TextureUse.TRANSFER_DESTINATION,
            after:   gpu::TextureUse.SAMPLED_FRAGMENT,
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_read)!;
        *ctx.checker_uploaded = true;
    }

    gpu::TextureUse swapchain_before;
    switch (acquired.prior_use) {
        case gpu::TextureUse.UNDEFINED:
            swapchain_before = gpu::TextureUse.UNDEFINED;
        case gpu::TextureUse.PRESENT:
            swapchain_before = gpu::TextureUse.PRESENT;
        default:
            return gpu::INVALID_RESOURCE_STATE~;
    }
    gpu::TextureBarrier to_attach = gpu::texture_transition(
        texture: acquired.texture,
        before:  swapchain_before,
        after:   gpu::TextureUse.COLOR_ATTACHMENT,
    )!;
    gpu::cmd_texture_barrier(&cmd, &to_attach)!;

    float pulse = (float)(ctx.frame % 120) / 120.0f * 0.15f;
    gpu::GpuSpan verts_span = sample_frame_upload::alloc_frame_upload(
        batch:     &upload_batch,
        size:      3 * 16,
        alignment: 16,
    )!;
    float* verts = (float*)gpu::get_span_mapping(ctx.device, verts_span)!.ptr;
    float[12] vertex_data = {
        -0.8f, -0.8f, 0.0f, 0.0f,
         0.8f, -0.8f, 1.0f, 0.0f,
         0.0f,  0.8f, 0.5f, 1.0f,
    };
    for (uint i = 0; i < 12; i++) verts[i] = vertex_data[i];

    gpu::GpuSpan frag_span = sample_frame_upload::alloc_frame_upload(
        batch:     &upload_batch,
        size:      FragRoot::size,
        alignment: 16,
    )!;
    FragRoot* frag_root = (FragRoot*)gpu::get_span_mapping(ctx.device, frag_span)!.ptr;
    frag_root.texture_index = ctx.tex_index;
    frag_root.sampler_index = ctx.smp_index;

    gpu::ColorTargetDesc[1] colors = {{
        .texture = acquired.texture,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .rgba = { 0.05f + pulse, 0.05f, 0.12f, 1.0f } },
    }};
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .width  = ctx.swapchain_info.width,
        .height = ctx.swapchain_info.height,
    };
    gpu::cmd_bind_pipeline(&cmd, ctx.pipeline)!;
    gpu::cmd_begin_render_pass(&cmd, &pass)!;
    gpu::DepthState depth_state = {};
    gpu::cmd_set_depth_state(&cmd, &depth_state)!;
    gpu::cmd_draw(
        commands:       &cmd,
        vertex_root:    gpu::get_span_address(ctx.device, verts_span)!,
        fragment_root:  gpu::get_span_address(ctx.device, frag_span)!,
        vertex_count:   3,
        instance_count: 1,
    )!;
    gpu::cmd_end_render_pass(&cmd)!;

    gpu::TextureBarrier to_present = gpu::texture_transition(
        texture: acquired.texture,
        before:  gpu::TextureUse.COLOR_ATTACHMENT,
        after:   gpu::TextureUse.PRESENT,
    )!;
    gpu::cmd_texture_barrier(&cmd, &to_present)!;

    sample_frame_upload::flush_frame_upload(&upload_batch)!;
    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = {
        .command_lists = lists[..],
        .readiness     = acquired.readiness,
    };
    *ctx.last_graphics = gpu::submit(graphics_queue, &submit)!;
    sample_frame_upload::retire_frame_upload(&upload_batch, *ctx.last_graphics)!;

    if (ctx.options.capture_frame(ctx.frame)) {
        sample_capture::capture_texture_png(
            device:              ctx.device,
            producer_completion: *ctx.last_graphics,
            queue_kind:          gpu::QueueKind.GRAPHICS,
            src:                 acquired.texture,
            width:       ctx.swapchain_info.width,
            height:      ctx.swapchain_info.height,
            format:      ctx.swapchain_info.format,
            from_use:    gpu::TextureUse.PRESENT,
            path:        ctx.options.screenshot_path,
        )!;
    }

    if (catch err = sample_window::present_when_ready(ctx.device, &acquired, *ctx.last_graphics)) {
        if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
        *ctx.swapchain_info = sample_window::recover_swapchain(ctx.device, ctx.swapchain, ctx.window)!;
    }

    ctx.rendered = true;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l hello triangle", 800, 600)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::RuntimeDesc runtime_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .application_name  = "hello_triangle_sdl",
    };
    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer (void)gpu::destroy_runtime(&runtime);

    gpu::Surface surface = sample_window::create_surface(&runtime, &window)!;
    defer (void)gpu::destroy_surface(&surface);

    gpu::Device device = sample_window::create_presentation_device(&runtime, &surface)!;
    defer (void)gpu::destroy_device(&device);

    gpu::QueueRoles upload_access = { .graphics };
    sample_frame_upload::FrameUploadRing upload_ring =
        sample_frame_upload::create_frame_upload_ring(
            device:        &device,
            slot_capacity: UPLOAD_BYTES_PER_SLOT,
            access:        upload_access,
            debug_name:    "hello_triangle_frame_upload",
        )!;
    defer (void)sample_frame_upload::destroy_frame_upload_ring(&upload_ring);

    uint width;
    uint height;
    sample_window::pixel_size(&window, &width, &height);
    gpu::SwapchainDesc swapchain_desc = {
        .width        = width,
        .height       = height,
        .preferred_format = gpu::Format.BGRA8_UNORM,
        .present_mode = options.vsync ? gpu::PresentMode.FIFO : gpu::PresentMode.MAILBOX,
        .srgb         = false,
        .debug_name   = "hello_triangle_swapchain",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)sample_window::destroy_swapchain_when_ready(&device, swapchain);

    gpu::TextureDesc tex_desc = {
        .dimension = gpu::TextureDimension.TEX_2D,
        .width     = TEX_SIZE,
        .height    = TEX_SIZE,
        .format    = gpu::Format.RGBA8_UNORM,
        .usage     = { .sampled, .transfer_dst },
        .access     = { .graphics },
    };
    gpu::TextureHandle checker = gpu::create_texture(&device, &tex_desc)!;
    defer (void)gpu::destroy_texture(&device, checker);
    gpu::TextureView tex_view = gpu::create_texture_view(&device, checker, null)!;
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

    gpu::AllocationDesc staging_desc = {
        .size         = TEX_SIZE * TEX_SIZE * 4,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
    };
    gpu::GpuAllocation staging = gpu::allocate_memory(&device, &staging_desc)!;
    defer (void)gpu::free_allocation(&device, &staging);
    gpu::GpuSpan staging_span = gpu::get_allocation_span(&device, staging)!;
    char* texels = (char*)gpu::get_span_mapping(&device, staging_span)!.ptr;
    for (uint y = 0; y < TEX_SIZE; y++) {
        for (uint x = 0; x < TEX_SIZE; x++) {
            bool checkered = ((x / 4) + (y / 4)) % 2 == 0;
            char* texel = &texels[(y * TEX_SIZE + x) * 4];
            texel[0] = checkered ? (char)230 : (char)40;
            texel[1] = checkered ? (char)180 : (char)90;
            texel[2] = checkered ? (char)60 : (char)200;
            texel[3] = (char)255;
        }
    }
    gpu::flush_mapped_span(&device, staging_span)!;

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = TRIANGLE_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode vert = gpu::prepare_shader_code(&vert_sd)!;
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = TRIANGLE_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode frag = gpu::prepare_shader_code(&frag_sd)!;

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::GraphicsPipelineDesc pipe_desc = {
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .color_formats   = color_formats[..],
        .debug_name      = "hello_triangle",
    };
    gpu::PipelineHandle pipeline;
    bool pipeline_valid = false;
    if (!swapchain_info.dormant) {
        pipeline = gpu::create_graphics_pipeline(&device, &pipe_desc)!;
        pipeline_valid = true;
    }
    defer {
        if (pipeline_valid) (void)gpu::destroy_pipeline(&device, pipeline);
    }

    bool checker_uploaded = false;
    long frame = 0;
    bool running = true;
    gpu::CompletionPoint last_graphics;
    defer {
        if (last_graphics.is_valid()) (void)gpu::wait_completion(last_graphics, ulong::max);
    }
    while (running) {
        sample_window::WindowEvents events = sample_window::pump_events(&window);
        if (events.quit) break;
        if (events.resized) {
            swapchain_info = sample_window::recover_swapchain(&device, swapchain, &window)!;
        }
        if (swapchain_info.dormant) {
            sample_window::throttle_dormant();
            continue;
        }
        if (!pipeline_valid || color_formats[0] != swapchain_info.format) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
            if (pipeline_valid) gpu::destroy_pipeline(&device, pipeline)!;
            pipeline_valid = false;
            color_formats[0] = swapchain_info.format;
            pipeline = gpu::create_graphics_pipeline(&device, &pipe_desc)!;
            pipeline_valid = true;
        }

        FrameWork work = {
            .device           = &device,
            .window           = &window,
            .swapchain        = swapchain,
            .swapchain_info   = &swapchain_info,
            .pipeline         = pipeline,
            .checker          = checker,
            .tex_index        = tex_index,
            .smp_index        = smp_index,
            .staging_span     = staging_span,
            .upload_ring      = &upload_ring,
            .options          = &options,
            .checker_uploaded = &checker_uploaded,
            .last_graphics    = &last_graphics,
            .frame            = frame,
        };
        if (catch err = render_frame(&work)) return err~;
        if (!work.rendered) continue;

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

    if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
}
