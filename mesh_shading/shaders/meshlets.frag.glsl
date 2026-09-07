#version 460
#include "generated/shader_abi.glsl"
#include "generated/mesh_shading_abi.glsl"

layout(location = 0) in vec4 v_color;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

void main() {
    FragRoot frag_root = FragRoot(pc.fragment_root_gpu);
    out_color = v_color * frag_root.tint;
}
