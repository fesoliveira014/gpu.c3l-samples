#version 460
#include "generated/shader_abi.glsl"
#include "generated/shadow_mapping_abi.glsl"
#include "descriptor_heap.glsl"

layout(location = 0) in vec3 v_world;
layout(location = 1) in vec3 v_color;
layout(location = 2) in float v_lambert_base;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push { GraphicsRootPush pc; };

const float AMBIENT = 0.22;

void main() {
    ScenePassRoot root = ScenePassRoot(pc.fragment_root_gpu);
    mat4 light_vp = mat4(root.light_vp_c0, root.light_vp_c1, root.light_vp_c2, root.light_vp_c3);

    vec4 light_clip = light_vp * vec4(v_world, 1.0);
    vec3 ndc = light_clip.xyz / light_clip.w;
    vec2 uv = ndc.xy * 0.5 + 0.5;

    float shadow = 1.0;
    if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
        float texel = 1.0 / float(SHADOW_MAP_SIZE);
        float sum = 0.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                sum += sample_shadow_2d(
                    root.shadow_map,
                    root.shadow_sampler,
                    vec3(uv + vec2(x, y) * texel, ndc.z));
            }
        }
        shadow = sum / 9.0;
    }

    float light = AMBIENT + (1.0 - AMBIENT) * v_lambert_base * shadow;
    o_color = vec4(v_color * light, 1.0);
}
