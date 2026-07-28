# Windowed Volume Texture Sample Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic SDL window sample that uploads a procedural `48 x 48 x 48` RGBA8 texture and renders it as an animated nebula with a fullscreen 3D-texture raymarch.

**Architecture:** The sample follows the existing swapchain and frame-upload loop, but uses a bufferless fullscreen triangle and reconstructs its camera in the fragment shader. Startup capability-gates the exact 3D descriptor and linear filtering, creates the texture with caller-owned dedicated storage, performs one explicit full-volume upload, then renders from a 16-byte generated root record.

**Tech Stack:** C3 0.8.0, `gpu.c3l`, SDL3, generated shader ABI, GLSL 4.60/Vulkan 1.3, Xvfb, lavapipe.

## Global Constraints

- Keep the program windowed; do not add a headless or `--selftest` mode.
- Use an `800 x 600` resizable SDL window.
- Generate a fixed `48 x 48 x 48` RGBA8 volume on the CPU with no asset or random seed.
- Set `TextureDesc.depth = 48`; zero depth would select a 2D texture.
- Require the exact sampled-plus-transfer-destination descriptor and RGBA8 linear filtering.
- Print `volume_texture: SKIP (...)` and exit zero only for the sample's two capability checks; propagate every other fault.
- Use exactly 32 explicit-LOD `sample_texture_3d` samples with front-to-back compositing and opacity early exit.
- Derive animation only from `(float)frame / 60.0f`.
- Preserve the common `--frames`, `--no-vsync`, resize recovery, screenshot-before-present, and final-frame capture behavior.
- Keep C3 naming, declaration order, K&R braces, named calls with four or more arguments, minimal comments, optionals/faults, and `defer` ownership.
- Do not add compute work, vertex buffers, depth targets, asset loading, shared SDL changes, or a renderer abstraction.
- Ignore CI failures caused only by exhausted GitHub Actions credits.

---

## File Map

- `lib/gpu.c3l`: pin to merged gpu.c3l commit `c5d65637090e7747de741823f389683652c95cdb`.
- `volume_texture/abi/volume.abi`: define the 16-byte root contract.
- `volume_texture/shader_abi.c3`: generated C3 root type.
- `volume_texture/shaders/generated/volume_texture_abi.glsl`: generated GLSL root type.
- `volume_texture/shaders/volume.vert.glsl`: emit a fullscreen triangle without a vertex buffer.
- `volume_texture/shaders/volume.frag.glsl`: reconstruct the camera and raymarch the 3D texture.
- `volume_texture/main.c3`: own window/device/resources, generate/upload texels, and render frames.
- `volume_texture/README.md`: explain the result, capabilities, and bounded invocation.
- `volume_texture/screenshots/volume_texture.png`: committed visual reference.
- `project.json`: register the SDL executable.
- `scripts/gen_abi.py`: register the new ABI-generation job.
- `README.md`: update the sample count and smoke matrix.
- `.github/workflows/ci.yml`: include the sample in the existing bounded windowed loop.

### Task 1: Pin the GPU Dependency with the Public 3D Texture Surface

**Files:**
- Modify: `lib/gpu.c3l`

**Interfaces:**
- Consumes: merged gpu.c3l commit `c5d65637090e7747de741823f389683652c95cdb`.
- Produces: `TextureDesc.depth`, `supports_texture_desc`, `get_texture_format_support`, `create_dedicated_texture`, 3D buffer-texture copy extents, and `sample_texture_3d`.

- [ ] **Step 1: Initialize the isolated worktree's dependencies**

Run:

```sh
git submodule update --init --recursive
```

Expected: `lib/gpu.c3l`, its nested bindings, and `lib/sdl3.c3l` are populated without changing tracked gitlinks.

- [ ] **Step 2: Verify the old pin does not contain the required shader helper**

Run:

```sh
rg -n 'sample_texture_3d' lib/gpu.c3l/include/shaders/descriptor_heap.glsl
```

