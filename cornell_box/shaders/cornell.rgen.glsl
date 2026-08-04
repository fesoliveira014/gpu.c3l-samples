#version 460
#extension GL_GOOGLE_include_directive : require
#include "ray_tracing.glsl"
#include "descriptor_heap.glsl"
#include "include/cornell_common.glsl"

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(location = 0) rayPayloadEXT RadiancePayload payload;

void main() {
    CornellRoot root = CornellRoot(pc.root_gpu);
    uvec2 pixel = gl_LaunchIDEXT.xy;
    uint random_state = root.seed
        ^ (pixel.x * 1973u + pixel.y * 9277u + root.sample_index * 26699u);
    vec2 jitter = vec2(
        cornell_random(random_state),
        cornell_random(random_state));
    vec2 uv = (vec2(pixel) + jitter) / vec2(root.width, root.height);
    vec2 film = uv * 2.0 - 1.0;
    film.x *= float(root.width) / float(root.height);
    vec3 direction = normalize(
        root.camera_forward.xyz
        + film.x * root.camera_right.xyz * 0.357142857
        - film.y * root.camera_up.xyz * 0.357142857);

    payload.color = vec3(0.0);
    traceRayEXT(
        GPU_ACCELERATION_STRUCTURE(root.tlas),
        gl_RayFlagsOpaqueEXT,
        0xff,
        0,
        0,
        0,
        root.camera_position.xyz,
        0.1,
        direction,
        5000.0,
        0);

    ivec2 coordinate = ivec2(pixel);
    vec3 previous = load_storage_texture(root.output_texture, coordinate).rgb;
    float sample_count = float(root.sample_index);
    vec3 accumulated = root.sample_index == 0u
        ? payload.color
        : (previous * sample_count + payload.color) / (sample_count + 1.0);
    store_storage_texture(
        root.output_texture,
        coordinate,
        vec4(accumulated, 1.0));
}
