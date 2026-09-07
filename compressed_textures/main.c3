module compressed_textures;

import gpu;
import gpu::util;
import sample_args;
import sample_camera;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::core::mem;
import std::io;
import std::math;

const char[*] QUAD_VERT_SPIRV = $embed("shaders/quad.vert.spv");
const char[*] QUAD_FRAG_SPIRV = $embed("shaders/quad.frag.spv");

const uint TEX_SIZE = 128;
const uint MIP_LEVELS = 8;
const usz BLOCK_BYTES = 8;
const usz UPLOAD_BYTES_PER_SLOT = SceneRoot::size;

const uint QUAD_VERTEX_COUNT = 12;
const uint QUAD_VERTEX_VEC4S = QUAD_VERTEX_COUNT * 2;
const usz  QUAD_VERTEX_BYTES = QUAD_VERTEX_VEC4S * gpu::Vec4f::size;
const usz  RGBA8_TEXEL_BYTES = 4;
const usz  STAGING_ALIGNMENT = 16;
const float QUAD_HALF = 1.0f;
const float QUAD_GAP = 0.15f;
const float ORBIT_RADIUS = 5.0f;

struct Rgba {
    char r;
    char g;
    char b;
    char a;
}

<* Bright bands, a soft radial gradient, and a hard-edged disc so BC1 sees
   both smooth and high-contrast blocks. *>
fn Rgba color_source(uint x, uint y, uint size) {
    float fx = ((float)x + 0.5f) / (float)size;
    float fy = ((float)y + 0.5f) / (float)size;
    float dx = fx - 0.5f;
    float dy = fy - 0.5f;
    float radial = 1.0f - math::sqrt(dx * dx + dy * dy) * 1.2f;
    if (radial < 0.0f) radial = 0.0f;
    bool band = ((x / 8) + (y / 8)) % 2 == 0;
    bool disc = dx * dx + dy * dy < 0.06f;
    float r = disc ? 0.95f : (band ? 0.9f * fx : 0.2f);
    float g = disc ? 0.3f  : (band ? 0.3f : 0.85f * fy);
    float b = disc ? 0.2f  : 0.35f + 0.6f * radial;
    return {
        .r = (char)(r * 255.0f),
        .g = (char)(g * 255.0f),
        .b = (char)(b * 255.0f),
        .a = (char)255,
    };
}

<* Height field: crossed sine ridges plus a hashed grain; BC4 keeps one
   channel of it. *>
fn char gray_source(uint x, uint y, uint size) {
    float fx = (float)x / (float)size;
    float fy = (float)y / (float)size;
    float ridges = 0.5f + 0.25f * (math::sin(fx * 25.0f) + math::sin(fy * 19.0f + fx * 6.0f));
    uint hash = (x * 73856093u) ^ (y * 19349663u);
    float grain = (float)(hash % 61) / 61.0f * 0.2f;
    float v = ridges * 0.8f + grain;
    if (v > 1.0f) v = 1.0f;
    if (v < 0.0f) v = 0.0f;
    return (char)(v * 255.0f);
}

fn void write_color_mip0(Rgba[] out, uint size) {
    for (uint y = 0; y < size; y++) {
        for (uint x = 0; x < size; x++) out[y * size + x] = color_source(x, y, size);
    }
}

fn void write_gray_mip0(char[] out, uint size) {
    for (uint y = 0; y < size; y++) {
        for (uint x = 0; x < size; x++) out[y * size + x] = gray_source(x, y, size);
    }
}

<* 2x2 box filter; a 1-wide axis repeats its single column or row. *>
fn void downsample_color(Rgba[] src, uint src_size, Rgba[] dst, uint dst_size) {
    uint step = src_size > 1 ? 2 : 1;
    for (uint y = 0; y < dst_size; y++) {
        for (uint x = 0; x < dst_size; x++) {
            uint[4] sum;
            for (uint sy = 0; sy < step; sy++) {
                for (uint sx = 0; sx < step; sx++) {
                    Rgba p = src[(y * step + sy) * src_size + x * step + sx];
                    sum[0] += p.r;
                    sum[1] += p.g;
                    sum[2] += p.b;
                    sum[3] += p.a;
                }
            }
            uint count = step * step;
            dst[y * dst_size + x] = {
                .r = (char)(sum[0] / count),
                .g = (char)(sum[1] / count),
                .b = (char)(sum[2] / count),
                .a = (char)(sum[3] / count),
            };
        }
    }
}

