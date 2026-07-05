# texture_filtering

![texture_filtering](screenshots/texture_filtering.png)

Texture mapping fundamentals on one receding plane: a full CPU-generated mip
chain with a **distinct tint per level**, so LOD selection is directly visible
as color bands, compared across four sampler configurations side by side.

Strips, left to right (samplers picked per-fragment from four `SamplerIndex`
values in one root — bindless sampler selection):

1. **Nearest, lod 0** — raw aliasing to the horizon.
2. **Bilinear, lod 0** — smoother close up, still aliases in the distance.
3. **Trilinear, nearest mip** — hard tinted bands mark each mip switch.
4. **Trilinear, linear mip + `mip_lod_bias 1.0`** — smooth band blends,
   shifted one level closer. (Anisotropic filtering replaces this strip once
   gpu.c3l#19 enables the `samplerAnisotropy` feature.)

Notes:

- Mips are generated on the CPU (the analytic box-filter result for an
  axis-aligned checker) and uploaded per level via `upload_texture_data`.
- The fragment shader uses a local implicit-LOD helper built on the heap
  arrays — the published `sample_texture_2d` is explicit-LOD (compute-safe)
  and would pin level 0 (gpu.c3l#20 tracks an implicit variant).

```sh
c3c run texture_filtering -- --frames 30 --screenshot filtering.png
```
