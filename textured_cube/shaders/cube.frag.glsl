#version 460
#include "generated/shader_abi.glsl"
#include "generated/textured_cube_abi.glsl"
#include "descriptor_heap.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 1) in float v_lambert;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push { GraphicsRootPush pc; };

void main() {
    SceneRoot root = SceneRoot(pc.fragment_root_gpu);
    vec4 albedo = sample_texture_2d(root.albedo_texture, root.albedo_sampler, v_uv);
    o_color = vec4(albedo.rgb * v_lambert, 1.0);
}
