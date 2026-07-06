#version 460
#include "generated/shader_abi.glsl"
#include "generated/pipeline_cache_timing_abi.glsl"

layout(push_constant) uniform Push { GraphicsRootPush pc; };

layout(location = 0) out vec4 v_color;

const vec2 CORNERS[6] = vec2[6](
    vec2(0, 0), vec2(1, 0), vec2(1, 1),
    vec2(0, 0), vec2(1, 1), vec2(0, 1)
);

// rect = {x0, y0, x1, y1} in NDC.
void main() {
    QuadRoot root = QuadRoot(pc.vertex_root_gpu);
    vec2 p = mix(root.rect.xy, root.rect.zw, CORNERS[gl_VertexIndex]);
    gl_Position = vec4(p, 0.0, 1.0);
    v_color = root.color;
}
