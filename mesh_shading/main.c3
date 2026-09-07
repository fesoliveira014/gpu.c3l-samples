module mesh_shading;

import gpu;
import sample_args;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;

const char[*] MESHLETS_TASK_SPIRV = $embed("shaders/meshlets.task.spv");
const char[*] MESHLETS_MESH_SPIRV = $embed("shaders/meshlets.mesh.spv");
const char[*] MESHLETS_FRAG_SPIRV = $embed("shaders/meshlets.frag.spv");

const uint MESHLET_COUNT = COLUMNS * ROWS;
const uint DIRECT_MESHLETS = MESHLET_COUNT / 2;
const uint INDIRECT_MESHLETS = MESHLET_COUNT - DIRECT_MESHLETS;
const uint DIRECT_TASKS = (DIRECT_MESHLETS + MESHLETS_PER_TASK - 1) / MESHLETS_PER_TASK;
const uint INDIRECT_TASKS = (INDIRECT_MESHLETS + MESHLETS_PER_TASK - 1) / MESHLETS_PER_TASK;
const usz UPLOAD_BYTES_PER_SLOT = 2 * MeshRoot::size + 2 * FragRoot::size;

struct FrameWork {
    gpu::Device*                 device;
    gpu::CommandAllocator*       command_allocator;
    sample_window::SampleWindow* window;
    gpu::SwapchainHandle         swapchain;
    gpu::SwapchainInfo*          swapchain_info;
    gpu::PipelineHandle          pipeline;
    gpu::GpuSpan                 indirect_args;
    sample_frame_upload::FrameUploadRing* upload_ring;
    sample_args::Options*        options;
    gpu::CompletionPoint*        last_graphics;
    long                         frame;
    bool                         rendered;
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("mesh_shading: FAIL (%s)", err);
        return 1;
    }
    io::printn("mesh_shading: PASS");
    return 0;
}

fn void? check_mesh_caps(gpu::MeshShaderCaps* caps) {
    io::printfn(
        "mesh_shading: task shaders %s, max mesh groups %d x %d x %d (total %d)",
        caps.task_shaders ? "on" : "off",
        caps.max_mesh_work_group_count.x,
        caps.max_mesh_work_group_count.y,
        caps.max_mesh_work_group_count.z,
        caps.max_mesh_work_group_total_count,
    );
    io::printfn(
        "mesh_shading: max task groups %d x %d x %d (total %d), max outputs %d vertices / %d primitives",
        caps.max_task_work_group_count.x,
        caps.max_task_work_group_count.y,
        caps.max_task_work_group_count.z,
        caps.max_task_work_group_total_count,
        caps.max_mesh_output_vertices,
        caps.max_mesh_output_primitives,
    );
    if (!caps.enabled || !caps.task_shaders) return gpu::UNSUPPORTED_FEATURE~;
    if (caps.max_mesh_output_vertices < HEX_VERTICES
        || caps.max_mesh_output_primitives < HEX_TRIANGLES
        || caps.max_task_work_group_count.x < DIRECT_TASKS
        || caps.max_task_work_group_count.x < INDIRECT_TASKS
        || caps.max_mesh_work_group_count.x < MESHLETS_PER_TASK) {
        return gpu::UNSUPPORTED_FEATURE~;
    }
}

macro char[] @bytes_of(value) => ((char*)value)[:@sizeof(*value)];

fn gpu::GpuSpan? write_root(sample_frame_upload::FrameUploadBatch* batch, gpu::Device* device, char[] bytes) {
    gpu::GpuSpan span = sample_frame_upload::alloc_frame_upload(
        batch:     batch,
        size:      bytes.len,
        alignment: 16,
    )!;
    char[] mapping = gpu::get_span_mapping(device, span)!;
    mapping[:bytes.len] = bytes[..];
    return span;
}

