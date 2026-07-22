#version 460
#include "generated/shader_abi.glsl"
#include "generated/particle_sim_abi.glsl"

struct Particle {
    vec4 pos_age;
    vec4 vel_seed;
};

layout(buffer_reference, std430) readonly buffer Particles { Particle items[]; };
layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) out vec2 v_corner;
layout(location = 1) out float v_speed;

const vec2 CORNERS[6] = vec2[](
    vec2(-1, -1), vec2(1, -1), vec2(1, 1),
    vec2(-1, -1), vec2(1, 1), vec2(-1, 1));

void main() {
    ParticleDrawRoot root = ParticleDrawRoot(pc.vertex_root_gpu);
    mat4 view_proj = mat4(root.view_proj_c0, root.view_proj_c1, root.view_proj_c2, root.view_proj_c3);

    Particle p = Particles(root.particles_gpu).items[gl_InstanceIndex];
    vec4 clip = view_proj * vec4(p.pos_age.xyz, 1.0);

    vec2 corner = CORNERS[gl_VertexIndex];
    clip.xy += corner * vec2(root.quad_size, root.quad_size * root.aspect) * clip.w;

    gl_Position = clip;
    v_corner = corner;
    v_speed = length(p.vel_seed.xyz);
}
