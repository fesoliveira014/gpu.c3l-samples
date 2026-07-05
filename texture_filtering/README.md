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
4. **Trilinear, linear mip + 16× anisotropy** — sharp detail holds far
   deeper toward the horizon; the mip bands compress into the distance
   (caps-gated: falls back to plain trilinear on devices without
   `samplerAnisotropy`).

Notes:

- Mips are generated on the CPU (the analytic box-filter result for an
  axis-aligned checker) and uploaded per level via `upload_texture_data`.
- Sampling goes through the published `sample_texture_2d_implicit` helper
  (derivative-driven LOD); the explicit-LOD `sample_texture_2d` would pin
  level 0 in a fragment shader.

```sh
c3c run texture_filtering -- --frames 30 --screenshot filtering.png
```
