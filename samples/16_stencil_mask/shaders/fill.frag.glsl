#version 460
#include "generated/shader_abi.glsl"
#include "generated/stencil_mask_abi.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    MaskRoot root = MaskRoot(pc.fragment_root_gpu);
    vec2 p = (v_uv * 2.0 - 1.0) * vec2(root.aspect, 1.0);
    if (root.fill_mode == FILL_INSIDE) {
        float band = sin((p.x + p.y) * 12.0 - root.time * 3.0) * 0.5 + 0.5;
        vec3 warm = vec3(0.95, 0.55, 0.15);
        vec3 cool = vec3(0.20, 0.70, 0.95);
        o_color = vec4(mix(warm, cool, band), 1.0);
    } else {
        vec2 cell = fract(p * 6.0);
        float line = step(0.94, max(cell.x, cell.y));
        o_color = vec4(mix(vec3(0.08, 0.09, 0.12), vec3(0.22, 0.24, 0.30), line), 1.0);
    }
}
