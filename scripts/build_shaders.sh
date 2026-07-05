#!/usr/bin/env sh
# Compile each sample's GLSL shaders to SPIR-V next to their sources. .spv is
# gitignored; .glsl is the source of truth. Run after cloning and after
# editing a shader or regenerating ABI includes (scripts/gen_abi.sh).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GLSLC="${GLSLC:-glslc}"
INC="$ROOT/lib/gpu.c3l/include/shaders"

for src in "$ROOT"/*/shaders/*.glsl; do
    case "$src" in
        */shaders/generated/*) continue ;;
    esac
    out="${src%.glsl}.spv"
    # Stage is the middle extension (foo.comp.glsl -> compute); glslc cannot
    # infer it from a .glsl suffix.
    case "$src" in
        *.comp.glsl) stage=compute ;;
        *.vert.glsl) stage=vertex ;;
        *.frag.glsl) stage=fragment ;;
        *) echo "build_shaders: unknown shader stage for $src" >&2; exit 1 ;;
    esac
    "$GLSLC" -fshader-stage="$stage" --target-env=vulkan1.3 -I "$INC" "$src" -o "$out"
    echo "built $out"
done
