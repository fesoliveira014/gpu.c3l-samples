#version 460

layout(location = 0) out vec2 v_ndc;

void main() {
    vec2 corners[3] = vec2[3](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
    v_ndc = corners[gl_VertexIndex];
    gl_Position = vec4(v_ndc, 0.0, 1.0);
}
