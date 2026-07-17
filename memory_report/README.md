# memory_report

Creates one independent allocation for each memory class plus representative
buffers and textures. It prints allocation properties, heap budgets, resource
counts, arena statistics, and the VMA report, then verifies clean teardown.

A structured debug callback captures diagnostics without formatting inside the
callback.

```sh
c3c run memory_report
c3c run memory_report -- --detailed
```
