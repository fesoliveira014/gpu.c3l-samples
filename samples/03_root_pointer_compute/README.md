# root_pointer_compute

Headless root-pointer compute sample. A root struct carries input and output GPU
addresses in one 64-bit push constant. Application code uses no descriptor sets
or binding numbers.

## Flow

1. Allocate a `CPU_WRITE` input and `CPU_READ` output.
2. Put their span addresses and element count in a caller-owned `CPU_WRITE` root.
3. Dispatch once and order the output against host reads.
4. Invalidate the output mapping and verify all 256 values.

The schema is `abi/root_pointer.abi`; `scripts/gen_abi.py` generates matching C3
and GLSL layouts.

## Run

```sh
c3c build root_pointer_compute
./build/root_pointer_compute
```

Runs on Vulkan 1.3 drivers, including lavapipe.
