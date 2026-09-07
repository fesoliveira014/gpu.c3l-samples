#version 460
#include "generated/shader_abi.glsl"
#include "generated/stencil_mask_abi.glsl"

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

const float TAU = 6.28318530718;

vec2 star_point(MaskRoot root, uint segment) {
    float angle = TAU * float(segment) / float(STAR_SEGMENTS);
    float radius = 0.45 + 0.18 * cos(5.0 * angle - root.time * 1.5);
    return vec2(cos(angle), sin(angle)) * radius / vec2(root.aspect, 1.0);
}

// A rotating five-lobed star as a triangle fan: centre, rim[i], rim[i + 1].
void main() {
    MaskRoot root = MaskRoot(pc.vertex_root_gpu);
    uint segment = gl_VertexIndex / 3;
    uint corner = gl_VertexIndex % 3;
    vec2 p = corner == 0 ? vec2(0.0) : star_point(root, segment + corner - 1);
    gl_Position = vec4(p, 0.0, 1.0);
}
