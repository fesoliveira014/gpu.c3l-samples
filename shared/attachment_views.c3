module sample_attachment_views;

import gpu;
import std::core::mem;

struct AttachmentViewCache {
    gpu::Device                 device;
    gpu::AttachmentViewHandle[] views;
    gpu::TextureHandle[]        textures;
    gpu::CompletionPoint        completion;
}

fn AttachmentViewCache? create_attachment_view_cache(
    gpu::Device* device,
    uint image_count,
) {
    if (device == null || !device.is_valid()) return gpu::INVALID_HANDLE~;
    gpu::AttachmentViewHandle[] views = image_count > 0
        ? mem::new_array(gpu::AttachmentViewHandle, image_count)
        : {};
    gpu::TextureHandle[] textures = image_count > 0
        ? mem::new_array(gpu::TextureHandle, image_count)
        : {};
    return {
        .device   = *device,
        .views    = views,
        .textures = textures,
    };
}

fn void? clear_attachment_views(
    AttachmentViewCache* cache,
) {
    if (cache == null || !cache.device.is_valid()) return gpu::INVALID_HANDLE~;
    if (cache.completion.is_valid()) {
        gpu::wait_completion(cache.completion, ulong::max)!;
        cache.completion = gpu::COMPLETION_POINT_INVALID;
    }
    foreach (i, view : cache.views) {
        if (view.is_valid()) {
            gpu::destroy_attachment_view(&cache.device, view)!;
            cache.views[i] = gpu::ATTACHMENT_VIEW_INVALID;
            cache.textures[i] = gpu::TEXTURE_HANDLE_INVALID;
        }
    }
}

fn void? retire_attachment_views(
    AttachmentViewCache* cache,
    gpu::CompletionPoint completion,
) {
    if (cache == null || !cache.device.is_valid()) return gpu::INVALID_HANDLE~;
    if (!completion.is_valid()) return gpu::INVALID_HANDLE~;
    cache.completion = completion;
}

fn void? resize_attachment_view_cache(
    AttachmentViewCache* cache,
    uint image_count,
) {
    if (cache == null || !cache.device.is_valid()) return gpu::INVALID_HANDLE~;
    foreach (view : cache.views) {
        if (view.is_valid()) return gpu::RESOURCE_IN_USE~;
    }
    mem::free(cache.views.ptr);
    mem::free(cache.textures.ptr);
    cache.views = image_count > 0
        ? mem::new_array(gpu::AttachmentViewHandle, image_count)
        : {};
    cache.textures = image_count > 0
        ? mem::new_array(gpu::TextureHandle, image_count)
        : {};
}

fn gpu::AttachmentViewHandle? attachment_view_for(
    AttachmentViewCache* cache,
    gpu::AcquiredImage image,
) {
    if (cache == null || !cache.device.is_valid()) return gpu::INVALID_HANDLE~;
    if (image.index >= cache.views.len) return gpu::INVALID_ARGUMENT~;
    if (cache.views[image.index].is_valid()) {
        if (cache.textures[image.index] != image.texture) {
            return gpu::INVALID_RESOURCE_STATE~;
        }
        return cache.views[image.index];
    }
    gpu::AttachmentViewDesc desc = { .texture = image.texture };
    cache.views[image.index] = gpu::create_attachment_view(
        &cache.device,
        &desc,
    )!;
    cache.textures[image.index] = image.texture;
    return cache.views[image.index];
}

fn void? destroy_attachment_view_cache(AttachmentViewCache* cache) {
    if (cache == null || !cache.device.is_valid()) return gpu::INVALID_HANDLE~;
    clear_attachment_views(cache)!;
    mem::free(cache.views.ptr);
    mem::free(cache.textures.ptr);
    *cache = {};
}
