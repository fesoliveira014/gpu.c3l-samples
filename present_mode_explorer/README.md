# present_mode_explorer

Windowed explorer for the present-mode query API: enumerate what the surface
supports, cycle the swapchain through every supported mode at runtime, and
put numbers on frame pacing per mode. Closes M22.4.

![present_mode_explorer](screenshots/present_mode_explorer.png)

## Flow

```
FIFO probe swapchain ──▶ get_present_mode_support(device, swapchain)
                              │  (FIFO asserted — Vulkan guarantees it)
                              ▼
              for each supported mode: recreate swapchain,
              render 120 frames of the test card, collect stats
```

- The test card is the classic tearing/pacing pattern: an animated gradient
  plus a vertical bar sweeping at fixed velocity. Run it interactively on a
  real display to see IMMEDIATE tear and MAILBOX drop frames.
- Unsupported modes print a `skipped (unsupported)` row — the query is the
  point; the sample never blind-fires a mode.
- `--frames N` sets the per-mode window (CI uses 30); `--screenshot`
  captures the last FIFO frame.

## Reading the table

```
  FIFO       frame 2.73 ms mean (1.19..72.29)  acquire 0.00 ms  ~367 fps
  MAILBOX    frame 1.67 ms mean (1.27..2.59)   acquire 0.01 ms  ~600 fps
  IMMEDIATE  frame 1.44 ms mean (1.22..2.97)   acquire 0.00 ms  ~696 fps
```

Mean/min/max wall time between frames (first 10 per mode discarded as
warmup) and mean acquire-wait. **xvfb caveat**: the numbers above come from
a virtual display — there is no real vblank, so FIFO does not throttle to a
refresh rate and its outliers are X11 sync hiccups, not missed vsyncs. On a
real display FIFO pins to the refresh interval and the acquire column shows
where the driver blocks. Structure of the table is the point; nothing is
asserted on timing.

## Run

```
c3c build present_mode_explorer
./build/present_mode_explorer [--frames N] [--screenshot out.png]
```
