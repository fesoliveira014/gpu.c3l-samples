#version 460
#include "generated/shader_abi.glsl"
#include "generated/texture_filtering_abi.glsl"
#include "descriptor_heap.glsl"

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 o_color;

layout(push_constant) uniform Push { GraphicsRootPush pc; };

void main() {
    FilterRoot root = FilterRoot(pc.fragment_root_gpu);
    int strip = int(gl_FragCoord.x / root.strip_width);
    uint smp = strip == 0 ? root.nearest_smp
             : strip == 1 ? root.bilinear_smp
             : strip == 2 ? root.trilinear_smp
             : root.aniso_smp;
    vec4 albedo = sample_texture_2d_implicit(root.checker, smp, v_uv);

    float edge = mod(gl_FragCoord.x, root.strip_width);
    if (strip > 0 && edge < 2.0) albedo = vec4(1.0);
    o_color = vec4(albedo.rgb, 1.0);
}
