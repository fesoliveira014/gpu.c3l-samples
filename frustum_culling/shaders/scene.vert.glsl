#version 460
#extension GL_ARB_shader_draw_parameters : require
#include "generated/shader_abi.glsl"
#include "generated/frustum_culling_abi.glsl"

struct Instance {
    vec4 center_radius;
    vec4 color;
};

// Cube vertex = position.xyz + face lambert (w); one shared 36-vertex cube.
layout(buffer_reference, std430) readonly buffer Instances { Instance items[]; };
layout(buffer_reference, std430) readonly buffer Vertices { vec4 data[]; };
layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) out vec3 v_color;

const float CUBE_HALF = 0.35;

void main() {
    SceneDrawRoot root = SceneDrawRoot(pc.vertex_root_gpu);
    mat4 view_proj = mat4(root.view_proj_c0, root.view_proj_c1, root.view_proj_c2, root.view_proj_c3);

    Instance inst = Instances(root.instances_gpu).items[gl_DrawID];
    vec4 v = Vertices(root.vertex_gpu).data[gl_VertexIndex];

    vec3 world = inst.center_radius.xyz + v.xyz * CUBE_HALF;
    gl_Position = view_proj * vec4(world, 1.0);
    v_color = inst.color.rgb * v.w;
}
