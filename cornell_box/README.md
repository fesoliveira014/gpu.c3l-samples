# Cornell Box

An interactive direct-ray-tracing rendering of the classical Cornell Box.
The room, two blocks, ceiling area light, and default camera are hardcoded from
Cornell's published measurements:

<https://bowers.cornell.edu/computer-graphics/data>

The default camera is `(278, 273, -800)`, looking along `(0, 0, 1)` with up
`(0, 1, 0)`. Surface colors are linear-RGB approximations derived from the
published spectral reflectance tables. Quads are triangulated in source; the
sample intentionally has no model loader or scene framework.

It demonstrates:

- explicit triangle BLAS and TLAS construction;
- one ray-generation group, radiance and shadow miss groups, and one triangle
  closest-hit group;
- caller-owned SBT packing from queried shader-group handles;
- direct area-light sampling and shadow rays;
- a storage output texture presented through a fullscreen graphics pass;
- explicit build-to-trace and trace-to-sample barriers;
- mouse-look, WASD plus Q/E movement, resize handling, and accumulation reset
  without rebuilding static acceleration structures.

```sh
python3 scripts/gen_abi.py
python3 scripts/build_shaders.py
c3c build cornell_box
./build/cornell_box [--frames N] [--no-vsync] [--screenshot out.png]
```

The fixed-seed validation mode locks the published default camera, renders one
deterministic frame unless `--frames N` is supplied, and checks representative
red-wall, center-scene, green-wall, floor-shadow, and short-block pixels with
an 18-code-value tolerance:

```sh
./build/cornell_box --validate --frames 1
```

Controls: move with W/A/S/D, rise/fall with E/Q, and look with the mouse.
