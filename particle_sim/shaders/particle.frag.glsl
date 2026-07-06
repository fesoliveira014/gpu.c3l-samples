#version 460

layout(location = 0) in vec2 v_corner;
layout(location = 1) in float v_speed;
layout(location = 0) out vec4 o_color;

void main() {
    float falloff = max(0.0, 1.0 - dot(v_corner, v_corner));
    float glow = falloff * falloff;
    vec3 slow = vec3(0.10, 0.25, 0.9);
    vec3 fast = vec3(1.0, 0.55, 0.15);
    vec3 color = mix(slow, fast, clamp(v_speed * 1.4, 0.0, 1.0));
    o_color = vec4(color * glow * 0.35, 1.0);
}