fn void downsample_gray(char[] src, uint src_size, char[] dst, uint dst_size) {
    uint step = src_size > 1 ? 2 : 1;
    for (uint y = 0; y < dst_size; y++) {
        for (uint x = 0; x < dst_size; x++) {
            uint sum;
            for (uint sy = 0; sy < step; sy++) {
                for (uint sx = 0; sx < step; sx++) {
                    sum += src[(y * step + sy) * src_size + x * step + sx];
                }
            }
            dst[y * dst_size + x] = (char)(sum / (step * step));
        }
    }
}

fn uint luminance(Rgba p) => 299u * p.r + 587u * p.g + 114u * p.b;

fn ushort to_rgb565(Rgba p) => (ushort)(((uint)p.r >> 3) << 11 | ((uint)p.g >> 2) << 5 | (uint)p.b >> 3);

fn uint[<3>] from_rgb565(ushort c) {
    uint r = (c >> 11) & 31;
    uint g = (c >> 5) & 63;
    uint b = c & 31;
    return { (r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2) };
}

fn uint color_distance(uint[<3>] a, Rgba p) {
    int dr = (int)a[0] - p.r;
    int dg = (int)a[1] - p.g;
    int db = (int)a[2] - p.b;
    return (uint)(dr * dr + dg * dg + db * db);
}

<* Encodes one 4x4 block as BC1: RGB565 endpoints from the brightest and
   darkest texels, four-color mode, and the nearest palette entry per texel.
   Texels beyond the mip edge repeat the last texel. *>
fn void encode_bc1_block(Rgba[] pixels, uint size, uint bx, uint by, char[] out) {
    Rgba[16] texels;
    for (uint i = 0; i < 16; i++) {
        uint x = bx * 4 + i % 4;
        uint y = by * 4 + i / 4;
        if (x >= size) x = size - 1;
        if (y >= size) y = size - 1;
        texels[i] = pixels[y * size + x];
    }
    Rgba brightest = texels[0];
    Rgba darkest = texels[0];
    for (uint i = 1; i < 16; i++) {
        if (luminance(texels[i]) > luminance(brightest)) brightest = texels[i];
        if (luminance(texels[i]) < luminance(darkest)) darkest = texels[i];
    }
    ushort c0 = to_rgb565(brightest);
    ushort c1 = to_rgb565(darkest);
    if (c0 < c1) @swap(c0, c1);
    uint[<3>] p0 = from_rgb565(c0);
    uint[<3>] p1 = from_rgb565(c1);
    uint[<3>][4] palette = { p0, p1, (2 * p0 + p1) / 3, (p0 + 2 * p1) / 3 };
    out[0] = (char)(c0 & 0xFF);
    out[1] = (char)(c0 >> 8);
    out[2] = (char)(c1 & 0xFF);
    out[3] = (char)(c1 >> 8);
    for (uint row = 0; row < 4; row++) {
        uint bits;
        for (uint col = 0; col < 4; col++) {
            Rgba p = texels[row * 4 + col];
            uint best = 0;
            uint best_distance = uint::max;
            uint candidates = c0 == c1 ? 1 : 4;
            for (uint k = 0; k < candidates; k++) {
                uint d = color_distance(palette[k], p);
                if (d < best_distance) {
                    best_distance = d;
                    best = k;
                }
            }
            bits |= best << (col * 2);
        }
        out[4 + row] = (char)bits;
    }
}

<* Encodes one 4x4 block as BC4: byte endpoints from the block extremes,
   eight-value mode, 3-bit indices packed LSB first across six bytes. *>
