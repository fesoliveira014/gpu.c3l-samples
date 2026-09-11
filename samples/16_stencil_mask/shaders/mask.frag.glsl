#version 460
#include "generated/shader_abi.glsl"
#include "generated/stencil_mask_abi.glsl"

layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

// Colour writes are masked off for this draw; only the stencil plane changes.
void main() {
    o_color = vec4(0.0);
}
