#version 460
#include "generated/shader_abi.glsl"
#include "generated/hello_triangle_abi.glsl"
#include "descriptor_heap.glsl"

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

void main() {
    vec4 texel = sample_texture_2d_implicit(pc.texture_index, pc.sampler_index, in_uv);
    out_color = vec4(texel.rgb * (1.0 - pc.pulse), texel.a);
}
