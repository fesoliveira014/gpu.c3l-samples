# root_pointer_compute

Headless proof of the root-pointer compute ABI end to end: a compute shader
reads and writes buffers through GPU addresses carried in a root struct
pushed as a single 64-bit push constant — no descriptor sets, no binding
numbers. The smallest complete program in the repository and the pattern
every other sample builds on.

## What it does

1. Two storage buffers (`addressable`), input filled 0..255.
2. A 24-byte root struct (input address, output address, count) written into
   the frame arena.
3. One dispatch doubles every value; a barrier makes the writes host-visible.
4. CPU verifies all 256 results.

No screenshot — output is `root_pointer_compute: PASS`.

## Run

```
c3c build root_pointer_compute
./build/root_pointer_compute
```

Runs on lavapipe (no GPU needed). The schema lives in
`abi/root_pointer.abi`; `scripts/gen_abi.py` regenerates both sides.
