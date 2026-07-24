module sample_capture;

import gpu;
import sample_png;

<* Read back a color target and write it as a PNG. Works on offscreen targets
   and acquired swapchain images (capture point for swapchain: post-submit,
   pre-present, with the PRESENT state). The source needs
   transfer_src usage — swapchain images carry it when the surface allows. *>
fn void? capture_texture_png(
    gpu::CommandAllocator* allocator,
    gpu::CompletionPoint producer_completion,
    gpu::TextureHandle src,
    uint width,
    uint height,
    gpu::Format format,
    gpu::TextureState from_state,
    String path,
) {
    if (allocator == null) return gpu::INVALID_HANDLE~;
    if (width == 0 || height == 0 || !producer_completion.is_valid()) {
        return gpu::INVALID_ARGUMENT~;
    }
    gpu::wait_completion(producer_completion)!;
    usz pixel_count = (usz)width * (usz)height;
    if (pixel_count > usz::max / 4) return gpu::INVALID_ARGUMENT~;
    usz byte_count = pixel_count * 4;

    gpu::QueueRoles access = allocator.queue.roles;
    gpu::AllocationDesc readback_desc = {
        .size         = byte_count,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = access,
        .debug_name   = "sample_capture_readback",
    };
    gpu::Device* device = &allocator.device;
    gpu::GpuAllocation readback = gpu::allocate_memory(device, &readback_desc)!;
    defer (void)gpu::free_allocation(device, &readback);
    gpu::GpuSpan readback_span = gpu::get_allocation_span(device, readback)!;

    gpu::Queue queue = allocator.queue;
    gpu::CommandList commands = gpu::begin_commands(allocator)!;
    defer (void)gpu::discard_commands(&commands);
    gpu::TextureBarrier to_transfer = {
        .texture = src,
        .before  = from_state,
        .after   = {
            .layout = gpu::TextureLayout.TRANSFER_SOURCE,
            .stages = { .transfer },
            .access = { .read },
        },
    };
    gpu::cmd_texture_barrier(&commands, &to_transfer);
    gpu::TextureBufferCopyDesc copy = {
        .texture = src,
        .dst     = readback_span,
    };
    gpu::cmd_copy_texture_to_buffer(&commands, &copy);
    gpu::Barrier host_read = {
        .before = { .transfer = true },
        .after = { .host = true },
    };
    gpu::cmd_barrier(&commands, &host_read);
    gpu::TextureBarrier restore = {
        .texture = src,
        .before  = {
            .layout = gpu::TextureLayout.TRANSFER_SOURCE,
            .stages = { .transfer },
            .access = { .read },
        },
        .after   = from_state,
    };
    gpu::cmd_texture_barrier(&commands, &restore);
    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&commands)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::CompletionPoint completion = gpu::submit(queue, &submit)!;
    gpu::wait_completion(completion)!;
    gpu::invalidate_mapped_span(device, readback_span)!;

    char[] mapping = gpu::get_span_mapping(device, readback_span)!;
    char[] pixels = mem::new_array(char, (sz)byte_count);
    defer free(pixels.ptr);
    pixels[..] = mapping[..];
    if (format == gpu::Format.BGRA8_UNORM || format == gpu::Format.BGRA8_SRGB) {
        for (usz i = 0; i < byte_count; i += 4) {
            char b = pixels[i];
            pixels[i] = pixels[i + 2];
            pixels[i + 2] = b;
        }
    }
    return sample_png::write_png_rgba8(path, pixels, width, height);
}
