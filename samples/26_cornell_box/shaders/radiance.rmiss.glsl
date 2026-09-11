#version 460
#extension GL_GOOGLE_include_directive : require
#include "ray_tracing.glsl"
#include "include/cornell_common.glsl"

layout(location = 0) rayPayloadInEXT RadiancePayload payload;

void main() {
    payload.color = vec3(0.0);
}
