module image_processing;

import gpu;
import sample_device;
import sample_args;
import sample_capture;
import std::io;

const char[*] GENERATE_SPIRV  = $embed("shaders/generate.comp.spv");
const char[*] BLUR_SPIRV      = $embed("shaders/blur.comp.spv");
const char[*] HISTOGRAM_SPIRV = $embed("shaders/histogram.comp.spv");

const uint CHART_ROWS = 16;
const uint CHART_COLS = 64;

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("image_processing: FAIL (%s)", err);
        return 1;
    }
    io::printn("image_processing: PASS");
    return 0;
}

fn gpu::TextureHandle? create_storage_image(gpu::Device* device, bool capture_target, ZString name) {
    gpu::TextureDesc desc = {
        .dimension  = gpu::TextureDimension.TEX_2D,
        .width      = IMAGE_SIZE,
        .height     = IMAGE_SIZE,
        .format     = gpu::Format.RGBA8_UNORM,
        .usage      = {
            .storage,
            .transfer_src = capture_target,
        },
        .access     = { .graphics = capture_target, .compute },
        .debug_name = name,
    };
    return gpu::create_texture(device, &desc);
}

fn void? run(sample_args::Options options) {
    gpu::RuntimeDesc runtime_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .application_name  = "image_processing",
    };
    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer (void)gpu::destroy_runtime(&runtime);
    gpu::Device device = sample_device::create_strict_device(&runtime)!;
    defer (void)gpu::destroy_device(&device);

    gpu::TextureHandle image_a = create_storage_image(&device, true, "plasma_a")!;
    defer (void)gpu::destroy_texture(&device, image_a);
    gpu::TextureHandle image_b = create_storage_image(&device, false, "plasma_b")!;
    defer (void)gpu::destroy_texture(&device, image_b);
    gpu::TextureView view_a = gpu::create_texture_view(&device, image_a, null)!;
    defer (void)gpu::destroy_texture_view(&device, view_a);
    gpu::TextureIndex index_a = view_a.index;
    gpu::TextureView view_b = gpu::create_texture_view(&device, image_b, null)!;
    defer (void)gpu::destroy_texture_view(&device, view_b);
    gpu::TextureIndex index_b = view_b.index;

    gpu::AllocationDesc bins_desc = {
        .size         = HISTOGRAM_BINS * 4,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .compute },
        .debug_name   = "histogram_bins",
    };
    gpu::GpuAllocation bins = gpu::allocate_memory(&device, &bins_desc)!;
    defer (void)gpu::free_allocation(&device, &bins);
    gpu::GpuSpan bins_span = gpu::get_allocation_span(&device, bins)!;
    uint* bin_counts = (uint*)gpu::get_span_mapping(&device, bins_span)!.ptr;

    gpu::ShaderDesc gen_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = GENERATE_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode gen_shader = gpu::prepare_shader_code(&gen_sd)!;
    gpu::ShaderDesc blur_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = BLUR_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode blur_shader = gpu::prepare_shader_code(&blur_sd)!;
    gpu::ShaderDesc hist_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = HISTOGRAM_SPIRV[..], .entry_point = "main" };
    gpu::ShaderCode hist_shader = gpu::prepare_shader_code(&hist_sd)!;

    gpu::ComputePipelineDesc gen_pd = { .shader = gen_shader, .debug_name = "generate" };
    gpu::PipelineHandle gen_pipe = gpu::create_compute_pipeline(&device, &gen_pd)!;
    defer (void)gpu::destroy_pipeline(&device, gen_pipe);
    gpu::ComputePipelineDesc blur_pd = { .shader = blur_shader, .debug_name = "blur" };
    gpu::PipelineHandle blur_pipe = gpu::create_compute_pipeline(&device, &blur_pd)!;
    defer (void)gpu::destroy_pipeline(&device, blur_pipe);
    gpu::ComputePipelineDesc hist_pd = { .shader = hist_shader, .debug_name = "histogram" };
    gpu::PipelineHandle hist_pipe = gpu::create_compute_pipeline(&device, &hist_pd)!;
    defer (void)gpu::destroy_pipeline(&device, hist_pipe);

    gpu::AllocationDesc roots_desc = {
        .size         = GenerateRoot::size + 2 * BlurRoot::size + HistogramRoot::size,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .compute },
        .debug_name   = "image_processing_roots",
    };
    gpu::GpuAllocation roots_allocation = gpu::allocate_memory(&device, &roots_desc)!;
    defer (void)gpu::free_allocation(&device, &roots_allocation);
    gpu::GpuSpan roots_span = gpu::get_allocation_span(&device, roots_allocation)!;

    gpu::GpuSpan gen_span = roots_span.checked_subspan(0, GenerateRoot::size)!;
    GenerateRoot* gen_root = (GenerateRoot*)gpu::get_span_mapping(&device, gen_span)!.ptr;
    gen_root.target = index_a;
    gen_root.size   = IMAGE_SIZE;
    gen_root.seed   = 3.7f;

    gpu::GpuSpan blur_h_span = roots_span.checked_subspan(GenerateRoot::size, BlurRoot::size)!;
    BlurRoot* blur_h = (BlurRoot*)gpu::get_span_mapping(&device, blur_h_span)!.ptr;
    blur_h.src        = index_a;
    blur_h.dst        = index_b;
    blur_h.size       = IMAGE_SIZE;
    blur_h.horizontal = 1;

    gpu::GpuSpan blur_v_span = roots_span.checked_subspan(GenerateRoot::size + BlurRoot::size, BlurRoot::size)!;
    BlurRoot* blur_v = (BlurRoot*)gpu::get_span_mapping(&device, blur_v_span)!.ptr;
    blur_v.src        = index_b;
    blur_v.dst        = index_a;
    blur_v.size       = IMAGE_SIZE;
    blur_v.horizontal = 0;

    gpu::GpuSpan hist_span = roots_span.checked_subspan(GenerateRoot::size + 2 * BlurRoot::size, HistogramRoot::size)!;
    HistogramRoot* hist_root = (HistogramRoot*)gpu::get_span_mapping(&device, hist_span)!.ptr;
    hist_root.bins_gpu = gpu::get_span_address(&device, bins_span)!;
    hist_root.src      = index_a;
    hist_root.size     = IMAGE_SIZE;
    gpu::flush_mapped_span(&device, roots_span)!;

    gpu::Queue compute_queue = gpu::get_queue(&device, gpu::QueueKind.COMPUTE)!;

    gpu::CommandList cmd = gpu::begin_commands(compute_queue)!;
    defer (void)gpu::discard_commands(&cmd);

    gpu::cmd_fill_buffer(&cmd, bins_span, 0)!;
    gpu::Barrier bins_cleared = {
        .before = { .transfer = true },
        .after = { .compute = true },
    };
    gpu::cmd_barrier(&cmd, &bins_cleared)!;

    gpu::TextureHandle[2] images = { image_a, image_b };
    foreach (image : images) {
        gpu::TextureBarrier to_general = {
            .texture = image,
            .before  = { .layout = gpu::TextureLayout.UNDEFINED },
            .after   = gpu::storage_at({ .compute }, { .write }),
        };
        gpu::cmd_texture_barrier(&cmd, &to_general)!;
    }

    const uint TILE_GROUPS = (IMAGE_SIZE + GEN_TILE - 1) / GEN_TILE;
    const uint STRIP_GROUPS = (IMAGE_SIZE + BLUR_TILE - 1) / BLUR_TILE;

    gpu::cmd_bind_pipeline(&cmd, gen_pipe)!;
    gpu::cmd_dispatch(
        commands: &cmd,
        root:     gpu::get_span_address(&device, gen_span)!,
        groups:   { TILE_GROUPS, TILE_GROUPS, 1 },
    )!;

    // Storage write -> storage read between every chain stage.
    gpu::TextureBarrier a_written = {
        .texture = image_a,
        .before  = gpu::storage_at({ .compute }, { .write }),
        .after   = gpu::storage_at({ .compute }, { .read }),
    };
    gpu::cmd_texture_barrier(&cmd, &a_written)!;

    gpu::cmd_bind_pipeline(&cmd, blur_pipe)!;
    gpu::cmd_dispatch(
        commands: &cmd,
        root:     gpu::get_span_address(&device, blur_h_span)!,
        groups:   { STRIP_GROUPS, IMAGE_SIZE, 1 },
    )!;

    gpu::TextureBarrier b_written = a_written;
    b_written.texture = image_b;
    gpu::cmd_texture_barrier(&cmd, &b_written)!;

    gpu::TextureBarrier a_read_to_write = {
        .texture = image_a,
        .before  = gpu::storage_at({ .compute }, { .read }),
        .after   = gpu::storage_at({ .compute }, { .write }),
    };
    gpu::cmd_texture_barrier(&cmd, &a_read_to_write)!;

    gpu::cmd_dispatch(
        commands: &cmd,
        root:     gpu::get_span_address(&device, blur_v_span)!,
        groups:   { STRIP_GROUPS, IMAGE_SIZE, 1 },
    )!;

    gpu::cmd_texture_barrier(&cmd, &a_written)!;

    gpu::cmd_bind_pipeline(&cmd, hist_pipe)!;
    gpu::cmd_dispatch(
        commands: &cmd,
        root:     gpu::get_span_address(&device, hist_span)!,
        groups:   { TILE_GROUPS, TILE_GROUPS, 1 },
    )!;

    gpu::Barrier bins_read = {
        .before = { .compute = true },
        .after = { .host = true },
    };
    gpu::cmd_barrier(&cmd, &bins_read)!;

    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&cmd)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::CompletionPoint completion = gpu::submit(compute_queue, &submit)!;
    defer (void)gpu::wait_completion(completion, ulong::max);
    gpu::wait_completion(completion, ulong::max)!;
    gpu::invalidate_mapped_span(&device, bins_span)!;

    print_histogram(bin_counts)!;

    if (options.wants_screenshot()) {
        sample_capture::capture_texture_png(
            device:              &device,
            producer_completion: completion,
            queue_kind:          gpu::QueueKind.COMPUTE,
            src:                 image_a,
            width:               IMAGE_SIZE,
            height:              IMAGE_SIZE,
            format:              gpu::Format.RGBA8_UNORM,
            from_state:          gpu::storage_at({ .compute }, { .read }),
            path:                options.screenshot_path,
        )!;
    }
}

