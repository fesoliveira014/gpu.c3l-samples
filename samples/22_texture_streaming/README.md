# texture_streaming

Headless texture-index reservation sample. Shaders read stable heap indices
while the textures behind them are swapped in place.

## Flow

1. `reserve_texture_indices(&device, 4)` returns a contiguous
   `TextureIndexRange` at the top of the heap. Three plain
   `create_texture_view` calls prove the general region never lands inside
   it.
2. Two generations of four 8x8 textures are staged through one
   `allocate_mapped_memory` span and uploaded with explicit barriers.
3. The compute root lives in `CPU_WRITE_GPU_LOCAL` memory; the sample prints
   whether the driver placed it in device-local memory. The root carries only
   the range base; the shader derives `base + i` per slot.
4. Generation A is published with `create_texture_view_at` into the reserved
   slots. A dispatch samples one texel per slot into a `CPU_READ` span and the
   host verifies the colors.
5. `update_texture_view` swaps every slot to generation B without touching
   the root record. The same dispatch now reads generation B.
6. Destroying one view leaves its slot reserved: the general region still
   avoids it, and `create_texture_view_at` republishes into it. Finally every
   view is destroyed and `release_texture_indices` returns the range.

Each step prints `OK`; any mismatch prints the slot and channel and fails.

Run from the repository root:

```sh
python3 scripts/build_shaders.py
c3c run texture_streaming
```
