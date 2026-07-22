# present_mode_explorer

![present_mode_explorer](screenshots/present_mode_explorer.png)

Queries surface present-mode support, recreates the swapchain for each supported
mode, and reports frame and acquire timing.

Acquire timing covers successful calls made with the shared finite
two-millisecond budget. A timed-out attempt returns to event processing and is
not recorded as a completed frame.

It demonstrates:

- FIFO as the required baseline mode.
- Support-gated MAILBOX and IMMEDIATE selection.
- Swapchain recreation, bounded frame runs, and screenshot capture.

Timing results depend on the driver and display environment.

```sh
c3c build present_mode_explorer
./build/present_mode_explorer [--frames N] [--screenshot out.png]
```
