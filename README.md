# gpu.c3l samples

Standalone consumers of [`gpu.c3l`](https://github.com/fesoliveira014/gpu.c3l),
vendored here as a pinned submodule together with the SDL3 binding. Each sample
owns its shaders (`<sample>/shaders/`) and its shader ABI schemas
(`<sample>/abi/`).

## Setup

```sh
git clone --recursive https://github.com/fesoliveira014/gpu.c3l-samples
```

(Already cloned? `git submodule update --init --recursive`.)

Requirements:

- `c3c` 0.8.0 on PATH
- `glslc` on PATH (Vulkan SDK or shaderc)
- A Vulkan 1.3 loader; any 1.3 ICD to run (lavapipe works headless)
- Windowed samples additionally need the SDL3 native library and a window system

## Build order

Generated ABI includes and SPIR-V come first (`.spv` and generated outputs are
committed-per-policy of this repo: generated ABI files are committed, `.spv` is
gitignored — `.glsl` and `.abi` are the sources of truth):

```sh
python3 scripts/gen_abi.py --check   # verify committed ABI outputs match the schemas
python3 scripts/build_shaders.py     # compile every sample's shaders to SPIR-V
c3c build root_pointer_compute  # or any target from project.json
python3 scripts/copy_runtime_deps.py # Windows: place SDL3.dll next to the exe (no-op elsewhere)
```

On Windows the SDL3 binding links an import library, so `SDL3.dll` (vendored in
`sdl3.c3l/linked-libs/windows-x64/`) must sit beside each executable;
`copy_runtime_deps.py` mirrors it into `build/`. Linux/macOS link SDL3
statically, so the step is a no-op there.

## Running

On a machine without a hardware ICD, pin lavapipe:

```sh
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json ./build/root_pointer_compute
```

Windowed samples take `--frames N` for an auto-exit smoke run and `--no-vsync`
for MAILBOX present mode:

```sh
./build/hello_triangle_sdl --frames 30
```

## Samples

- `root_pointer_compute` — headless. The root-pointer ABI proof: a compute
  shader reaches buffers through GPU addresses in a `ComputeRoot` pushed as a
  single 64-bit root pointer; no descriptor sets.
- `bindless_texture_compute` — headless. Writes a pattern into a storage image
  by `TextureIndex`, samples it back by the same index through the descriptor
  heap.
- `offscreen_triangle` — headless. Textured triangles rendered into
  dynamic viewport/scissor regions, verified by readback, with optional PNG
  capture.
- `memory_report` — headless. Creates a resource spread, prints memory stats,
  and demonstrates the structured debug callback from
  [gpu.c3l#140](https://github.com/fesoliveira014/gpu.c3l/issues/140) /
  [PR #188](https://github.com/fesoliveira014/gpu.c3l/pull/188).
- `hello_triangle_sdl` — windowed. SDL3 window + swapchain presenting the
  textured triangle.
- `gpu_driven_draw_sdl` — windowed. Compute culls a quad grid and writes
  indirect draw args (+ count where supported); one multi-draw renders via
  `gl_DrawID`.

Each sample directory has a README with details.
