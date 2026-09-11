#version 460
#include "generated/shader_abi.glsl"
#include "generated/stencil_mask_abi.glsl"

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) out vec2 v_uv;

void main() {
    vec2 corner = vec2((gl_VertexIndex & 1) << 2, (gl_VertexIndex & 2) << 1);
    v_uv = corner * 0.5;
    gl_Position = vec4(corner - 1.0, 0.0, 1.0);
}