fn void encode_bc4_block(char[] pixels, uint size, uint bx, uint by, char[] out) {
    char[16] texels;
    for (uint i = 0; i < 16; i++) {
        uint x = bx * 4 + i % 4;
        uint y = by * 4 + i / 4;
        if (x >= size) x = size - 1;
        if (y >= size) y = size - 1;
        texels[i] = pixels[y * size + x];
    }
    uint r0 = texels[0];
    uint r1 = texels[0];
    for (uint i = 1; i < 16; i++) {
        if (texels[i] > r0) r0 = texels[i];
        if (texels[i] < r1) r1 = texels[i];
    }
    uint[8] palette;
    palette[0] = r0;
    palette[1] = r1;
    for (uint k = 2; k < 8; k++) palette[k] = ((8 - k) * r0 + (k - 1) * r1) / 7;
    out[0] = (char)r0;
    out[1] = (char)r1;
    ulong bits;
    for (uint i = 0; i < 16; i++) {
        uint value = texels[i];
        uint best = 0;
        uint best_distance = uint::max;
        uint candidates = r0 == r1 ? 1 : 8;
        for (uint k = 0; k < candidates; k++) {
            uint d = palette[k] > value ? palette[k] - value : value - palette[k];
            if (d < best_distance) {
                best_distance = d;
                best = k;
            }
        }
        bits |= (ulong)best << (i * 3);
    }
    for (uint i = 0; i < 6; i++) out[2 + i] = (char)(bits >> (i * 8));
}

fn uint blocks_across(uint size) => (size + 3) / 4;

fn void encode_bc1_mip(Rgba[] pixels, uint size, char[] out) {
    uint blocks = blocks_across(size);
    for (uint by = 0; by < blocks; by++) {
        for (uint bx = 0; bx < blocks; bx++) {
            usz offset = ((usz)by * blocks + bx) * BLOCK_BYTES;
            encode_bc1_block(
                pixels: pixels,
                size:   size,
                bx:     bx,
                by:     by,
                out:    out[offset : BLOCK_BYTES],
            );
        }
    }
}

fn void encode_bc4_mip(char[] pixels, uint size, char[] out) {
    uint blocks = blocks_across(size);
    for (uint by = 0; by < blocks; by++) {
        for (uint bx = 0; bx < blocks; bx++) {
            usz offset = ((usz)by * blocks + bx) * BLOCK_BYTES;
            encode_bc4_block(
                pixels: pixels,
                size:   size,
                bx:     bx,
                by:     by,
                out:    out[offset : BLOCK_BYTES],
            );
        }
    }
}

<* Encodes every mip of both textures into `staging`; the BC4 chain starts
   at `gray_offset`. *>
fn void? encode_chains(
    gpu::TextureDesc* color_desc,
    gpu::TextureDesc* gray_desc,
    char[] staging,
    usz gray_offset,
) {
    Rgba[] color_a = mem::new_array(Rgba, (usz)TEX_SIZE * TEX_SIZE);
    defer free(color_a.ptr);
    Rgba[] color_b = mem::new_array(Rgba, (usz)TEX_SIZE * TEX_SIZE);
    defer free(color_b.ptr);
    char[] gray_a = mem::new_array(char, (usz)TEX_SIZE * TEX_SIZE);
    defer free(gray_a.ptr);
    char[] gray_b = mem::new_array(char, (usz)TEX_SIZE * TEX_SIZE);
    defer free(gray_b.ptr);

    write_color_mip0(color_a, TEX_SIZE);
    write_gray_mip0(gray_a, TEX_SIZE);
    usz color_offset = 0;
    usz gray_cursor = gray_offset;
    uint previous_size = TEX_SIZE;
    for (uint mip = 0; mip < MIP_LEVELS; mip++) {
        uint size = gpu::texture_mip_dimension(TEX_SIZE, mip);
        if (mip > 0) {
            downsample_color(
                src:      color_b,
                src_size: previous_size,
                dst:      color_a,
                dst_size: size,
            );
            downsample_gray(
                src:      gray_b,
                src_size: previous_size,
                dst:      gray_a,
                dst_size: size,
            );
        }
        usz color_bytes = gpu::texture_mip_bytes(color_desc, mip)!;
        usz gray_bytes = gpu::texture_mip_bytes(gray_desc, mip)!;
        encode_bc1_mip(color_a, size, staging[color_offset : color_bytes]);
        encode_bc4_mip(gray_a, size, staging[gray_cursor : gray_bytes]);
        color_offset += color_bytes;
        gray_cursor += gray_bytes;
        Rgba[] color_swap = color_a;
        color_a = color_b;
        color_b = color_swap;
        char[] gray_swap = gray_a;
        gray_a = gray_b;
        gray_b = gray_swap;
        previous_size = size;
    }
}

