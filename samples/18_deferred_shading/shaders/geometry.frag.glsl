#version 460

layout(location = 0) in vec3 v_world;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec3 v_albedo;

layout(location = 0) out vec4 o_albedo;
layout(location = 1) out vec4 o_normal;
layout(location = 2) out vec4 o_position;

void main() {
    o_albedo   = vec4(v_albedo, 1.0);
    o_normal   = vec4(normalize(v_normal), 0.0);
    o_position = vec4(v_world, 1.0);
}
