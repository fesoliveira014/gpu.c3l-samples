module memory_report;

import gpu;
import std::atomic;
import std::io;

faultdef EXPECTED_REJECTION_MISSING;

// Headless: creates a resource spread, prints memory stats and the VMA
// report, and tears down cleanly — zero leak lines under validation.

const uint DEBUG_MESSAGE_CAP = 32;
const usz DEBUG_NAME_CAP = 64;
const usz DEBUG_TEXT_CAP = 256;

struct DebugMessageCopy {
    gpu::DebugMessageSeverity severity;
    gpu::DebugMessageCategory category;
    bool                      has_fault;
    fault                     public_fault;
    gpu::DebugResourceKind    resource_kind;
    bool                      has_public_identity;
    uint                      resource_index;
    uint                      resource_generation;
    int                       validation_id_number;
    char[DEBUG_NAME_CAP]      operation;
    char[DEBUG_NAME_CAP]      resource_name;
    char[DEBUG_NAME_CAP]      rejected_field;
    char[DEBUG_TEXT_CAP]      invariant;
    char[DEBUG_TEXT_CAP]      backend_text;
    char[DEBUG_NAME_CAP]      validation_id_name;
}

struct DebugMessageSlot {
    DebugMessageCopy message;
    Atomic{bool}     ready;
}

struct DebugMessageSink {
    Atomic{uint}                       claimed;
    Atomic{ulong}                      dropped;
    DebugMessageSlot[DEBUG_MESSAGE_CAP] slots;
}

fn void copy_debug_text(char* destination, usz capacity, ZString source) {
    usz index = 0;
    if (source != null) {
        while (index + 1 < capacity && source[index] != 0) {
            destination[index] = source[index];
            index++;
        }
    }
    destination[index] = 0;
}

fn void capture_debug_message(gpu::DebugMessage* message, void* user_data) {
    DebugMessageSink* sink = (DebugMessageSink*)user_data;
    uint index = sink.claimed.load(AtomicOrdering.RELAXED);
    while (true) {
        if (index >= DEBUG_MESSAGE_CAP) {
            sink.dropped.add(1, AtomicOrdering.RELAXED);
            return;
        }
        uint observed = mem::compare_exchange(
            &sink.claimed.data,
            index,
            index + 1,
            AtomicOrdering.ACQUIRE_RELEASE,
            AtomicOrdering.RELAXED,
        );
        if (observed == index) break;
        index = observed;
    }

    DebugMessageSlot* slot = &sink.slots[index];
    DebugMessageCopy* copy = &slot.message;
    copy.severity = message.severity;
    copy.category = message.category;
    copy.has_fault = message.has_fault;
    copy.public_fault = message.public_fault;
    copy.resource_kind = message.resource.kind;
    copy.has_public_identity = message.resource.has_public_identity;
    copy.resource_index = message.resource.index;
    copy.resource_generation = message.resource.generation;
    copy.validation_id_number = message.validation_id_number;
    copy_debug_text(&copy.operation[0], DEBUG_NAME_CAP, message.operation);
    copy_debug_text(&copy.resource_name[0], DEBUG_NAME_CAP, message.resource.debug_name);
    copy_debug_text(&copy.rejected_field[0], DEBUG_NAME_CAP, message.rejected_field);
    copy_debug_text(&copy.invariant[0], DEBUG_TEXT_CAP, message.invariant);
    copy_debug_text(&copy.backend_text[0], DEBUG_TEXT_CAP, message.backend_text);
    copy_debug_text(&copy.validation_id_name[0], DEBUG_NAME_CAP, message.validation_id_name);
    slot.ready.store(true, AtomicOrdering.RELEASE);
}

fn ZString debug_severity_name(gpu::DebugMessageSeverity severity) {
    switch (severity) {
        case gpu::DebugMessageSeverity.VERBOSE: return "verbose";
        case gpu::DebugMessageSeverity.INFO: return "info";
        case gpu::DebugMessageSeverity.WARNING: return "warning";
        case gpu::DebugMessageSeverity.ERROR: return "error";
    }
}

