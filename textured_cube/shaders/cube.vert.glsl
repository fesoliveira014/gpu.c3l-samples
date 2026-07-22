#version 460
#include "generated/shader_abi.glsl"
#include "generated/textured_cube_abi.glsl"

// Vertex = position (xyz) + face lambert factor (w), uv (xy) packed as two vec4s.
layout(buffer_reference, std430) readonly buffer Vertices { vec4 data[]; };
layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out float v_lambert;

void main() {
    SceneRoot root = SceneRoot(pc.vertex_root_gpu);
    mat4 view_proj = mat4(root.view_proj_c0, root.view_proj_c1, root.view_proj_c2, root.view_proj_c3);
    mat4 model = mat4(root.model_c0, root.model_c1, root.model_c2, root.model_c3);

    vec4 a = Vertices(root.vertex_gpu).data[gl_VertexIndex * 2];
    vec4 b = Vertices(root.vertex_gpu).data[gl_VertexIndex * 2 + 1];

    gl_Position = view_proj * model * vec4(a.xyz, 1.0);
    v_uv = b.xy;
    v_lambert = a.w;
}
