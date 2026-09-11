#version 460
#include "generated/shader_abi.glsl"
#include "generated/particle_sim_abi.glsl"

layout(local_size_x = SIM_TILE) in;

struct Particle {
    vec4 pos_age;
    vec4 vel_seed;
};

layout(buffer_reference, std430) readonly buffer ReadState { Particle items[]; };
layout(buffer_reference, std430) writeonly buffer WriteState { Particle items[]; };
layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

const float MAX_AGE = 6.0;
const float FIELD_STRENGTH = 0.9;
const float DRAG = 0.985;

float hash1(float n) { return fract(sin(n) * 43758.5453123); }

vec3 hash3(float n) {
    return vec3(hash1(n), hash1(n + 17.13), hash1(n + 41.79)) * 2.0 - 1.0;
}

// Cheap divergence-light swirl: three sine-gradient octaves curled around y.
vec3 field(vec3 p, float time) {
    vec3 v = vec3(0.0);
    v += vec3(-p.z, 0.25 * sin(time * 0.4 + p.x * 2.0), p.x) * 0.7;
    v += vec3(
        sin(p.y * 3.1 + time),
        sin(p.z * 2.7 - time * 0.8),
        sin(p.x * 3.7 + time * 0.6)) * 0.35;
    v += vec3(
        sin(p.z * 7.3 - time * 1.7),
        sin(p.x * 6.1 + time * 1.3),
        sin(p.y * 6.9 - time)) * 0.12;
    return v * FIELD_STRENGTH;
}

void main() {
    SimRoot root = SimRoot(pc.root_gpu);
    uint id = gl_GlobalInvocationID.x;
    if (id >= root.count) return;

    Particle p = ReadState(root.read_gpu).items[id];
    vec3 pos = p.pos_age.xyz;
    float age = p.pos_age.w + root.dt;
    vec3 vel = p.vel_seed.xyz;
    float seed = p.vel_seed.w;

    vel = vel * DRAG + field(pos, root.time) * root.dt;
    pos += vel * root.dt;

    if (age > MAX_AGE || any(greaterThan(abs(pos), vec3(1.5)))) {
        vec3 h = hash3(seed + root.time);
        pos = vec3(h.x * 0.4, -1.0 + h.y * 0.1, h.z * 0.4);
        vel = vec3(0.0, 0.3 + 0.2 * hash1(seed * 3.3 + root.time), 0.0);
        age = MAX_AGE * hash1(seed * 7.7);
    }

    WriteState(root.write_gpu).items[id] = Particle(vec4(pos, age), vec4(vel, seed));
}