Expected: no match at the old `1345a7ce3081b3ee64acc1ab63b074584c17b50f` pin.

- [ ] **Step 3: Advance only the gpu.c3l gitlink**

Run:

```sh
git -C lib/gpu.c3l fetch origin main
git -C lib/gpu.c3l checkout c5d65637090e7747de741823f389683652c95cdb
```

Expected: `git status --short` reports only `M lib/gpu.c3l`.

- [ ] **Step 4: Verify the required public surface at the new pin**

Run:

```sh
rg -n 'sample_texture_3d' lib/gpu.c3l/include/shaders/descriptor_heap.glsl
rg -n 'fn (TextureFormatSupport|bool|DedicatedTexture).*?(get_texture_format_support|supports_texture_desc|create_dedicated_texture)' lib/gpu.c3l/gpu/gpu.c3
rg -n 'uint[[:space:]]+depth' lib/gpu.c3l/gpu/gpu.c3i
git -C lib/gpu.c3l rev-parse HEAD
```

Expected: every API query matches and the final command prints the exact pinned commit.

- [ ] **Step 5: Commit the dependency checkpoint**

```sh
git add lib/gpu.c3l
git commit -m "chore: update gpu.c3l for volume textures"
```

### Task 2: Add the Buildable Windowed Volume Renderer

**Files:**
- Create: `volume_texture/abi/volume.abi`
- Create: `volume_texture/shader_abi.c3`
- Create: `volume_texture/shaders/generated/volume_texture_abi.glsl`
- Create: `volume_texture/shaders/volume.vert.glsl`
- Create: `volume_texture/shaders/volume.frag.glsl`
- Create: `volume_texture/main.c3`
- Modify: `scripts/gen_abi.py`
- Modify: `project.json`

**Interfaces:**
- Consumes: the Task 1 gpu.c3l APIs and existing `sample_window`, `sample_args`, `sample_frame_upload`, and `sample_capture` modules.
- Produces: target `volume_texture`, root `VolumeRoot`, and a bounded executable accepting `--frames 30 --screenshot <path>`.

- [ ] **Step 1: Register the ABI job before adding its schema**

Add this tuple beside the other texture samples in `scripts/gen_abi.py`:

```python
("volume_texture", "volume_texture", "volume_texture_abi.glsl", "volume.abi"),
```

- [ ] **Step 2: Run the ABI generator to expose the missing contract**

Run:

```sh
python3 scripts/gen_abi.py --check
```

Expected: FAIL because `volume_texture/abi/volume.abi` or its generated outputs do not exist.

- [ ] **Step 3: Add the minimal root schema**

Create `volume_texture/abi/volume.abi`:

```text
abi volume_texture;

root VolumeRoot {
    TextureIndex volume_texture;
    SamplerIndex volume_sampler;
    float        time;
    float        aspect;
}
```

Generate and verify the paired outputs:

```sh
python3 scripts/gen_abi.py
python3 scripts/gen_abi.py --check
```

Expected: `volume_texture/shader_abi.c3` and `volume_texture/shaders/generated/volume_texture_abi.glsl` are created, and the drift check passes.

- [ ] **Step 4: Add the fullscreen vertex shader**

Create `volume_texture/shaders/volume.vert.glsl`:

```glsl
#version 460

layout(location = 0) out vec2 v_uv;

void main() {
    vec2 corner = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
    gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    v_uv = corner;
}
```

- [ ] **Step 5: Add the fixed 32-step fragment raymarch**

Create `volume_texture/shaders/volume.frag.glsl` with these exact contracts and algorithm:

