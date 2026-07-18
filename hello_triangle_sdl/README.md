# hello_triangle_sdl

![hello_triangle_sdl](screenshots/hello_triangle_sdl.png)

Presents a textured triangle through an SDL3 window and a GPU surface.

It demonstrates:

- Platform handle extraction confined to `shared/sample_window_sdl.c3`.
- Swapchain acquire readiness, color rendering, and presentation.
- Explicit `COLOR_ATTACHMENT` and `PRESENT` transitions.
- Resize recovery and dormant minimized-window handling.

Use `--frames N` for automatic exit and `--no-vsync` to request MAILBOX.

```sh
c3c run hello_triangle_sdl -- --frames 30 --screenshot out/hello_triangle_sdl.png
```
