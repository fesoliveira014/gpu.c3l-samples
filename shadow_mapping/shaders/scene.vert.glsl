#version 460
#include "generated/shader_abi.glsl"
#include "generated/shadow_mapping_abi.glsl"

layout(buffer_reference, std430) readonly buffer Instances { vec4 data[]; };
layout(buffer_reference, std430) readonly buffer Vertices { vec4 data[]; };
layout(push_constant) uniform Push { GraphicsRootPush pc; };

layout(location = 0) out vec3 v_world;
layout(location = 1) out vec3 v_color;
layout(location = 2) out float v_lambert_base;

void main() {
    ScenePassRoot root = ScenePassRoot(pc.vertex_root_gpu);
    mat4 view_proj = mat4(root.view_proj_c0, root.view_proj_c1, root.view_proj_c2, root.view_proj_c3);

    vec4 center = Instances(root.instances_gpu).data[gl_InstanceIndex * 3];
    vec4 scale4 = Instances(root.instances_gpu).data[gl_InstanceIndex * 3 + 1];
    vec4 color  = Instances(root.instances_gpu).data[gl_InstanceIndex * 3 + 2];
    vec4 v = Vertices(root.vertex_gpu).data[gl_VertexIndex];

    vec3 world = center.xyz + v.xyz * scale4.xyz;
    gl_Position = view_proj * vec4(world, 1.0);
    v_world = world;
    v_color = color.rgb;
    v_lambert_base = v.w;
}
