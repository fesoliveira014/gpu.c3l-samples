module sample_frame_upload;

import gpu;

faultdef FRAME_UPLOAD_FULL;

const usz FRAME_UPLOAD_SLOT_COUNT = 2;

struct FrameUploadSlot {
    gpu::GpuAllocation allocation;
    gpu::GpuSpan       span;
    gpu::CompletionPoint completion;
}

struct FrameUploadRing {
    gpu::Device device;
    FrameUploadSlot[FRAME_UPLOAD_SLOT_COUNT] slots;
    usz slot_capacity;
    uint next_slot;
    ulong generation;
    bool active;
}

struct FrameUploadBatch {
    FrameUploadRing* ring;
    uint slot_index;
    usz cursor;
    ulong generation;
}

fn FrameUploadRing? create_frame_upload_ring(
    gpu::Device* device,
    usz slot_capacity,
    gpu::QueueRoles access,
    ZString debug_name,
) {
    if (device == null || !device.is_valid()) return gpu::INVALID_HANDLE~;
    if (slot_capacity == 0) return gpu::INVALID_ARGUMENT~;

    FrameUploadRing ring = {
        .device        = *device,
        .slot_capacity = slot_capacity,
    };
    defer catch {
        for (uint i = 0; i < FRAME_UPLOAD_SLOT_COUNT; i++) {
            if (ring.slots[i].allocation.is_valid()) {
                (void)gpu::free_allocation(&ring.device, &ring.slots[i].allocation);
            }
        }
    };

    gpu::AllocationDesc desc = {
        .size         = slot_capacity,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_WRITE,
        .access       = access,
        .debug_name   = debug_name,
    };
    for (uint i = 0; i < FRAME_UPLOAD_SLOT_COUNT; i++) {
        ring.slots[i].allocation = gpu::allocate_memory(&ring.device, &desc)!;
        ring.slots[i].span = gpu::get_allocation_span(
            &ring.device,
            ring.slots[i].allocation,
        )!;
    }
    return ring;
}

fn void? destroy_frame_upload_ring(FrameUploadRing* ring) {
    if (ring == null || !ring.device.is_valid()) return gpu::INVALID_HANDLE~;
    if (ring.active) return gpu::INVALID_RESOURCE_STATE~;

    for (uint i = 0; i < FRAME_UPLOAD_SLOT_COUNT; i++) {
        if (ring.slots[i].completion.is_valid()) {
            gpu::wait_completion(ring.slots[i].completion)!;
            ring.slots[i].completion = gpu::COMPLETION_POINT_INVALID;
        }
    }
    for (uint i = 0; i < FRAME_UPLOAD_SLOT_COUNT; i++) {
        if (ring.slots[i].allocation.is_valid()) {
            gpu::free_allocation(&ring.device, &ring.slots[i].allocation)!;
        }
    }
    *ring = {};
}

fn FrameUploadBatch? begin_frame_upload(FrameUploadRing* ring) {
    if (ring == null || !ring.device.is_valid()) return gpu::INVALID_HANDLE~;
    if (ring.active) return gpu::INVALID_RESOURCE_STATE~;

    FrameUploadSlot* slot = &ring.slots[ring.next_slot];
    if (slot.completion.is_valid()) {
        gpu::wait_completion(slot.completion)!;
        slot.completion = gpu::COMPLETION_POINT_INVALID;
    }
    return claim_frame_upload_batch(ring);
}

fn gpu::GpuSpan? alloc_frame_upload(
    FrameUploadBatch* batch,
    usz size,
    usz alignment,
) {
    validate_frame_upload_batch(batch)!;
    usz offset = reserve_frame_upload_offset(
        cursor:    &batch.cursor,
        capacity:  batch.ring.slot_capacity,
        size:      size,
        alignment: alignment,
    )!;
    return batch.ring.slots[batch.slot_index].span.checked_subspan(offset, size);
}

<* Flush after the final batch write and before its consuming submit. *>
fn void? flush_frame_upload(FrameUploadBatch* batch) {
    validate_frame_upload_batch(batch)!;
    if (batch.cursor == 0) return gpu::INVALID_ARGUMENT~;

    gpu::GpuSpan used = batch.ring.slots[batch.slot_index].span.checked_subspan(
        0,
        batch.cursor,
    )!;
    return gpu::flush_mapped_span(&batch.ring.device, used);
}

<* Retire with the exact completion returned by the submission that consumes
   every span allocated from this batch. *>
fn void? retire_frame_upload(
    FrameUploadBatch* batch,
    gpu::CompletionPoint completion,
) {
    validate_frame_upload_batch(batch)!;
    if (!completion.is_valid() || completion.device != batch.ring.device) {
        return gpu::INVALID_HANDLE~;
    }

    FrameUploadRing* ring = batch.ring;
    ring.slots[batch.slot_index].completion = completion;
    ring.next_slot = (batch.slot_index + 1) % (uint)FRAME_UPLOAD_SLOT_COUNT;
    ring.active = false;
    *batch = {};
}

<* Cancel a batch whose spans have not been submitted for GPU use. *>
fn void? cancel_frame_upload(FrameUploadBatch* batch) {
    validate_frame_upload_batch(batch)!;
    batch.ring.active = false;
    *batch = {};
}

fn FrameUploadBatch? claim_frame_upload_batch(FrameUploadRing* ring) @private {
    if (ring == null || ring.active) return gpu::INVALID_RESOURCE_STATE~;
    ring.generation = ring.generation == ulong::max ? 1 : ring.generation + 1;
    ring.active = true;
    return {
        .ring       = ring,
        .slot_index = ring.next_slot,
        .generation = ring.generation,
    };
}

fn void? validate_frame_upload_batch(FrameUploadBatch* batch) @private {
    if (batch == null || batch.ring == null) return gpu::INVALID_HANDLE~;
    FrameUploadRing* ring = batch.ring;
    if (!ring.device.is_valid() || !ring.active
        || batch.slot_index != ring.next_slot
        || batch.generation != ring.generation) {
        return gpu::INVALID_HANDLE~;
    }
}

fn usz? reserve_frame_upload_offset(
    usz* cursor,
    usz capacity,
    usz size,
    usz alignment,
) @private {
    if (cursor == null || size == 0 || alignment == 0
        || (alignment & (alignment - 1)) != 0) {
        return gpu::INVALID_ARGUMENT~;
    }

    usz mask = alignment - 1;
    if (*cursor > usz::max - mask) return FRAME_UPLOAD_FULL~;
    usz offset = (*cursor + mask) & ~mask;
    if (offset > capacity || size > capacity - offset) {
        return FRAME_UPLOAD_FULL~;
    }
    *cursor = offset + size;
    return offset;
}
