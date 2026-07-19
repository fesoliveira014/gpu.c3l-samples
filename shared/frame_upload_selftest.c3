module sample_frame_upload;

import gpu;
import std::io;

faultdef SELFTEST_FAILED;

fn int main() {
    if (catch err = run_selftest()) {
        io::printfn("frame_upload_selftest: FAIL (%s)", err);
        return 1;
    }
    io::printn("frame_upload_selftest: PASS");
    return 0;
}

fn void? run_selftest() {
    if (FRAME_UPLOAD_SLOT_COUNT != 2) return SELFTEST_FAILED~;

    test_reservations()!;
    test_batch_state()!;
}

fn void? test_reservations() {
    usz cursor;
    usz first = reserve_frame_upload_offset(
        cursor:    &cursor,
        capacity:  64,
        size:      12,
        alignment: 16,
    )!;
    usz second = reserve_frame_upload_offset(
        cursor:    &cursor,
        capacity:  64,
        size:      4,
        alignment: 16,
    )!;
    if (first != 0 || second != 16 || cursor != 20) return SELFTEST_FAILED~;

    usz preserved = cursor;
    if (@catch(reserve_frame_upload_offset(
            cursor:    &cursor,
            capacity:  64,
            size:      0,
            alignment: 16,
        )) != gpu::INVALID_ARGUMENT || cursor != preserved) {
        return SELFTEST_FAILED~;
    }
    if (@catch(reserve_frame_upload_offset(
            cursor:    &cursor,
            capacity:  64,
            size:      1,
            alignment: 3,
        )) != gpu::INVALID_ARGUMENT || cursor != preserved) {
        return SELFTEST_FAILED~;
    }
    if (@catch(reserve_frame_upload_offset(
            cursor:    &cursor,
            capacity:  24,
            size:      8,
            alignment: 16,
        )) != FRAME_UPLOAD_FULL || cursor != preserved) {
        return SELFTEST_FAILED~;
    }

    cursor = usz::max;
    if (@catch(reserve_frame_upload_offset(
            cursor:    &cursor,
            capacity:  usz::max,
            size:      1,
            alignment: 16,
        )) != FRAME_UPLOAD_FULL || cursor != usz::max) {
        return SELFTEST_FAILED~;
    }
}

fn void? test_batch_state() {
    FrameUploadRing ring = { .device = (gpu::Device)1 };
    FrameUploadBatch first = claim_frame_upload_batch(&ring)!;
    if (!ring.active || first.generation == 0 || first.slot_index != 0) {
        return SELFTEST_FAILED~;
    }
    if (@catch(claim_frame_upload_batch(&ring)) != gpu::INVALID_RESOURCE_STATE) {
        return SELFTEST_FAILED~;
    }

    FrameUploadBatch stale = first;
    cancel_frame_upload(&first)!;
    if (ring.active || first.ring != null) return SELFTEST_FAILED~;

    FrameUploadBatch second = claim_frame_upload_batch(&ring)!;
    if (second.generation == stale.generation) return SELFTEST_FAILED~;
    if (@catch(cancel_frame_upload(&stale)) != gpu::INVALID_HANDLE) {
        return SELFTEST_FAILED~;
    }
    cancel_frame_upload(&second)!;

    gpu::CompletionPoint completion = {
        .device  = ring.device,
        .payload = 1ull << 10,
    };
    FrameUploadBatch third = claim_frame_upload_batch(&ring)!;
    retire_frame_upload(&third, completion)!;
    if (ring.active || third.ring != null || ring.next_slot != 1
        || ring.slots[0].completion != completion) {
        return SELFTEST_FAILED~;
    }

    FrameUploadBatch fourth = claim_frame_upload_batch(&ring)!;
    if (fourth.slot_index != 1) return SELFTEST_FAILED~;
    retire_frame_upload(&fourth, completion)!;
    if (ring.active || ring.next_slot != 0
        || ring.slots[1].completion != completion) {
        return SELFTEST_FAILED~;
    }
}
