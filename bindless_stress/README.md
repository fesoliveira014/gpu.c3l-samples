# bindless_stress

Headless stress of the descriptor heap at scale and under churn. No
screenshot — the output is a timing table and a hard PASS/FAIL.

## What is stressed

- **Fill**: 8192 one-texel textures — twice the library's default descriptor
  capacity, on a device created with `texture_descriptor_capacity` and
  `texture_capacity` raised to match. Each texture's payload encodes its own
  index, one compute dispatch samples every slot through its `TextureIndex`,
  and the CPU verifies every result. Any wrong slot wiring fails loudly.
- **Churn**: 24 frames, each destroying and recreating a rolling slice of
  256 textures + descriptors (payloads re-salted per frame), re-verifying
  the full heap every frame. This crosses the heap's retire ring several
  times and proves timeline-gated slot recycling under frames-in-flight.

## Sizing note

Destroyed slots retire against the current frame's timeline value and only
recycle on a later frame, so a churn frame consumes its whole slice from
fresh capacity before anything drains. The heap is sized
`TEXTURE_COUNT + CHURN_SLICE + margin` for that reason — undersize it and
the sample fails with `DESCRIPTOR_HEAP_FULL`, which is the machinery
working, not a bug.

## Output

```
bindless_stress: 8192 textures, heap capacity 8512
  create fleet    ~40 ms
  upload payloads ~40 ms
  verify dispatch ~17 ms
  churn           ~4 ms/frame (24 frames x 256 slots)
bindless_stress: PASS
```

Timings are advisory (lavapipe numbers above); the correctness checks are
the gate.

## Run

```
c3c build bindless_stress
./build/bindless_stress
```
