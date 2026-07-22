module pipeline_cache_timing;

import gpu;
import sample_device;
import std::io;
import std::time;
import std::core::mem;

const char[*] QUAD_VERT_SPIRV = $embed("shaders/quad.vert.spv");
const char[*] QUAD_FRAG_SPIRV = $embed("shaders/quad.frag.spv");
const char[*] SCALE_COMP_SPIRV = $embed("shaders/scale.comp.spv");

const uint SMOKE_SIZE = 64;
const uint SCALE_COUNT = 128;

const gpu::Format[3] COLOR_FORMATS = { gpu::Format.RGBA8_UNORM, gpu::Format.BGRA8_UNORM, gpu::Format.RGBA16_FLOAT };
const uint VARIANTS = 2 * 2 * 3 * 2;
const uint IMMUTABLE_IDENTITIES = 2 * 3 * 2;

struct Shaders {
    gpu::ShaderCode vert;
    gpu::ShaderCode frag;
    gpu::ShaderCode comp;
}

fn Shaders? prepare_shaders() {
    gpu::ShaderDesc vert_sd = { .stage = gpu::ShaderStage.VERTEX, .spirv = QUAD_VERT_SPIRV[..], .entry_point = "main" };
    gpu::ShaderDesc frag_sd = { .stage = gpu::ShaderStage.FRAGMENT, .spirv = QUAD_FRAG_SPIRV[..], .entry_point = "main" };
    gpu::ShaderDesc comp_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = SCALE_COMP_SPIRV[..], .entry_point = "main" };
    Shaders s;
    s.vert = gpu::prepare_shader_code(&vert_sd)!;
    s.frag = gpu::prepare_shader_code(&frag_sd)!;
    s.comp = gpu::prepare_shader_code(&comp_sd)!;
    return s;
}

<* Variant v spreads over blend enable x command-time topology x color format
   x depth format. Topology pairs intentionally alias one immutable pipeline. *>
