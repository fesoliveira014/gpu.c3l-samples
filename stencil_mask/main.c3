module stencil_mask;

import gpu;
import gpu::util;
import sample_args;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;

const char[*] FULLSCREEN_VERT_SPIRV = $embed("shaders/fullscreen.vert.spv");
const char[*] STAR_VERT_SPIRV       = $embed("shaders/star.vert.spv");
const char[*] MASK_FRAG_SPIRV       = $embed("shaders/mask.frag.spv");
const char[*] FILL_FRAG_SPIRV       = $embed("shaders/fill.frag.spv");
const char[*] OUTLINE_FRAG_SPIRV    = $embed("shaders/outline.frag.spv");

const uint MASK_ID = 1;
const usz  UPLOAD_BYTES_PER_SLOT = 2 * MaskRoot::size;
const float MIN_COVERAGE = 0.05f;
const float MAX_COVERAGE = 0.60f;

<* The depth-stencil target, its attachment view, and its stencil-aspect
   sampled view. Recreated with the swapchain extent. *>
struct StencilTarget {
    gpu::TextureDesc         desc;
    gpu::TextureHandle       texture;
    gpu::AttachmentViewHandle attachment;
    gpu::TextureView         stencil_view;
    bool                     valid;
    bool                     fresh;
}

struct Pipelines {
    gpu::PipelineHandle mask;
    gpu::PipelineHandle fill;
    gpu::PipelineHandle outline;
    bool                valid;
}

fn StencilTarget? create_stencil_target(gpu::Device* device, gpu::Format format, uint width, uint height) {
    StencilTarget target = {
        .desc = {
            .width      = width,
            .height     = height,
            .format     = format,
            .usage      = { .depth_attach, .sampled, .transfer_src },
            .access     = { .graphics },
            .debug_name = "stencil_mask_depth_stencil",
        },
    };
    target.texture = gpu::create_texture(device, &target.desc)!;
    defer catch (void)gpu::destroy_texture(device, target.texture);
    gpu::AttachmentViewDesc attachment_desc = { .texture = target.texture };
    target.attachment = gpu::create_attachment_view(device, &attachment_desc)!;
    defer catch (void)gpu::destroy_attachment_view(device, target.attachment);
    gpu::TextureViewDesc stencil_desc = { .aspect = gpu::TextureAspect.STENCIL };
    target.stencil_view = gpu::create_texture_view(device, target.texture, &stencil_desc)!;
    target.valid = true;
    target.fresh = true;
    return target;
}

fn void destroy_stencil_target(gpu::Device* device, StencilTarget* target) {
    if (!target.valid) return;
    (void)gpu::destroy_texture_view(device, target.stencil_view);
    (void)gpu::destroy_attachment_view(device, target.attachment);
    (void)gpu::destroy_texture(device, target.texture);
    target.valid = false;
}

fn gpu::PipelineHandle? create_pipeline(
    gpu::Device* device,
    char[] vertex_spirv,
    char[] fragment_spirv,
    gpu::Format[] color_formats,
    gpu::Format depth_format,
    ZString debug_name,
) {
    gpu::GraphicsPipelineDesc desc = {
        .vertex_shader   = { .spirv = vertex_spirv, .entry_point = "main" },
        .fragment_shader = { .spirv = fragment_spirv, .entry_point = "main" },
        .color_formats   = color_formats,
        .depth_format    = depth_format,
        .debug_name      = debug_name,
    };
    return gpu::create_graphics_pipeline(device, &desc);
}