fn ZString debug_resource_name(gpu::DebugResourceKind kind) {
    switch (kind) {
        case gpu::DebugResourceKind.NONE: return "none";
        case gpu::DebugResourceKind.DEVICE: return "device";
        case gpu::DebugResourceKind.BUFFER: return "buffer";
        case gpu::DebugResourceKind.TEXTURE: return "texture";
        case gpu::DebugResourceKind.PIPELINE: return "pipeline";
        case gpu::DebugResourceKind.SEMAPHORE: return "semaphore";
        case gpu::DebugResourceKind.SWAPCHAIN: return "swapchain";
        case gpu::DebugResourceKind.SHADER: return "shader";
        case gpu::DebugResourceKind.RECORDING_CONTEXT: return "recording_context";
        case gpu::DebugResourceKind.COMMAND_LIST: return "command_list";
        case gpu::DebugResourceKind.TEXTURE_DESCRIPTOR: return "texture_descriptor";
        case gpu::DebugResourceKind.SAMPLER: return "sampler";
        case gpu::DebugResourceKind.FRAME: return "frame";
        case gpu::DebugResourceKind.PERSISTENT_SPAN: return "persistent_span";
    }
}

fn ZString copied_text(char* text) {
    return text[0] == 0 ? (ZString)"-" : (ZString)text;
}

fn void print_debug_category(gpu::DebugMessageCategory category) {
    bool has_category = false;
    if (category.public_contract) {
        io::printn("  category: public_contract");
        has_category = true;
    }
    if (category.backend) {
        io::printn("  category: backend");
        has_category = true;
    }
    if (category.validation) {
        io::printn("  category: validation");
        has_category = true;
    }
    if (category.performance) {
        io::printn("  category: performance");
        has_category = true;
    }
    if (category.resource_lifetime) {
        io::printn("  category: resource_lifetime");
        has_category = true;
    }
    if (category.general) {
        io::printn("  category: general");
        has_category = true;
    }
    if (!has_category) io::printn("  category: none");
}

fn void print_debug_messages(DebugMessageSink* sink) {
    uint observed = sink.claimed.load(AtomicOrdering.ACQUIRE);
    for (uint index = 0; index < observed; index++) {
        DebugMessageSlot* slot = &sink.slots[index];
        if (!slot.ready.load(AtomicOrdering.ACQUIRE)) continue;
        DebugMessageCopy* message = &slot.message;
        io::printfn("debug message %d: severity=%s operation=%s",
            index, debug_severity_name(message.severity), copied_text(&message.operation[0]));
        print_debug_category(message.category);
        if (message.has_fault) io::printfn("  fault: %s", message.public_fault);
        io::printfn("  resource: %s name=%s", debug_resource_name(message.resource_kind),
            copied_text(&message.resource_name[0]));
        if (message.has_public_identity) {
            io::printfn("  identity: index=%d generation=%d", message.resource_index, message.resource_generation);
        }
        if (message.rejected_field[0] != 0) io::printfn("  rejected field: %s", copied_text(&message.rejected_field[0]));
        if (message.invariant[0] != 0) io::printfn("  invariant: %s", copied_text(&message.invariant[0]));
        if (message.validation_id_name[0] != 0 || message.validation_id_number != 0) {
            io::printfn("  validation ID: %s (%d)", copied_text(&message.validation_id_name[0]),
                message.validation_id_number);
        }
        if (message.backend_text[0] != 0) io::printfn("  backend: %s", copied_text(&message.backend_text[0]));
    }
    ulong dropped = sink.dropped.load(AtomicOrdering.RELAXED);
    if (dropped > 0) io::printfn("debug messages dropped: %d", dropped);
}

fn int main(String[] args) {
    bool detailed = false;
    foreach (arg : args) {
        if (arg == "--detailed") detailed = true;
    }
    if (catch err = run(detailed)) {
        io::printfn("memory_report: FAIL (%s)", err);
        return 1;
    }
    io::printn("memory_report: PASS");
    return 0;
}

