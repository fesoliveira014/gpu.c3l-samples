#version 460
#include "generated/shader_abi.glsl"
#include "generated/gpu_driven_abi.glsl"

layout(buffer_reference, std430) readonly buffer Corners { vec2 items[]; };
layout(buffer_reference, std430) readonly buffer DrawRoots { DrawRoot roots[]; };
layout(buffer_reference, std430) readonly buffer Instances { Instance items[]; };
layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) out vec4 v_color;

void main() {
    DrawRoot root = DrawRoots(pc.vertex_root_gpu).roots[0];
    Instance inst = Instances(root.instances_gpu).items[gl_InstanceIndex];
    vec2 corner = Corners(root.corners_gpu).items[gl_VertexIndex];
    gl_Position = vec4(inst.pos + corner * inst.scale, 0.0, 1.0);
    v_color = inst.color;
}
