module sample_capture;

import gpu;
import sample_png;

<* Read back a color target and write it as a PNG. Works on offscreen targets
   and acquired swapchain images (capture point for swapchain: post-submit,
   pre-present, with the PRESENT stage/hazard/layout triple). The source needs
   transfer_src usage — swapchain images carry it when the surface allows. *>
fn void? capture_texture_png(
    gpu::Device* device,
    gpu::TextureHandle src,
    uint width,
    uint height,
    gpu::Format format,
    gpu::Stage from_stage,
    gpu::Hazard from_hazard,
    gpu::TextureLayout from_layout,
    String path,
) {
    usz byte_count = (usz)width * height * 4;
    char[] pixels = mem::new_array(char, (sz)byte_count);
    defer free(pixels.ptr);
    gpu::readback_texture_data(
        device:      device,
        src:         src,
        mip:         0,
        out_data:    pixels,
        from_stage:  from_stage,
        from_hazard: from_hazard,
        from_layout: from_layout,
    )!;
    if (format == gpu::Format.BGRA8_UNORM || format == gpu::Format.BGRA8_SRGB) {
        for (usz i = 0; i < byte_count; i += 4) {
            char b = pixels[i];
            pixels[i] = pixels[i + 2];
            pixels[i + 2] = b;
        }
    }
    return sample_png::write_png_rgba8(path, pixels, width, height);
}
