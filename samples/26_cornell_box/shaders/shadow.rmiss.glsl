#version 460
#extension GL_GOOGLE_include_directive : require
#include "ray_tracing.glsl"
#include "include/cornell_common.glsl"

layout(location = 1) rayPayloadInEXT uint visible;

void main() {
    visible = 1u;
}
