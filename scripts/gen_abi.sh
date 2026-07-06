#!/usr/bin/env sh
# Regenerate each sample's shader ABI outputs from its .abi schemas using the
# generator vendored in lib/gpu.c3l. Pass --check to verify committed outputs
# instead of rewriting them (exits nonzero on drift).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="${1:-}"

c3c build gen_shader_abi --path "$ROOT/lib/gpu.c3l/tools/gen_shader_abi" >/dev/null
GEN="$ROOT/lib/gpu.c3l/tools/gen_shader_abi/build/gen_shader_abi"

# gen <module> <c3-out> <glsl-out> <schemas...>
gen() {
    module="$1"; c3_out="$2"; glsl_out="$3"
    shift 3
    mkdir -p "$(dirname "$glsl_out")"
    # shellcheck disable=SC2086
    "$GEN" --module "$module" --c3-out "$c3_out" --glsl-out "$glsl_out" $CHECK "$@"
}

RPC="$ROOT/root_pointer_compute"
gen root_pointer_compute "$RPC/shader_abi.c3" "$RPC/shaders/generated/root_pointer_abi.glsl" \
    "$RPC/abi/root_pointer.abi"

GDD="$ROOT/gpu_driven_draw_sdl"
gen gpu_driven_draw_sdl "$GDD/shader_abi.c3" "$GDD/shaders/generated/gpu_driven_abi.glsl" \
    "$GDD/abi/gpu_driven.abi"

BTC="$ROOT/bindless_texture_compute"
gen bindless_texture_compute "$BTC/shader_abi.c3" "$BTC/shaders/generated/bindless_abi.glsl" \
    "$BTC/abi/bindless.abi"

TC="$ROOT/textured_cube"
gen textured_cube "$TC/shader_abi.c3" "$TC/shaders/generated/textured_cube_abi.glsl" \
    "$TC/abi/scene.abi"

TF="$ROOT/texture_filtering"
gen texture_filtering "$TF/shader_abi.c3" "$TF/shaders/generated/texture_filtering_abi.glsl" \
    "$TF/abi/filtering.abi"

IP="$ROOT/image_processing"
gen image_processing "$IP/shader_abi.c3" "$IP/shaders/generated/image_processing_abi.glsl" \
    "$IP/abi/processing.abi"

PS="$ROOT/particle_sim"
gen particle_sim "$PS/shader_abi.c3" "$PS/shaders/generated/particle_sim_abi.glsl" \
    "$PS/abi/particles.abi"

OT="$ROOT/offscreen_triangle"
gen offscreen_triangle "$OT/shader_abi.c3" "$OT/shaders/generated/offscreen_abi.glsl" \
    "$OT/abi/offscreen.abi"
gen hello_triangle_sdl "$ROOT/hello_triangle_sdl/shader_abi.c3" "$OT/shaders/generated/offscreen_abi.glsl" \
    "$OT/abi/offscreen.abi"
