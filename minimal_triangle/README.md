# minimal_triangle

![minimal_triangle](screenshots/minimal_triangle.png)

The smallest windowed program: a vertex-colored triangle on an sRGB swapchain,
mirroring the `triangle` example from
[NoGraphicsAPI](https://github.com/sebbbi/NoGraphicsAPI/tree/main/examples/triangle).

It demonstrates:

- Adapter selection and device creation with `unified_layouts`, so no barrier
  is recorded anywhere.
- A pipeline whose shaders take no root data: positions and colors come from
  `gl_VertexIndex`, and the draw passes zero roots.
- One command list per frame: clear, draw, submit against the acquire
  readiness point, present.
- No shader ABI schema, no allocations, no descriptors.

Use `--frames N` for automatic exit and `--no-vsync` to request MAILBOX.

```sh
c3c run minimal_triangle -- --frames 30 --screenshot out/minimal_triangle.png
```
