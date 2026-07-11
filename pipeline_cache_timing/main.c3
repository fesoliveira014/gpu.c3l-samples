module pipeline_cache_timing;

import gpu;
import std::io;
import std::time;
import std::core::mem;

const char[*] QUAD_VERT_SPIRV = $embed("shaders/quad.vert.spv");
const char[*] QUAD_FRAG_SPIRV = $embed("shaders/quad.frag.spv");
const char[*] SCALE_COMP_SPIRV = $embed("shaders/scale.comp.spv");

const uint SMOKE_SIZE = 64;
const uint SCALE_COUNT = 128;

const gpu::PrimitiveTopology[2] TOPOLOGIES = { gpu::PrimitiveTopology.TRIANGLES, gpu::PrimitiveTopology.LINES };
const gpu::Format[3] COLOR_FORMATS = { gpu::Format.RGBA8_UNORM, gpu::Format.BGRA8_UNORM, gpu::Format.RGBA16_FLOAT };
const uint VARIANTS = 2 * 2 * 3 * 2;

struct Shaders {
    gpu::ShaderHandle vert;
    gpu::ShaderHandle frag;
    gpu::ShaderHandle comp;
}

fn Shaders? create_shaders(gpu::Device* device) {
    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = QUAD_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = QUAD_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderDesc comp_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = SCALE_COMP_SPIRV[..], .entry_point = "main" };
    Shaders s;
    s.vert = gpu::create_shader(device, &vert_sd)!;
    s.frag = gpu::create_shader(device, &frag_sd)!;
    s.comp = gpu::create_shader(device, &comp_sd)!;
    return s;
}

fn void destroy_shaders(gpu::Device* device, Shaders* s) {
    (void)gpu::destroy_shader(device, s.comp);
    (void)gpu::destroy_shader(device, s.frag);
    (void)gpu::destroy_shader(device, s.vert);
}

<* Variant v spreads over blend enable x topology x color format x depth
   presence — 24 distinct immutable-state keys, each a real driver compile. *>
fn gpu::GraphicsPipelineDesc variant_desc(Shaders* s, uint v, gpu::Format[] color_slot) {
    bool blend_on  = (v & 1) != 0;
    uint topo      = (v >> 1) & 1;
    uint fmt       = (v >> 2) % 3;
    bool has_depth = ((v >> 2) / 3) != 0;
    color_slot[0] = COLOR_FORMATS[fmt];
    gpu::GraphicsPipelineDesc desc = {
        .vertex_shader   = s.vert,
        .fragment_shader = s.frag,
        .topology        = TOPOLOGIES[topo],
        .color_formats   = color_slot,
    };
    if (has_depth) {
        desc.depth        = { .test_enable = true, .write_enable = true, .compare = gpu::CompareOp.LESS };
        desc.depth_format = gpu::Format.D32_FLOAT;
    }
    if (blend_on) {
        desc.blend = {
            .enable    = true,
            .src_color = gpu::BlendFactor.SRC_ALPHA,
            .dst_color = gpu::BlendFactor.ONE_MINUS_SRC_ALPHA,
            .color_op  = gpu::BlendOp.ADD,
            .src_alpha = gpu::BlendFactor.ONE,
            .dst_alpha = gpu::BlendFactor.ZERO,
            .alpha_op  = gpu::BlendOp.ADD,
        };
    }
    return desc;
}

struct TierResult {
    NanoDuration total;
    NanoDuration min;
    NanoDuration max;
}

<* Build all variants + the compute pipeline; returns per-tier timing. Handles
   land in `graphics` (len VARIANTS) and `*compute`. *>
fn TierResult? build_all(gpu::Device* device, Shaders* s, gpu::PipelineHandle[] graphics, gpu::PipelineHandle* compute) {
    TierResult r = { .min = (NanoDuration)long::max };
    gpu::Format[1] color_slot;
    for (uint v = 0; v < VARIANTS; v++) {
        Clock clk = clock::now();
        gpu::GraphicsPipelineDesc desc = variant_desc(s, v, color_slot[..]);
        graphics[v] = gpu::create_graphics_pipeline(device, &desc)!;
        NanoDuration d = clk.mark();
        r.total += d;
        if (d < r.min) r.min = d;
        if (d > r.max) r.max = d;
    }
    Clock clk = clock::now();
    gpu::ComputePipelineDesc comp_desc = { .shader = s.comp, .push_constant_size = gpu::RootPush::size };
    *compute = gpu::create_compute_pipeline(device, &comp_desc)!;
    r.total += clk.mark();
    return r;
}

