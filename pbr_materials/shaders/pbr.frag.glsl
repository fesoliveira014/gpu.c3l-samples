#version 460
#include "generated/shader_abi.glsl"
#include "generated/pbr_materials_abi.glsl"
#include "descriptor_heap.glsl"

layout(buffer_reference, std430) readonly buffer Materials { Material items[]; };

layout(location = 0) in vec3 v_world;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec2 v_uv;
layout(location = 3) flat in uint v_material;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push { GraphicsRootPush pc; };

const float PI = 3.14159265;
const float DIFFUSE_AMBIENT = 0.03;
const float SPECULAR_AMBIENT = 0.08;

struct DirLight {
    vec3 dir;
    vec3 color;
};

const DirLight LIGHTS[2] = DirLight[2](
    DirLight(normalize(vec3(-0.5, -1.0, -0.3)), vec3(2.6, 2.5, 2.3)),
    DirLight(normalize(vec3(0.7, -0.4, 0.6)), vec3(0.5, 0.55, 0.7))
);

// GGX-lite: GGX NDF + Schlick fresnel, visibility approximated by the
// Kelemen term 1/(4·vdh²) instead of full Smith — over-brightens grazing
// specular on rough surfaces, acceptable for this scene.
vec3 brdf(vec3 albedo, float roughness, float metallic, vec3 n, vec3 v, vec3 l) {
    vec3 h = normalize(v + l);
    float ndh = max(dot(n, h), 0.0);
    float vdh = max(dot(v, h), 1e-3);
    float a = roughness * roughness;
    float a2 = a * a;
    float denom = ndh * ndh * (a2 - 1.0) + 1.0;
    float d = a2 / (PI * denom * denom);
    vec3 f0 = mix(vec3(0.04), albedo, metallic);
    vec3 f = f0 + (1.0 - f0) * pow(1.0 - vdh, 5.0);
    vec3 spec = d * f / (4.0 * vdh * vdh);
    vec3 kd = (1.0 - f) * (1.0 - metallic);
    return kd * albedo / PI + spec;
}

void main() {
    PbrRoot root = PbrRoot(pc.fragment_root_gpu);
    Material mat = Materials(root.materials_gpu).items[v_material];

    vec3 tex = sample_texture_2d(mat.albedo_tex, root.albedo_sampler, v_uv).rgb;
    vec3 albedo = mat.base_color.rgb * tex;
    vec3 n = normalize(v_normal);
    vec3 v = normalize(root.camera_pos.xyz - v_world);

    // Metals have no diffuse; the f0-tinted term stands in for missing IBL
    // so the metallic rows stay readable.
    vec3 f0 = mix(vec3(0.04), albedo, mat.metallic);
    vec3 lit = (1.0 - mat.metallic) * albedo * DIFFUSE_AMBIENT + f0 * SPECULAR_AMBIENT;
    for (int i = 0; i < 2; i++) {
        vec3 l = -LIGHTS[i].dir;
        float ndl = max(dot(n, l), 0.0);
        if (ndl > 0.0) {
            lit += brdf(albedo, mat.roughness, mat.metallic, n, v, l) * LIGHTS[i].color * ndl;
        }
    }

    // Reinhard, then gamma encode: the swapchain is UNORM, not sRGB.
    lit = lit / (1.0 + lit);
    o_color = vec4(pow(lit, vec3(1.0 / 2.2)), 1.0);
}