<* ASCII chart plus the self-check: every pixel lands in exactly one bin. *>
fn void? print_histogram(uint* bin_counts) {
    ulong total = 0;
    uint peak = 0;
    for (uint i = 0; i < HISTOGRAM_BINS; i++) {
        total += bin_counts[i];
        if (bin_counts[i] > peak) peak = bin_counts[i];
    }
    io::printfn("luminance histogram (%d bins, peak %d):", HISTOGRAM_BINS, peak);
    const uint BINS_PER_COL = HISTOGRAM_BINS / CHART_COLS;
    for (uint row = 0; row < CHART_ROWS; row++) {
        uint threshold = peak * (CHART_ROWS - row) / CHART_ROWS;
        char[CHART_COLS] line;
        for (uint col = 0; col < CHART_COLS; col++) {
            uint col_peak = 0;
            for (uint b = col * BINS_PER_COL; b < (col + 1) * BINS_PER_COL; b++) {
                if (bin_counts[b] > col_peak) col_peak = bin_counts[b];
            }
            line[col] = col_peak >= threshold && col_peak > 0 ? '#' : ' ';
        }
        io::printfn("|%s|", (String)line[..]);
    }

    ulong expected = (ulong)IMAGE_SIZE * IMAGE_SIZE;
    if (total != expected) {
        io::printfn("bin sum %d != pixel count %d", total, expected);
        return gpu::INVALID_RESOURCE_STATE~;
    }
    io::printfn("bin sum == %d pixels: OK", total);
}