fn gpu::GraphicsPipelineDesc variant_desc(Shaders* s, uint v, gpu::ColorTargetState[] color_slot) {
    bool blend_on  = (v & 1) != 0;
    uint fmt       = (v >> 2) % 3;
    bool has_depth = ((v >> 2) / 3) != 0;
    color_slot[0] = {
        .format     = COLOR_FORMATS[fmt],
        .write_mask = gpu::COLOR_WRITE_ALL,
    };
    gpu::GraphicsPipelineDesc desc = {
        .vertex_shader   = s.vert,
        .fragment_shader = s.frag,
        .colors          = color_slot,
    };
    if (has_depth) {
        desc.depth_format = gpu::Format.D32_FLOAT;
    }
    if (blend_on) {
        color_slot[0].blend = {
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
    gpu::ColorTargetState[1] color_slot;
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
    gpu::ComputePipelineDesc comp_desc = { .shader = s.comp };
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
        .width     = SMOKE_SIZE,
        .height    = SMOKE_SIZE,
        .format    = gpu::Format.RGBA8_UNORM,
        .usage     = { .color_attach, .transfer_src },
        .access     = { .graphics },
    };
    gpu::TextureHandle target = gpu::create_texture(device, &target_desc)!;
    defer (void)gpu::destroy_texture(device, target);
    gpu::AttachmentViewDesc target_view_desc = { .texture = target };
    gpu::AttachmentViewHandle target_view = gpu::create_attachment_view(
        device,
        &target_view_desc,
    )!;
    defer (void)gpu::destroy_attachment_view(device, target_view);

    gpu::AllocationDesc input_desc = {
        .size         = SCALE_COUNT * float::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "cache_smoke_input",
    };
    gpu::GpuAllocation input = gpu::allocate_memory(device, &input_desc)!;
    defer (void)gpu::free_allocation(device, &input);
    gpu::GpuSpan input_span = gpu::get_allocation_span(device, input)!;
    float* input_data = (float*)gpu::get_span_mapping(device, input_span)!.ptr;
    for (uint i = 0; i < SCALE_COUNT; i++) input_data[i] = (float)i;
    gpu::flush_mapped_span(device, input_span)!;

    gpu::AllocationDesc output_desc = {
        .size         = SCALE_COUNT * float::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "cache_smoke_output",
    };
    gpu::GpuAllocation output = gpu::allocate_memory(device, &output_desc)!;
    defer (void)gpu::free_allocation(device, &output);
    gpu::GpuSpan output_span = gpu::get_allocation_span(device, output)!;
    float* output_data = (float*)gpu::get_span_mapping(device, output_span)!.ptr;

    gpu::AllocationDesc roots_desc = {
        .size         = QuadRoot::size + ScaleRoot::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "cache_smoke_roots",
    };
    gpu::GpuAllocation roots_allocation = gpu::allocate_memory(device, &roots_desc)!;
    defer (void)gpu::free_allocation(device, &roots_allocation);
    gpu::GpuSpan roots_span = gpu::get_allocation_span(device, roots_allocation)!;

    gpu::GpuSpan quad_span = roots_span.checked_subspan(0, QuadRoot::size)!;
    QuadRoot* quad_root = (QuadRoot*)gpu::get_span_mapping(device, quad_span)!.ptr;
    quad_root.rect  = { -1.0f, -1.0f, 1.0f, 1.0f };
    quad_root.color = { 0.0f, 1.0f, 0.0f, 1.0f };
    gpu::GpuAddress quad_address = gpu::get_span_address(device, quad_span)!;

    gpu::GpuSpan scale_span = roots_span.checked_subspan(QuadRoot::size, ScaleRoot::size)!;
    ScaleRoot* scale_root = (ScaleRoot*)gpu::get_span_mapping(device, scale_span)!.ptr;
    scale_root.input_gpu  = gpu::get_span_address(device, input_span)!;
    scale_root.output_gpu = gpu::get_span_address(device, output_span)!;
    scale_root.count      = SCALE_COUNT;
    gpu::GpuAddress scale_address = gpu::get_span_address(device, scale_span)!;
    gpu::flush_mapped_span(device, roots_span)!;

    gpu::Queue graphics_queue = gpu::get_queue(device, gpu::QueueKind.GRAPHICS)!;

    gpu::CommandList cmd = gpu::begin_commands(graphics_queue)!;
    defer (void)gpu::discard_commands(&cmd);
    gpu::TextureBarrier to_attach = {
        .texture = target,
        .before  = { .layout = gpu::TextureLayout.UNDEFINED },
        .after   = {
            .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
            .stages = { .color_output },
            .access = { .read, .write },
        },
    };
    gpu::cmd_texture_barrier(&cmd, &to_attach)!;
    gpu::ColorTargetDesc[1] colors = {{
        .view     = target_view,
        .load_op  = gpu::LoadOp.CLEAR,
        .store_op = gpu::StoreOp.STORE,
        .clear    = { .rgba = { 0, 0, 0, 1 } },
    }};
    gpu::RenderPassDesc pass = { .colors = colors[..], .width = SMOKE_SIZE, .height = SMOKE_SIZE };
    gpu::cmd_bind_pipeline(&cmd, quad_pipe)!;
    gpu::cmd_begin_render_pass(&cmd, &pass)!;
    gpu::DynamicRasterState triangle_raster = {};
    gpu::cmd_set_raster_state(&cmd, &triangle_raster)!;
    gpu::DepthState depth_state = {};
    gpu::cmd_set_depth_state(&cmd, &depth_state)!;
    gpu::cmd_draw(
        commands:       &cmd,
        vertex_root:    quad_address,
        fragment_root:  quad_address,
        vertex_count:   6,
        instance_count: 1,
    )!;
    gpu::DynamicRasterState line_raster = {
        .topology = gpu::PrimitiveTopology.LINES,
    };
    gpu::cmd_set_raster_state(&cmd, &line_raster)!;
    gpu::cmd_draw(
        commands:       &cmd,
        vertex_root:    quad_address,
        fragment_root:  quad_address,
        vertex_count:   6,
        instance_count: 1,
    )!;
    gpu::cmd_end_render_pass(&cmd)!;
    gpu::cmd_bind_pipeline(&cmd, compute)!;
    gpu::cmd_dispatch(
        commands: &cmd,
        root:     scale_address,
        groups:   { (SCALE_COUNT + CACHE_COMPUTE_WORKGROUP - 1) / CACHE_COMPUTE_WORKGROUP, 1, 1 },
    )!;
    gpu::Barrier host_read = {
        .before = { .compute = true },
        .after = { .host = true },
    };
    gpu::cmd_barrier(&cmd, &host_read)!;
    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::CompletionPoint completion = gpu::submit(graphics_queue, &submit)!;

    char[] pixels = mem::new_array(char, (usz)SMOKE_SIZE * SMOKE_SIZE * 4);
    defer mem::free(pixels.ptr);
    read_color_target(
        device:              device,
        queue:               graphics_queue,
        target:              target,
        producer_completion: completion,
        out:                 pixels,
    )!;
    // Full-target green quad: center pixel must be pure green.
    usz center = ((usz)SMOKE_SIZE / 2 * SMOKE_SIZE + SMOKE_SIZE / 2) * 4;
    if (pixels[center] != 0 || pixels[center + 1] != (char)255) {
        io::printn("pipeline_cache_timing: quad smoke failed");
        return gpu::INVALID_ARGUMENT~;
    }

    gpu::invalidate_mapped_span(device, output_span)!;
    for (uint i = 0; i < SCALE_COUNT; i++) {
        if (output_data[i] != (float)i * 3.0f) {
            io::printn("pipeline_cache_timing: compute smoke failed");
            return gpu::INVALID_ARGUMENT~;
        }
    }
}

fn double ms(NanoDuration d) => (double)(long)d / 1_000_000.0;

fn void print_tier(String name, TierResult r) {
    io::printfn("  %s  total %8.2f ms   per-variant %6.2f..%.2f ms",
        name, ms(r.total), ms(r.min), ms(r.max));
}

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
        .texture = target,
        .before  = {
            .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
            .stages = { .color_output },
            .access = { .read, .write },
        },
        .after   = {
            .layout = gpu::TextureLayout.TRANSFER_SOURCE,
            .stages = { .transfer },
            .access = { .read },
        },
    };
    gpu::cmd_texture_barrier(&commands, &to_source)!;
    gpu::TextureBufferCopyDesc copy = { .texture = target, .dst = readback_span };
    gpu::cmd_copy_texture_to_buffer(&commands, &copy)!;
    gpu::Barrier to_host = {
        .before = { .transfer = true },
        .after = { .host = true },
    };
    gpu::cmd_barrier(&commands, &to_host)!;
    gpu::TextureBarrier restore = {
        .texture = target,
        .before  = {
            .layout = gpu::TextureLayout.TRANSFER_SOURCE,
            .stages = { .transfer },
            .access = { .read },
        },
        .after   = {
            .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
            .stages = { .color_output },
            .access = { .read, .write },
        },
    };
    gpu::cmd_texture_barrier(&commands, &restore)!;

    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&commands)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::CompletionWait[1] waits = {{
        .point  = producer_completion,
        .before = { .transfer },
    }};
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
    Shaders shaders = prepare_shaders()!;

    gpu::RuntimeDesc runtime_a_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .application_name  = "pipeline_cache_timing",
    };
    gpu::Runtime runtime_a = gpu::create_runtime(&runtime_a_desc)!;
    defer (void)gpu::destroy_runtime(&runtime_a);
    gpu::Device device_a = sample_device::create_strict_device(&runtime_a)!;
    defer (void)gpu::destroy_device(&device_a);
    TierResult cold = build_all(&device_a, &shaders, graphics_a[..], &compute)!;
    smoke(&device_a, graphics_a[0], compute)!;

    gpu::PipelineHandle[VARIANTS] graphics_dedup;
    gpu::PipelineHandle compute_dedup;
    TierResult dedup = build_all(&device_a, &shaders, graphics_dedup[..], &compute_dedup)!;
    destroy_all(&device_a, graphics_dedup[..], compute_dedup);

    usz blob_size = gpu::get_pipeline_cache_size(&device_a)!;
    char[] blob = mem::new_array(char, (sz)blob_size);
    defer mem::free(blob.ptr);
    usz written = gpu::get_pipeline_cache_data(&device_a, blob)!;
    destroy_all(&device_a, graphics_a[..], compute);

    gpu::RuntimeDesc runtime_b_desc = {
        .backend             = gpu::BackendKind.VULKAN,
        .enable_validation   = true,
        .pipeline_cache_data = blob[:written],
        .application_name    = "pipeline_cache_timing",
    };
    gpu::Runtime runtime_b = gpu::create_runtime(&runtime_b_desc)!;
    defer (void)gpu::destroy_runtime(&runtime_b);
    gpu::Device device_b = sample_device::create_strict_device(&runtime_b)!;
    defer (void)gpu::destroy_device(&device_b);
    TierResult warm = build_all(&device_b, &shaders, graphics_b[..], &compute)!;
    smoke(&device_b, graphics_b[0], compute)!;
    destroy_all(&device_b, graphics_b[..], compute);

    io::printfn(
        "pipeline_cache_timing: %d graphics handles, %d immutable identities + 1 compute",
        VARIANTS,
        IMMUTABLE_IDENTITIES,
    );
    print_tier("cold (device A) ", cold);
    print_tier("dedup (device A)", dedup);
    print_tier("warm (device B) ", warm);
    io::printfn("  blob %d bytes (driver-dependent whether it holds compiled shaders)", written);
}
