#version 460
#include "generated/shader_abi.glsl"
#include "generated/present_mode_explorer_abi.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

// params: x = time, y = bar position [0,1], zw = resolution.
void main() {
    ExplorerRoot root = ExplorerRoot(pc.fragment_root_gpu);
    float t = root.params.x;
    vec3 grad = 0.5 + 0.4 * cos(t + v_uv.xyx * 3.0 + vec3(0.0, 2.094, 4.189));
    float bar_half = 8.0 / root.params.z;
    float in_bar = step(abs(v_uv.x - root.params.y), bar_half);
    vec3 color = mix(grad, vec3(1.0), in_bar);
    o_color = vec4(pow(color, vec3(1.0 / 2.2)), 1.0);
}
