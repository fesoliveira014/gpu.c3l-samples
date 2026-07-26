module sample_device;

import gpu;

fn gpu::Device? create_device(gpu::Runtime* runtime) {
    gpu::AdapterList adapters = gpu::enumerate_adapters(runtime)!;
    for (uint i = 0; i < adapters.count; i++) {
        gpu::Adapter adapter = adapters.get(i)!;
        if (!gpu::supports_device_desc(&adapter)!.supported) continue;
        return gpu::create_device(&adapter);
    }
    return gpu::UNSUPPORTED_FEATURE~;
}
