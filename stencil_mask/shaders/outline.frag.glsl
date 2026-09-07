#version 460
#include "generated/shader_abi.glsl"
#include "generated/stencil_mask_abi.glsl"
#include "descriptor_heap.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

uint stencil_at(MaskRoot root, ivec2 texel) {
    ivec2 clamped = clamp(texel, ivec2(0), ivec2(root.width, root.height) - 1);
    return gpu_fetch_uint(root.stencil_texture, clamped, 0);
}

// White edge wherever the stencil id differs from a neighbour two texels
// away, read through the integer heap alias; alpha blending hides the rest.
void main() {
    MaskRoot root = MaskRoot(pc.fragment_root_gpu);
    ivec2 c = ivec2(gl_FragCoord.xy);
    uint here = stencil_at(root, c);
    bool edge = stencil_at(root, c + ivec2(2, 0)) != here
        || stencil_at(root, c - ivec2(2, 0)) != here
        || stencil_at(root, c + ivec2(0, 2)) != here
        || stencil_at(root, c - ivec2(0, 2)) != here;
    o_color = vec4(1.0, 1.0, 1.0, edge ? 1.0 : 0.0);
}