fn void? render_frame(FrameWork* ctx) {
    gpu::AcquiredImage? acquired = gpu::acquire_next_image(
        device:     ctx.device,
        swapchain:  ctx.swapchain,
        timeout_ns: sample_window::FRAME_ACQUIRE_TIMEOUT_NS,
    );
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

    float time = (float)ctx.frame / 60.0f;
    float aspect = (float)ctx.swapchain_info.width / (float)ctx.swapchain_info.height;
    MeshRoot direct_root = {
        .first_meshlet = 0,
        .meshlet_count = DIRECT_MESHLETS,
        .time          = time,
        .aspect        = aspect,
    };
    MeshRoot indirect_root = {
        .first_meshlet = DIRECT_MESHLETS,
        .meshlet_count = INDIRECT_MESHLETS,
        .time          = time,
        .aspect        = aspect,
    };
    FragRoot direct_tint = { .tint = { 1.0f, 1.0f, 1.0f, 1.0f } };
    FragRoot indirect_tint = { .tint = { 1.0f, 0.75f, 0.45f, 1.0f } };
    gpu::GpuSpan direct_span = write_root(&upload_batch, ctx.device, @bytes_of(&direct_root))!;
    gpu::GpuSpan indirect_span = write_root(&upload_batch, ctx.device, @bytes_of(&indirect_root))!;
    gpu::GpuSpan direct_tint_span = write_root(&upload_batch, ctx.device, @bytes_of(&direct_tint))!;
    gpu::GpuSpan indirect_tint_span = write_root(&upload_batch, ctx.device, @bytes_of(&indirect_tint))!;

    gpu::CommandList cmd = gpu::begin_commands(ctx.command_allocator)!;
    defer (void)gpu::discard_commands(&cmd);

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
    gpu::Barrier args_visible = {
        .before = { .host = true },
        .after  = { .indirect = true },
    };
    gpu::cmd_barrier(&cmd, &args_visible)!;

    gpu::ColorTargetDesc[1] colors = {{
        .view     = acquired.attachment_view,
        .load_op  = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear    = { .rgba = { 0.04f, 0.05f, 0.09f, 1.0f } },
    }};
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .width  = ctx.swapchain_info.width,
        .height = ctx.swapchain_info.height,
    };
    gpu::GraphicsState graphics = gpu::render_geometry_state(pass.width, pass.height)!;
    gpu::ColorTargetState[1] color_targets = { gpu::color_blend_disabled() };
    graphics.color.targets = color_targets[..];

    gpu::cmd_begin_render_pass(&cmd, &pass)!;
    gpu::cmd_bind_pipeline(&cmd, ctx.pipeline)!;
    gpu::cmd_set_graphics_state(&cmd, &graphics)!;
    gpu::cmd_draw_mesh_tasks(
        commands:      &cmd,
        mesh_root:     gpu::get_span_address(ctx.device, direct_span)!,
        fragment_root: gpu::get_span_address(ctx.device, direct_tint_span)!,
        groups:        { DIRECT_TASKS, 1, 1 },
    )!;
    gpu::cmd_draw_mesh_tasks_indirect(
        commands:      &cmd,
        mesh_root:     gpu::get_span_address(ctx.device, indirect_span)!,
        fragment_root: gpu::get_span_address(ctx.device, indirect_tint_span)!,
        args:          ctx.indirect_args,
        draw_count:    1,
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
    *ctx.last_graphics = gpu::submit(ctx.command_allocator.queue, &submit)!;
    sample_frame_upload::retire_frame_upload(&upload_batch, *ctx.last_graphics)!;

    if (ctx.options.capture_frame(ctx.frame)) {
        sample_capture::capture_texture_png(
            allocator:           ctx.command_allocator,
            producer_completion: *ctx.last_graphics,
            src:                 acquired.texture,
            width:               ctx.swapchain_info.width,
            height:              ctx.swapchain_info.height,
            format:              ctx.swapchain_info.format,
            from_state:          { .layout = gpu::TextureLayout.PRESENT },
            path:                ctx.options.screenshot_path,
        )!;
    }

    if (catch err = sample_window::present_when_ready(ctx.device, &acquired, *ctx.last_graphics)) {
        if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
        *ctx.swapchain_info = sample_window::recover_swapchain(ctx.device, ctx.swapchain, ctx.window)!;
    }

    ctx.rendered = true;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l mesh shading", 800, 600)!;
    defer sample_window::destroy_sample_window(&window);

    gpu::RuntimeDesc runtime_desc = {
        .contract_validation      = gpu::ContractValidation.FULL,
        .enable_vulkan_validation = true,
        .application_name         = "mesh_shading",
    };
    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer (void)gpu::destroy_runtime(&runtime);

    gpu::Surface surface = sample_window::create_surface(&runtime, &window)!;
    defer (void)gpu::destroy_surface(&surface);

    gpu::Device device = sample_window::create_presentation_device(
        &runtime,
        &surface,
        { .enable_mesh_shaders = true },
    )!;
    defer (void)gpu::destroy_device(&device);
    gpu::DeviceCaps caps = gpu::get_device_caps(&device)!;
    check_mesh_caps(&caps.mesh_shaders)!;

    gpu::Queue graphics_queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;
    gpu::CommandAllocator graphics_allocator =
        gpu::create_command_allocator(&device, graphics_queue)!;
    defer (void)gpu::destroy_command_allocator(&graphics_allocator);

    gpu::QueueRoles upload_access = { .graphics };
    sample_frame_upload::FrameUploadRing upload_ring =
        sample_frame_upload::create_frame_upload_ring(
            device:        &device,
            slot_capacity: UPLOAD_BYTES_PER_SLOT,
            access:        upload_access,
            debug_name:    "mesh_shading_frame_upload",
        )!;
    defer (void)sample_frame_upload::destroy_frame_upload_ring(&upload_ring);

    gpu::AllocationDesc args_desc = {
        .size         = gpu::DrawMeshTasksIndirectCommand::size,
        .memory_class = gpu::MemoryClass.CPU_WRITE_GPU_LOCAL,
        .access       = upload_access,
        .debug_name   = "mesh_shading_indirect_args",
    };
    gpu::MappedGpuSpan args = gpu::allocate_mapped_memory(&device, &args_desc)!;
    gpu::GpuAllocation args_allocation = args.span.allocation();
    defer (void)gpu::free_allocation(&device, &args_allocation);
    gpu::DrawMeshTasksIndirectCommand* args_record = (gpu::DrawMeshTasksIndirectCommand*)args.bytes.ptr;
    *args_record = { .x = INDIRECT_TASKS, .y = 1, .z = 1 };
    gpu::flush_mapped_span(&device, args.span)!;
    gpu::AllocationInfo args_info = gpu::get_allocation_info(&device, args_allocation)!;
    io::printfn(
        "mesh_shading: %d meshlets, %d direct task groups + %d indirect (args device_local %s)",
        MESHLET_COUNT,
        DIRECT_TASKS,
        INDIRECT_TASKS,
        args_info.device_local ? "yes" : "no",
    );

    uint width;
    uint height;
    sample_window::pixel_size(&window, &width, &height);
    gpu::SwapchainDesc swapchain_desc = {
        .width            = width,
        .height           = height,
        .preferred_format = gpu::Format.BGRA8_UNORM,
        .present_mode     = options.vsync ? gpu::PresentMode.FIFO : gpu::PresentMode.MAILBOX,
        .srgb             = false,
        .debug_name       = "mesh_shading_swapchain",
    };
    gpu::SwapchainHandle swapchain = gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)sample_window::destroy_swapchain_when_ready(&device, swapchain);

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::MeshPipelineDesc pipe_desc = {
        .task_shader     = { .spirv = MESHLETS_TASK_SPIRV[..], .entry_point = "main" },
        .mesh_shader     = { .spirv = MESHLETS_MESH_SPIRV[..], .entry_point = "main" },
        .fragment_shader = { .spirv = MESHLETS_FRAG_SPIRV[..], .entry_point = "main" },
        .color_formats   = color_formats[..],
        .debug_name      = "mesh_shading_meshlets",
    };
    gpu::PipelineHandle pipeline;
    bool pipeline_valid = false;
    if (!swapchain_info.dormant) {
        pipeline = gpu::create_mesh_pipeline(&device, &pipe_desc)!;
        pipeline_valid = true;
    }
    defer {
        if (pipeline_valid) (void)gpu::destroy_pipeline(&device, pipeline);
    }

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
            pipeline = gpu::create_mesh_pipeline(&device, &pipe_desc)!;
            pipeline_valid = true;
        }

        FrameWork work = {
            .device            = &device,
            .command_allocator = &graphics_allocator,
            .window            = &window,
            .swapchain         = swapchain,
            .swapchain_info    = &swapchain_info,
            .pipeline          = pipeline,
            .indirect_args     = args.span,
            .upload_ring       = &upload_ring,
            .options           = &options,
            .last_graphics     = &last_graphics,
            .frame             = frame,
        };
        if (catch err = render_frame(&work)) return err~;
        if (!work.rendered) continue;

        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }

    if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
}