fn Pipelines? create_pipelines(gpu::Device* device, gpu::Format[] color_formats, gpu::Format depth_format) {
    Pipelines pipelines;
    pipelines.mask = create_pipeline(
        device:          device,
        vertex_spirv:    STAR_VERT_SPIRV[..],
        fragment_spirv:  MASK_FRAG_SPIRV[..],
        color_formats:   color_formats,
        depth_format:    depth_format,
        debug_name:      "stencil_mask_write_id",
    )!;
    defer catch (void)gpu::destroy_pipeline(device, pipelines.mask);
    pipelines.fill = create_pipeline(
        device:          device,
        vertex_spirv:    FULLSCREEN_VERT_SPIRV[..],
        fragment_spirv:  FILL_FRAG_SPIRV[..],
        color_formats:   color_formats,
        depth_format:    depth_format,
        debug_name:      "stencil_mask_fill",
    )!;
    defer catch (void)gpu::destroy_pipeline(device, pipelines.fill);
    pipelines.outline = create_pipeline(
        device:          device,
        vertex_spirv:    FULLSCREEN_VERT_SPIRV[..],
        fragment_spirv:  OUTLINE_FRAG_SPIRV[..],
        color_formats:   color_formats,
        depth_format:    gpu::Format.UNDEFINED,
        debug_name:      "stencil_mask_outline",
    )!;
    pipelines.valid = true;
    return pipelines;
}

fn void destroy_pipelines(gpu::Device* device, Pipelines* pipelines) {
    if (!pipelines.valid) return;
    (void)gpu::destroy_pipeline(device, pipelines.outline);
    (void)gpu::destroy_pipeline(device, pipelines.fill);
    (void)gpu::destroy_pipeline(device, pipelines.mask);
    pipelines.valid = false;
}

fn gpu::GraphicsState stencil_state(gpu::GraphicsState base, gpu::StencilFaceState face) {
    base.stencil = { .test_enable = true, .front = face, .back = face };
    return base;
}

<* Copy the stencil plane to the host after `producer` completes and count the
   texels holding MASK_ID. *>
