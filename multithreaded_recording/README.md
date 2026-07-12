# multithreaded_recording

Records 32 command lists serially and across eight worker-owned recording
contexts, then submits both workloads and compares their readbacks byte for
byte.

The timed region contains only command recording. Draw roots live in persistent
upload memory, and each list writes a disjoint horizontal band of a 512×512
offscreen target.

Correctness runs with validation enabled. Timing uses a second device with
validation disabled because validation serializes command recording. Reported
speedup is advisory; the readback comparison is the correctness gate.

```sh
c3c run multithreaded_recording
```
