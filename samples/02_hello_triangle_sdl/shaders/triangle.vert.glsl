#version 460
#include "generated/shader_abi.glsl"
#include "generated/hello_triangle_abi.glsl"

layout(location = 0) out vec2 out_uv;

const vec2 POSITIONS[3] = vec2[3](vec2(-0.8, -0.8), vec2(0.8, -0.8), vec2(0.0, 0.8));
const vec2 UVS[3] = vec2[3](vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.5, 1.0));

void main() {
    gl_Position = vec4(POSITIONS[gl_VertexIndex], 0.0, 1.0);
    out_uv = UVS[gl_VertexIndex];
}
