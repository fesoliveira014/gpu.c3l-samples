#version 460
#include "generated/shader_abi.glsl"
#include "generated/texture_filtering_abi.glsl"

// Vertex = position (xyz), uv (xy) packed as two vec4s.
layout(buffer_reference, std430) readonly buffer Vertices { vec4 data[]; };
layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) out vec2 v_uv;

void main() {
    FilterRoot root = FilterRoot(pc.vertex_root_gpu);
    mat4 view_proj = mat4(root.view_proj_c0, root.view_proj_c1, root.view_proj_c2, root.view_proj_c3);
    vec4 a = Vertices(root.vertex_gpu).data[gl_VertexIndex * 2];
    vec4 b = Vertices(root.vertex_gpu).data[gl_VertexIndex * 2 + 1];
    gl_Position = view_proj * vec4(a.xyz, 1.0);
    v_uv = b.xy;
}
