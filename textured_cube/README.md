# textured_cube

![textured_cube](screenshots/textured_cube.png)

The canonical hello-3D: a depth-tested rotating cube, textured through the
descriptor heap, driven entirely by per-frame root data.

What it demonstrates:

- **Per-frame data pattern** — everything the shaders need each frame
  (view-projection and model matrices, texture/sampler indices, time) is
  written into a fresh frame-arena span as a `SceneRoot`; no persistent
  uniform buffer exists. One root serves both stages: the push-constant pair
  points vertex and fragment roots at the same span.
- **Depth testing** — `D32_FLOAT` depth attachment (recreated on resize),
  depth test/write `LESS`, cleared to 1.0 per pass.
- **Matrices over the ABI** — the schema has no mat4 type; matrices ride as
  four `vec4` columns (`abi/scene.abi`), reconstructed with `mat4(c0, c1,
  c2, c3)` in the vertex shader. The generated asserts pin the layout.
- **Root-addressed geometry** — 36 non-indexed vertices in a persistent
  `storage|addressable` buffer, fetched by `gl_VertexIndex` through
  `SceneRoot.vertex_gpu`.

Run (windowed; `--frames N` for an auto-exit smoke, `--screenshot <path>` to
capture the final frame):

```sh
c3c run textured_cube -- --frames 120 --screenshot cube.png
```