```glsl
#version 460
#include "generated/shader_abi.glsl"
#include "generated/volume_texture_abi.glsl"
#include "descriptor_heap.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

const int STEP_COUNT = 32;
const vec3 BOX_MIN = vec3(0.0);
const vec3 BOX_MAX = vec3(1.0);
const vec3 BACKGROUND = vec3(0.008, 0.012, 0.025);

vec2 intersect_box(vec3 origin, vec3 direction) {
    vec3 inverse_direction = 1.0 / direction;
    vec3 first = (BOX_MIN - origin) * inverse_direction;
    vec3 second = (BOX_MAX - origin) * inverse_direction;
    vec3 near_axis = min(first, second);
    vec3 far_axis = max(first, second);
    return vec2(
        max(max(near_axis.x, near_axis.y), near_axis.z),
        min(min(far_axis.x, far_axis.y), far_axis.z));
}

void main() {
    VolumeRoot root = VolumeRoot(pc.fragment_root_gpu);
    float angle = root.time * 0.35;
    vec3 origin = vec3(
        0.5 + cos(angle) * 2.2,
        0.55 + sin(root.time * 0.6) * 0.12,
        0.5 + sin(angle) * 2.2);
    vec3 forward = normalize(vec3(0.5) - origin);
    vec3 right = normalize(cross(forward, vec3(0.0, 1.0, 0.0)));
    vec3 up = cross(right, forward);
    vec2 screen = v_uv * 2.0 - 1.0;
    screen.x *= root.aspect;
    vec3 direction = normalize(forward + right * screen.x * 0.7 + up * screen.y * 0.7);
    vec2 hit = intersect_box(origin, direction);

    if (hit.x >= hit.y || hit.y <= 0.0) {
        o_color = vec4(BACKGROUND, 1.0);
        return;
    }

    float entry = max(hit.x, 0.0);
    float step_length = (hit.y - entry) / float(STEP_COUNT);
    vec3 position = origin + direction * (entry + step_length * 0.5);
    vec4 accumulated = vec4(0.0);
    float pulse = 0.85 + 0.15 * sin(root.time);

    for (int i = 0; i < STEP_COUNT; i++) {
        vec4 voxel = sample_texture_3d(
            root.volume_texture,
            root.volume_sampler,
            position);
        float alpha = voxel.a * 0.11 * pulse;
        accumulated.rgb += (1.0 - accumulated.a) * voxel.rgb * alpha;
        accumulated.a += (1.0 - accumulated.a) * alpha;
        if (accumulated.a >= 0.98) break;
        position += direction * step_length;
    }

    vec3 color = accumulated.rgb + BACKGROUND * (1.0 - accumulated.a);
    color = color / (1.0 + color);
    o_color = vec4(pow(color, vec3(1.0 / 2.2)), 1.0);
}
```

- [ ] **Step 6: Compile the shaders before writing the host**

Run:

```sh
python3 scripts/build_shaders.py
```

Expected: both `volume.vert.spv` and `volume.frag.spv` are emitted without compiler diagnostics.

- [ ] **Step 7: Register the executable before its host source exists**

Add this target beside `texture_filtering` in `project.json`:

```json
"volume_texture": {
  "type": "executable",
  "dependencies": [ "sdl3" ],
  "sources": [
    "volume_texture/main.c3", "volume_texture/shader_abi.c3",
    "shared/sample_window_sdl.c3", "shared/frame_upload.c3",
    "shared/sample_args.c3", "shared/screenshot.c3", "shared/png.c3"
  ]
},
```

Run:

```sh
c3c build volume_texture
```

Expected: FAIL because `volume_texture/main.c3` does not exist. This confirms the target is wired to the intended source rather than accidentally building another sample.

- [ ] **Step 8: Implement deterministic volume generation**

Start `volume_texture/main.c3` with module/imports, shader embeds, constants, the capability fault, and these helpers:

