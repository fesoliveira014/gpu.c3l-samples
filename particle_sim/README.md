# particle_sim

![particle_sim](screenshots/particle_sim.png)

65,536 particles integrated on the GPU through a procedural swirl field and
rendered as additively-blended billboards — the compute→graphics loop, built
async-friendly.

What it demonstrates:

- **Ping-ponged simulation state** — two storage buffers of
  `{pos+age, vel+seed}`; each frame the compute pass reads one and writes the
  other, and rendering consumes the freshly written buffer. Roots swap the
  GPU addresses; no descriptor churn.
- **Split submits + timeline semaphore** — simulation is its own submit
  (queue kind COMPUTE) that *signals* a timeline value at `COMPUTE_SHADER`;
  the render submit *waits* that value at `VERTEX_SHADER`. Today both queue
  kinds share one hardware queue (gpu.c3l#23), so this is structure, not
  overlap — but the moment a real async compute queue lands, this sample
  overlaps with zero changes.
- **First `BlendState` use** — additive (`ONE/ONE ADD`), order-independent,
  so no sorting and no depth buffer.
- **Instanced billboards** — 6 vertices × 65k instances; the vertex shader
  fetches the particle by `gl_InstanceIndex` from the root-addressed buffer
  and offsets the projected center by a screen-space corner.

```sh
c3c run particle_sim -- --frames 300 --screenshot particles.png
```
