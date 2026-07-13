# gpu_driven_draw_sdl

![gpu_driven_draw_sdl](screenshots/gpu_driven_draw_sdl.png)

Windowed GPU-driven rendering: a compute pass culls a 16×16 quad grid against
an animated spotlight and writes `DrawIndexedIndirectCommand`s (plus a draw
count where `DeviceCaps.draw_indirect_count` holds); one indirect multi-draw
renders the visible quads, with per-draw position/color pulled through
`gl_DrawID`.

Build and run from the repository root:

```sh
python3 scripts/build_shaders.py
mkdir -p out
c3c run gpu_driven_draw_sdl -- --frames 30 --screenshot out/gpu_driven_draw_sdl.png
```

`--no-vsync` requests MAILBOX; draw-count buffers are used when supported.
