# bindless_texture_compute

Headless bindless descriptor-heap sample. Application code uses no descriptor
sets.

## Flow

1. Register one sampled/storage texture, intern one nearest sampler, and
   publish it to the strict heap.
2. The first dispatch writes a coordinate pattern through
   `store_storage_texture(TextureIndex, ...)`.
3. A texture barrier orders the write against sampled reads.
4. The second dispatch samples through `sample_texture_2d(TextureIndex,
   SamplerIndex, uv)` into a `CPU_READ` allocation through its span address.
5. A host barrier and mapping invalidation precede verification.

Both shaders consume `include/shaders/descriptor_heap.glsl` and receive heap
indices through a root struct.

Run from the repository root:

```sh
python3 scripts/build_shaders.py
c3c run bindless_texture_compute
```
