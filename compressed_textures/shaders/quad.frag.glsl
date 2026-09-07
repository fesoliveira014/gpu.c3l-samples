#version 460
#include "generated/shader_abi.glsl"
#include "generated/compressed_textures_abi.glsl"
#include "descriptor_heap.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 1) flat in uint v_quad;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    SceneRoot root = SceneRoot(pc.fragment_root_gpu);
    if (v_quad == 0u) {
        o_color = vec4(sample_texture_2d_implicit(root.color_tex, root.trilinear, v_uv).rgb, 1.0);
    } else {
        float height = sample_texture_2d_implicit(root.gray_tex, root.trilinear, v_uv).r;
        o_color = vec4(vec3(height), 1.0);
    }
}
