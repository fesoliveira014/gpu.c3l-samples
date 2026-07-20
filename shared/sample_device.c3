module sample_device;

import gpu;

fn gpu::Device? create_strict_device(gpu::Runtime* runtime) {
    gpu::DeviceRequest request = gpu::strict_device_request();
    gpu::AdapterList adapters = gpu::enumerate_adapters(runtime)!;
    for (uint i = 0; i < adapters.count; i++) {
        gpu::Adapter adapter = adapters.get(i)!;
        if (!gpu::supports_device_request(&adapter, &request)!.supported) continue;
        return gpu::create_device(&adapter, &request);
    }
    return gpu::UNSUPPORTED_FEATURE~;
}
