#!/usr/bin/env python3
"""Compile each sample's GLSL shaders to SPIR-V next to their sources.

.spv is gitignored; .glsl is the source of truth. Run after cloning and
after editing a shader or regenerating ABI includes (scripts/gen_abi.py).
Set GLSLC to point at a specific glslc binary.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STAGES = {".comp": "compute", ".vert": "vertex", ".frag": "fragment"}


def main():
    glslc = shutil.which(os.environ.get("GLSLC", "glslc"))
    if glslc is None:
        sys.exit("build_shaders: glslc not found (set GLSLC or add it to PATH)")
    include_dir = ROOT / "lib" / "gpu.c3l" / "include" / "shaders"

    for src in sorted(ROOT.glob("*/shaders/*.glsl")):
        if src.parent.name == "generated":
            continue
        stage = STAGES.get(Path(src.stem).suffix)
        if stage is None:
            print(f"build_shaders: unknown shader stage for {src}", file=sys.stderr)
            sys.exit(1)
        out = src.with_suffix(".spv")
        subprocess.run(
            [glslc, f"-fshader-stage={stage}", "--target-env=vulkan1.3",
             "-I", str(include_dir), str(src), "-o", str(out)],
            check=True,
        )
        print(f"built {out}")


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
