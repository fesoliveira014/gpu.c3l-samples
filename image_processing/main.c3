module image_processing;

import gpu;
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
        .usage      = { .storage, .transfer_src = capture_target },
        .debug_name = name,
    };
    return gpu::create_texture(device, &desc);
}

fn void? run(sample_args::Options options) {
    gpu::DeviceDesc device_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .frames_in_flight  = 2,
        .application_name  = "image_processing",
    };
    gpu::Device device = gpu::create_device(&device_desc)!;
    defer (void)gpu::destroy_device(&device);

    gpu::TextureHandle image_a = create_storage_image(&device, true, "plasma_a")!;
    defer (void)gpu::destroy_texture(&device, image_a);
    gpu::TextureHandle image_b = create_storage_image(&device, false, "plasma_b")!;
    defer (void)gpu::destroy_texture(&device, image_b);
    gpu::TextureIndex index_a = gpu::create_texture_descriptor(&device, image_a, null)!;
    defer (void)gpu::destroy_texture_descriptor(&device, index_a);
    gpu::TextureIndex index_b = gpu::create_texture_descriptor(&device, image_b, null)!;
    defer (void)gpu::destroy_texture_descriptor(&device, index_b);

    gpu::BufferDesc bins_desc = {
        .size        = HISTOGRAM_BINS * 4,
        .usage       = { .storage, .addressable },
        .memory_kind = gpu::MemoryKind.PERSISTENT_UPLOAD,
        .debug_name  = "histogram_bins",
    };
    gpu::BufferHandle bins = gpu::create_buffer(&device, &bins_desc)!;
    defer (void)gpu::destroy_buffer(&device, bins);
    gpu::GpuSpan bins_span = gpu::get_buffer_span(&device, bins)!;
    uint* bin_counts = (uint*)bins_span.cpu;
    for (uint i = 0; i < HISTOGRAM_BINS; i++) bin_counts[i] = 0;
    gpu::flush_buffer(&device, bins, 0, 0)!;

    gpu::ShaderDesc gen_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = GENERATE_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle gen_shader = gpu::create_shader(&device, &gen_sd)!;
    defer (void)gpu::destroy_shader(&device, gen_shader);
    gpu::ShaderDesc blur_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = BLUR_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle blur_shader = gpu::create_shader(&device, &blur_sd)!;
    defer (void)gpu::destroy_shader(&device, blur_shader);
    gpu::ShaderDesc hist_sd = { .stage = gpu::ShaderStage.COMPUTE, .spirv = HISTOGRAM_SPIRV[..], .entry_point = "main" };
    gpu::ShaderHandle hist_shader = gpu::create_shader(&device, &hist_sd)!;
    defer (void)gpu::destroy_shader(&device, hist_shader);

    gpu::ComputePipelineDesc gen_pd = { .shader = gen_shader, .push_constant_size = gpu::RootPush::size, .debug_name = "generate" };
    gpu::PipelineHandle gen_pipe = gpu::create_compute_pipeline(&device, &gen_pd)!;
    defer (void)gpu::destroy_pipeline(&device, gen_pipe);
    gpu::ComputePipelineDesc blur_pd = { .shader = blur_shader, .push_constant_size = gpu::RootPush::size, .debug_name = "blur" };
    gpu::PipelineHandle blur_pipe = gpu::create_compute_pipeline(&device, &blur_pd)!;
    defer (void)gpu::destroy_pipeline(&device, blur_pipe);
    gpu::ComputePipelineDesc hist_pd = { .shader = hist_shader, .push_constant_size = gpu::RootPush::size, .debug_name = "histogram" };
    gpu::PipelineHandle hist_pipe = gpu::create_compute_pipeline(&device, &hist_pd)!;
    defer (void)gpu::destroy_pipeline(&device, hist_pipe);

    gpu::begin_frame(&device)!;

    gpu::GpuSpan gen_span = gpu::alloc_frame_span(&device, GenerateRoot::size, 16)!;
    GenerateRoot* gen_root = (GenerateRoot*)gen_span.cpu;
    gen_root.target = index_a;
    gen_root.size   = IMAGE_SIZE;
    gen_root.seed   = 3.7f;

    gpu::GpuSpan blur_h_span = gpu::alloc_frame_span(&device, BlurRoot::size, 16)!;
    BlurRoot* blur_h = (BlurRoot*)blur_h_span.cpu;
    blur_h.src        = index_a;
    blur_h.dst        = index_b;
    blur_h.size       = IMAGE_SIZE;
    blur_h.horizontal = 1;

    gpu::GpuSpan blur_v_span = gpu::alloc_frame_span(&device, BlurRoot::size, 16)!;
    BlurRoot* blur_v = (BlurRoot*)blur_v_span.cpu;
    blur_v.src        = index_b;
    blur_v.dst        = index_a;
    blur_v.size       = IMAGE_SIZE;
    blur_v.horizontal = 0;

    gpu::GpuSpan hist_span = gpu::alloc_frame_span(&device, HistogramRoot::size, 16)!;
    HistogramRoot* hist_root = (HistogramRoot*)hist_span.cpu;
    hist_root.bins_gpu = bins_span.gpu;
    hist_root.src      = index_a;
    hist_root.size     = IMAGE_SIZE;

    gpu::CommandList cmd = gpu::begin_commands(&device, gpu::QueueKind.COMPUTE)!;

    gpu::TextureHandle[2] images = { image_a, image_b };
    foreach (image : images) {
        gpu::TextureBarrier to_general = {
            .texture       = image,
            .before_stage  = gpu::Stage.HOST,
            .after_stage   = gpu::Stage.COMPUTE_SHADER,
            .before_hazard = gpu::Hazard.HOST_WRITE,
            .after_hazard  = gpu::Hazard.SHADER_WRITE,
            .old_layout    = gpu::TextureLayout.UNDEFINED,
            .new_layout    = gpu::TextureLayout.GENERAL,
        };
        gpu::cmd_texture_barrier(&cmd, &to_general)!;
    }

    const uint TILE_GROUPS = (IMAGE_SIZE + GEN_TILE - 1) / GEN_TILE;
    const uint STRIP_GROUPS = (IMAGE_SIZE + BLUR_TILE - 1) / BLUR_TILE;

    gpu::cmd_dispatch(
        commands: &cmd,
        pipeline: gen_pipe,
        root:     gen_span.gpu,
        groups:   { TILE_GROUPS, TILE_GROUPS, 1 },
    )!;

    // Storage write -> storage read between every chain stage.
    gpu::TextureBarrier a_written = {
        .texture       = image_a,
        .before_stage  = gpu::Stage.COMPUTE_SHADER,
        .after_stage   = gpu::Stage.COMPUTE_SHADER,
        .before_hazard = gpu::Hazard.SHADER_WRITE,
        .after_hazard  = gpu::Hazard.SHADER_READ,
        .old_layout    = gpu::TextureLayout.GENERAL,
        .new_layout    = gpu::TextureLayout.GENERAL,
    };
    gpu::cmd_texture_barrier(&cmd, &a_written)!;

    gpu::cmd_dispatch(
        commands: &cmd,
        pipeline: blur_pipe,
        root:     blur_h_span.gpu,
        groups:   { STRIP_GROUPS, IMAGE_SIZE, 1 },
    )!;

    gpu::TextureBarrier b_written = a_written;
    b_written.texture = image_b;
    gpu::cmd_texture_barrier(&cmd, &b_written)!;

    gpu::cmd_dispatch(
        commands: &cmd,
        pipeline: blur_pipe,
        root:     blur_v_span.gpu,
        groups:   { STRIP_GROUPS, IMAGE_SIZE, 1 },
    )!;

    gpu::cmd_texture_barrier(&cmd, &a_written)!;

    gpu::cmd_dispatch(
        commands: &cmd,
        pipeline: hist_pipe,
        root:     hist_span.gpu,
        groups:   { TILE_GROUPS, TILE_GROUPS, 1 },
    )!;

    gpu::BufferBarrier bins_read = {
        .buffer = bins, .offset = 0, .size = HISTOGRAM_BINS * 4,
        .before_stage = gpu::Stage.COMPUTE_SHADER, .after_stage = gpu::Stage.HOST,
        .before_hazard = gpu::Hazard.SHADER_WRITE, .after_hazard = gpu::Hazard.HOST_READ,
    };
    gpu::cmd_buffer_barrier(&cmd, &bins_read)!;

    gpu::end_commands(&device, &cmd)!;
    gpu::CommandList[1] lists = { cmd };
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::submit(&device, &submit)!;
    gpu::wait_queue_idle(&device, gpu::QueueKind.COMPUTE)!;
    gpu::invalidate_buffer(&device, bins, 0, 0)!;

    print_histogram(bin_counts)!;

    if (options.wants_screenshot()) {
        sample_capture::capture_texture_png(
            device:      &device,
            src:         image_a,
            width:       IMAGE_SIZE,
            height:      IMAGE_SIZE,
            format:      gpu::Format.RGBA8_UNORM,
            from_stage:  gpu::Stage.COMPUTE_SHADER,
            from_hazard: gpu::Hazard.SHADER_READ,
            from_layout: gpu::TextureLayout.GENERAL,
            path:        options.screenshot_path,
        )!;
    }

    gpu::end_frame(&device)!;
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