fn void destroy_all(gpu::Device* device, gpu::PipelineHandle[] graphics, gpu::PipelineHandle compute) {
    (void)gpu::destroy_pipeline(device, compute);
    foreach (h : graphics) (void)gpu::destroy_pipeline(device, h);
}

<* Correctness smoke: draw variant 0 to a small offscreen target and run the
   compute pipeline; verify both readbacks. *>
fn void? smoke(gpu::Device* device, gpu::PipelineHandle quad_pipe, gpu::PipelineHandle compute) {
    gpu::TextureDesc target_desc = {
        .dimension = gpu::TextureDimension.TEX_2D,
        .width     = SMOKE_SIZE,
        .height    = SMOKE_SIZE,
        .format    = gpu::Format.RGBA8_UNORM,
        .usage     = { .color_attach, .transfer_src },
    };
    gpu::TextureHandle target = gpu::create_texture(device, &target_desc)!;
    defer (void)gpu::destroy_texture(device, target);

    gpu::BufferDesc io_desc = {
        .size        = SCALE_COUNT * float::size * 2,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .debug_name  = "cache_smoke_io",
    };
    gpu::BufferHandle io = gpu::create_buffer(device, &io_desc)!;
    defer (void)gpu::destroy_buffer(device, io);
    gpu::GpuSpan io_span = gpu::get_buffer_span(device, io)!;
    float* io_data = (float*)io_span.cpu;
    for (uint i = 0; i < SCALE_COUNT; i++) io_data[i] = (float)i;
    gpu::flush_buffer(device, io, 0, 0)!;

    gpu::FrameToken frame_token = gpu::begin_frame(device)!;
    gpu::GpuSpan quad_span = gpu::alloc_frame_span(&frame_token, QuadRoot::size, 16)!;
    QuadRoot* quad_root = (QuadRoot*)quad_span.cpu;
    quad_root.rect  = { -1.0f, -1.0f, 1.0f, 1.0f };
    quad_root.color = { 0.0f, 1.0f, 0.0f, 1.0f };

    gpu::GpuSpan scale_span = gpu::alloc_frame_span(&frame_token, ScaleRoot::size, 16)!;
    ScaleRoot* scale_root = (ScaleRoot*)scale_span.cpu;
    scale_root.input_gpu  = io_span.gpu;
    scale_root.output_gpu = (gpu::GpuAddress)((ulong)io_span.gpu + SCALE_COUNT * float::size);
    scale_root.count      = SCALE_COUNT;

    gpu::CommandList cmd = gpu::begin_commands(device, gpu::QueueKind.GRAPHICS)!;
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
        .texture  = target,
        .load_op  = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear    = { .rgba = { 0, 0, 0, 1 } },
    }};
    gpu::RenderPassDesc pass = { .colors = colors[..], .width = SMOKE_SIZE, .height = SMOKE_SIZE };
    gpu::cmd_begin_render_pass(&cmd, &pass)!;
    gpu::cmd_draw(
        commands:       &cmd,
        pipeline:       quad_pipe,
        vertex_root:    quad_span.gpu,
        fragment_root:  quad_span.gpu,
        vertex_count:   6,
        instance_count: 1,
    )!;
    gpu::cmd_end_render_pass(&cmd)!;
    gpu::cmd_dispatch(
        commands: &cmd,
        pipeline: compute,
        root:     scale_span.gpu,
        groups:   { (SCALE_COUNT + CACHE_COMPUTE_WORKGROUP - 1) / CACHE_COMPUTE_WORKGROUP, 1, 1 },
    )!;
    gpu::BufferBarrier host_read = {
        .buffer = io, .offset = 0, .size = io_span.size,
        .before_stage = gpu::Stage.COMPUTE_SHADER, .after_stage = gpu::Stage.HOST,
        .before_hazard = gpu::Hazard.SHADER_WRITE, .after_hazard = gpu::Hazard.HOST_READ,
    };
    gpu::cmd_buffer_barrier(&cmd, &host_read)!;
    gpu::end_commands(&cmd)!;
    gpu::CommandList[1] lists = { cmd };
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::submit(device, &submit)!;
    gpu::wait_queue_idle(device, gpu::QueueKind.GRAPHICS)!;

    char[] pixels = mem::new_array(char, (usz)SMOKE_SIZE * SMOKE_SIZE * 4);
    defer mem::free(pixels.ptr);
    gpu::readback_texture_data(
        device:      device,
        src:         target,
        mip:         0,
        out_data:    pixels,
        from_stage:  gpu::Stage.COLOR_ATTACHMENT,
        from_hazard: gpu::Hazard.COLOR_WRITE,
        from_layout: gpu::TextureLayout.COLOR_ATTACHMENT,
    )!;
    // Full-target green quad: center pixel must be pure green.
    usz center = ((usz)SMOKE_SIZE / 2 * SMOKE_SIZE + SMOKE_SIZE / 2) * 4;
    if (pixels[center] != 0 || pixels[center + 1] != (char)255) {
        io::printn("pipeline_cache_timing: quad smoke failed");
        return gpu::INVALID_ARGUMENT~;
    }

    gpu::invalidate_buffer(device, io, 0, 0)!;
    for (uint i = 0; i < SCALE_COUNT; i++) {
        if (io_data[SCALE_COUNT + i] != (float)i * 3.0f) {
            io::printn("pipeline_cache_timing: compute smoke failed");
            return gpu::INVALID_ARGUMENT~;
        }
    }
    gpu::end_frame(&frame_token)!;
}

