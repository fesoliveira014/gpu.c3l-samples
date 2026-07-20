# gpu.c3l samples

Eighteen standalone consumers of [`gpu.c3l`](https://github.com/fesoliveira014/gpu.c3l),
vendored as a pinned submodule. Each sample owns its shaders and ABI schemas.

## Setup

```sh
git clone --recursive https://github.com/fesoliveira014/gpu.c3l-samples
cd gpu.c3l-samples
```

Requirements:

- `c3c` 0.8.0
- `glslc` from the Vulkan SDK or shaderc
- A Vulkan 1.3 loader and driver; lavapipe works for headless samples
- SDL3 and a window system for windowed samples

On Windows, build the VMA 3.3.0 static library using the pinned-header commands
in [`testing.md`](lib/gpu.c3l/docs/testing.md) under “Prerequisites on windows-x64”.
Run `python3 scripts/copy_runtime_deps.py` after building to place `SDL3.dll`
beside the executables.

## Strict device setup

Samples create a runtime, enumerate adapters, test an immutable strict request,
and create a device from a supported adapter:

```c3
gpu::RuntimeDesc runtime_desc = {
    .backend          = gpu::BackendKind.VULKAN,
    .application_name = "my_sample",
};
gpu::Runtime runtime = gpu::create_runtime(&runtime_desc)!;
defer (void)gpu::destroy_runtime(&runtime);

gpu::DeviceRequest request = gpu::strict_device_request();
gpu::AdapterList adapters = gpu::enumerate_adapters(&runtime)!;
gpu::Device device = {};
for (uint i = 0; i < adapters.count; i++) {
    gpu::Adapter adapter = adapters.get(i)!;
    if (!gpu::supports_device_request(&adapter, &request)!.supported) continue;
    device = gpu::create_device(&adapter, &request)!;
    break;
}
if (!device.is_valid()) return gpu::UNSUPPORTED_FEATURE~;
defer (void)gpu::destroy_device(&device);
```

The reusable adapter-selection form lives in `shared/sample_device.c3`.
Allocations, upload reuse, readback, and completion policy remain sample-local.

## Build and run

```sh
python3 scripts/check_strict_api.py
python3 scripts/gen_abi.py --check
python3 scripts/build_shaders.py
c3c build root_pointer_compute
./build/root_pointer_compute
```

Windowed samples accept `--frames N` for an automatic smoke-test exit and
`--no-vsync` for MAILBOX presentation:

```sh
./build/hello_triangle_sdl --frames 30
```

## Smoke matrix

All GPU samples require Vulkan 1.3. Windowed samples also require SDL3 and
presentation support. Build with `c3c build <target>`, then run
`./build/<target> <smoke args>`; omit arguments shown as `—`. Create `out/`
before commands that request screenshots.

| Target | Type | Additional capability | Smoke args |
|---|---|---|---|
| `shared_selftest` | helper | none | — |
| `frame_upload_selftest` | helper | none | — |
| `root_pointer_compute` | headless | compute, GPU-addressed spans | — |
| `bindless_texture_compute` | headless | sampled and storage images | — |
| `offscreen_triangle` | headless | dynamic rendering, transfer readback | `--screenshot out/offscreen_triangle.png` |
| `memory_report` | headless | memory-budget and independent-allocation reporting | — |
| `bindless_stress` | headless | 8,192 published texture views with churn | — |
| `multithreaded_recording` | headless | host threads, recording contexts | — |
| `pipeline_cache_timing` | headless | graphics and compute pipeline caches | — |
| `image_processing` | headless | storage images, span atomics | `--screenshot out/image_processing.png` |
| `hello_triangle_sdl` | windowed | baseline presentation | `--frames 30 --screenshot out/hello_triangle_sdl.png` |
| `textured_cube` | windowed | depth attachment, sampled texture | `--frames 30 --screenshot out/textured_cube.png` |
| `texture_filtering` | windowed | mip sampling; anisotropy optional | `--frames 30 --screenshot out/texture_filtering.png` |
| `gpu_driven_draw_sdl` | windowed | GPU-compacted generated roots/draws; shared-root indirect fallback | `--frames 30 --screenshot out/gpu_driven_draw_sdl.png` |
| `particle_sim` | windowed | compute; async compute queue optional | `--frames 30 --screenshot out/particle_sim.png` |
| `frustum_culling` | windowed | indirect multi-draw | `--frames 30 --screenshot out/frustum_culling.png` |
| `shadow_mapping` | windowed | depth compare sampling | `--frames 30 --screenshot out/shadow_mapping.png` |
| `deferred_shading` | windowed | three color attachments, RGBA16F | `--frames 30 --screenshot out/deferred_shading.png` |
| `pbr_materials` | windowed | instancing, sampled textures | `--frames 30 --screenshot out/pbr_materials.png` |
| `present_mode_explorer` | windowed | FIFO; MAILBOX and IMMEDIATE optional | `--frames 30 --screenshot out/present_mode_explorer.png` |

Each sample README describes its output and optional flags. CI runs this full
matrix on lavapipe; windowed targets use xvfb and the listed frame bound.
