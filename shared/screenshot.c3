module sample_capture;

import gpu;
import sample_png;

<* A recorded color-target readback awaiting completion. *>
struct Capture {
    gpu::Device*      device;
    gpu::GpuAllocation readback;
    gpu::GpuSpan      span;
    uint              width;
    uint              height;
    gpu::Format       format;
}

fn bool Capture.is_valid(&self) => self.readback.is_valid();

<* Record a readback of `src` into a fresh CPU_READ allocation inside the
   caller's command list, leaving the texture in `from_state`. `access` names
   the recording queue's roles. Finish with finish_capture after the list's
   completion point. *>
fn Capture? record_capture(
    gpu::Device* device,
    gpu::CommandList* commands,
    gpu::TextureHandle src,
    uint width,
    uint height,
    gpu::Format format,
    gpu::TextureState from_state,
    gpu::QueueRoles access,
) {
    if (width == 0 || height == 0) return gpu::INVALID_ARGUMENT~;
    usz pixel_count = (usz)width * (usz)height;
    if (pixel_count > usz::max / 4) return gpu::INVALID_ARGUMENT~;
    gpu::AllocationDesc readback_desc = {
        .size         = pixel_count * 4,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = access,
        .debug_name   = "sample_capture_readback",
    };
    gpu::GpuAllocation readback = gpu::allocate_memory(device, &readback_desc)!;
    defer catch (void)gpu::free_allocation(device, &readback);
    gpu::GpuSpan span = gpu::get_allocation_span(device, readback)!;

    gpu::TextureState transfer_source = {
        .layout = gpu::TextureLayout.TRANSFER_SOURCE,
        .stages = { .transfer },
        .access = { .read },
    };
    gpu::TextureBarrier to_transfer = { .texture = src, .before = from_state, .after = transfer_source };
    gpu::cmd_texture_barrier(commands, &to_transfer)!;
    gpu::TextureBufferCopyDesc copy = { .texture = src, .dst = span };
    gpu::cmd_copy_texture_to_buffer(commands, &copy)!;
    gpu::Barrier host_read = { .before = { .transfer = true }, .after = { .host = true } };
    gpu::cmd_barrier(commands, &host_read)!;
    gpu::TextureBarrier restore = { .texture = src, .before = transfer_source, .after = from_state };
    gpu::cmd_texture_barrier(commands, &restore)!;
    return {
        .device   = device,
        .readback = readback,
        .span     = span,
        .width    = width,
        .height   = height,
        .format   = format,
    };
}

<* Wait for `completion`, write the captured pixels as RGBA8 PNG, and free the
   readback. The capture is invalid afterwards. *>
fn void? finish_capture(Capture* capture, gpu::CompletionPoint completion, String path) {
    if (capture == null || !capture.is_valid()) return gpu::INVALID_ARGUMENT~;
    defer {
        (void)gpu::free_allocation(capture.device, &capture.readback);
        capture.readback = {};
    }
    gpu::wait_completion(completion)!;
    gpu::invalidate_mapped_span(capture.device, capture.span)!;
    char[] mapping = gpu::get_span_mapping(capture.device, capture.span)!;
    char[] pixels = mem::new_array(char, mapping.len);
    defer free(pixels.ptr);
    pixels[..] = mapping[..];
    if (capture.format == gpu::Format.BGRA8_UNORM || capture.format == gpu::Format.BGRA8_SRGB) {
        for (usz i = 0; i < pixels.len; i += 4) @swap(pixels[i], pixels[i + 2]);
    }
    return sample_png::write_png_rgba8(path, pixels, capture.width, capture.height);
}

<* Read back a color target and write it as a PNG in its own submit. Works on
   offscreen targets and acquired swapchain images (capture point for
   swapchain: post-submit, pre-present, with the PRESENT state). The source
   needs transfer_src usage — swapchain images carry it when the surface
   allows. Under unified layouts, swapchain images must instead use
   record_capture inside the frame's own list. *>
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
    if (!producer_completion.is_valid()) return gpu::INVALID_ARGUMENT~;
    gpu::wait_completion(producer_completion)!;
    gpu::Device* device = &allocator.device;
    gpu::CommandList commands = gpu::begin_commands(allocator)!;
    defer (void)gpu::discard_commands(&commands);
    Capture capture = record_capture(
        device:     device,
        commands:   &commands,
        src:        src,
        width:      width,
        height:     height,
        format:     format,
        from_state: from_state,
        access:     allocator.queue.roles,
    )!;
    defer catch if (capture.is_valid()) (void)gpu::free_allocation(device, &capture.readback);
    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&commands)! };
    defer (void)gpu::discard_executable_commands(&lists[0]);
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::CompletionPoint completion = gpu::submit(allocator.queue, &submit)!;
    return finish_capture(&capture, completion, path);
}
