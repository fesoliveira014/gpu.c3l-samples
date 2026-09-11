#version 460
#include "generated/shader_abi.glsl"
#include "generated/skybox_abi.glsl"
#include "descriptor_heap.glsl"

layout(location = 0) in vec2 v_ndc;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

const float SPHERE_RADIUS = 1.0;
const float HUD_TOP = 0.72;
const float HUD_TILE = 1.0 / 6.0;

// Returns the nearest positive ray parameter, or a negative value on miss.
float intersect_sphere(vec3 origin, vec3 dir) {
    float b = dot(origin, dir);
    float c = dot(origin, origin) - SPHERE_RADIUS * SPHERE_RADIUS;
    float disc = b * b - c;
    if (disc < 0.0) return -1.0;
    return -b - sqrt(disc);
}

void main() {
    SkyRoot root = SkyRoot(pc.fragment_root_gpu);

    if (v_ndc.y > HUD_TOP) {
        float u = (v_ndc.x + 1.0) * 0.5;
        uint face = min(uint(u * 6.0), 5u);
        vec2 tile = vec2(fract(u * 6.0), (v_ndc.y - HUD_TOP) / (1.0 - HUD_TOP));
        vec2 margin = vec2(0.04, 0.08);
        if (any(lessThan(tile, margin)) || any(greaterThan(tile, 1.0 - margin))) {
            o_color = vec4(0.02, 0.02, 0.03, 1.0);
            return;
        }
        vec2 uv = (tile - margin) / (1.0 - 2.0 * margin);
        o_color = sample_texture_2d_implicit(root.faces[face], root.face_sampler, uv);
        return;
    }

    float tan_half_fov = root.camera_forward.w;
    float aspect = root.camera_up.w;
    vec3 dir = normalize(
        root.camera_forward.xyz
        + root.camera_right.xyz * (v_ndc.x * tan_half_fov * aspect)
        - root.camera_up.xyz * (v_ndc.y * tan_half_fov));

    float t = intersect_sphere(root.camera_pos.xyz, dir);
    if (t > 0.0) {
        vec3 hit = root.camera_pos.xyz + dir * t;
        vec3 normal = normalize(hit);
        vec3 reflected = reflect(dir, normal);
        float roughness = clamp(0.5 - 0.5 * normal.y, 0.0, 1.0);
        float lod = roughness * float(root.mip_count - 1u);
        vec4 env = sample_texture_cube_lod(root.cube, root.cube_sampler, reflected, lod);
        float fresnel = pow(1.0 - max(dot(-dir, normal), 0.0), 3.0);
        o_color = vec4(env.rgb * mix(0.6, 1.0, fresnel), 1.0);
        return;
    }

    o_color = sample_texture_cube_implicit(root.cube, root.cube_sampler, dir);
}