```c3
module volume_texture;

import gpu;
import sample_args;
import sample_capture;
import sample_frame_upload;
import sample_window;
import std::io;
import std::math;

faultdef VOLUME_TEXTURE_UNSUPPORTED;

const char[*] VOLUME_VERT_SPIRV = $embed("shaders/volume.vert.spv");
const char[*] VOLUME_FRAG_SPIRV = $embed("shaders/volume.frag.spv");

const uint VOLUME_SIZE = 48;
const usz VOLUME_BYTES = (usz)VOLUME_SIZE * VOLUME_SIZE * VOLUME_SIZE * 4;
const uint FULLSCREEN_VERTEX_COUNT = 3;

fn float saturate(float value) {
    if (value < 0.0f) return 0.0f;
    if (value > 1.0f) return 1.0f;
    return value;
}

fn void write_volume(char[] texels) {
    float side = (float)VOLUME_SIZE;
    usz side_index = (usz)VOLUME_SIZE;
    for (uint z = 0; z < VOLUME_SIZE; z++) {
        for (uint y = 0; y < VOLUME_SIZE; y++) {
            for (uint x = 0; x < VOLUME_SIZE; x++) {
                float px = ((float)x + 0.5f) / side * 2.0f - 1.0f;
                float py = ((float)y + 0.5f) / side * 2.0f - 1.0f;
                float pz = ((float)z + 0.5f) / side * 2.0f - 1.0f;
                float radius = math::sqrt(px * px + py * py + pz * pz);
                float variation =
                    math::sin(px * 5.0f + pz * 3.0f) * 0.13f
                    + math::sin(py * 7.0f - px * 2.0f) * 0.09f
                    + math::sin((px + py + pz) * 9.0f) * 0.05f;
                float density = saturate((1.0f - radius) * 1.35f + variation);
                usz offset =
                    (((usz)z * side_index + y) * side_index + x) * 4;
                texels[offset] =
                    (char)(uint)(saturate(0.35f + px * 0.25f + density * 0.55f) * 255.0f);
                texels[offset + 1] =
                    (char)(uint)(saturate(0.25f + py * 0.20f + density * 0.45f) * 255.0f);
                texels[offset + 2] =
                    (char)(uint)(saturate(0.55f + pz * 0.20f + density * 0.40f) * 255.0f);
                texels[offset + 3] = (char)(uint)(density * 255.0f);
            }
        }
    }
}
```

- [ ] **Step 9: Implement exact capability gating and ownership**

Use this main/fault boundary:

```c3
fn int main(String[] args) {
    if (catch err = run(sample_args::parse_options(args))) {
        if (err == VOLUME_TEXTURE_UNSUPPORTED) {
            io::printn("volume_texture: SKIP (3D RGBA8 sampling unavailable)");
            return 0;
        }
        io::printfn("volume_texture: FAIL (%s)", err);
        return 1;
    }
    io::printn("volume_texture: PASS");
    return 0;
}
```

In `run`, create the window/runtime/surface/presentation device/graphics queue and allocator exactly once, then construct and gate this descriptor:

```c3
gpu::TextureDesc volume_desc = {
    .width        = VOLUME_SIZE,
    .height       = VOLUME_SIZE,
    .depth        = VOLUME_SIZE,
    .mip_levels   = 1,
    .array_layers = 1,
    .format       = gpu::Format.RGBA8_UNORM,
    .usage        = { .sampled, .transfer_dst },
    .access       = { .graphics },
    .sample_count = gpu::SampleCount.ONE,
    .debug_name   = "volume_texture",
};
gpu::TextureFormatSupport format_support =
    gpu::get_texture_format_support(&device, volume_desc.format)!;
if (!format_support.features.linear_filter
    || !gpu::supports_texture_desc(&device, &volume_desc)!) {
    return VOLUME_TEXTURE_UNSUPPORTED~;
}
```

Create caller-owned dedicated texture storage and keep the required destruction order explicit:

