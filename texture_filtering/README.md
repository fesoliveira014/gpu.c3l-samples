# texture_filtering

![texture_filtering](screenshots/texture_filtering.png)

Compares four sampler configurations on a receding textured plane.

It demonstrates:

- A CPU-generated, per-level-tinted mip chain packed into one explicit CPU-write allocation and uploaded in one command list.
- A sample-owned two-slot upload ring for per-draw root data.
- Four device-interned sampler identities published as stable `SamplerIndex`
  values for bindless selection.
- Nearest, bilinear, trilinear, and anisotropic filtering.
- Capability-gated anisotropy with a trilinear fallback.

```sh
c3c run texture_filtering -- --frames 30 --screenshot filtering.png
```
