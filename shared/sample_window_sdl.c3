module sample_window;

import sdl;
import gpu;
import gpu::surface::wayland;
import gpu::surface::win32;
import gpu::surface::x11;

faultdef WINDOW_INIT_FAILED, UNSUPPORTED_VIDEO_DRIVER;

struct SampleWindow {
    sdl::Window* window;
}

struct WindowEvents {
    bool quit;
    bool resized;
}

fn SampleWindow? create_sample_window(ZString title, uint width, uint height) {
    if (!sdl::init({ .video })) return WINDOW_INIT_FAILED~;
    sdl::Window* window = sdl::create_window((char*)title, (int)width, (int)height, { .resizable });
    if (window == null) {
        sdl::quit();
        return WINDOW_INIT_FAILED~;
    }
    return (SampleWindow){ .window = window };
}

fn void destroy_sample_window(SampleWindow* sample) {
    if (sample.window != null) {
        sdl::destroy_window(sample.window);
        sample.window = null;
    }
    sdl::quit();
}

<* Create a runtime-owned surface for the active SDL video driver. *>
fn gpu::Surface? create_surface(gpu::Runtime* runtime, SampleWindow* sample) {
    sdl::PropertiesID props = sdl::get_window_properties(sample.window);
    ZString driver = (ZString)sdl::get_current_video_driver();

    if (driver.str_view() == "wayland") {
        return gpu::surface::wayland::create_surface(
            runtime,
            (gpu::surface::wayland::DisplayHandle)sdl::get_pointer_property(
                props,
                (char*)sdl::WindowProperties.WAYLAND_DISPLAY_POINTER,
                null,
            ),
            (gpu::surface::wayland::SurfaceHandle)sdl::get_pointer_property(
                props,
                (char*)sdl::WindowProperties.WAYLAND_SURFACE_POINTER,
                null,
            ),
        );
    }
    if (driver.str_view() == "x11") {
        return gpu::surface::x11::create_surface(
            runtime,
            (gpu::surface::x11::DisplayHandle)sdl::get_pointer_property(
                props,
                (char*)sdl::WindowProperties.X11_DISPLAY_POINTER,
                null,
            ),
            (gpu::surface::x11::WindowHandle)sdl::get_number_property(
                props,
                (char*)sdl::WindowProperties.X11_WINDOW_NUMBER,
                0,
            ),
        );
    }
    if (driver.str_view() == "windows") {
        return gpu::surface::win32::create_surface(
            runtime,
            (gpu::surface::win32::InstanceHandle)sdl::get_pointer_property(
                props,
                (char*)sdl::WindowProperties.WIN32_INSTANCE_POINTER,
                null,
            ),
            (gpu::surface::win32::WindowHandle)sdl::get_pointer_property(
                props,
                (char*)sdl::WindowProperties.WIN32_HWND_POINTER,
                null,
            ),
        );
    }
    return UNSUPPORTED_VIDEO_DRIVER~;
}

fn gpu::Device? create_presentation_device(
    gpu::Runtime* runtime,
    gpu::Surface* surface,
) {
    gpu::DeviceRequest request = gpu::request_presentation(
        gpu::strict_device_request(),
        surface,
    )!;
    gpu::AdapterList adapters = gpu::enumerate_adapters(runtime)!;
    for (uint i = 0; i < adapters.count; i++) {
        gpu::Adapter adapter = adapters.get(i)!;
        if (!gpu::supports_presentation(&adapter, surface)!) continue;
        if (!gpu::supports_device_request(&adapter, &request)!.supported) continue;
        return gpu::create_device(&adapter, &request);
    }
    return gpu::UNSUPPORTED_FEATURE~;
}

fn void pixel_size(SampleWindow* sample, uint* width, uint* height) {
    int w = 0;
    int h = 0;
    sdl::get_window_size_in_pixels(sample.window, &w, &h);
    *width = w < 0 ? 0 : (uint)w;
    *height = h < 0 ? 0 : (uint)h;
}

fn gpu::SwapchainInfo? recover_swapchain(gpu::Device* device, gpu::SwapchainHandle swapchain, SampleWindow* sample) {
    uint width;
    uint height;
    pixel_size(sample, &width, &height);
    while (catch err = gpu::resize_swapchain(device, swapchain, width, height)) {
        if (err != gpu::RESOURCE_IN_USE) return err~;
        sdl::delay(1);
    }
    return gpu::get_swapchain_info(device, swapchain);
}

fn void? present_when_ready(
    gpu::Device* device,
    gpu::AcquiredImage* image,
    gpu::CompletionPoint render_completion,
) {
    while (catch err = gpu::present(device, image, render_completion)) {
        if (err != gpu::WAIT_TIMEOUT) return err~;
        sdl::delay(1);
    }
}

fn void? destroy_swapchain_when_ready(
    gpu::Device* device,
    gpu::SwapchainHandle swapchain,
) {
    while (catch err = gpu::destroy_swapchain(device, swapchain)) {
        if (err != gpu::RESOURCE_IN_USE) return err~;
        sdl::delay(1);
    }
}

fn void throttle_dormant() {
    sdl::delay(16);
}

fn WindowEvents pump_events(SampleWindow* sample) {
    WindowEvents events;
    sdl::Event event;
    while (sdl::poll_event(&event)) {
        switch (event.type) {
            case sdl::EventType.QUIT:
                events.quit = true;
            case sdl::EventType.WINDOW_RESIZED:
            case sdl::EventType.WINDOW_PIXEL_SIZE_CHANGED:
                events.resized = true;
            default:
                break;
        }
    }
    return events;
}