fn usz? count_masked_texels(
    gpu::CommandAllocator* allocator,
    gpu::CompletionPoint producer,
    StencilTarget* target,
) {
    gpu::Device* device = &allocator.device;
    gpu::wait_completion(producer)!;
    usz stencil_bytes = gpu::texture_mip_aspect_bytes(&target.desc, 0, gpu::TextureAspect.STENCIL)!;
    gpu::AllocationDesc readback_desc = {
        .size         = stencil_bytes,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "stencil_mask_readback",
    };
    gpu::GpuAllocation readback = gpu::allocate_memory(device, &readback_desc)!;
    defer (void)gpu::free_allocation(device, &readback);
    gpu::GpuSpan readback_span = gpu::get_allocation_span(device, readback)!;

    gpu::TextureState sampled = gpu::sampled_at({ .fragment_shader });
    gpu::TextureState transfer = {
        .layout = gpu::TextureLayout.TRANSFER_SOURCE,
        .stages = { .transfer },
        .access = { .read },
    };
    gpu::CommandList cmd = gpu::begin_commands(allocator)!;
    defer (void)gpu::discard_commands(&cmd);
    gpu::TextureBarrier to_src = gpu::texture_transition(target.texture, sampled, transfer)!;
    gpu::cmd_texture_barrier(&cmd, &to_src)!;
    gpu::TextureBufferCopyDesc copy = {
        .texture = target.texture,
        .dst     = readback_span,
        .aspect  = gpu::TextureAspect.STENCIL,
    };
    gpu::cmd_copy_texture_to_buffer(&cmd, &copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&cmd, &host_read)!;
    gpu::TextureBarrier restore = gpu::texture_transition(target.texture, transfer, sampled)!;
    gpu::cmd_texture_barrier(&cmd, &restore)!;
    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::wait_completion(gpu::submit(allocator.queue, &submit)!)!;
    gpu::invalidate_mapped_span(device, readback_span)!;

    char[] stencil = gpu::get_span_mapping(device, readback_span)!;
    usz masked = 0;
    foreach (value : stencil) if (value == (char)MASK_ID) masked++;
    return masked;
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("stencil_mask: FAIL (%s)", err);
        return 1;
    }
    io::printn("stencil_mask: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l stencil mask", 800, 600)!;
    defer sample_window::destroy_sample_window(&window);

    util::DeviceContextDesc desc = util::default_device_context_desc();
    desc.runtime.enable_vulkan_validation = true;
    desc.runtime.application_name = "stencil_mask";
    desc.create_surface = &sample_window::surface_factory;
    desc.surface_user_data = &window;
    sample_window::pixel_size(&window, &desc.swapchain.width, &desc.swapchain.height);
    desc.swapchain.present_mode = options.vsync ? gpu::PresentMode.FIFO : gpu::PresentMode.MAILBOX;
    desc.swapchain.debug_name = "stencil_mask_swapchain";
    util::DeviceContext context = util::create_device_context(&desc)!;
    defer util::destroy_device_context(&context);
    defer (void)gpu::wait_swapchain_presentations(&context.device, context.swapchain);
    gpu::Device* device = &context.device;
    gpu::SwapchainHandle swapchain = context.swapchain;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(device, swapchain)!;
    gpu::Format depth_stencil_format = gpu::get_device_caps(device)!.depth_stencil_format;
    if (depth_stencil_format == gpu::Format.UNDEFINED) return gpu::UNSUPPORTED_FEATURE~;
    io::printfn("stencil_mask: depth-stencil format %s", depth_stencil_format);

    gpu::QueueRoles upload_access = { .graphics };
    sample_frame_upload::FrameUploadRing upload_ring =
        sample_frame_upload::create_frame_upload_ring(
            device:        device,
            slot_capacity: UPLOAD_BYTES_PER_SLOT,
            access:        upload_access,
            debug_name:    "stencil_mask_frame_upload",
        )!;
    defer (void)sample_frame_upload::destroy_frame_upload_ring(&upload_ring);

    StencilTarget target;
    defer destroy_stencil_target(device, &target);
    gpu::Format[1] color_formats = { swapchain_info.format };
    Pipelines pipelines;
    defer destroy_pipelines(device, &pipelines);
    if (!swapchain_info.dormant) {
        target = create_stencil_target(
            device: device,
            format: depth_stencil_format,
            width:  swapchain_info.width,
            height: swapchain_info.height,
        )!;
        pipelines = create_pipelines(device, color_formats[..], depth_stencil_format)!;
    }

    gpu::ColorTargetState[1] write_color = { gpu::color_blend_disabled() };
    gpu::ColorTargetState[1] no_color = { gpu::color_blend_disabled({}) };
    gpu::ColorTargetState[1] overlay_color = { gpu::alpha_blend() };
    gpu::StencilFaceState write_id = gpu::stencil_face(gpu::CompareOp.ALWAYS, gpu::StencilOp.REPLACE, MASK_ID);
    gpu::StencilFaceState inside   = gpu::stencil_face(gpu::CompareOp.EQUAL, gpu::StencilOp.KEEP, MASK_ID);
    gpu::StencilFaceState outside  = gpu::stencil_face(gpu::CompareOp.NOT_EQUAL, gpu::StencilOp.KEEP, MASK_ID);

    bool verified = false;
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
            swapchain_info = sample_window::recover_swapchain(device, swapchain, &window)!;
        }
        if (swapchain_info.dormant) {
            sample_window::throttle_dormant();
            continue;
        }

        bool pipelines_changed = !pipelines.valid || color_formats[0] != swapchain_info.format;
        bool target_changed = !target.valid
            || target.desc.width != swapchain_info.width
            || target.desc.height != swapchain_info.height;
        if (pipelines_changed || target_changed) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
        }
        if (pipelines_changed) {
            destroy_pipelines(device, &pipelines);
            color_formats[0] = swapchain_info.format;
            pipelines = create_pipelines(device, color_formats[..], depth_stencil_format)!;
        }
        if (target_changed) {
            destroy_stencil_target(device, &target);
            target = create_stencil_target(
                device: device,
                format: depth_stencil_format,
                width:  swapchain_info.width,
                height: swapchain_info.height,
            )!;
        }

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(
            device:     device,
            swapchain:  swapchain,
            timeout_ns: sample_window::FRAME_ACQUIRE_TIMEOUT_NS,
        );
        if (catch err = acquired) {
            if (err != gpu::WAIT_TIMEOUT && err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) swapchain_info = sample_window::recover_swapchain(device, swapchain, &window)!;
            continue;
        }

        sample_frame_upload::FrameUploadBatch upload_batch =
            sample_frame_upload::begin_frame_upload(&upload_ring)!;
        defer catch {
            if (upload_batch.ring != null) {
                (void)sample_frame_upload::cancel_frame_upload(&upload_batch);
            }
        };

        gpu::CommandList cmd = gpu::begin_commands(&context.command_allocator)!;
        defer (void)gpu::discard_commands(&cmd);

        gpu::TextureState depth_attach = {
            .layout = gpu::TextureLayout.DEPTH_ATTACHMENT,
            .stages = { .depth_output },
            .access = { .read, .write },
        };
        gpu::TextureState stencil_sampled = gpu::sampled_at({ .fragment_shader });
        gpu::TextureBarrier target_to_attach = gpu::texture_transition(
            texture: target.texture,
            before:  target.fresh ? (gpu::TextureState){ .layout = gpu::TextureLayout.UNDEFINED } : stencil_sampled,
            after:   depth_attach,
        )!;
        gpu::cmd_texture_barrier(&cmd, &target_to_attach)!;
        target.fresh = false;

        gpu::TextureBarrier to_attach = gpu::texture_transition(
            texture: acquired.texture,
            before:  acquired.prior_state,
            after:   {
                .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
                .stages = { .color_output },
                .access = { .read, .write },
            },
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_attach)!;

        gpu::GpuSpan roots_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      2 * MaskRoot::size,
            alignment: 16,
        )!;
        MaskRoot* roots = (MaskRoot*)gpu::get_span_mapping(device, roots_span)!.ptr;
        MaskRoot shared = {
            .time            = (float)frame / 60.0f,
            .aspect          = (float)swapchain_info.width / (float)swapchain_info.height,
            .stencil_texture = target.stencil_view.index,
            .width           = swapchain_info.width,
            .height          = swapchain_info.height,
        };
        roots[0] = shared;
        roots[0].fill_mode = FILL_INSIDE;
        roots[1] = shared;
        roots[1].fill_mode = FILL_OUTSIDE;
        gpu::GpuAddress roots_address = gpu::get_span_address(device, roots_span)!;
        gpu::GpuAddress inside_root  = roots_address;
        gpu::GpuAddress outside_root = roots_address + MaskRoot::size;

        gpu::ColorTargetDesc[1] colors = {{
            .view     = acquired.attachment_view,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0.0f, 0.0f, 0.0f, 1.0f } },
        }};
        gpu::DepthTargetDesc depth_target = {
            .view             = target.attachment,
            .load_op          = gpu::LoadOp.CLEAR,
            .store_op         = gpu::StoreOp.STORE,
            .stencil_load_op  = gpu::LoadOp.CLEAR,
            .stencil_store_op = gpu::StoreOp.STORE,
            .clear            = { .depth = 1.0f, .stencil = 0 },
        };
        gpu::RenderPassDesc mask_pass = {
            .colors = colors[..],
            .depth  = &depth_target,
        };
        gpu::GraphicsState base = gpu::render_geometry_state(swapchain_info.width, swapchain_info.height)!;
        gpu::GraphicsState write_state = stencil_state(base, write_id);
        write_state.color.targets = no_color[..];
        gpu::GraphicsState inside_state = stencil_state(base, inside);
        inside_state.color.targets = write_color[..];
        gpu::GraphicsState outside_state = stencil_state(base, outside);
        outside_state.color.targets = write_color[..];

        gpu::cmd_begin_render_pass(&cmd, &mask_pass)!;
        gpu::cmd_bind_pipeline(&cmd, pipelines.mask)!;
        gpu::cmd_set_graphics_state(&cmd, &write_state)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    inside_root,
            fragment_root:  inside_root,
            vertex_count:   STAR_VERTEX_COUNT,
            instance_count: 1,
        )!;
        gpu::cmd_bind_pipeline(&cmd, pipelines.fill)!;
        gpu::cmd_set_graphics_state(&cmd, &inside_state)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    inside_root,
            fragment_root:  inside_root,
            vertex_count:   3,
            instance_count: 1,
        )!;
        gpu::cmd_set_graphics_state(&cmd, &outside_state)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    outside_root,
            fragment_root:  outside_root,
            vertex_count:   3,
            instance_count: 1,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier target_to_sampled = gpu::texture_transition(
            texture: target.texture,
            before:  depth_attach,
            after:   stencil_sampled,
        )!;
        gpu::cmd_texture_barrier(&cmd, &target_to_sampled)!;

        gpu::ColorTargetDesc[1] overlay_colors = {{
            .view     = acquired.attachment_view,
            .load_op  = gpu::LoadOp.LOAD,
            .store_op = gpu::StoreOp.STORE,
        }};
        gpu::RenderPassDesc overlay_pass = { .colors = overlay_colors[..] };
        gpu::GraphicsState overlay_state = base;
        overlay_state.color.targets = overlay_color[..];
        gpu::cmd_bind_pipeline(&cmd, pipelines.outline)!;
        gpu::cmd_begin_render_pass(&cmd, &overlay_pass)!;
        gpu::cmd_set_graphics_state(&cmd, &overlay_state)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    inside_root,
            fragment_root:  inside_root,
            vertex_count:   3,
            instance_count: 1,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier to_present = gpu::texture_transition(
            texture: acquired.texture,
            before:  {
                .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
                .stages = { .color_output },
                .access = { .read, .write },
            },
            after:   { .layout = gpu::TextureLayout.PRESENT },
        )!;
        gpu::cmd_texture_barrier(&cmd, &to_present)!;

        sample_frame_upload::flush_frame_upload(&upload_batch)!;
        gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
        defer (void)gpu::discard_executable_commands(&lists[0]);
        gpu::SubmitDesc submit = {
            .command_lists    = lists[..],
            .readiness        = acquired.readiness,
            .readiness_before = { .color_output },
        };
        last_graphics = gpu::submit(context.queue, &submit)!;
        sample_frame_upload::retire_frame_upload(&upload_batch, last_graphics)!;

        bool verify_now = options.wants_screenshot() ? options.capture_frame(frame) : frame == 0;
        if (verify_now) {
            usz masked = count_masked_texels(&context.command_allocator, last_graphics, &target)!;
            usz total = (usz)swapchain_info.width * swapchain_info.height;
            float coverage = (float)masked / (float)total;
            io::printfn("stencil_mask: stencil coverage %d / %d (%.1f%%)", masked, total, coverage * 100.0f);
            if (coverage < MIN_COVERAGE || coverage > MAX_COVERAGE) return gpu::INVALID_RESOURCE_STATE~;
            verified = true;
        }

        if (options.capture_frame(frame)) {
            sample_capture::capture_texture_png(
                allocator:           &context.command_allocator,
                producer_completion: last_graphics,
                src:                 acquired.texture,
                width:               swapchain_info.width,
                height:              swapchain_info.height,
                format:              swapchain_info.format,
                from_state:          { .layout = gpu::TextureLayout.PRESENT },
                path:                options.screenshot_path,
            )!;
        }

        if (catch err = sample_window::present_when_ready(device, &acquired, last_graphics)) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(device, swapchain, &window)!;
        }

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

    if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
    if (!verified && frame > 0) return gpu::INVALID_RESOURCE_STATE~;
}
