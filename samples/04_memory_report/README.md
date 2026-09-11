# memory_report

Creates one independent allocation for each generic memory class, including
`CPU_WRITE_GPU_LOCAL`, and two textures. It prints allocation properties (with
the selected `device_local` memory), heap budgets, live resource counts, and the
allocator report. It also captures structured diagnostics
and prints them after device teardown.

```sh
c3c run memory_report
c3c run memory_report -- --detailed
```
