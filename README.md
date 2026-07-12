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

## Build and run

```sh
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

## Samples

| Sample | Type | Purpose |
|---|---|---|
| `root_pointer_compute` | headless | Minimal root-pointer compute and readback. |
| `bindless_texture_compute` | headless | Storage-image write and sampled read through the bindless heap. |
| `offscreen_triangle` | headless | Dynamic rendering, viewport/scissor, readback, and PNG output. |
| `memory_report` | headless | Heap budgets, arena statistics, diagnostics, and clean teardown. |
| `bindless_stress` | headless | Descriptor creation and churn at scale. |
| `multithreaded_recording` | headless | Recording-context throughput across worker counts. |
| `pipeline_cache_timing` | headless | Cold, duplicate, and warm pipeline-cache timing. |
| `image_processing` | headless | Procedural image, blur, histogram, and readback. |
| `hello_triangle_sdl` | windowed | SDL3 surface, swapchain, and textured triangle. |
| `textured_cube` | windowed | Depth-tested textured cube. |
| `texture_filtering` | windowed | Mip levels, LOD, and filter modes. |
| `gpu_driven_draw_sdl` | windowed | Compute culling and indirect multi-draw. |
| `particle_sim` | windowed | Compute particles rendered as additive billboards. |
| `frustum_culling` | windowed | GPU frustum culling feeding indirect draws. |
| `shadow_mapping` | windowed | Depth-only shadow map and compare sampling. |
| `deferred_shading` | windowed | G-buffer pass and animated-light resolve. |
| `pbr_materials` | windowed | Instanced PBR material grid. |
| `present_mode_explorer` | windowed | Present-mode enumeration and pacing. |

`shared_selftest` verifies shared sample helpers. Each sample directory has a
short README with its flags and expected output.
