module cornell_box;

import gpu;
import sample_args;
import sample_capture;
import sample_frame_upload;
import sample_window;
import sdl;
import std::io;
import std::math;

faultdef CORNELL_VALIDATION_FAILED;

const char[*] RAYGEN_SPIRV = $embed("shaders/cornell.rgen.spv");
const char[*] RADIANCE_MISS_SPIRV = $embed("shaders/radiance.rmiss.spv");
const char[*] SHADOW_MISS_SPIRV = $embed("shaders/shadow.rmiss.spv");
const char[*] CLOSEST_HIT_SPIRV = $embed("shaders/cornell.rchit.spv");
const char[*] DISPLAY_VERT_SPIRV = $embed("shaders/display.vert.spv");
const char[*] DISPLAY_FRAG_SPIRV = $embed("shaders/display.frag.spv");

const uint CORNELL_QUAD_COUNT = 19;
const uint CORNELL_TRIANGLE_COUNT = CORNELL_QUAD_COUNT * 2;
const uint CORNELL_VERTEX_COUNT = CORNELL_TRIANGLE_COUNT * 3;
const uint VALIDATION_TOLERANCE = 18;
const uint FIXED_SEED = 0xC04E_11u;
const usz FRAME_UPLOAD_BYTES = CornellRoot::size + DisplayRoot::size + 32;

struct OwnedSpan {
    gpu::GpuAllocation allocation;
    gpu::GpuSpan       span;
}

struct FlyCamera {
    float[<3>] position;
    float      yaw;
    float      pitch;
}

struct OutputTarget {
    gpu::TextureHandle texture;
    gpu::TextureView   view;
    gpu::TextureState  state;
    uint               width;
    uint               height;
}

struct CornellQuad {
    gpu::Vec4f a;
    gpu::Vec4f b;
    gpu::Vec4f c;
    gpu::Vec4f d;
    uint       material;
}

struct CornellGeometryWriter {
    gpu::Vec4f* vertices;
    uint*       materials;
    uint        triangle_count;
}

fn bool wants_validation(String[] args) {
    foreach (arg : args) if (arg == "--validate") return true;
    return false;
}

