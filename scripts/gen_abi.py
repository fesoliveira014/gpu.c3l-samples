#!/usr/bin/env python3
"""Regenerate each sample's shader ABI outputs from its .abi schemas.

Uses the generator vendored in lib/gpu.c3l. Pass --check to verify committed
outputs instead of rewriting them (exits nonzero on drift).

Portable replacement for the old gen_abi.sh — runs anywhere python3 and c3c
do, including native Windows (no bash required).
"""

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# (module, sample dir, generated glsl name, schema file)
JOBS = [
    ("root_pointer_compute", "root_pointer_compute", "root_pointer_abi.glsl", "root_pointer.abi"),
    ("gpu_driven_draw_sdl", "gpu_driven_draw_sdl", "gpu_driven_abi.glsl", "gpu_driven.abi"),
    ("bindless_texture_compute", "bindless_texture_compute", "bindless_abi.glsl", "bindless.abi"),
    ("textured_cube", "textured_cube", "textured_cube_abi.glsl", "scene.abi"),
    ("texture_filtering", "texture_filtering", "texture_filtering_abi.glsl", "filtering.abi"),
    ("image_processing", "image_processing", "image_processing_abi.glsl", "processing.abi"),
    ("particle_sim", "particle_sim", "particle_sim_abi.glsl", "particles.abi"),
    ("frustum_culling", "frustum_culling", "frustum_culling_abi.glsl", "culling.abi"),
    ("shadow_mapping", "shadow_mapping", "shadow_mapping_abi.glsl", "shadow.abi"),
    ("deferred_shading", "deferred_shading", "deferred_shading_abi.glsl", "deferred.abi"),
    ("pbr_materials", "pbr_materials", "pbr_materials_abi.glsl", "pbr.abi"),
    ("bindless_stress", "bindless_stress", "bindless_stress_abi.glsl", "stress.abi"),
    ("multithreaded_recording", "multithreaded_recording", "multithreaded_recording_abi.glsl", "mtrec.abi"),
    ("pipeline_cache_timing", "pipeline_cache_timing", "pipeline_cache_timing_abi.glsl", "cachetime.abi"),
    ("present_mode_explorer", "present_mode_explorer", "present_mode_explorer_abi.glsl", "explorer.abi"),
    ("offscreen_triangle", "offscreen_triangle", "offscreen_abi.glsl", "offscreen.abi"),
]


def generator_binary(tool_dir):
    exe = tool_dir / "build" / "gen_shader_abi.exe"
    return exe if exe.exists() else tool_dir / "build" / "gen_shader_abi"


def build_generator():
    tool_dir = ROOT / "lib" / "gpu.c3l" / "tools" / "gen_shader_abi"
    c3c = shutil.which("c3c")
    if c3c is None:
        sys.exit("gen_abi: c3c not found on PATH")
    subprocess.run(
        [c3c, "build", "gen_shader_abi", "--path", str(tool_dir)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return generator_binary(tool_dir)


def gen(gen_bin, check, module, c3_out, glsl_out, schemas):
    Path(glsl_out).parent.mkdir(parents=True, exist_ok=True)
    cmd = [str(gen_bin), "--module", module, "--c3-out", str(c3_out), "--glsl-out", str(glsl_out)]
    if check:
        cmd.append("--check")
    cmd += [str(s) for s in schemas]
    subprocess.run(cmd, check=True)


def main():
    check = "--check" in sys.argv[1:]
    gen_bin = build_generator()

    for module, sample, glsl_name, schema in JOBS:
        sample_dir = ROOT / sample
        gen(gen_bin, check, module,
            sample_dir / "shader_abi.c3",
            sample_dir / "shaders" / "generated" / glsl_name,
            [sample_dir / "abi" / schema])

    # hello_triangle_sdl reuses offscreen_triangle's schema and GLSL output;
    # only its C3 twin is its own.
    offscreen = ROOT / "offscreen_triangle"
    gen(gen_bin, check, "hello_triangle_sdl",
        ROOT / "hello_triangle_sdl" / "shader_abi.c3",
        offscreen / "shaders" / "generated" / "offscreen_abi.glsl",
        [offscreen / "abi" / "offscreen.abi"])


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
