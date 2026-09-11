#version 460
#extension GL_EXT_mesh_shader : require
#include "generated/shader_abi.glsl"
#include "generated/mesh_shading_abi.glsl"

layout(local_size_x = 1) in;
layout(triangles, max_vertices = 7, max_primitives = 6) out;

layout(location = 0) out vec4 v_color[];

layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

struct TaskPayload {
    uint first_meshlet;
};
taskPayloadSharedEXT TaskPayload payload;

const float TAU = 6.28318530718;

vec3 hue(float t) {
    vec3 k = vec3(0.0, 2.0, 4.0);
    return 0.55 + 0.45 * cos(TAU * t + k);
}

void main() {
    MeshRoot root = MeshRoot(pc.vertex_root_gpu);
    uint meshlet = payload.first_meshlet + gl_WorkGroupID.x;
    uint col = meshlet % COLUMNS;
    uint row = meshlet / COLUMNS;
    vec2 cell = vec2(2.0 / float(COLUMNS), 2.0 / float(ROWS));
    vec2 center = vec2(-1.0, -1.0) + (vec2(col, row) + 0.5) * cell;
    float phase = float(meshlet) * 0.37;
    float radius = min(cell.x, cell.y) * (0.34 + 0.12 * sin(root.time * 2.0 + phase));
    vec3 base = hue(float(meshlet) / float(COLUMNS * ROWS));

    SetMeshOutputsEXT(HEX_VERTICES, HEX_TRIANGLES);
    gl_MeshVerticesEXT[0].gl_Position = vec4(center, 0.0, 1.0);
    v_color[0] = vec4(base, 1.0);
    for (uint i = 0; i < 6; i++) {
        float angle = root.time * 0.6 + phase + float(i) * TAU / 6.0;
        vec2 offset = radius * vec2(cos(angle) / root.aspect, sin(angle));
        gl_MeshVerticesEXT[i + 1].gl_Position = vec4(center + offset, 0.0, 1.0);
        v_color[i + 1] = vec4(base * 0.3, 1.0);
    }
    for (uint t = 0; t < 6; t++) {
        gl_PrimitiveTriangleIndicesEXT[t] = uvec3(0, 1 + t, 1 + (t + 1) % 6);
    }
}
