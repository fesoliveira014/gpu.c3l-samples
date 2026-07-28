#version 460
#include "generated/shader_abi.glsl"
#include "generated/volume_texture_abi.glsl"
#include "descriptor_heap.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

const int STEP_COUNT = 32;
const vec3 BOX_MIN = vec3(0.0);
const vec3 BOX_MAX = vec3(1.0);
const vec3 BACKGROUND = vec3(0.008, 0.012, 0.025);

vec2 intersect_box(vec3 origin, vec3 direction) {
    vec3 inverse_direction = 1.0 / direction;
    vec3 first = (BOX_MIN - origin) * inverse_direction;
    vec3 second = (BOX_MAX - origin) * inverse_direction;
    vec3 near_axis = min(first, second);
    vec3 far_axis = max(first, second);
    return vec2(
        max(max(near_axis.x, near_axis.y), near_axis.z),
        min(min(far_axis.x, far_axis.y), far_axis.z));
}

void main() {
    VolumeRoot root = VolumeRoot(pc.fragment_root_gpu);
    float angle = root.time * 0.35;
    vec3 origin = vec3(
        0.5 + cos(angle) * 2.2,
        0.55 + sin(root.time * 0.6) * 0.12,
        0.5 + sin(angle) * 2.2);
    vec3 forward = normalize(vec3(0.5) - origin);
    vec3 right = normalize(cross(forward, vec3(0.0, 1.0, 0.0)));
    vec3 up = cross(right, forward);
    vec2 screen = v_uv * 2.0 - 1.0;
    screen.x *= root.aspect;
    vec3 direction = normalize(forward + right * screen.x * 0.7 + up * screen.y * 0.7);
    vec2 hit = intersect_box(origin, direction);

    if (hit.x >= hit.y || hit.y <= 0.0) {
        o_color = vec4(BACKGROUND, 1.0);
        return;
    }

    float entry = max(hit.x, 0.0);
    float step_length = (hit.y - entry) / float(STEP_COUNT);
    vec3 position = origin + direction * (entry + step_length * 0.5);
    vec4 accumulated = vec4(0.0);
    float pulse = 0.85 + 0.15 * sin(root.time);

    for (int i = 0; i < STEP_COUNT; i++) {
        vec4 voxel = sample_texture_3d(
            root.volume_texture,
            root.volume_sampler,
            position);
        float alpha = voxel.a * 0.11 * pulse;
        accumulated.rgb += (1.0 - accumulated.a) * voxel.rgb * alpha;
        accumulated.a += (1.0 - accumulated.a) * alpha;
        if (accumulated.a >= 0.98) break;
        position += direction * step_length;
    }

    vec3 color = accumulated.rgb + BACKGROUND * (1.0 - accumulated.a);
    color = color / (1.0 + color);
    o_color = vec4(pow(color, vec3(1.0 / 2.2)), 1.0);
}
