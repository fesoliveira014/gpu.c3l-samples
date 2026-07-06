#version 460
#include "generated/shader_abi.glsl"
#include "generated/deferred_shading_abi.glsl"

// Vertex = two vec4s: position.xyz + pad, normal.xyz + pad.
layout(buffer_reference, std430) readonly buffer Instances { vec4 data[]; };
layout(buffer_reference, std430) readonly buffer Vertices { vec4 data[]; };
layout(push_constant) uniform Push { GraphicsRootPush pc; };

layout(location = 0) out vec3 v_world;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec3 v_albedo;

void main() {
    GeometryRoot root = GeometryRoot(pc.vertex_root_gpu);
    mat4 view_proj = mat4(root.view_proj_c0, root.view_proj_c1, root.view_proj_c2, root.view_proj_c3);

    vec4 center = Instances(root.instances_gpu).data[gl_InstanceIndex * 3];
    vec4 scale4 = Instances(root.instances_gpu).data[gl_InstanceIndex * 3 + 1];
    vec4 color  = Instances(root.instances_gpu).data[gl_InstanceIndex * 3 + 2];
    vec4 p = Vertices(root.vertex_gpu).data[gl_VertexIndex * 2];
    vec4 n = Vertices(root.vertex_gpu).data[gl_VertexIndex * 2 + 1];

    vec3 world = center.xyz + p.xyz * scale4.xyz;
    gl_Position = view_proj * vec4(world, 1.0);
    v_world = world;
    // Non-uniform scale would need the inverse-transpose; axis-aligned boxes
    // with positive scales keep face normals unchanged.
    v_normal = n.xyz;
    v_albedo = color.rgb;
}