fn gpu::Device? make_device(char[] blob) {
    gpu::DeviceDesc desc = {
        .backend             = gpu::BackendKind.VULKAN,
        .enable_validation   = true,
        .frames_in_flight    = 2,
        .pipeline_cache_data = blob,
        .application_name    = "pipeline_cache_timing",
    };
    return gpu::create_device(&desc);
}

fn double ms(NanoDuration d) => (double)(long)d / 1_000_000.0;

fn void print_tier(String name, TierResult r) {
    io::printfn("  %s  total %8.2f ms   per-variant %6.2f..%.2f ms",
        name, ms(r.total), ms(r.min), ms(r.max));
}

fn int main(String[] args) {
    if (catch err = run()) {
        io::printfn("pipeline_cache_timing: FAIL (%s)", err);
        return 1;
    }
    io::printn("pipeline_cache_timing: PASS");
    return 0;
}

fn void? run() {
    gpu::PipelineHandle[VARIANTS] graphics_a;
    gpu::PipelineHandle[VARIANTS] graphics_b;
    gpu::PipelineHandle compute;

    // Tier 1: cold — first build of every variant on device A.
    gpu::Device device_a = make_device({})!;
    Shaders shaders_a = create_shaders(&device_a)!;
    TierResult cold = build_all(&device_a, &shaders_a, graphics_a[..], &compute)!;
    smoke(&device_a, graphics_a[0], compute)!;

    // Tier 2: dedup — identical descriptors on the same device alias the
    // library's cache entries; no driver compile happens.
    gpu::PipelineHandle[VARIANTS] graphics_dedup;
    gpu::PipelineHandle compute_dedup;
    TierResult dedup = build_all(&device_a, &shaders_a, graphics_dedup[..], &compute_dedup)!;
    destroy_all(&device_a, graphics_dedup[..], compute_dedup);

    // Export the driver blob, then tear device A down.
    usz blob_size = gpu::get_pipeline_cache_size(&device_a)!;
    char[] blob = mem::new_array(char, (sz)blob_size);
    defer mem::free(blob.ptr);
    usz written = gpu::get_pipeline_cache_data(&device_a, blob)!;
    destroy_all(&device_a, graphics_a[..], compute);
    destroy_shaders(&device_a, &shaders_a);
    gpu::destroy_device(&device_a)!;

    // Tier 3: warm — device B's only head start is the imported blob.
    gpu::Device device_b = make_device(blob[:written])!;
    defer (void)gpu::destroy_device(&device_b);
    Shaders shaders_b = create_shaders(&device_b)!;
    defer destroy_shaders(&device_b, &shaders_b);
    TierResult warm = build_all(&device_b, &shaders_b, graphics_b[..], &compute)!;
    smoke(&device_b, graphics_b[0], compute)!;
    destroy_all(&device_b, graphics_b[..], compute);

    io::printfn("pipeline_cache_timing: %d graphics variants + 1 compute", VARIANTS);
    print_tier("cold (device A) ", cold);
    print_tier("dedup (device A)", dedup);
    print_tier("warm (device B) ", warm);
    io::printfn("  blob %d bytes (driver-dependent whether it holds compiled shaders)", written);
}
