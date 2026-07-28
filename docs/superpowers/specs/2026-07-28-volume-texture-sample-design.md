# Windowed Volume Texture Sample Design

## Purpose

Issue #96 should demonstrate the `gpu.c3l` three-dimensional texture path in a
visually compelling, self-contained sample. The sample will open an SDL window
and render a slowly animated procedural nebula by raymarching a real 3D texture.
It will also support the repository's bounded screenshot workflow so the same
program can be exercised deterministically in CI.

## Scope

The sample will:

- create a `48 x 48 x 48` RGBA8 texture with a positive depth;
- generate and upload all volume texels on the CPU;
- sample the texture with `sample_texture_3d` from a fragment shader;
- render through the existing window, swapchain, resize, frame-upload, and
  screenshot conventions;
- animate from the submitted frame number rather than wall-clock time;
- skip cleanly when the required 3D texture or filtering support is absent.

The sample will not add compute work, a vertex buffer, a depth target, asset
loading, shared SDL infrastructure, or a reusable renderer abstraction. It will
not change `gpu.c3l` behavior.

## Visual and Volume Data

The CPU will fill a fixed RGBA8 volume. Each voxel's RGB channels will derive
from its normalized position and its alpha channel will hold procedural density.
The density field will combine a centered falloff with a small number of smooth,
deterministic variations so the result reads as a colorful cloud rather than a
solid cube. No random seed or external asset is required.

The fragment shader will draw a fullscreen triangle and reconstruct a ray through
a unit volume box. The camera will orbit slowly around the box and apply a subtle
deterministic pulse. It will intersect the ray with the box, take 32 explicit-LOD
`sample_texture_3d` samples between the entry and exit points,
and composite them front to back over a dark background. Accumulation stops
early once opacity is effectively saturated.

Animation will use `frame / 60` as its time input. The same frame number
therefore produces the same pixels regardless of machine speed.

## GPU Resources and Frame Flow

Startup follows the established windowed sample sequence:

1. Parse the common sample arguments and create an SDL window.
2. Create the GPU context and swapchain.
3. Query support for the exact 3D texture descriptor and confirm RGBA8 linear
   filtering support.
4. Create the sampled 3D texture and its caller-owned allocation.
5. Upload the generated volume through the public texture-copy path.
6. Create the fullscreen graphics pipeline and frame-root data.

Each frame acquires the current swapchain texture, updates the frame-derived
camera data, renders the fullscreen triangle, and presents. Existing resize and
out-of-date recovery behavior will be preserved. Cleanup will follow normal C3
`defer`-based resource ownership.

The sample will use an `800 x 600` window.

## Capability and Error Behavior

The capability gate is intentionally exact:

- the requested `48 x 48 x 48` sampled RGBA8 descriptor must be supported; and
- the chosen RGBA8 format must support linear filtering.

If either capability is unavailable, the program prints a visible `SKIP`
message and exits successfully. Any other failure remains an error and produces
a non-zero exit status. The sample will not silently fall back to a 2D
representation because that would stop testing the feature it exists to show.

## Deterministic Screenshot and CI

The sample will accept the repository-standard bounded invocation:

```sh
--frames 30 --screenshot <path>
```

The final frame is captured before presentation using the existing screenshot
path. Fixed volume generation, frame-number animation, explicit sample count,
and final-frame capture make the result deterministic enough for a windowed
smoke test under Xvfb and lavapipe. CI will build and run the sample, confirm the
screenshot exists, and upload it as an artifact. A separate headless or
`--selftest` execution mode is out of scope.

## Repository Changes

The implementation is expected to add:

- `volume_texture/main.c3`;
- `volume_texture/README.md`;
- `volume_texture/abi/volume.abi`;
- the generated `volume_texture/shader_abi.c3`;
- `volume_texture/shaders/volume.vert.glsl`;
- `volume_texture/shaders/volume.frag.glsl`;
- the generated `volume_texture/shaders/generated/volume_texture_abi.glsl`;
- `volume_texture/screenshots/volume_texture.png`.

It will also register the sample in `project.json`, the ABI-generation jobs, the
root README, and the windowed sample CI workflow. The existing shader build
script already discovers shader files and should not need special-case logic.
The `lib/gpu.c3l` gitlink will be advanced to a merged revision containing the
required 3D texture API.

## Validation

Implementation is complete only after:

- `c3c --version` reports the repository's supported C3 0.8.0 toolchain;
- generated ABI output is current;
- all shaders compile through the repository shader builder;
- the new sample builds;
- the bounded windowed run succeeds under the supported Vulkan setup and writes
  a non-empty screenshot;
- the screenshot is inspected to confirm a clearly three-dimensional animated
  volume rather than a flat diagnostic image;
- existing sample validation remains green, excluding known CI billing failures.

## Alternatives Rejected

Three orthogonal animated slices would be simpler and fast, but would look like
a diagnostic visualization rather than a volume. A rotating stack of
alpha-blended slices would appear volumetric, but would add sorting and blending
complexity and expose avoidable slice artifacts. The fullscreen raymarch is the
smallest design that directly exercises true 3D sampling while producing an
impressive result.