fn void? run(bool detailed) {
    DebugMessageSink debug_messages = {};
    // Registered first so LIFO prints after device teardown stops callbacks.
    defer print_debug_messages(&debug_messages);

    gpu::DeviceDesc device_desc = {
        .backend           = gpu::BackendKind.VULKAN,
        .enable_validation = true,
        .enable_debug_names = true,
        .frames_in_flight  = 2,
        .application_name  = "memory_report",
        .debug_callback    = &capture_debug_message,
        .debug_user_data   = &debug_messages,
    };
    gpu::Device device = gpu::create_device_from_desc(&device_desc)!;
    defer (void)gpu::destroy_device(&device);

    gpu::BufferDesc rejected_desc = {
        .size        = 0,
        .usage       = { .storage },
        .memory_kind = gpu::MemoryKind.DEVICE,
        .debug_name  = "report_rejected_buffer",
    };
    gpu::BufferHandle? maybe_rejected = gpu::create_buffer(&device, &rejected_desc);
    if (try unexpected = maybe_rejected) {
        gpu::destroy_buffer(&device, unexpected)!;
        return EXPECTED_REJECTION_MISSING~;
    }
    fault rejected = @catch(maybe_rejected);
    if (rejected != gpu::INVALID_ARGUMENT) return rejected~;

    gpu::BufferDesc device_buf = {
        .size = 1 << 20, .usage = { .storage, .addressable }, .memory_kind = gpu::MemoryKind.DEVICE,
        .debug_name = "report_device_buffer",
    };
    gpu::BufferHandle storage = gpu::create_buffer(&device, &device_buf)!;
    defer (void)gpu::destroy_buffer(&device, storage);

    gpu::BufferDesc staging_buf = {
        .size = 256 << 10, .usage = { .transfer_src }, .memory_kind = gpu::MemoryKind.STAGING,
        .debug_name = "report_staging_buffer",
    };
    gpu::BufferHandle staging = gpu::create_buffer(&device, &staging_buf)!;
    defer (void)gpu::destroy_buffer(&device, staging);

    gpu::BufferDesc readback_buf = {
        .size = 64 << 10, .usage = { .transfer_dst }, .memory_kind = gpu::MemoryKind.READBACK,
        .debug_name = "report_readback_buffer",
    };
    gpu::BufferHandle readback = gpu::create_buffer(&device, &readback_buf)!;
    defer (void)gpu::destroy_buffer(&device, readback);

    gpu::TextureDesc sampled_desc = {
        .dimension = gpu::TextureDimension.TEX_2D,
        .width     = 256,
        .height    = 256,
        .mip_levels = 4,
        .format    = gpu::Format.RGBA8_UNORM,
        .usage     = { .sampled, .transfer_dst },
        .debug_name = "report_sampled_texture",
    };
    gpu::TextureHandle sampled = gpu::create_texture(&device, &sampled_desc)!;
    defer (void)gpu::destroy_texture(&device, sampled);

    gpu::TextureDesc depth_desc = {
        .dimension = gpu::TextureDimension.TEX_2D,
        .width     = 512,
        .height    = 512,
        .format    = gpu::Format.D32_FLOAT,
        .usage     = { .depth_attach },
        .debug_name = "report_depth_texture",
    };
    gpu::TextureHandle depth = gpu::create_texture(&device, &depth_desc)!;
    defer (void)gpu::destroy_texture(&device, depth);

    gpu::MemoryStats stats = gpu::get_memory_stats(&device)!;
    io::printfn("live buffers:  %d", stats.buffer_count);
    io::printfn("live textures: %d", stats.texture_count);
    io::printfn("allocations:   %d", stats.live_allocation_count);
    for (uint i = 0; i < stats.heap_count; i++) {
        io::printfn("heap %d: usage %d / budget %d bytes (blocks %d)",
            i, stats.heaps[i].usage, stats.heaps[i].budget, stats.heaps[i].block_bytes);
    }

    gpu::PersistentArenaStats arena = gpu::get_persistent_stats(&device)!;
    io::printfn("persistent arena: %d / %d bytes in %d spans", arena.used_bytes, arena.capacity_bytes, arena.allocation_count);

    String report = gpu::build_memory_report(&device, detailed)!;
    defer free(report);
    io::printfn("--- VMA report (%s) ---", detailed ? "detailed" : "summary");
    io::printn(report);
}
