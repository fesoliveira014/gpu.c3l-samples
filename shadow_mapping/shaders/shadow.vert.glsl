#version 460
#include "generated/shader_abi.glsl"
#include "generated/shadow_mapping_abi.glsl"

// Instance = three vec4s: center, per-axis scale, color (color unused here).
layout(buffer_reference, std430) readonly buffer Instances { vec4 data[]; };
layout(buffer_reference, std430) readonly buffer Vertices { vec4 data[]; };
layout(push_constant) uniform Push { RootPush pc; };

void main() {
    ShadowPassRoot root = ShadowPassRoot(pc.root_gpu);
    mat4 light_vp = mat4(root.light_vp_c0, root.light_vp_c1, root.light_vp_c2, root.light_vp_c3);

    vec4 scale4 = Instances(root.instances_gpu).data[gl_InstanceIndex * 3 + 1];
    vec4 center = Instances(root.instances_gpu).data[gl_InstanceIndex * 3];
    vec4 v = Vertices(root.vertex_gpu).data[gl_VertexIndex];

    vec3 world = center.xyz + v.xyz * scale4.xyz;
    gl_Position = light_vp * vec4(world, 1.0);
}
