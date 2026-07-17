# bindless_stress

Headless descriptor-heap stress with 8,192 textures and repeated slot churn.
Every sampled payload is verified after initial fill and after each recycle batch.

It exercises:

- Explicit descriptor and texture capacity at device creation.
- Root-addressed index data and bindless sampling across the full heap.
- Twenty-four churn frames that replace 256 textures and descriptors each.
- Timeline-gated descriptor retirement under frames in flight.

Timings are advisory; any payload mismatch or capacity error fails the run.

```sh
c3c build bindless_stress
./build/bindless_stress
```
