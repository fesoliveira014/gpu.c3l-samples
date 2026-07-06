# shadow_mapping

![shadow_mapping](screenshots/shadow_mapping.png)

The classic two-pass technique, driving the library's shadow features
end to end: an orbiting directional light renders a depth-only pass into a
2048² map, and the camera pass samples it with hardware depth compare.

```
pass 1 (light): depth-only render pass (no color attachments) → shadow map
                pipeline depth bias: constant 8, slope 3
barrier: DEPTH_STENCIL/DEPTH_WRITE → FRAGMENT_SHADER/SHADER_READ
pass 2 (camera): fragment transforms world → light clip, 3×3 PCF via
                 sample_shadow_2d (compare-enabled sampler, LESS)
```

What it demonstrates:

- **Depth-only passes** — `RenderPassDesc` with an empty color list and a
  pass-through fragment shader.
- **Hardware-compare sampling** — `SamplerDesc.compare_enable` +
  `sample_shadow_2d` through the aliased shadow heap view; nine PCF taps
  average the comparison results for soft edges.
- **Pipeline depth bias** — `RasterState.depth_bias_constant/slope` on the
  shadow pass kills self-shadowing acne (front-face culling is the other
  classic tool, not used here).
- **Cross-pass texture lifecycle** — the shadow map round-trips
  `DEPTH_STENCIL ↔ SHADER_READ` every frame under explicit barriers.

```sh
c3c run shadow_mapping -- --frames 120 --screenshot shadows.png
```
