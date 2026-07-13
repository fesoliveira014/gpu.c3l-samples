# pipeline_cache_timing

Headless demonstration of the pipeline-cache workflow: build cold, export
the driver cache blob, warm-start a second device from it. Times three
tiers; correctness is the only gate. No screenshot — the output is a table.

## Tiers

```
device A                                 device B
────────                                 ────────
cold:  24 graphics variants + 1 compute
       (distinct immutable state: blend
        × topology × format × depth —
        every one a real driver compile)
dedup: same descriptors again → library
       PipelineKey hash hit, no driver
       work at all
       │
       └─ get_pipeline_cache_data ──▶ DeviceDesc.pipeline_cache_data
                                         warm: same variants, fresh device;
                                         the blob is its only head start
```

Both devices run a smoke (quad draw + compute dispatch, readback-verified)
so every tier's pipelines are proven to actually work.

## Reading the table

```
  cold (device A)   total   ~5 ms   per-variant  0.1..1.6 ms
  dedup (device A)  total  ~0.01 ms
  warm (device B)   total   ~3.5 ms
  blob 32 bytes (driver-dependent whether it holds compiled shaders)
```

- **dedup ~0** is the library's in-memory PipelineKey table — identical
  descriptors alias one backend pipeline. This tier is always fast,
  regardless of driver.
- **blob size indicates warm-cache coverage**: lavapipe returns a
  32-byte header-only blob (it keeps no compiled-shader payload), so warm ≈
  cold there minus first-compile warmup. Drivers that populate the cache
  (NVIDIA/AMD/Intel) may move warm results toward dedup. Timings are advisory.

## Run

```
c3c build pipeline_cache_timing
./build/pipeline_cache_timing
```
