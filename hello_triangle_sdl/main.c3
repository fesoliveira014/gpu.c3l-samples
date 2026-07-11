module hello_triangle_sdl;

import gpu;
import sample_args;
import sample_capture;
import sample_window;
import std::io;

const char[*] TRIANGLE_VERT_SPIRV = $embed("../offscreen_triangle/shaders/offscreen.vert.spv");
const char[*] TRIANGLE_FRAG_SPIRV = $embed("../offscreen_triangle/shaders/offscreen.frag.spv");

const uint TEX_SIZE = 16;

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
    sample_args::Options*        options;
    bool*                        checker_uploaded;
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

fn void? run_frame(gpu::FrameToken* frame, FrameWork* ctx) {
    gpu::AcquiredImage? acquired = gpu::acquire_next_image(ctx.device, ctx.swapchain);
    if (catch err = acquired) {
        if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
        if (err == gpu::SWAPCHAIN_OUT_OF_DATE) *ctx.swapchain_info = sample_window::recover_swapchain(ctx.device, ctx.swapchain, ctx.window)!;
        return;
    }

    if (ctx.frame == 0) {
        // Swapchain-owned images must reject destroy_texture.
        fault owned_fault = @catch(gpu::destroy_texture(ctx.device, acquired.texture));
        if (owned_fault != gpu::INVALID_ARGUMENT) return gpu::INVALID_RESOURCE_STATE~;
    }

    gpu::CommandList cmd = gpu::begin_commands(ctx.device, gpu::QueueKind.GRAPHICS)!;

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
    switch (acquired.prior_layout) {
        case gpu::TextureLayout.UNDEFINED:
            swapchain_before = gpu::TextureUse.UNDEFINED;
        case gpu::TextureLayout.PRESENT:
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
    gpu::GpuSpan verts_span = gpu::alloc_frame_span(frame, 3 * 16, 16)!;
    float* verts = (float*)verts_span.cpu;
    float[12] vertex_data = {
        -0.8f, -0.8f, 0.0f, 0.0f,
         0.8f, -0.8f, 1.0f, 0.0f,
         0.0f,  0.8f, 0.5f, 1.0f,
    };
    for (uint i = 0; i < 12; i++) verts[i] = vertex_data[i];

    gpu::GpuSpan frag_span = gpu::alloc_frame_span(frame, FragRoot::size, 16)!;
    FragRoot* frag_root = (FragRoot*)frag_span.cpu;
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
    gpu::cmd_begin_render_pass(&cmd, &pass)!;
    gpu::cmd_draw(
        commands:       &cmd,
        pipeline:       ctx.pipeline,
        vertex_root:    verts_span.gpu,
        fragment_root:  frag_span.gpu,
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

    gpu::end_commands(&cmd)!;
    gpu::CommandList[1] lists = { cmd };
    gpu::SubmitDesc submit = { .command_lists = lists[..], .swapchain = ctx.swapchain };
    gpu::submit(ctx.device, &submit)!;

    if (ctx.options.capture_frame(ctx.frame)) {
        sample_capture::capture_texture_png(
            device:      ctx.device,
            src:         acquired.texture,
            width:       ctx.swapchain_info.width,
            height:      ctx.swapchain_info.height,
            format:      ctx.swapchain_info.format,
            from_stage:  gpu::Stage.PRESENT,
            from_hazard: gpu::Hazard.PRESENT_READ,
            from_layout: gpu::TextureLayout.PRESENT,
            path:        ctx.options.screenshot_path,
        )!;
    }

    gpu::PresentDesc present_desc = { .swapchain = ctx.swapchain };
    if (catch err = gpu::present(ctx.device, &present_desc)) {
        if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
        *ctx.swapchain_info = sample_window::recover_swapchain(ctx.device, ctx.swapchain, ctx.window)!;
    }

    ctx.rendered = true;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l hello triangle", 800, 600)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::DeviceDesc device_desc = {
        .backend             = gpu::BackendKind.VULKAN,
        .enable_validation   = true,
        .enable_presentation = true,
        .frames_in_flight    = 2,
        .application_name    = "hello_triangle_sdl",
    };
    gpu::Device device = gpu::create_device(&device_desc)!;
    defer (void)gpu::destroy_device(&device);

    gpu::SurfaceDesc surface = sample_window::surface_desc_for(&window)!;
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
    defer (void)gpu::destroy_swapchain(&device, swapchain);

    gpu::TextureDesc tex_desc = {
        .dimension = gpu::TextureDimension.TEX_2D,
        .width     = TEX_SIZE,
        .height    = TEX_SIZE,
        .format    = gpu::Format.RGBA8_UNORM,
        .usage     = { .sampled, .transfer_dst },
    };
    gpu::TextureHandle checker = gpu::create_texture(&device, &tex_desc)!;
    defer (void)gpu::destroy_texture(&device, checker);
    gpu::TextureIndex tex_index = gpu::create_texture_descriptor(&device, checker, null)!;
    defer (void)gpu::destroy_texture_descriptor(&device, tex_index);

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::SamplerIndex smp_index = gpu::create_sampler(&device, &sampler_desc)!;
    defer (void)gpu::destroy_sampler(&device, smp_index);

    gpu::BufferDesc staging_desc = {
        .size = TEX_SIZE * TEX_SIZE * 4, .usage = { .transfer_src }, .memory_kind = gpu::MemoryKind.STAGING,
    };
    gpu::BufferHandle staging = gpu::create_buffer(&device, &staging_desc)!;
    defer (void)gpu::destroy_buffer(&device, staging);
    gpu::GpuSpan staging_span = gpu::get_buffer_span(&device, staging)!;
    char* texels = (char*)staging_span.cpu;
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
    gpu::flush_buffer(&device, staging, 0, 0)!;

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = TRIANGLE_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle vert = gpu::create_shader(&device, &vert_sd)!;
    defer (void)gpu::destroy_shader(&device, vert);
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = TRIANGLE_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle frag = gpu::create_shader(&device, &frag_sd)!;
    defer (void)gpu::destroy_shader(&device, frag);

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
    gpu::FrameToken retry_frame;
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
            gpu::wait_queue_idle(&device, gpu::QueueKind.GRAPHICS)!;
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
            .options          = &options,
            .checker_uploaded = &checker_uploaded,
            .frame            = frame,
        };
        fault frame_fault = @catch(gpu::@with_frame(&retry_frame, &device, run_frame, &work));
        if (frame_fault) {
            if (retry_frame.device != null) gpu::end_frame(&retry_frame)!;
            return frame_fault~;
        }
        if (!work.rendered) continue;

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

    gpu::wait_queue_idle(&device, gpu::QueueKind.GRAPHICS)!;
}