```c3
gpu::TextureRequirements requirements =
    gpu::get_texture_requirements(&device, &volume_desc)!;
gpu::TextureRequirements[1] texture_requirements = { requirements };
gpu::AllocationDesc texture_memory_desc = {
    .size                 = requirements.size,
    .alignment            = requirements.alignment,
    .memory_class         = gpu::MemoryClass.TEXTURE,
    .access               = volume_desc.access,
    .texture_requirements = texture_requirements[..],
    .debug_name           = "volume_texture_memory",
};
gpu::DedicatedTexture volume = gpu::create_dedicated_texture(
    device:          &device,
    desc:            &volume_desc,
    allocation_desc: &texture_memory_desc,
)!;
defer {
    (void)gpu::destroy_texture(&device, volume.texture);
    (void)gpu::free_allocation(&device, &volume.allocation);
}
gpu::TextureView volume_view =
    gpu::create_texture_view(&device, volume.texture, null)!;
defer (void)gpu::destroy_texture_view(&device, volume_view);
```

Intern one `LINEAR` min/mag, `NEAREST` mip, `CLAMP_TO_EDGE` U/V/W sampler.

- [ ] **Step 10: Upload the complete 3D extent once**

Create a scoped `CPU_WRITE` allocation of exactly `VOLUME_BYTES`, call `write_volume`, flush it, and record:

```c3
gpu::BufferTextureCopyDesc copy = {
    .src         = staging_span,
    .texture     = volume.texture,
    .base_layer  = 0,
    .layer_count = 1,
    .x           = 0,
    .y           = 0,
    .z           = 0,
    .width       = VOLUME_SIZE,
    .height      = VOLUME_SIZE,
    .depth       = VOLUME_SIZE,
};
```

Surround the copy with:

```text
UNDEFINED
  -> TRANSFER_DESTINATION / transfer write
  -> sampled_at(fragment_shader)
```

Submit on the graphics queue and wait for that completion before leaving the staging scope.

- [ ] **Step 11: Implement the existing windowed frame contract**

Complete `run` with this concrete sequence:

1. Create the swapchain from the SDL pixel size, BGRA8 preference, and `options.vsync`.
2. Create a two-slot `FrameUploadRing` with `slot_capacity: VolumeRoot::size`.
3. Create a no-depth graphics pipeline from `VOLUME_VERT_SPIRV` and `VOLUME_FRAG_SPIRV`.
4. Pump SDL events, recover resize/out-of-date swapchains, throttle dormant windows, and use `FRAME_ACQUIRE_TIMEOUT_NS`.
5. Recreate the pipeline only when the swapchain format changes, after waiting for `last_graphics`.
6. Transition each acquired image from `acquired.prior_state` to `COLOR_ATTACHMENT`.
7. Allocate one aligned `VolumeRoot`, then set:

```c3
root.volume_texture = volume_view.index;
root.volume_sampler = volume_sampler;
root.time = (float)frame / 60.0f;
root.aspect =
    (float)swapchain_info.width / (float)swapchain_info.height;
```

8. Clear to `{ 0.008f, 0.012f, 0.025f, 1.0f }`, use `render_geometry_state`, set one `color_blend_disabled()` target, and draw:

```c3
gpu::cmd_draw(
    commands:       &commands,
    vertex_root:    root_address,
    fragment_root:  root_address,
    vertex_count:   FULLSCREEN_VERTEX_COUNT,
    instance_count: 1,
)!;
```

9. Transition to `PRESENT`, flush the frame upload, submit with acquired readiness, and retire the upload batch.
10. When `options.capture_frame(frame)` is true, call `capture_texture_png` after submission and before presentation with `from_state.layout = PRESENT`.
11. Present through `present_when_ready`, increment `frame` only after a rendered frame, stop at `options.frames`, and wait for `last_graphics` before returning.

- [ ] **Step 12: Build and run the focused sample**

Run:

