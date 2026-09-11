#version 460
#extension GL_EXT_mesh_shader : require
#include "generated/shader_abi.glsl"
#include "generated/mesh_shading_abi.glsl"

layout(local_size_x = 1) in;

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

struct TaskPayload {
    uint first_meshlet;
};
taskPayloadSharedEXT TaskPayload payload;

void main() {
    if (pc.vertex_root_gpu == 0ul) {
        EmitMeshTasksEXT(0, 0, 0);
        return;
    }
    MeshRoot root = MeshRoot(pc.vertex_root_gpu);
    uint offset = gl_WorkGroupID.x * MESHLETS_PER_TASK;
    uint remaining = offset < root.meshlet_count ? root.meshlet_count - offset : 0u;
    payload.first_meshlet = root.first_meshlet + offset;
    EmitMeshTasksEXT(min(remaining, MESHLETS_PER_TASK), 1, 1);
}
