#version 460
#include "generated/shader_abi.glsl"
#include "generated/gpu_driven_abi.glsl"

layout(buffer_reference, std430) readonly buffer FragmentRoots { FragmentRoot roots[]; };
layout(push_constant) uniform Push { GraphicsRootPush pc; };

layout(location = 0) in vec4 v_color;
layout(location = 0) out vec4 o_color;

void main() {
    FragmentRoot root = FragmentRoots(pc.fragment_root_gpu).roots[0];
    o_color = v_color * root.tint;
}
