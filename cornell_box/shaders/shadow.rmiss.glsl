#version 460
#extension GL_GOOGLE_include_directive : require
#include "ray_tracing.glsl"
#include "include/cornell_common.glsl"

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(location = 1) rayPayloadInEXT uint visible;

void main() {
    if (pc.root_gpu == 0ul) return;
    visible = 1u;
}
