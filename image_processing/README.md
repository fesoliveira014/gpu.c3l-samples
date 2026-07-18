# image_processing

![image_processing](screenshots/image_processing.png)

A headless compute chain over root-addressed storage images.

```text
generate.comp ─▶ A ─▶ blur.comp (H) ─▶ B ─▶ blur.comp (V) ─▶ A ─▶ histogram.comp ─▶ bins SSBO ─▶ readback
```

It demonstrates:

- Explicit compute-to-compute texture barriers.
- A shared-memory separable blur.
- A GPU-cleared `CPU_READ` span receiving atomic histogram writes.
- Host invalidation and verification of the histogram total.

```sh
c3c run image_processing -- --screenshot blurred.png
```
