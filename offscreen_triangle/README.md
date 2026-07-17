# offscreen_triangle

![offscreen_triangle](screenshots/offscreen_triangle.png)

Headless rasterization with dynamic viewports, scissors, and optional PNG
capture.

It demonstrates:

- Texture upload and explicit render-target transitions.
- Root-addressed geometry and bindless texture sampling.
- Three draws with distinct viewport and clipped scissor regions.
- Readback verification of drawn and preserved-clear pixels.

```sh
c3c run offscreen_triangle -- --screenshot offscreen_triangle.png
```
