# offscreen_triangle

![offscreen_triangle](screenshots/offscreen_triangle.png)

Headless rasterization proof: textured triangles rendered through dynamic
viewport/scissor regions without a window or swapchain, with optional PNG capture.

Flow:

1. Upload a checkerboard texture (staging → `TRANSFER_DST` → `SHADER_READ`).
2. Transition a `color_attach|transfer_src` render target to `COLOR_ATTACHMENT`.
3. One dynamic-rendering pass: clear, then three `cmd_draw` calls with dynamic
   viewports and hardware scissors. The third starts from a negative-origin,
   oversized UI-style clip rect and clamps it to the pass bounds before
   `cmd_set_scissor`. The built-in readback verifies all three footprints and
   preserved clear regions. The vertex shader
   pulls positions/UVs through `vertex_root` (no vertex buffers); the fragment
   shader samples the checkerboard through `TextureIndex`/`SamplerIndex` in
   `fragment_root` — the descriptor heap, from a graphics stage.
4. Read back and verify the clipped footprint; `--screenshot <path>` optionally
   writes the result as PNG.

Build and run from the repository root:

```sh
python3 scripts/build_shaders.py
c3c run offscreen_triangle -- --screenshot offscreen_triangle.png
```
