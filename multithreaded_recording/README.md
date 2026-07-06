# multithreaded_recording

Headless showcase of the tiered threading model: 32 command lists (2048
draws each) recorded once on a single thread, once across 8 worker threads —
each worker owning a private recording context — then submitted identically.
No screenshot: the output is a timing table and a byte-compare gate.

## Structure

```
              serial run                        threaded run
   main thread ──▶ 32 lists          8 workers ──▶ 4 lists each
                                       (one recording context per worker,
                                        @pool_init temp allocator per thread)
        │                                        │
        └──────── one submit: clear preamble + 32 band lists ────────┘
                                   │
                        readback → byte-compare
```

- Each list renders a horizontal band of a 512² offscreen target
  (`LoadOp.LOAD`, disjoint bands), so submit order cannot affect pixels —
  any divergence means a recording bug, and every quad's tint encodes its
  chunk + draw index so mis-wiring changes the image.
- Draw roots are precomputed into a persistent buffer (the frame arena is
  1 MiB fixed — gpu.c3l#28), so the timed region is pure `cmd_draw`
  recording.

## The gate and the numbers

Correctness runs on a validation-enabled device: serial and threaded
readbacks must be byte-identical, validation-clean. Timing then runs on a
second device with validation off — the validation layer takes a lock in
every `vkCmd*`, hiding all scaling (with it on, threaded recording measures
~1x; the first measurement of this sample showed 8× total overhead from
validation alone).

```
multithreaded_recording: 32 lists x 2048 draws, 8 workers
  serial record   ~4.7 ms
  threaded record ~1.2 ms
  speedup         ~4.1x (advisory, validation off)
  readback: byte-identical (both devices)
```

lavapipe numbers; advisory only — the byte-compare is the test.

## Run

```
c3c build multithreaded_recording
./build/multithreaded_recording
```
