#version 460
#include "generated/shader_abi.glsl"
#include "generated/deferred_shading_abi.glsl"
#include "descriptor_heap.glsl"

struct Light {
    vec4 pos_radius;
    vec4 color;
};

layout(buffer_reference, std430) readonly buffer Lights { Light items[]; };

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push { GraphicsRootPush pc; };

const float AMBIENT = 0.06;

void main() {
    ResolveRoot root = ResolveRoot(pc.fragment_root_gpu);

    vec3 albedo   = sample_texture_2d(root.albedo_target, root.gbuffer_sampler, v_uv).rgb;
    vec4 normal_w = sample_texture_2d(root.normal_target, root.gbuffer_sampler, v_uv);
    vec3 position = sample_texture_2d(root.position_target, root.gbuffer_sampler, v_uv).xyz;

    // Sky pixels never wrote the G-buffer (normal.w stays 0 after clear-to-0
    // vs geometry's stored 0 — use position.w as the coverage flag instead).
    float coverage = sample_texture_2d(root.position_target, root.gbuffer_sampler, v_uv).w;
    if (coverage < 0.5) {
        o_color = vec4(0.07, 0.08, 0.12, 1.0);
        return;
    }

    vec3 n = normalize(normal_w.xyz);
    vec3 lit = albedo * AMBIENT;
    for (uint i = 0u; i < root.light_count; i++) {
        Light light = Lights(root.lights_gpu).items[i];
        vec3 to_light = light.pos_radius.xyz - position;
        float dist = length(to_light);
        float atten = clamp(1.0 - dist / light.pos_radius.w, 0.0, 1.0);
        atten *= atten;
        float lambert = max(dot(n, to_light / max(dist, 1e-4)), 0.0);
        lit += albedo * light.color.rgb * lambert * atten;
    }
    o_color = vec4(lit, 1.0);
}
