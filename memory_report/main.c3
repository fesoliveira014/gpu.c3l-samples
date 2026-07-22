module memory_report;

import gpu;
import sample_device;
import std::atomic;
import std::io;

faultdef EXPECTED_REJECTION_MISSING;

const uint DEBUG_MESSAGE_CAP = 32;
const usz DEBUG_NAME_CAP = 64;
const usz DEBUG_TEXT_CAP = 256;
const usz INDEPENDENT_ALLOCATION_SIZE = 256 << 10;
const usz INDEPENDENT_ALLOCATION_ALIGNMENT = 256;

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
        case gpu::DebugResourceKind.GPU_SPAN: return "gpu_span";
        case gpu::DebugResourceKind.TEXTURE: return "texture";
        case gpu::DebugResourceKind.PIPELINE: return "pipeline";
        case gpu::DebugResourceKind.SWAPCHAIN: return "swapchain";
        case gpu::DebugResourceKind.SHADER: return "shader";
        case gpu::DebugResourceKind.COMMAND_ALLOCATOR: return "command_allocator";
        case gpu::DebugResourceKind.COMMAND_LIST: return "command_list";
        case gpu::DebugResourceKind.TEXTURE_DESCRIPTOR: return "texture_descriptor";
        case gpu::DebugResourceKind.SAMPLER: return "sampler";
        case gpu::DebugResourceKind.ALLOCATION: return "allocation";
        case gpu::DebugResourceKind.ATTACHMENT_VIEW: return "attachment_view";
    }
}

fn ZString copied_text(char* text) {
    return text[0] == 0 ? (ZString)"-" : (ZString)text;
}

fn void? print_independent_allocation(
    gpu::Device* device,
    gpu::GpuAllocation allocation,
    ZString name,
) {
    gpu::AllocationInfo info = gpu::get_allocation_info(device, allocation)!;
    gpu::GpuSpan span = gpu::get_allocation_span(device, allocation)!;
    gpu::GpuAddress address = gpu::get_span_address(device, span)!;
    if (!info.addressable || (ulong)address == 0) {
        return gpu::INVALID_RESOURCE_STATE~;
    }
    if (info.mapped) {
        char[] mapping = gpu::get_span_mapping(device, span)!;
        if (mapping.len != info.size) return gpu::INVALID_RESOURCE_STATE~;
        if (info.memory_class == gpu::MemoryClass.CPU_WRITE) {
            mapping[0] = (char)0x2A;
        }
    } else {
        char[]? maybe_mapping = gpu::get_span_mapping(device, span);
        if (try unexpected = maybe_mapping) {
            (void)unexpected;
            return EXPECTED_REJECTION_MISSING~;
        }
        fault mapping_fault = @catch(maybe_mapping);
        if (mapping_fault != gpu::INVALID_ARGUMENT) return mapping_fault~;
    }
    io::printfn(
        "  %s: %d bytes, alignment %d, mapped=%s, coherent=%s, address=%d",
        name,
        info.size,
        info.alignment,
        info.mapped ? "yes" : "no",
        info.coherent ? "yes" : "no",
        (ulong)address,
    );
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

    gpu::RuntimeDesc runtime_desc = {
        .backend                      = gpu::BackendKind.VULKAN,
        .contract_validation          = gpu::ContractValidation.FULL,
        .track_resource_lifetimes     = true,
        .enable_vulkan_validation     = true,
        .enable_debug_names           = true,
        .application_name             = "memory_report",
        .debug_callback               = &capture_debug_message,
        .debug_user_data              = &debug_messages,
    };
    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer (void)gpu::destroy_runtime(&runtime);
    gpu::Device device = sample_device::create_strict_device(&runtime)!;
    defer (void)gpu::destroy_device(&device);

    gpu::AllocationDesc rejected_desc = {
        .size         = 0,
        .alignment    = INDEPENDENT_ALLOCATION_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics },
        .debug_name   = "report_rejected_allocation",
    };
    gpu::GpuAllocation? maybe_rejected = gpu::allocate_memory(&device, &rejected_desc);
    if (try unexpected = maybe_rejected) {
        gpu::free_allocation(&device, &unexpected)!;
        return EXPECTED_REJECTION_MISSING~;
    }
    fault rejected = @catch(maybe_rejected);
    if (rejected != gpu::INVALID_ARGUMENT) return rejected~;

    gpu::MemoryClass[3] allocation_classes = {
        gpu::MemoryClass.CPU_WRITE,
        gpu::MemoryClass.GPU_PRIVATE,
        gpu::MemoryClass.CPU_READ,
    };
    ZString[3] allocation_names = {
        "report_cpu_write",
        "report_gpu_private",
        "report_cpu_read",
    };
    gpu::GpuAllocation[3] allocations = {};
    uint allocation_count = 0;
    defer {
        for (uint i = 0; i < allocation_count; i++) {
            if (allocations[i].is_valid()) {
                (void)gpu::free_allocation(&device, &allocations[i]);
            }
        }
    }
    io::printn("independent allocations:");
    for (uint i = 0; i < allocation_classes.len; i++) {
        gpu::AllocationDesc allocation_desc = {
            .size         = INDEPENDENT_ALLOCATION_SIZE,
            .alignment    = INDEPENDENT_ALLOCATION_ALIGNMENT,
            .memory_class = allocation_classes[i],
            .access       = { .graphics },
            .debug_name   = allocation_names[i],
        };
        allocations[i] = gpu::allocate_memory(&device, &allocation_desc)!;
        allocation_count++;
        print_independent_allocation(&device, allocations[i], allocation_names[i])!;
    }

    gpu::TextureDesc sampled_desc = {
        .width     = 256,
        .height    = 256,
        .mip_levels = 4,
        .format    = gpu::Format.RGBA8_UNORM,
        .usage     = { .sampled, .transfer_dst },
        .access     = { .graphics },
        .debug_name = "report_sampled_texture",
    };
    gpu::TextureHandle sampled = gpu::create_texture(&device, &sampled_desc)!;
    defer (void)gpu::destroy_texture(&device, sampled);

    gpu::TextureDesc depth_desc = {
        .width     = 512,
        .height    = 512,
        .format    = gpu::Format.D32_FLOAT,
        .usage     = { .depth_attach },
        .access     = { .graphics },
        .debug_name = "report_depth_texture",
    };
    gpu::TextureHandle depth = gpu::create_texture(&device, &depth_desc)!;
    defer (void)gpu::destroy_texture(&device, depth);

    gpu::MemoryStats stats = gpu::get_memory_stats(&device)!;
    io::printfn("live textures: %d", stats.texture_count);
    io::printfn("live allocations: %d", stats.live_allocation_count);
    for (uint i = 0; i < stats.heap_count; i++) {
        io::printfn("heap %d: usage %d / budget %d bytes (blocks %d)",
            i, stats.heaps[i].usage, stats.heaps[i].budget, stats.heaps[i].block_bytes);
    }

    String report = gpu::build_memory_report(&device, detailed)!;
    defer free(report);
    io::printfn("--- allocator report (%s) ---", detailed ? "detailed" : "summary");
    io::printn(report);
}
