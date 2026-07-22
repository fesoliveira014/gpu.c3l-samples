#version 460
#include "generated/shader_abi.glsl"
#include "generated/pbr_materials_abi.glsl"

// Vertex = two vec4s: unit-sphere position + u, normal + v.
layout(buffer_reference, std430) readonly buffer Vertices { vec4 data[]; };
layout(buffer_reference, std430) readonly buffer Instances { SphereInstance items[]; };
layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;

layout(location = 0) out vec3 v_world;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec2 v_uv;
layout(location = 3) flat out uint v_material;

void main() {
    PbrRoot root = PbrRoot(pc.vertex_root_gpu);
    mat4 view_proj = mat4(root.view_proj_c0, root.view_proj_c1, root.view_proj_c2, root.view_proj_c3);

    SphereInstance inst = Instances(root.instances_gpu).items[gl_InstanceIndex];
    vec4 p = Vertices(root.vertex_gpu).data[gl_VertexIndex * 2];
    vec4 n = Vertices(root.vertex_gpu).data[gl_VertexIndex * 2 + 1];

    vec3 world = inst.pos_scale.xyz + p.xyz * inst.pos_scale.w;
    gl_Position = view_proj * vec4(world, 1.0);
    v_world = world;
    // Uniform scale: normals unchanged.
    v_normal = n.xyz;
    v_uv = vec2(p.w, n.w);
    v_material = inst.material;
}