fn usz? chain_bytes(gpu::TextureDesc* desc) {
    usz total;
    for (uint mip = 0; mip < desc.mip_levels; mip++) total += gpu::texture_mip_bytes(desc, mip)!;
    return total;
}

fn usz rgba8_chain_bytes(uint size, uint mip_levels) {
    usz total;
    for (uint mip = 0; mip < mip_levels; mip++) {
        usz dim = gpu::texture_mip_dimension(size, mip);
        total += dim * dim * RGBA8_TEXEL_BYTES;
    }
    return total;
}

fn void? report_bc_support(gpu::Device* device) {
    gpu::Format[6] formats = {
        gpu::Format.BC1_RGBA_UNORM,
        gpu::Format.BC3_UNORM,
        gpu::Format.BC4_UNORM,
        gpu::Format.BC5_UNORM,
        gpu::Format.BC6H_UFLOAT,
        gpu::Format.BC7_UNORM,
    };
    foreach (format : formats) {
        gpu::TextureDesc probe = {
            .width  = 4,
            .height = 4,
            .format = format,
            .usage  = { .sampled, .transfer_dst },
            .access = { .graphics },
        };
        bool supported = gpu::supports_texture_desc(device, &probe)!;
        io::printfn("  %-14s %s", format, supported ? "supported" : "unsupported");
    }
}

fn void write_quad_vertices(float* out) {
    float h = QUAD_HALF;
    float g = QUAD_GAP;
    gpu::Vec4f[QUAD_VERTEX_VEC4S] data = {
        { -2 * h - g, -h, 0, 0 }, { 0, 1, 0, 0 },
        { -g, -h, 0, 0 },         { 1, 1, 0, 0 },
        { -g, h, 0, 0 },          { 1, 0, 0, 0 },
        { -2 * h - g, -h, 0, 0 }, { 0, 1, 0, 0 },
        { -g, h, 0, 0 },          { 1, 0, 0, 0 },
        { -2 * h - g, h, 0, 0 },  { 0, 0, 0, 0 },
        { g, -h, 0, 0 },          { 0, 1, 0, 0 },
        { 2 * h + g, -h, 0, 0 },  { 1, 1, 0, 0 },
        { 2 * h + g, h, 0, 0 },   { 1, 0, 0, 0 },
        { g, -h, 0, 0 },          { 0, 1, 0, 0 },
        { 2 * h + g, h, 0, 0 },   { 1, 0, 0, 0 },
        { g, h, 0, 0 },           { 0, 0, 0, 0 },
    };
    for (uint i = 0; i < QUAD_VERTEX_VEC4S; i++) {
        for (uint c = 0; c < 4; c++) out[i * 4 + c] = data[i][c];
    }
}

fn void write_matrix(gpu::Mat4f* out, sample_camera::Mat4 m) {
    for (uint c = 0; c < 4; c++) {
        (*out)[c] = { m[c * 4], m[c * 4 + 1], m[c * 4 + 2], m[c * 4 + 3] };
    }
}

fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        io::printfn("compressed_textures: FAIL (%s)", err);
        return 1;
    }
    io::printn("compressed_textures: PASS");
    return 0;
}

