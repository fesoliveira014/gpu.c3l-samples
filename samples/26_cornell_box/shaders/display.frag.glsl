#version 460
#include "generated/cornell_box_abi.glsl"
#include "descriptor_heap.glsl"

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 color;

void main() {
    DisplayRoot root = DisplayRoot(pc.fragment_root_gpu);
    vec3 linear_color = sample_texture_2d_implicit(
        root.output_texture,
        root.heap_sampler,
        uv).rgb;
    vec3 mapped = linear_color / (linear_color + vec3(1.0));
    color = vec4(pow(mapped, vec3(1.0 / 2.2)), 1.0);
}
