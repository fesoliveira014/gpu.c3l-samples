#version 460
#include "generated/shader_abi.glsl"
#include "generated/frustum_culling_abi.glsl"

layout(local_size_x = CULL_TILE) in;

struct Instance {
    vec4 center_radius;
    vec4 color;
};

layout(buffer_reference, std430) readonly buffer Instances { Instance items[]; };
layout(buffer_reference, std430) writeonly buffer Args { DrawIndirectCommand cmds[]; };
layout(buffer_reference, std430) buffer Stats { uint visible; };
layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    CullRoot root = CullRoot(pc.root_gpu);
    uint id = gl_GlobalInvocationID.x;
    if (id >= root.count) return;

    vec4 sphere = Instances(root.instances_gpu).items[id].center_radius;
    bool visible = true;
    for (int i = 0; i < 6; i++) {
        if (dot(root.planes[i].xyz, sphere.xyz) + root.planes[i].w < -sphere.w) visible = false;
    }

    Args(root.args_gpu).cmds[id] = DrawIndirectCommand(36u, visible ? 1u : 0u, 0u, id);
    if (visible) atomicAdd(Stats(root.stats_gpu).visible, 1u);
}