```sh
python3 scripts/gen_abi.py --check
python3 scripts/build_shaders.py
c3c build volume_texture
mkdir -p out
VK_DRIVER_FILES=$(ls /usr/share/vulkan/icd.d/lvp_icd*.json | head -1) \
  xvfb-run -a env SDL_VIDEODRIVER=x11 WAYLAND_DISPLAY= \
  ./build/volume_texture --frames 30 --screenshot out/volume_texture.png
test -s out/volume_texture.png
```

Expected: generator and compiler succeed, the program prints `volume_texture: PASS`, and the PNG is non-empty.

- [ ] **Step 13: Inspect the rendered result**

Open `out/volume_texture.png` with the image viewer. Confirm:

- the image reads as a bounded three-dimensional cloud;
- color and opacity vary within the volume;
- the volume is centered and not clipped;
- the output is not black, flat, or a set of diagnostic slices.

If visual tuning is required, change only volume density/color constants or fragment camera/compositing constants, then rerun Steps 6 and 12.

- [ ] **Step 14: Commit the working sample**

```sh
git add project.json scripts/gen_abi.py volume_texture/abi \
  volume_texture/shader_abi.c3 volume_texture/shaders volume_texture/main.c3
git commit -m "feat: add windowed volume texture sample"
```

Do not add generated `.spv` files; they are intentionally ignored.

### Task 3: Add Documentation, Screenshot, and CI Coverage

**Files:**
- Create: `volume_texture/README.md`
- Create: `volume_texture/screenshots/volume_texture.png`
- Modify: `README.md`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the Task 2 bounded executable and inspected screenshot.
- Produces: discoverable sample documentation and inclusion in the repository's existing windowed smoke matrix.

- [ ] **Step 1: Save the approved visual reference**

Copy the inspected output:

```sh
mkdir -p volume_texture/screenshots
cp out/volume_texture.png volume_texture/screenshots/volume_texture.png
test -s volume_texture/screenshots/volume_texture.png
```

- [ ] **Step 2: Document the sample**

Create `volume_texture/README.md`:

```markdown
# volume_texture

![volume_texture](screenshots/volume_texture.png)

A windowed fullscreen raymarch through a CPU-generated 3D nebula texture.

It demonstrates:

- Exact 3D texture and linear-filter capability checks.
- A caller-owned dedicated texture allocation and full-volume buffer upload.
- Bindless `sample_texture_3d` access from a fragment shader.
- Deterministic frame-derived animation and final-frame screenshot capture.

Unsupported 3D RGBA8 sampling prints `SKIP` and exits successfully. Other
failures remain errors.

```sh
c3c run volume_texture -- --frames 30 --screenshot volume_texture.png
```
```

- [ ] **Step 3: Register the sample in the root catalog**

Change the README introduction from “Eighteen” to “Nineteen” and add this smoke-matrix row beside the texture samples:

```markdown
| `volume_texture` | windowed | 3D texture upload and sampled volume raymarch | `--frames 30 --screenshot out/volume_texture.png` |
```

- [ ] **Step 4: Add it to the existing bounded CI loop**

Append `volume_texture` to the space-separated loop in `.github/workflows/ci.yml`:

```sh
for s in hello_triangle_sdl gpu_driven_draw_sdl textured_cube texture_filtering volume_texture particle_sim frustum_culling shadow_mapping deferred_shading pbr_materials present_mode_explorer; do
```

Do not add another job, Xvfb setup, or artifact step; the existing loop and `out/*.png` upload cover it.

- [ ] **Step 5: Run focused documentation/CI-equivalent checks**

Run:

```sh
python3 scripts/gen_abi.py --check
python3 scripts/build_shaders.py
c3c run shared_selftest
c3c run frame_upload_selftest
c3c build volume_texture
VK_DRIVER_FILES=$(ls /usr/share/vulkan/icd.d/lvp_icd*.json | head -1) \
  xvfb-run -a env SDL_VIDEODRIVER=x11 WAYLAND_DISPLAY= \
  ./build/volume_texture --frames 30 --screenshot out/volume_texture.png
test -s out/volume_texture.png
git diff --check
```

