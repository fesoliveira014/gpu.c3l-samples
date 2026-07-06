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

const float AMBIENT = 0.05;
const vec3 SKY = vec3(0.003, 0.004, 0.010);

void main() {
    ResolveRoot root = ResolveRoot(pc.fragment_root_gpu);

    vec3 albedo   = sample_texture_2d(root.albedo_target, root.gbuffer_sampler, v_uv).rgb;
    vec4 normal_w = sample_texture_2d(root.normal_target, root.gbuffer_sampler, v_uv);
    vec4 pos_cov  = sample_texture_2d(root.position_target, root.gbuffer_sampler, v_uv);
    vec3 position = pos_cov.xyz;

    // Sky pixels never wrote the G-buffer; position.w is the coverage flag
    // (1 from geometry, 0 from clear).
    vec3 lit;
    if (pos_cov.w < 0.5) {
        lit = SKY;
    } else {
        vec3 n = normalize(normal_w.xyz);
        vec3 view_dir = normalize(root.camera_pos.xyz - position);
        lit = albedo * AMBIENT;
        for (uint i = 0u; i < root.light_count; i++) {
            Light light = Lights(root.lights_gpu).items[i];
            vec3 to_light = light.pos_radius.xyz - position;
            float dist = length(to_light);
            float atten = clamp(1.0 - dist / light.pos_radius.w, 0.0, 1.0);
            atten *= atten;
            vec3 light_dir = to_light / max(dist, 1e-4);
            float lambert = max(dot(n, light_dir), 0.0);
            vec3 half_dir = normalize(light_dir + view_dir);
            float spec = pow(max(dot(n, half_dir), 0.0), 32.0) * 0.25;
            lit += (albedo * lambert + vec3(spec)) * light.color.rgb * atten;
        }
    }

    // Reinhard, then gamma encode: the swapchain is UNORM, not sRGB.
    lit = lit / (1.0 + lit);
    o_color = vec4(pow(lit, vec3(1.0 / 2.2)), 1.0);
}
