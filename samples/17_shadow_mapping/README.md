# shadow_mapping

![shadow_mapping](screenshots/shadow_mapping.png)

A depth-only light pass followed by a camera pass with hardware comparison
sampling.

It demonstrates:

- A 2048x2048 depth-only render target.
- Front-face culling, slope bias, and a compare-enabled sampler.
- Nine-tap percentage-closer filtering through `sample_shadow_2d`.
- Explicit `DEPTH_STENCIL` to `SHADER_READ` transitions each frame.

```sh
c3c run shadow_mapping -- --frames 120 --screenshot shadows.png
```
