# memory_report

Headless memory observability: creates a spread of buffers and textures,
prints `MemoryStats` (live resource counts, per-heap VMA budgets), the
persistent-arena stats, and the VMA statistics string, then tears down
cleanly — with validation enabled, teardown prints zero leak lines.
It also installs the structured debug callback added by
[gpu.c3l#140](https://github.com/fesoliveira014/gpu.c3l/issues/140) and
[gpu.c3l#188](https://github.com/fesoliveira014/gpu.c3l/pull/188).
The callback only reserves an atomic slot and copies borrowed fields into a
bounded sink; the sample formats severity, categories, operation, fault,
resource name, rejected field, invariant, and validation ID after device
destruction, outside the callback.

```sh
c3c run memory_report --path samples          # summary VMA report
c3c run memory_report --path samples -- --detailed
```
