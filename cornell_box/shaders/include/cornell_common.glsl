#ifndef CORNELL_COMMON_GLSL
#define CORNELL_COMMON_GLSL

#include "../generated/cornell_box_abi.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer CornellVertices {
    vec4 values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer CornellMaterials {
    uint values[];
};

struct RadiancePayload {
    vec3 color;
};

uint cornell_hash(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    return value ^ (value >> 16);
}

float cornell_random(inout uint state) {
    state = cornell_hash(state);
    return float(state) * (1.0 / 4294967296.0);
}

vec3 cornell_albedo(uint material) {
    if (material == 1u) return vec3(0.63, 0.065, 0.05);
    if (material == 2u) return vec3(0.14, 0.45, 0.091);
    return vec3(0.725, 0.71, 0.68);
}

#endif
