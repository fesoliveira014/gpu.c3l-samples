# deferred_shading

![deferred_shading](screenshots/deferred_shading.png)

A two-pass renderer with a three-target G-buffer and 16 animated point lights.

It demonstrates:

- Albedo `RGBA8_UNORM`, normal `RGBA16_FLOAT`, and position `RGBA16_FLOAT`
  color targets plus a `D32_FLOAT` depth target.
- Descriptor-heap reads in a fullscreen resolve pass.
- Frame-arena light data addressed through the resolve root.
- Explicit color-attachment-to-shader-read transitions and resize recovery.

```sh
c3c build deferred_shading
./build/deferred_shading [--frames N] [--no-vsync] [--screenshot out.png]
```
