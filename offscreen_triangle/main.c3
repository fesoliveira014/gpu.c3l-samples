module offscreen_triangle;

import gpu;
import sample_args;
import sample_capture;
import std::io;
import std::io::file;
import std::core::mem;

const char[*] OFFSCREEN_VERT_SPIRV = $embed("shaders/offscreen.vert.spv");
const char[*] OFFSCREEN_FRAG_SPIRV = $embed("shaders/offscreen.frag.spv");

const uint RT_SIZE = 256;
const usz RT_BYTES = RT_SIZE * RT_SIZE * 4;
const uint TEX_SIZE = 16;

fn int main(String[] args) {
    sample_args::Options options = sample_args::parse_options(args);
    if (catch err = run(options)) {
        io::printfn("offscreen_triangle: FAIL (%s)", err);
        return 1;
    }
    io::printn("offscreen_triangle: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    gpu::DeviceDesc device_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .frames_in_flight  = 2,
        .application_name  = "offscreen_triangle",
    };
    gpu::Device device = gpu::create_device(&device_desc)!;
    defer (void)gpu::destroy_device(&device);

    gpu::TextureDesc rt_desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = RT_SIZE,
        .height     = RT_SIZE,
        .format     = gpu::Format.RGBA8_UNORM,
        .usage      = { .color_attach, .transfer_src },
        .debug_name = "render_target",
    };
    gpu::TextureHandle target = gpu::create_texture(&device, &rt_desc)!;
    defer (void)gpu::destroy_texture(&device, target);

    gpu::TextureDesc tex_desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = TEX_SIZE,
        .height     = TEX_SIZE,
        .format     = gpu::Format.RGBA8_UNORM,
        .usage      = { .sampled, .transfer_dst },
        .debug_name = "checker",
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

    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = OFFSCREEN_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle vert = gpu::create_shader(&device, &vert_sd)!;
    defer (void)gpu::destroy_shader(&device, vert);
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = OFFSCREEN_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle frag = gpu::create_shader(&device, &frag_sd)!;
    defer (void)gpu::destroy_shader(&device, frag);

    gpu::Format[1] color_formats = { gpu::Format.RGBA8_UNORM };
    gpu::GraphicsPipelineDesc pipe_desc = {
        .vertex_shader   = vert,
        .fragment_shader = frag,
        .topology        = gpu::PrimitiveTopology.TRIANGLES,
        .color_formats   = color_formats[..],
        .debug_name      = "offscreen_triangle",
    };
    gpu::PipelineHandle pipeline = gpu::create_graphics_pipeline(&device, &pipe_desc)!;
    defer (void)gpu::destroy_pipeline(&device, pipeline);

    gpu::begin_frame(&device)!;

    gpu::GpuSpan verts_span = gpu::alloc_frame_span(&device, 3 * 16, 16)!;
    float[12] vertex_data = {
        -0.8f, -0.8f, 0.0f, 0.0f,
         0.8f, -0.8f, 1.0f, 0.0f,
         0.0f,  0.8f, 0.5f, 1.0f,
    };
    mem::copy(verts_span.cpu, &vertex_data, vertex_data.len * float::size);

    gpu::GpuSpan frag_span = gpu::alloc_frame_span(&device, FragRoot::size, 16)!;
    FragRoot* frag_root = (FragRoot*)frag_span.cpu;
    frag_root.texture_index = tex_index;
    frag_root.sampler_index = smp_index;

    gpu::CommandList cmd = gpu::begin_commands(&device, gpu::QueueKind.GRAPHICS)!;

    gpu::TextureBarrier checker_to_dst = {
        .texture       = checker,
        .before_stage  = gpu::Stage.HOST,
        .after_stage   = gpu::Stage.TRANSFER,
        .before_hazard = gpu::Hazard.HOST_WRITE,
        .after_hazard  = gpu::Hazard.TRANSFER_WRITE,
        .old_layout    = gpu::TextureLayout.UNDEFINED,
        .new_layout    = gpu::TextureLayout.TRANSFER_DST,
    };
    gpu::cmd_texture_barrier(&cmd, &checker_to_dst)!;
    gpu::BufferTextureCopyDesc upload = { .src = staging_span, .texture = checker };
    gpu::cmd_copy_buffer_to_texture(&cmd, &upload)!;
    gpu::TextureBarrier checker_to_read = {
        .texture       = checker,
        .before_stage  = gpu::Stage.TRANSFER,
        .after_stage   = gpu::Stage.FRAGMENT_SHADER,
        .before_hazard = gpu::Hazard.TRANSFER_WRITE,
        .after_hazard  = gpu::Hazard.SHADER_READ,
        .old_layout    = gpu::TextureLayout.TRANSFER_DST,
        .new_layout    = gpu::TextureLayout.SHADER_READ,
    };
    gpu::cmd_texture_barrier(&cmd, &checker_to_read)!;

    gpu::TextureBarrier to_attach = {
        .texture       = target,
        .before_stage  = gpu::Stage.HOST,
        .after_stage   = gpu::Stage.COLOR_ATTACHMENT,
        .before_hazard = gpu::Hazard.HOST_WRITE,
        .after_hazard  = gpu::Hazard.COLOR_WRITE,
        .old_layout    = gpu::TextureLayout.UNDEFINED,
        .new_layout    = gpu::TextureLayout.COLOR_ATTACHMENT,
    };
    gpu::cmd_texture_barrier(&cmd, &to_attach)!;

    gpu::ColorTargetDesc[1] colors = {{
        .texture = target,
        .load_op = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear = { .rgba = { 0.05f, 0.05f, 0.1f, 1.0f } },
    }};
    gpu::RenderPassDesc pass = { .colors = colors[..], .width = RT_SIZE, .height = RT_SIZE };
    gpu::cmd_begin_render_pass(&cmd, &pass)!;
    gpu::cmd_draw(
        commands:       &cmd,
        pipeline:       pipeline,
        vertex_root:    verts_span.gpu,
        fragment_root:  frag_span.gpu,
        vertex_count:   3,
        instance_count: 1,
    )!;
    gpu::cmd_end_render_pass(&cmd)!;

    gpu::end_commands(&device, &cmd)!;
    gpu::CommandList[1] lists = { cmd };
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::submit(&device, &submit)!;
    gpu::wait_queue_idle(&device, gpu::QueueKind.GRAPHICS)!;

    if (options.wants_screenshot()) {
        sample_capture::capture_texture_png(
            device:      &device,
            src:         target,
            width:       RT_SIZE,
            height:      RT_SIZE,
            format:      gpu::Format.RGBA8_UNORM,
            from_stage:  gpu::Stage.COLOR_ATTACHMENT,
            from_hazard: gpu::Hazard.COLOR_WRITE,
            from_layout: gpu::TextureLayout.COLOR_ATTACHMENT,
            path:        options.screenshot_path,
        )!;
    }
    gpu::end_frame(&device)!;
}

