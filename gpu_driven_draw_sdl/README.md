# gpu_driven_draw_sdl

![gpu_driven_draw_sdl](screenshots/gpu_driven_draw_sdl.png)

Windowed GPU-driven rendering: a compute pass culls a 16×16 quad grid against
an animated spotlight. When `DeviceCaps.generated_work` is available, it
compacts visible indexed draws and distinct vertex/fragment root records fully
on the GPU before one generated draw call. Unsupported devices use the
shared-root indirect path, with indirect count when available.

Build and run from the repository root:

```sh
python3 scripts/build_shaders.py
mkdir -p out
c3c run gpu_driven_draw_sdl -- --frames 30 --screenshot out/gpu_driven_draw_sdl.png
```

`--no-vsync` requests MAILBOX. Startup reports the selected generated or
shared-root path and the generated-work limit.
