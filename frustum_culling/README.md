# frustum_culling

![frustum_culling](screenshots/frustum_culling.png)

Compute-culls 4,096 cubes and feeds one indirect multi-draw.

It demonstrates:

- CPU frustum-plane extraction passed through a culling root.
- GPU-written indirect commands in a `GPU_PRIVATE` span.
- A compute-to-indirect barrier before drawing.
- Periodic `CPU_READ` statistics with host invalidation and bounds checks.

```sh
c3c run frustum_culling -- --frames 120 --screenshot culling.png
```
