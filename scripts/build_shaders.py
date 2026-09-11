#!/usr/bin/env python3
"""Generate every sample's shader ABI and compile its shaders.

Builds the gpu_shaders tool vendored in lib/gpu.c3l, then runs it once per
sample directory under samples/: schemas under <sample>/abi/ produce
<sample>/<name>_abi.c3 and <sample>/shaders/generated/<name>_abi.glsl; every
<sample>/shaders/*.glsl compiles to .spv beside it. The generated C3 module is
the directory name without its NN_ ordering prefix. Pass --check to verify
committed ABI outputs instead of rewriting them (exits nonzero on drift);
shaders compile either way. Set C3C or GLSLC to point at specific binaries.
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SAMPLES_DIR = ROOT / "samples"
TOOL_DIR = ROOT / "lib" / "gpu.c3l" / "tools" / "gpu_shaders"


def tool_binary():
    exe = TOOL_DIR / "build" / "gpu_shaders.exe"
    return exe if exe.exists() else TOOL_DIR / "build" / "gpu_shaders"


def build_tool():
    c3c = shutil.which(os.environ.get("C3C", "c3c"))
    if c3c is None:
        sys.exit("build_shaders: c3c not found (set C3C or add it to PATH)")
    subprocess.run(
        [c3c, "build", "gpu_shaders", "--path", str(TOOL_DIR)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return tool_binary()


def module_name(sample):
    return re.sub(r"^\d+_", "", sample.name)


def main():
    check = "--check" in sys.argv[1:]
    tool = build_tool()
    for sample in sorted(p for p in SAMPLES_DIR.iterdir() if (p / "shaders").is_dir()):
        args = ["--shader-dir", sample / "shaders"]
        if (sample / "abi").is_dir():
            args = [
                "--abi-dir", sample / "abi",
                "--module", module_name(sample),
                "--c3-out", sample,
                "--glsl-out", sample / "shaders" / "generated",
                *args,
            ]
        if check:
            args.append("--check")
        subprocess.run([str(tool), *map(str, args)], check=True, cwd=ROOT)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