fn usz align_up(usz value, usz alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn uint channel_delta(uint actual, uint expected) {
    return actual > expected ? actual - expected : expected - actual;
}

fn OwnedSpan? allocate_span(
    gpu::Device*     device,
    usz              size,
    usz              alignment,
    gpu::MemoryClass memory_class,
    ZString          debug_name,
) {
    gpu::AllocationDesc desc = {
        .size         = size,
        .alignment    = alignment,
        .memory_class = memory_class,
        .access       = { .graphics },
        .debug_name   = debug_name,
    };
    gpu::GpuAllocation allocation = gpu::allocate_memory(device, &desc)!;
    defer catch (void)gpu::free_allocation(device, &allocation);
    return {
        .allocation = allocation,
        .span       = gpu::get_allocation_span(device, allocation)!,
    };
}

fn void? free_span(gpu::Device* device, OwnedSpan* span) {
    if (span == null || !span.allocation.is_valid()) return;
    gpu::free_allocation(device, &span.allocation)!;
    span.span = {};
}

fn gpu::Device? create_cornell_device(
    gpu::Runtime* runtime,
    gpu::Surface surface,
) {
    gpu::DeviceDesc desc = {
        .surface                      = surface,
        .enable_ray_tracing_pipelines = true,
    };
    gpu::AdapterList adapters = gpu::enumerate_adapters(runtime)!;
    for (uint i = 0; i < adapters.count; i++) {
        gpu::Adapter adapter = adapters.get(i)!;
        if (!gpu::supports_device_desc(&adapter, &desc)!.supported) continue;
        return gpu::create_device(&adapter, &desc);
    }
    return gpu::UNSUPPORTED_FEATURE~;
}

fn void emit_quad(CornellGeometryWriter* writer, CornellQuad quad) {
    uint vertex = writer.triangle_count * 3;
    writer.vertices[vertex] = quad.a;
    writer.vertices[vertex + 1] = quad.b;
    writer.vertices[vertex + 2] = quad.c;
    writer.vertices[vertex + 3] = quad.a;
    writer.vertices[vertex + 4] = quad.c;
    writer.vertices[vertex + 5] = quad.d;
    writer.materials[writer.triangle_count] = quad.material;
    writer.materials[writer.triangle_count + 1] = quad.material;
    writer.triangle_count += 2;
}

fn void write_cornell_geometry(gpu::Vec4f* vertices, uint* materials) {
    CornellQuad[CORNELL_QUAD_COUNT] quads = {
        {
            .a = { 552.8, 0.0, 0.0, 1.0 },
            .b = { 0.0, 0.0, 0.0, 1.0 },
            .c = { 0.0, 0.0, 559.2, 1.0 },
            .d = { 549.6, 0.0, 559.2, 1.0 },
            .material = 0,
        },
        {
            .a = { 343.0, 548.8, 227.0, 1.0 },
            .b = { 343.0, 548.8, 332.0, 1.0 },
            .c = { 213.0, 548.8, 332.0, 1.0 },
            .d = { 213.0, 548.8, 227.0, 1.0 },
            .material = 3,
        },
        {
            .a = { 556.0, 548.8, 0.0, 1.0 },
            .b = { 556.0, 548.8, 227.0, 1.0 },
            .c = { 0.0, 548.8, 227.0, 1.0 },
            .d = { 0.0, 548.8, 0.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 213.0, 548.8, 227.0, 1.0 },
            .b = { 213.0, 548.8, 332.0, 1.0 },
            .c = { 0.0, 548.8, 332.0, 1.0 },
            .d = { 0.0, 548.8, 227.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 556.0, 548.8, 227.0, 1.0 },
            .b = { 556.0, 548.8, 332.0, 1.0 },
            .c = { 343.0, 548.8, 332.0, 1.0 },
            .d = { 343.0, 548.8, 227.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 556.0, 548.8, 332.0, 1.0 },
            .b = { 556.0, 548.8, 559.2, 1.0 },
            .c = { 0.0, 548.8, 559.2, 1.0 },
            .d = { 0.0, 548.8, 332.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 549.6, 0.0, 559.2, 1.0 },
            .b = { 0.0, 0.0, 559.2, 1.0 },
            .c = { 0.0, 548.8, 559.2, 1.0 },
            .d = { 556.0, 548.8, 559.2, 1.0 },
            .material = 0,
        },
        {
            .a = { 0.0, 0.0, 559.2, 1.0 },
            .b = { 0.0, 0.0, 0.0, 1.0 },
            .c = { 0.0, 548.8, 0.0, 1.0 },
            .d = { 0.0, 548.8, 559.2, 1.0 },
            .material = 2,
        },
        {
            .a = { 552.8, 0.0, 0.0, 1.0 },
            .b = { 549.6, 0.0, 559.2, 1.0 },
            .c = { 556.0, 548.8, 559.2, 1.0 },
            .d = { 556.0, 548.8, 0.0, 1.0 },
            .material = 1,
        },
        {
            .a = { 130.0, 165.0, 65.0, 1.0 },
            .b = { 82.0, 165.0, 225.0, 1.0 },
            .c = { 240.0, 165.0, 272.0, 1.0 },
            .d = { 290.0, 165.0, 114.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 290.0, 0.0, 114.0, 1.0 },
            .b = { 290.0, 165.0, 114.0, 1.0 },
            .c = { 240.0, 165.0, 272.0, 1.0 },
            .d = { 240.0, 0.0, 272.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 130.0, 0.0, 65.0, 1.0 },
            .b = { 130.0, 165.0, 65.0, 1.0 },
            .c = { 290.0, 165.0, 114.0, 1.0 },
            .d = { 290.0, 0.0, 114.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 82.0, 0.0, 225.0, 1.0 },
            .b = { 82.0, 165.0, 225.0, 1.0 },
            .c = { 130.0, 165.0, 65.0, 1.0 },
            .d = { 130.0, 0.0, 65.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 240.0, 0.0, 272.0, 1.0 },
            .b = { 240.0, 165.0, 272.0, 1.0 },
            .c = { 82.0, 165.0, 225.0, 1.0 },
            .d = { 82.0, 0.0, 225.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 423.0, 330.0, 247.0, 1.0 },
            .b = { 265.0, 330.0, 296.0, 1.0 },
            .c = { 314.0, 330.0, 456.0, 1.0 },
            .d = { 472.0, 330.0, 406.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 423.0, 0.0, 247.0, 1.0 },
            .b = { 423.0, 330.0, 247.0, 1.0 },
            .c = { 472.0, 330.0, 406.0, 1.0 },
            .d = { 472.0, 0.0, 406.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 472.0, 0.0, 406.0, 1.0 },
            .b = { 472.0, 330.0, 406.0, 1.0 },
            .c = { 314.0, 330.0, 456.0, 1.0 },
            .d = { 314.0, 0.0, 456.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 314.0, 0.0, 456.0, 1.0 },
            .b = { 314.0, 330.0, 456.0, 1.0 },
            .c = { 265.0, 330.0, 296.0, 1.0 },
            .d = { 265.0, 0.0, 296.0, 1.0 },
            .material = 0,
        },
        {
            .a = { 265.0, 0.0, 296.0, 1.0 },
            .b = { 265.0, 330.0, 296.0, 1.0 },
            .c = { 423.0, 330.0, 247.0, 1.0 },
            .d = { 423.0, 0.0, 247.0, 1.0 },
            .material = 0,
        },
    };
    CornellGeometryWriter writer = {
        .vertices  = vertices,
        .materials = materials,
    };
    foreach (quad : quads) emit_quad(&writer, quad);
    assert(writer.triangle_count == CORNELL_TRIANGLE_COUNT);
}

fn void camera_basis(
    FlyCamera* camera,
    float[<3>]* forward,
    float[<3>]* right,
    float[<3>]* up,
) {
    float cp = math::cos(camera.pitch);
    *forward = {
        math::sin(camera.yaw) * cp,
        math::sin(camera.pitch),
        math::cos(camera.yaw) * cp,
    };
    *right = {
        math::cos(camera.yaw),
        0.0,
        -math::sin(camera.yaw),
    };
    *up = {
        -math::sin(camera.yaw) * math::sin(camera.pitch),
        cp,
        -math::cos(camera.yaw) * math::sin(camera.pitch),
    };
}

fn bool update_camera(FlyCamera* camera, float delta_seconds) {
    float mouse_x;
    float mouse_y;
    sdl::get_relative_mouse_state(&mouse_x, &mouse_y);
    bool moved = mouse_x != 0.0 || mouse_y != 0.0;
    camera.yaw += mouse_x * 0.0025;
    camera.pitch -= mouse_y * 0.0025;
    camera.pitch = math::clamp(camera.pitch, -1.5f, 1.5f);

    float[<3>] forward;
    float[<3>] right;
    float[<3>] up;
    camera_basis(
        camera:  camera,
        forward: &forward,
        right:   &right,
        up:      &up,
    );
    bool* keys = sdl::get_keyboard_state(null);
    float speed = 300.0 * delta_seconds;
    if (keys[(int)sdl::Scancode.W]) {
        camera.position += forward * speed;
        moved = true;
    }
    if (keys[(int)sdl::Scancode.S]) {
        camera.position -= forward * speed;
        moved = true;
    }
    if (keys[(int)sdl::Scancode.D]) {
        camera.position += right * speed;
        moved = true;
    }
    if (keys[(int)sdl::Scancode.A]) {
        camera.position -= right * speed;
        moved = true;
    }
    if (keys[(int)sdl::Scancode.E]) {
        camera.position[1] += speed;
        moved = true;
    }
    if (keys[(int)sdl::Scancode.Q]) {
        camera.position[1] -= speed;
        moved = true;
    }
    return moved;
}

fn OutputTarget? create_output_target(
    gpu::Device* device,
    uint         width,
    uint         height,
) {
    gpu::TextureDesc desc = {
        .width      = width,
        .height     = height,
        .format     = gpu::Format.RGBA16_FLOAT,
        .usage      = { .sampled, .storage },
        .access     = { .graphics },
        .debug_name = "cornell_accumulation",
    };
    gpu::TextureHandle texture = gpu::create_texture(device, &desc)!;
    defer catch (void)gpu::destroy_texture(device, texture);
    gpu::TextureView view = gpu::create_texture_view(device, texture, null)!;
    return {
        .texture = texture,
        .view    = view,
        .state   = { .layout = gpu::TextureLayout.UNDEFINED },
        .width   = width,
        .height  = height,
    };
}

fn void? destroy_output_target(gpu::Device* device, OutputTarget* target) {
    if (target.view.is_valid()) gpu::destroy_texture_view(device, target.view)!;
    if (target.texture.is_valid()) gpu::destroy_texture(device, target.texture)!;
    *target = {};
}

fn gpu::PipelineHandle? create_ray_pipeline(gpu::Device* device) {
    gpu::ShaderDesc raygen = {
        .spirv       = RAYGEN_SPIRV[..],
        .entry_point = "main",
    };
    gpu::ShaderDesc radiance_miss = {
        .spirv       = RADIANCE_MISS_SPIRV[..],
        .entry_point = "main",
    };
    gpu::ShaderDesc shadow_miss = {
        .spirv       = SHADOW_MISS_SPIRV[..],
        .entry_point = "main",
    };
    gpu::ShaderDesc closest_hit = {
        .spirv       = CLOSEST_HIT_SPIRV[..],
        .entry_point = "main",
    };
    gpu::ShaderDesc[1] raygen_shaders = { raygen };
    gpu::ShaderDesc[2] miss_shaders = { radiance_miss, shadow_miss };
    gpu::RayTracingHitGroupDesc[1] hit_groups = {{
        .type               = gpu::RayTracingHitGroupType.TRIANGLES,
        .closest_hit_shader = &closest_hit,
    }};
    gpu::RayTracingPipelineDesc desc = {
        .ray_generation_shaders = raygen_shaders[..],
        .miss_shaders           = miss_shaders[..],
        .hit_groups             = hit_groups[..],
        .max_recursion_depth    = 2,
        .debug_name             = "cornell_ray_pipeline",
    };
    return gpu::create_ray_tracing_pipeline(device, &desc);
}

fn gpu::PipelineHandle? create_display_pipeline(
    gpu::Device* device,
    gpu::Format  format,
) {
    gpu::Format[1] formats = { format };
    gpu::GraphicsPipelineDesc desc = {
        .vertex_shader = {
            .spirv       = DISPLAY_VERT_SPIRV[..],
            .entry_point = "main",
        },
        .fragment_shader = {
            .spirv       = DISPLAY_FRAG_SPIRV[..],
            .entry_point = "main",
        },
        .color_formats = formats[..],
        .debug_name    = "cornell_display_pipeline",
    };
    return gpu::create_graphics_pipeline(device, &desc);
}

fn OwnedSpan? create_sbt(
    gpu::Device*                       device,
    gpu::PipelineHandle                pipeline,
    gpu::RayTracingPipelineCaps*       caps,
    gpu::RayTracingShaderBindingTable* table,
) {
    gpu::RayTracingPipelineInfo info =
        gpu::get_ray_tracing_pipeline_info(device, pipeline)!;
    if (info.total_group_count != 4) return gpu::INVALID_ARGUMENT~;
    usz handle_size = caps.shader_group_handle_size;
    usz stride = align_up(handle_size, caps.shader_group_handle_alignment);
    usz raygen_offset = 0;
    usz miss_offset = align_up(stride, caps.shader_group_base_alignment);
    usz hit_offset = align_up(
        miss_offset + 2 * stride,
        caps.shader_group_base_alignment,
    );
    usz total_size = hit_offset + stride;
    OwnedSpan sbt = allocate_span(
        device:       device,
        size:         total_size,
        alignment:    caps.shader_group_base_alignment,
        memory_class: gpu::MemoryClass.CPU_WRITE,
        debug_name:   "cornell_sbt",
    )!;
    defer catch (void)free_span(device, &sbt);
    char[4096] handle_storage;
    usz handle_bytes = (usz)info.total_group_count * handle_size;
    if (handle_bytes > handle_storage.len) return gpu::UNSUPPORTED_FEATURE~;
    char[] handles = handle_storage[0:handle_bytes];
    gpu::get_ray_tracing_shader_group_handles(
        device:      device,
        pipeline:    pipeline,
        first_group: 0,
        group_count: info.total_group_count,
        out:         handles,
    )!;
    char[] mapped = gpu::get_span_mapping(device, sbt.span)!;
    usz[4] offsets = {
        raygen_offset,
        miss_offset,
        miss_offset + stride,
        hit_offset,
    };
    foreach (group, offset : offsets) {
        mapped[offset:handle_size] =
            handles[(usz)group * handle_size:handle_size];
    }
    gpu::flush_mapped_span(device, sbt.span)!;
    table.ray_generation = {
        .span = sbt.span.checked_subspan(raygen_offset, stride)!,
        .stride = stride,
    };
    table.miss = {
        .span = sbt.span.checked_subspan(miss_offset, 2 * stride)!,
        .stride = stride,
    };
    table.hit = {
        .span = sbt.span.checked_subspan(hit_offset, stride)!,
        .stride = stride,
    };
    return sbt;
}

fn void? validate_pixels(
    gpu::CommandAllocator* allocator,
    gpu::CompletionPoint   producer,
    gpu::TextureHandle     texture,
    uint                   width,
    uint                   height,
    gpu::Format            format,
) {
    gpu::wait_completion(producer)!;
    usz byte_count = (usz)width * height * 4;
    OwnedSpan readback = allocate_span(
        device:       &allocator.device,
        size:         byte_count,
        alignment:    16,
        memory_class: gpu::MemoryClass.CPU_READ,
        debug_name:   "cornell_validation_readback",
    )!;
    defer (void)free_span(&allocator.device, &readback);
    gpu::CommandList commands = gpu::begin_commands(allocator)!;
    defer (void)gpu::discard_commands(&commands);
    gpu::TextureBarrier to_copy = {
        .texture = texture,
        .before  = { .layout = gpu::TextureLayout.PRESENT },
        .after   = {
            .layout = gpu::TextureLayout.TRANSFER_SOURCE,
            .stages = { .transfer },
            .access = { .read },
        },
    };
    gpu::cmd_texture_barrier(&commands, &to_copy)!;
    gpu::TextureBufferCopyDesc copy = {
        .texture = texture,
        .dst     = readback.span,
    };
    gpu::cmd_copy_texture_to_buffer(&commands, &copy)!;
    gpu::Barrier host_read = {
        .before = { .transfer }, .after = { .host },
    };
    gpu::cmd_barrier(&commands, &host_read)!;
    gpu::TextureBarrier restore = {
        .texture = texture,
        .before  = to_copy.after,
        .after   = { .layout = gpu::TextureLayout.PRESENT },
    };
    gpu::cmd_texture_barrier(&commands, &restore)!;
    gpu::ExecutableCommandList[1] lists = { gpu::end_commands(&commands)! };
    gpu::SubmitDesc submit = { .command_lists = lists[..] };
    gpu::CompletionPoint completion = gpu::submit(allocator.queue, &submit)!;
    gpu::wait_completion(completion)!;
    gpu::invalidate_mapped_span(&allocator.device, readback.span)!;
    char[] pixels = gpu::get_span_mapping(&allocator.device, readback.span)!;
    uint[3] xs = { width / 8, width / 2, width * 7 / 8 };
    uint[3] expected_red = { 55, 32, 103 };
    uint[3] expected_green = { 90, 32, 39 };
    uint[3] expected_blue = { 45, 32, 35 };
    bool bgra = format == gpu::Format.BGRA8_UNORM
        || format == gpu::Format.BGRA8_SRGB;
    foreach (sample, x : xs) {
        usz index = ((usz)(height / 2) * width + x) * 4;
        uint red = bgra ? (uint)pixels[index + 2] : (uint)pixels[index];
        uint green = (uint)pixels[index + 1];
        uint blue = bgra ? (uint)pixels[index] : (uint)pixels[index + 2];
        if (channel_delta(red, expected_red[sample]) > VALIDATION_TOLERANCE
            || channel_delta(green, expected_green[sample])
                > VALIDATION_TOLERANCE
            || channel_delta(blue, expected_blue[sample])
                > VALIDATION_TOLERANCE) {
            return CORNELL_VALIDATION_FAILED~;
        }
    }
}

fn int main(String[] args) {
    if (catch err = run(args)) {
        io::printfn("cornell_box: FAIL (%s)", err);
        return 1;
    }
    io::printn("cornell_box: PASS");
    return 0;
}

fn void? run(String[] args) {
    sample_args::Options options = sample_args::parse_options(args);
    bool validation = wants_validation(args);
    if (validation && options.frames < 0) options.frames = 1;
    sample_window::SampleWindow window = sample_window::create_sample_window(
        "gpu.c3l Cornell Box",
        768,
        768,
    )!;
    defer sample_window::destroy_sample_window(&window);
    if (!validation) {
        if (!sdl::set_window_relative_mouse_mode(window.window, true)) {
            return sample_window::WINDOW_INIT_FAILED~;
        }
    }
    defer if (!validation) {
        (void)sdl::set_window_relative_mouse_mode(window.window, false);
    };

    gpu::RuntimeDesc runtime_desc = {
        .contract_validation = gpu::ContractValidation.FULL,
        .enable_vulkan_validation = true,
        .application_name = "cornell_box",
        .acceleration_structure_heap_capacity = 8,
    };
    gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
    defer (void)gpu::destroy_runtime(&runtime);
    gpu::Surface surface = sample_window::create_surface(&runtime, &window)!;
    defer (void)gpu::destroy_surface(&surface);
    gpu::Device device = create_cornell_device(&runtime, surface)!;
    defer (void)gpu::destroy_device(&device);
    gpu::DeviceCaps caps = gpu::get_device_caps(&device)!;
    if (caps.ray_tracing_pipelines.max_recursion_depth < 2) {
        return gpu::UNSUPPORTED_FEATURE~;
    }
    gpu::Queue queue = gpu::get_queue(&device, gpu::QueueKind.GRAPHICS)!;
    gpu::CommandAllocatorDesc allocator_desc = {
        .max_acceleration_structure_geometries_per_build = 1,
    };
    gpu::CommandAllocator allocator = gpu::create_command_allocator(
        device: &device,
        queue:  queue,
        desc:   &allocator_desc,
    )!;
    defer (void)gpu::destroy_command_allocator(&allocator);

    sample_frame_upload::FrameUploadRing upload_ring =
        sample_frame_upload::create_frame_upload_ring(
            device:        &device,
            slot_capacity: FRAME_UPLOAD_BYTES,
            access:        { .graphics },
            debug_name:    "cornell_frame_upload",
        )!;
    defer (void)sample_frame_upload::destroy_frame_upload_ring(&upload_ring);

    OwnedSpan vertices = allocate_span(
        device:       &device,
        size:         CORNELL_VERTEX_COUNT * gpu::Vec4f::size,
        alignment:    16,
        memory_class: gpu::MemoryClass.CPU_WRITE,
        debug_name:   "cornell_vertices",
    )!;
    defer (void)free_span(&device, &vertices);
    OwnedSpan materials = allocate_span(
        device:       &device,
        size:         CORNELL_TRIANGLE_COUNT * uint::size,
        alignment:    16,
        memory_class: gpu::MemoryClass.CPU_WRITE,
        debug_name:   "cornell_materials",
    )!;
    defer (void)free_span(&device, &materials);
    write_cornell_geometry(
        (gpu::Vec4f*)gpu::get_span_mapping(&device, vertices.span)!.ptr,
        (uint*)gpu::get_span_mapping(&device, materials.span)!.ptr,
    );
    gpu::flush_mapped_span(&device, vertices.span)!;
    gpu::flush_mapped_span(&device, materials.span)!;

    gpu::AccelerationStructureGeometryDesc[1] geometries = {{
        .kind = gpu::AccelerationStructureGeometryKind.TRIANGLES,
        .flags = { .opaque },
        .triangles = {
            .max_vertex_count = CORNELL_VERTEX_COUNT,
            .max_primitive_count = CORNELL_TRIANGLE_COUNT,
            .index_type = gpu::AccelerationStructureIndexType.NONE,
        },
    }};
    gpu::AccelerationStructureDesc blas_desc = {
        .kind = gpu::AccelerationStructureKind.BOTTOM_LEVEL,
        .geometries = geometries[..],
        .flags = { .prefer_fast_trace },
        .debug_name = "cornell_blas",
    };
    gpu::AccelerationStructureRequirements blas_requirements =
        gpu::get_acceleration_structure_requirements(&device, &blas_desc)!;
    gpu::AccelerationStructureHandle blas =
        gpu::create_acceleration_structure(&device, &blas_desc)!;
    defer (void)gpu::destroy_acceleration_structure(&device, blas);
    OwnedSpan blas_scratch = allocate_span(
        device:       &device,
        size:         blas_requirements.build_scratch_size,
        alignment:    blas_requirements.scratch_alignment,
        memory_class: gpu::MemoryClass.GPU_PRIVATE,
        debug_name:   "cornell_blas_scratch",
    )!;
    defer (void)free_span(&device, &blas_scratch);

    gpu::AccelerationStructureInstanceDesc instance_desc = {
        .transform_row_0 = { 1.0, 0.0, 0.0, 0.0 },
        .transform_row_1 = { 0.0, 1.0, 0.0, 0.0 },
        .transform_row_2 = { 0.0, 0.0, 1.0, 0.0 },
        .bottom_level = blas,
        .mask = 0xff,
    };
    gpu::AccelerationStructureInstance instance =
        gpu::make_acceleration_structure_instance(&device, &instance_desc)!;
    OwnedSpan instances = allocate_span(
        device:       &device,
        size:         gpu::AccelerationStructureInstance::size,
        alignment:    16,
        memory_class: gpu::MemoryClass.CPU_WRITE,
        debug_name:   "cornell_instance",
    )!;
    defer (void)free_span(&device, &instances);
    *(gpu::AccelerationStructureInstance*)gpu::get_span_mapping(
        &device,
        instances.span,
    )!.ptr = instance;
    gpu::flush_mapped_span(&device, instances.span)!;

    gpu::AccelerationStructureDesc tlas_desc = {
        .kind = gpu::AccelerationStructureKind.TOP_LEVEL,
        .max_instance_count = 1,
        .flags = { .prefer_fast_trace },
        .debug_name = "cornell_tlas",
    };
    gpu::AccelerationStructureRequirements tlas_requirements =
        gpu::get_acceleration_structure_requirements(&device, &tlas_desc)!;
    gpu::AccelerationStructureHandle tlas =
        gpu::create_acceleration_structure(&device, &tlas_desc)!;
    defer (void)gpu::destroy_acceleration_structure(&device, tlas);
    OwnedSpan tlas_scratch = allocate_span(
        device:       &device,
        size:         tlas_requirements.build_scratch_size,
        alignment:    tlas_requirements.scratch_alignment,
        memory_class: gpu::MemoryClass.GPU_PRIVATE,
        debug_name:   "cornell_tlas_scratch",
    )!;
    defer (void)free_span(&device, &tlas_scratch);
    gpu::AccelerationStructureView tlas_view =
        gpu::create_acceleration_structure_view(&device, tlas)!;
    defer (void)gpu::destroy_acceleration_structure_view(&device, tlas_view);

    gpu::CommandList build_commands = gpu::begin_commands(&allocator)!;
    defer (void)gpu::discard_commands(&build_commands);
    gpu::AccelerationStructureGeometryBuildDesc[1] build_geometries = {{
        .kind = gpu::AccelerationStructureGeometryKind.TRIANGLES,
        .triangles = {
            .vertices = vertices.span,
            .vertex_stride = gpu::Vec4f::size,
            .vertex_count = CORNELL_VERTEX_COUNT,
            .primitive_count = CORNELL_TRIANGLE_COUNT,
        },
    }};
    gpu::AccelerationStructureBuildDesc blas_build = {
        .destination = blas,
        .geometries  = build_geometries[..],
        .scratch     = blas_scratch.span,
    };
    gpu::cmd_build_acceleration_structure(&build_commands, &blas_build)!;
    gpu::Barrier build_to_build = {
        .before = { .acceleration_structure_build },
        .after  = { .acceleration_structure_build },
    };
    gpu::cmd_barrier(&build_commands, &build_to_build)!;
    gpu::AccelerationStructureBuildDesc tlas_build = {
        .destination    = tlas,
        .instances      = instances.span,
        .instance_count = 1,
        .scratch        = tlas_scratch.span,
    };
    gpu::cmd_build_acceleration_structure(&build_commands, &tlas_build)!;
    gpu::Barrier build_to_trace = {
        .before = { .acceleration_structure_build },
        .after  = { .ray_tracing },
    };
    gpu::cmd_barrier(&build_commands, &build_to_trace)!;
    gpu::ExecutableCommandList[1] build_lists = {
        gpu::end_commands(&build_commands)!,
    };
    gpu::SubmitDesc build_submit = { .command_lists = build_lists[..] };
    gpu::CompletionPoint build_completion = gpu::submit(queue, &build_submit)!;
    gpu::wait_completion(build_completion)!;

    gpu::PipelineHandle ray_pipeline = create_ray_pipeline(&device)!;
    defer (void)gpu::destroy_pipeline(&device, ray_pipeline);
    gpu::RayTracingShaderBindingTable sbt_table;
    OwnedSpan sbt = create_sbt(
        device:   &device,
        pipeline: ray_pipeline,
        caps:     &caps.ray_tracing_pipelines,
        table:    &sbt_table,
    )!;
    defer (void)free_span(&device, &sbt);
    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .mip_filter = gpu::Filter.NEAREST,
        .address_u  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v  = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w  = gpu::AddressMode.CLAMP_TO_EDGE,
    };
    gpu::SamplerIndex display_sampler =
        gpu::intern_sampler(&device, &sampler_desc)!;

    uint width;
    uint height;
    sample_window::pixel_size(&window, &width, &height);
    gpu::SwapchainDesc swapchain_desc = {
        .width = width,
        .height = height,
        .preferred_format = gpu::Format.BGRA8_UNORM,
        .present_mode = options.vsync
            ? gpu::PresentMode.FIFO : gpu::PresentMode.MAILBOX,
        .srgb = false,
        .debug_name = "cornell_swapchain",
    };
    gpu::SwapchainHandle swapchain =
        gpu::create_swapchain(&device, &surface, &swapchain_desc)!;
    gpu::SwapchainInfo swapchain_info =
        gpu::get_swapchain_info(&device, swapchain)!;
    defer (void)sample_window::destroy_swapchain_when_ready(&device, swapchain);
    OutputTarget output = create_output_target(
        &device,
        swapchain_info.width,
        swapchain_info.height,
    )!;
    defer (void)destroy_output_target(&device, &output);
    gpu::PipelineHandle display_pipeline =
        create_display_pipeline(&device, swapchain_info.format)!;
    gpu::Format display_format = swapchain_info.format;
    defer (void)gpu::destroy_pipeline(&device, display_pipeline);

    FlyCamera camera = {
        .position = { 278.0, 273.0, -800.0 },
    };
    gpu::CompletionPoint last_frame;
    uint sample_index;
    long frame;
    ulong previous_ticks = sdl::get_ticks_ns();
    bool running = true;
    while (running) {
        sample_window::WindowEvents events = sample_window::pump_events(&window);
        if (events.quit) break;
        ulong current_ticks = sdl::get_ticks_ns();
        float delta_seconds = (float)(current_ticks - previous_ticks) / 1.0e9;
        previous_ticks = current_ticks;
        if (delta_seconds > 0.1) delta_seconds = 0.1;
        if (!validation && update_camera(&camera, delta_seconds)) sample_index = 0;
        if (events.resized) {
            swapchain_info = sample_window::recover_swapchain(
                &device,
                swapchain,
                &window,
            )!;
            sample_index = 0;
        }
        if (swapchain_info.dormant) {
            sample_window::throttle_dormant();
            continue;
        }
        if (output.width != swapchain_info.width
            || output.height != swapchain_info.height) {
            if (last_frame.is_valid()) gpu::wait_completion(last_frame)!;
            destroy_output_target(&device, &output)!;
            output = create_output_target(
                &device,
                swapchain_info.width,
                swapchain_info.height,
            )!;
            sample_index = 0;
        }
        if (display_format != swapchain_info.format) {
            if (last_frame.is_valid()) gpu::wait_completion(last_frame)!;
            gpu::destroy_pipeline(&device, display_pipeline)!;
            display_pipeline = create_display_pipeline(
                &device,
                swapchain_info.format,
            )!;
            display_format = swapchain_info.format;
        }

        gpu::AcquiredImage? acquired = gpu::acquire_next_image(
            device:     &device,
            swapchain:  swapchain,
            timeout_ns: sample_window::FRAME_ACQUIRE_TIMEOUT_NS,
        );
        if (catch err = acquired) {
            if (err == gpu::WAIT_TIMEOUT) continue;
            if (err == gpu::SWAPCHAIN_OUT_OF_DATE) {
                swapchain_info = sample_window::recover_swapchain(
                    &device,
                    swapchain,
                    &window,
                )!;
                sample_index = 0;
                continue;
            }
            return err~;
        }

        sample_frame_upload::FrameUploadBatch upload =
            sample_frame_upload::begin_frame_upload(&upload_ring)!;
        defer catch if (upload.ring != null) {
            (void)sample_frame_upload::cancel_frame_upload(&upload);
        };
        float[<3>] forward;
        float[<3>] right;
        float[<3>] up;
        camera_basis(
            camera:  &camera,
            forward: &forward,
            right:   &right,
            up:      &up,
        );
        gpu::GpuSpan root_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload,
            size:      CornellRoot::size,
            alignment: 16,
        )!;
        CornellRoot* root = (CornellRoot*)gpu::get_span_mapping(
            &device,
            root_span,
        )!.ptr;
        root.camera_position = {
            camera.position[0], camera.position[1], camera.position[2], 0.0,
        };
        root.camera_forward = { forward[0], forward[1], forward[2], 0.0 };
        root.camera_right = { right[0], right[1], right[2], 0.0 };
        root.camera_up = { up[0], up[1], up[2], 0.0 };
        root.vertex_gpu = gpu::get_span_address(&device, vertices.span)!;
        root.material_gpu = gpu::get_span_address(&device, materials.span)!;
        root.output_texture = output.view.index;
        root.tlas = tlas_view.index;
        root.width = output.width;
        root.height = output.height;
        root.sample_index = sample_index;
        root.seed = FIXED_SEED;
        gpu::GpuAddress root_address =
            gpu::get_span_address(&device, root_span)!;

        gpu::GpuSpan display_span = sample_frame_upload::alloc_frame_upload(
            batch:     &upload,
            size:      DisplayRoot::size,
            alignment: 16,
        )!;
        DisplayRoot* display = (DisplayRoot*)gpu::get_span_mapping(
            &device,
            display_span,
        )!.ptr;
        display.output_texture = output.view.index;
        display.heap_sampler = display_sampler;
        gpu::GpuAddress display_address =
            gpu::get_span_address(&device, display_span)!;

        gpu::CommandList commands = gpu::begin_commands(&allocator)!;
        defer (void)gpu::discard_commands(&commands);
        gpu::TextureState ray_state =
            gpu::storage_at({ .ray_tracing }, { .read, .write });
        gpu::TextureBarrier to_trace = gpu::texture_transition(
            texture: output.texture,
            before:  output.state,
            after:   ray_state,
        )!;
        gpu::cmd_texture_barrier(&commands, &to_trace)!;
        gpu::cmd_bind_pipeline(&commands, ray_pipeline)!;
        gpu::cmd_trace_rays(
            commands:             &commands,
            root:                 root_address,
            shader_binding_table: &sbt_table,
            dimensions:           { output.width, output.height, 1 },
        )!;
        gpu::TextureState sampled_state =
            gpu::sampled_at({ .fragment_shader });
        gpu::TextureBarrier to_sample = gpu::texture_transition(
            texture: output.texture,
            before:  ray_state,
            after:   sampled_state,
        )!;
        gpu::cmd_texture_barrier(&commands, &to_sample)!;
        output.state = sampled_state;

        gpu::TextureBarrier to_attachment = gpu::texture_transition(
            texture: acquired.texture,
            before:  acquired.prior_state,
            after:   {
                .layout = gpu::TextureLayout.COLOR_ATTACHMENT,
                .stages = { .color_output },
                .access = { .read, .write },
            },
        )!;
        gpu::cmd_texture_barrier(&commands, &to_attachment)!;
        gpu::ColorTargetDesc[1] colors = {{
            .view = acquired.attachment_view,
            .load_op = gpu::LoadOp.CLEAR,
            .store_op = gpu::StoreOp.STORE,
            .clear = { .rgba = { 0.0, 0.0, 0.0, 1.0 } },
        }};
        gpu::RenderPassDesc pass = {
            .colors = colors[..],
            .width = swapchain_info.width,
            .height = swapchain_info.height,
        };
        gpu::ColorTargetState[1] target_state = {
            gpu::color_blend_disabled(),
        };
        gpu::GraphicsState graphics =
            gpu::render_geometry_state(pass.width, pass.height)!;
        graphics.color.targets = target_state[..];
        gpu::cmd_begin_render_pass(&commands, &pass)!;
        gpu::cmd_bind_pipeline(&commands, display_pipeline)!;
        gpu::cmd_set_graphics_state(&commands, &graphics)!;
        gpu::cmd_draw(
            commands:       &commands,
            vertex_root:    display_address,
            fragment_root:  display_address,
            vertex_count:   3,
            instance_count: 1,
        )!;
        gpu::cmd_end_render_pass(&commands)!;
        gpu::TextureBarrier to_present = {
            .texture = acquired.texture,
            .before  = to_attachment.after,
            .after   = { .layout = gpu::TextureLayout.PRESENT },
        };
        gpu::cmd_texture_barrier(&commands, &to_present)!;
        sample_frame_upload::flush_frame_upload(&upload)!;
        gpu::ExecutableCommandList[1] lists = {
            gpu::end_commands(&commands)!,
        };
        gpu::SubmitDesc submit = {
            .command_lists    = lists[..],
            .readiness        = acquired.readiness,
            .readiness_before = { .color_output },
        };
        last_frame = gpu::submit(queue, &submit)!;
        sample_frame_upload::retire_frame_upload(&upload, last_frame)!;

        bool final_frame = options.frames > 0 && frame == options.frames - 1;
        if (validation && final_frame) {
            validate_pixels(
                allocator: &allocator,
                producer:  last_frame,
                texture:   acquired.texture,
                width:     swapchain_info.width,
                height:    swapchain_info.height,
                format:    swapchain_info.format,
            )!;
        }
        if (options.capture_frame(frame)) {
            sample_capture::capture_texture_png(
                allocator:           &allocator,
                producer_completion: last_frame,
                src:                 acquired.texture,
                width:               swapchain_info.width,
                height:              swapchain_info.height,
                format:              swapchain_info.format,
                from_state:          { .layout = gpu::TextureLayout.PRESENT },
                path:                options.screenshot_path,
            )!;
        }
        if (catch err = sample_window::present_when_ready(
            &device,
            &acquired,
            last_frame,
        )) {
            if (err != gpu::SWAPCHAIN_OUT_OF_DATE) return err~;
            swapchain_info = sample_window::recover_swapchain(
                &device,
                swapchain,
                &window,
            )!;
            sample_index = 0;
        }
        sample_index++;
        frame++;
        if (options.frames > 0 && frame >= options.frames) running = false;
    }
    if (last_frame.is_valid()) gpu::wait_completion(last_frame)!;
}