Expected: both helper selftests pass, the sample prints `PASS`, the screenshot is non-empty, and the diff check is silent.

- [ ] **Step 6: Commit the integration surface**

```sh
git add README.md .github/workflows/ci.yml \
  volume_texture/README.md volume_texture/screenshots/volume_texture.png
git commit -m "test: add volume texture sample to smoke matrix"
```

### Task 4: Final Verification and Ready PR

**Files:**
- Review: all changes from `origin/main` through `HEAD`.
- Create externally: ready pull request closing sample issue #96.

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: a reviewed, pushed branch and ready PR with `[Self review]`.

- [ ] **Step 1: Verify the complete branch**

Run:

```sh
c3c --version
python3 scripts/gen_abi.py --check
python3 scripts/build_shaders.py
c3c run shared_selftest
c3c run frame_upload_selftest
mkdir -p out
export VK_DRIVER_FILES=$(ls /usr/share/vulkan/icd.d/lvp_icd*.json | head -1)
c3c run root_pointer_compute
c3c run bindless_texture_compute
c3c run memory_report
c3c run bindless_stress
c3c run multithreaded_recording
c3c run pipeline_cache_timing
c3c run offscreen_triangle -- --screenshot out/offscreen_triangle.png
c3c run image_processing -- --screenshot out/image_processing.png
for sample in hello_triangle_sdl gpu_driven_draw_sdl textured_cube \
  texture_filtering volume_texture particle_sim frustum_culling \
  shadow_mapping deferred_shading pbr_materials present_mode_explorer; do
  c3c build "$sample"
  xvfb-run -a env SDL_VIDEODRIVER=x11 WAYLAND_DISPLAY= \
    "./build/$sample" --frames 30 --screenshot "out/$sample.png"
done
test -s out/volume_texture.png
git diff --check
git status --short
```

Expected: C3 reports 0.8.0, the complete local CI sample matrix succeeds, the
volume image is non-empty, and only intentional ignored build/output files are
absent from status.

- [ ] **Step 2: Review the branch for scope and ownership**

Run:

```sh
git diff --stat origin/main...HEAD
git diff origin/main...HEAD
git log --oneline origin/main..HEAD
```

Check explicitly:

- no shared helper behavior changed;
- only the local capability fault exits zero;
- exact 3D width/height/depth are used in creation and copy;
- texture view, texture, allocation, upload allocation, pipeline, swapchain, command allocator, device, surface, runtime, and SDL window all have ordered cleanup;
- completion waits precede destruction of GPU-used resources;
- no `.spv`, `out/`, or unrelated files are tracked;
- the design and implementation agree.

- [ ] **Step 3: Push the branch**

```sh
git push -u origin codex/issue-96-volume-texture-sample
```

- [ ] **Step 4: Open a ready PR**

Create a body file containing:

```markdown
## Summary

- add a windowed fullscreen raymarch over a true 48³ RGBA8 texture
- use exact 3D/linear-filter capability gating and caller-owned texture storage
- add deterministic screenshot documentation and bounded CI coverage

## Verification

- `python3 scripts/gen_abi.py --check`
- `python3 scripts/build_shaders.py`
- `c3c run shared_selftest`
- `c3c run frame_upload_selftest`
- `c3c build volume_texture`
- lavapipe/Xvfb: `volume_texture --frames 30 --screenshot out/volume_texture.png`

Closes #96
```

Open a non-draft PR titled `Add windowed volume texture sample` using the body file.

- [ ] **Step 5: Post `[Self review]` and hand the PR to the standing monitor**

Review the published diff and post a top-level comment beginning `[Self review]` that records:

- the exact capability-gate behavior;
- the caller-owned allocation cleanup order;
- the successful deterministic screenshot run;
- confirmation that generated ABI output is current.

Leave the PR open for external review. The standing all-open-PR monitor should detect and report all actionable review comments without pausing unrelated work.