fn void? run(sample_args::Options options) {
    sample_window::SampleWindow window = sample_window::create_sample_window("gpu.c3l compressed textures", 1024, 600)!;
    defer sample_window::destroy_sample_window(&window);

    util::DeviceContextDesc desc = util::default_device_context_desc();
    desc.runtime.enable_vulkan_validation = true;
    desc.runtime.application_name = "compressed_textures";
    desc.create_surface = &sample_window::surface_factory;
    desc.surface_user_data = &window;
    sample_window::pixel_size(&window, &desc.swapchain.width, &desc.swapchain.height);
    desc.swapchain.present_mode = options.vsync ? gpu::PresentMode.FIFO : gpu::PresentMode.MAILBOX;
    desc.swapchain.debug_name = "compressed_swapchain";
    util::DeviceContext context = util::create_device_context(&desc)!;
    defer util::destroy_device_context(&context);
    defer (void)gpu::wait_swapchain_presentations(&context.device, context.swapchain);
    gpu::Device* device = &context.device;
    gpu::SwapchainHandle swapchain = context.swapchain;
    gpu::SwapchainInfo swapchain_info = gpu::get_swapchain_info(device, swapchain)!;

    io::printn("compressed_textures: block-compressed format support");
    report_bc_support(device)!;

    gpu::TextureDesc color_desc = {
        .width      = TEX_SIZE,
        .height     = TEX_SIZE,
        .mip_levels = MIP_LEVELS,
        .format     = gpu::Format.BC1_RGBA_UNORM,
        .usage      = { .sampled, .transfer_dst },
        .access     = { .graphics },
        .debug_name = "bc1_pattern",
    };
    gpu::TextureDesc gray_desc = color_desc;
    gray_desc.format = gpu::Format.BC4_UNORM;
    gray_desc.debug_name = "bc4_height";
    if (!gpu::supports_texture_desc(device, &color_desc)! || !gpu::supports_texture_desc(device, &gray_desc)!) {
        io::printn("compressed_textures: BC1 or BC4 sampling unsupported on this device");
        return gpu::UNSUPPORTED_FEATURE~;
    }
    gpu::TextureHandle color_tex = gpu::create_texture(device, &color_desc)!;
    defer (void)gpu::destroy_texture(device, color_tex);
    gpu::TextureHandle gray_tex = gpu::create_texture(device, &gray_desc)!;
    defer (void)gpu::destroy_texture(device, gray_tex);

    usz color_bytes = chain_bytes(&color_desc)!;
    usz gray_bytes = chain_bytes(&gray_desc)!;
    usz gray_offset = (color_bytes + STAGING_ALIGNMENT - 1) / STAGING_ALIGNMENT * STAGING_ALIGNMENT;
    io::printfn(
        "compressed_textures: %dx%d, %d mips: BC1 %d bytes, BC4 %d bytes (RGBA8 would be %d)",
        TEX_SIZE,
        TEX_SIZE,
        MIP_LEVELS,
        color_bytes,
        gray_bytes,
        rgba8_chain_bytes(TEX_SIZE, MIP_LEVELS),
    );

    {
        gpu::AllocationDesc staging_desc = {
            .size         = gray_offset + gray_bytes,
            .alignment    = STAGING_ALIGNMENT,
            .memory_class = gpu::MemoryClass.CPU_WRITE,
            .access       = { .graphics },
            .debug_name   = "bc_staging",
        };
        gpu::GpuAllocation staging = gpu::allocate_memory(device, &staging_desc)!;
        defer (void)gpu::free_allocation(device, &staging);
        gpu::GpuSpan staging_span = gpu::get_allocation_span(device, staging)!;
        encode_chains(
            color_desc:  &color_desc,
            gray_desc:   &gray_desc,
            staging:     gpu::get_span_mapping(device, staging_span)!,
            gray_offset: gray_offset,
        )!;
        gpu::flush_mapped_span(device, staging_span)!;

        gpu::CommandList upload = gpu::begin_commands(&context.command_allocator)!;
        defer (void)gpu::discard_commands(&upload);
        gpu::TextureHandle[2] textures = { color_tex, gray_tex };
        gpu::TextureDesc*[2] descs = { &color_desc, &gray_desc };
        usz[2] offsets = { 0, gray_offset };
        for (uint t = 0; t < 2; t++) {
            gpu::TextureBarrier to_transfer = gpu::texture_transition(
                texture: textures[t],
                before:  { .layout = gpu::TextureLayout.UNDEFINED },
                after:   {
                    .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
                    .stages = { .transfer },
                    .access = { .write },
                },
            )!;
            gpu::cmd_texture_barrier(&upload, &to_transfer)!;
            usz offset = offsets[t];
            for (uint mip = 0; mip < MIP_LEVELS; mip++) {
                usz mip_bytes = gpu::texture_mip_bytes(descs[t], mip)!;
                gpu::BufferTextureCopyDesc copy = {
                    .src     = staging_span.checked_subspan(offset, mip_bytes)!,
                    .texture = textures[t],
                    .mip     = mip,
                };
                gpu::cmd_copy_buffer_to_texture(&upload, &copy)!;
                offset += mip_bytes;
            }
            gpu::TextureBarrier to_sample = gpu::texture_transition(
                texture: textures[t],
                before:  {
                    .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
                    .stages = { .transfer },
                    .access = { .write },
                },
                after:   gpu::sampled_at({ .fragment_shader }),
            )!;
            gpu::cmd_texture_barrier(&upload, &to_sample)!;
        }
        gpu::ExecutableCommandList[1] upload_lists = { gpu::end_commands(&upload)! };
        defer (void)gpu::discard_executable_commands(&upload_lists[0]);
        gpu::SubmitDesc upload_submit = { .command_lists = upload_lists[..] };
        gpu::wait_completion(gpu::submit(context.queue, &upload_submit)!)!;
    }

    gpu::TextureView color_view = gpu::create_texture_view(device, color_tex, null)!;
    defer (void)gpu::destroy_texture_view(device, color_view);
    gpu::TextureView gray_view = gpu::create_texture_view(device, gray_tex, null)!;
    defer (void)gpu::destroy_texture_view(device, gray_view);

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .mip_filter = gpu::Filter.LINEAR,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
        .max_lod    = (float)MIP_LEVELS,
    };
    gpu::SamplerIndex trilinear = gpu::intern_sampler(device, &sampler_desc)!;

    gpu::AllocationDesc vertex_desc = {
        .size         = QUAD_VERTEX_BYTES,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = { .graphics },
        .debug_name   = "quad_vertices",
    };
    gpu::GpuAllocation vertices = gpu::allocate_memory(device, &vertex_desc)!;
    defer (void)gpu::free_allocation(device, &vertices);
    gpu::GpuSpan vertex_span = gpu::get_allocation_span(device, vertices)!;
    write_quad_vertices((float*)gpu::get_span_mapping(device, vertex_span)!.ptr);
    gpu::flush_mapped_span(device, vertex_span)!;
    gpu::GpuAddress vertex_address = gpu::get_span_address(device, vertex_span)!;

    gpu::QueueRoles upload_access = { .graphics };
    sample_frame_upload::FrameUploadRing upload_ring =
        sample_frame_upload::create_frame_upload_ring(
            device:        device,
            slot_capacity: UPLOAD_BYTES_PER_SLOT,
            access:        upload_access,
            debug_name:    "compressed_textures_frame_upload",
        )!;
    defer (void)sample_frame_upload::destroy_frame_upload_ring(&upload_ring);

    gpu::Format[1] color_formats = { swapchain_info.format };
    gpu::ColorTargetState[1] color_targets = { gpu::color_blend_disabled() };
    gpu::GraphicsPipelineDesc pipe_desc = {
        .vertex_shader   = { .spirv = QUAD_VERT_SPIRV[..], .entry_point = "main" },
        .fragment_shader = { .spirv = QUAD_FRAG_SPIRV[..], .entry_point = "main" },
        .color_formats   = color_formats[..],
        .debug_name      = "compressed_textures",
    };
    gpu::PipelineHandle pipeline;
    bool pipeline_valid = false;
    if (!swapchain_info.dormant) {
        pipeline = gpu::create_graphics_pipeline(device, &pipe_desc)!;
        pipeline_valid = true;
    }
    defer {
        if (pipeline_valid) (void)gpu::destroy_pipeline(device, pipeline);
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
            swapchain_info = sample_window::recover_swapchain(device, swapchain, &window)!;
        }
        if (swapchain_info.dormant) {
            sample_window::throttle_dormant();
            continue;
        }
        if (!pipeline_valid || color_formats[0] != swapchain_info.format) {
            if (last_graphics.is_valid()) gpu::wait_completion(last_graphics, ulong::max)!;
            if (pipeline_valid) gpu::destroy_pipeline(device, pipeline)!;
            pipeline_valid = false;
            color_formats[0] = swapchain_info.format;
            pipeline = gpu::create_graphics_pipeline(device, &pipe_desc)!;
            pipeline_valid = true;
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

        // Tilt and pull back over time so the sampler walks the mip chain.
        float t = (float)frame / 60.0f;
        float tilt = 0.9f * math::sin(t * 0.7f);
        float distance = ORBIT_RADIUS + 3.0f * (0.5f - 0.5f * math::cos(t * 0.5f));
        float[<3>] eye = { distance * math::sin(tilt), 0.6f, distance * math::cos(tilt) };
        sample_camera::Mat4 view_proj = sample_camera::mul(
            sample_camera::perspective(
                fov_y_radians: 0.9f,
                aspect:        (float)swapchain_info.width / (float)swapchain_info.height,
                near:          0.1f,
                far:           100.0f,
            ),
            sample_camera::look_at(eye, { 0.0f, 0.0f, 0.0f }, { 0.0f, 1.0f, 0.0f }));

        gpu::GpuSpan root_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload_batch,
            size:      SceneRoot::size,
            alignment: 16,
        )!;
        SceneRoot* root = (SceneRoot*)gpu::get_span_mapping(device, root_span)!.ptr;
        write_matrix(&root.view_proj, view_proj);
        root.vertex_gpu = vertex_address;
        root.color_tex  = color_view.index;
        root.gray_tex   = gray_view.index;
        root.trilinear  = trilinear;
        gpu::GpuAddress root_address = gpu::get_span_address(device, root_span)!;

        gpu::ColorTargetDesc[1] colors = {{
            .view     = acquired.attachment_view,
            .load_op  = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear    = { .rgba = { 0.08f, 0.09f, 0.12f, 1.0f } },
        }};
        gpu::RenderPassDesc pass = {
            .colors = colors[..],
            .width  = swapchain_info.width,
            .height = swapchain_info.height,
        };
        gpu::GraphicsState graphics = gpu::render_geometry_state(pass.width, pass.height)!;
        graphics.color.targets = color_targets[..];
        graphics.raster.cull_mode = gpu::CullMode.NONE;
        gpu::cmd_begin_render_pass(&cmd, &pass)!;
        gpu::cmd_bind_pipeline(&cmd, pipeline)!;
        gpu::cmd_set_graphics_state(&cmd, &graphics)!;
        gpu::cmd_draw(
            commands:       &cmd,
            vertex_root:    root_address,
            fragment_root:  root_address,
            vertex_count:   QUAD_VERTEX_COUNT,
            instance_count: 1,
        )!;
        gpu::cmd_end_render_pass(&cmd)!;

        gpu::TextureBarrier to_present = {
            .texture = acquired.texture,
            .before  = {
                .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
                .stages = { .color_output },
                .access = { .read, .write },
            },
            .after   = { .layout = gpu::TextureLayout.PRESENT },
        };
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
}
