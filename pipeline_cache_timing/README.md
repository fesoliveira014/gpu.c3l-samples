# pipeline_cache_timing

Headless pipeline-cache workflow and correctness sample.

It measures:

- Cold creation of 24 graphics handles over 12 immutable identities and one
  compute pipeline. Triangle/line topology pairs share a pipeline and switch
  topology at command-recording time.
- In-device deduplication of identical pipeline descriptors.
- A second device initialized from the exported cache blob.

Both devices run a readback-verified draw and compute smoke. Timings and cache
blob size are advisory; correctness is the gate.

```sh
c3c build pipeline_cache_timing
./build/pipeline_cache_timing
```
