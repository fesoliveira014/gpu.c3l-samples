# gpu.c3l samples

Standalone consumers of [`gpu.c3l`](https://github.com/fesoliveira014/gpu.c3l),
vendored at [v0.5.0](https://github.com/fesoliveira014/gpu.c3l/releases/tag/v0.5.0)
as a pinned submodule. Each sample owns its shaders and ABI schemas;
`scripts/build_shaders.py` runs the library's `gpu_shaders` tool over every
sample.

## Setup

```sh
git clone --recursive https://github.com/fesoliveira014/gpu.c3l-samples
cd gpu.c3l-samples
```

Requirements:

- `c3c` 0.8.3
- `glslc` from the Vulkan SDK or shaderc
- A Vulkan 1.3 loader and driver; lavapipe works for headless samples
- SDL3 and a window system for windowed samples

On Windows, build the VMA 3.3.0 static library using the pinned-header commands
in [`testing.md`](lib/gpu.c3l/docs/contributing/testing.md) under “Prerequisites on windows-x64”.
Run `python3 scripts/copy_runtime_deps.py` after building to place `SDL3.dll`
beside the executables.

## Device setup

Samples create their runtime, device, queue, command allocator, and optional
surface and swapchain through `gpu::util::DeviceContext`. The defaults select
full contract checks and a graphics queue; samples turn on Vulkan validation
layers, name the application, and override what they need:

```c3
util::DeviceContextDesc desc = util::default_device_context_desc();
desc.runtime.enable_vulkan_validation = true;
desc.runtime.application_name = "my_sample";
util::DeviceContext context = util::create_device_context(&desc)!;
defer util::destroy_device_context(&context);
```

Headless compute samples set `desc.device.queues.required = { .compute }` and
`desc.command_queue = gpu::QueueKind.COMPUTE`. Windowed samples pass
`sample_window::surface_factory` with the `SampleWindow` as user data and fill
`desc.swapchain` from the window's pixel size; the context then owns the
swapchain, and the sample waits `wait_swapchain_presentations` before teardown.

Windowed samples borrow `context.swapchain_info` for the selected format, extent,
image count and dormant state. Resize recovery writes its fresh query result
back through that borrowed pointer, keeping the context snapshot current.

Optional device features (`enable_mesh_shaders`, `enable_ray_tracing_pipelines`,
`unified_layouts`) are set on `desc.device`; a larger command allocator or a
second queue is requested through `desc.command_allocator` and extra
`create_command_allocator` calls. Adapter selection prefers discrete, then
integrated, then software devices among those that satisfy the description.

`present_mode_explorer` recreates swapchains per present mode, so it keeps the
manual runtime, adapter, device, and swapchain path from
`shared/sample_window_sdl.c3`. Allocations, upload reuse, readback, and
completion policy remain sample-local.

## Build and run

```sh
python3 scripts/build_shaders.py
c3c build root_pointer_compute
./build/root_pointer_compute
```

Windowed samples accept `--frames N` for an automatic smoke-test exit and
`--no-vsync` for MAILBOX presentation:

```sh
./build/hello_triangle_sdl --frames 30
```

Every windowed loop uses the shared finite two-millisecond image-acquisition
budget. `WAIT_TIMEOUT` skips the current frame and returns to SDL event
processing, which avoids both an unbounded WSI wait and a hot nonblocking retry
loop.

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
| `multithreaded_recording` | headless | host threads, one explicit allocator per worker | — |
| `pipeline_cache_timing` | headless | graphics and compute pipeline caches | — |
| `image_processing` | headless | storage images, span atomics | `--screenshot out/image_processing.png` |
| `texture_streaming` | headless | reserved texture-index ranges, in-place view updates | — |
| `hello_triangle_sdl` | windowed | baseline presentation; unified layouts, inline root payload | `--frames 30 --screenshot out/hello_triangle_sdl.png` |
| `minimal_triangle` | windowed | smallest windowed program; no roots, no barriers, no descriptors | `--frames 30 --screenshot out/minimal_triangle.png` |
| `textured_cube` | windowed | depth attachment, sampled texture | `--frames 30 --screenshot out/textured_cube.png` |
| `texture_filtering` | windowed | mip sampling; anisotropy optional | `--frames 30 --screenshot out/texture_filtering.png` |
| `volume_texture` | windowed | 3D texture upload and sampled volume raymarch | `--frames 30 --screenshot out/volume_texture.png` |
| `gpu_driven_draw_sdl` | windowed | GPU-compacted generated roots/draws; shared-root indirect fallback | `--frames 30 --screenshot out/gpu_driven_draw_sdl.png` |
| `particle_sim` | windowed | compute; async compute queue optional | `--frames 30 --screenshot out/particle_sim.png` |
| `frustum_culling` | windowed | indirect multi-draw | `--frames 30 --screenshot out/frustum_culling.png` |
| `shadow_mapping` | windowed | depth compare sampling | `--frames 30 --screenshot out/shadow_mapping.png` |
| `deferred_shading` | windowed | three color attachments, RGBA16F | `--frames 30 --screenshot out/deferred_shading.png` |
| `pbr_materials` | windowed | instancing, sampled textures | `--frames 30 --screenshot out/pbr_materials.png` |
| `present_mode_explorer` | windowed | FIFO; MAILBOX and IMMEDIATE optional | `--frames 30 --screenshot out/present_mode_explorer.png` |
| `cornell_box` | windowed | direct ray-tracing pipelines, acceleration structures | `--validate --frames 1 --screenshot out/cornell_box.png` |
| `mesh_shading` | windowed | task and mesh shader pipelines, direct and indirect mesh draws | `--frames 30 --screenshot out/mesh_shading.png` |
| `stencil_mask` | windowed | stencil attachment state, stencil-aspect readback | `--frames 30 --screenshot out/stencil_mask.png` |
| `skybox` | windowed | cube-compatible texture, cube and per-face views | `--frames 30 --screenshot out/skybox.png` |
| `compressed_textures` | windowed | BC1 and BC4 upload with full mip chains | `--frames 30 --screenshot out/compressed_textures.png` |

Each sample README describes its output and optional flags. CI runs this full
matrix on lavapipe; windowed targets use xvfb and the listed frame bound.
