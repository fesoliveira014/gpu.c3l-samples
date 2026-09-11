#version 460
#include "generated/shader_abi.glsl"
#include "generated/image_processing_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = GEN_TILE, local_size_y = GEN_TILE) in;
layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    GenerateRoot root = GenerateRoot(pc.root_gpu);
    uvec2 p = gl_GlobalInvocationID.xy;
    if (p.x >= root.size || p.y >= root.size) return;

    vec2 uv = vec2(p) / float(root.size);
    float s = root.seed;
    float v = sin(uv.x * 14.0 + s) + sin(uv.y * 11.0 - s)
            + sin((uv.x + uv.y) * 21.0 + s * 0.7)
            + sin(length(uv - 0.5) * 34.0);
    vec3 color = 0.5 + 0.5 * vec3(
        sin(v * 3.14159),
        sin(v * 3.14159 + 2.094),
        sin(v * 3.14159 + 4.189));
    store_storage_texture(root.target, ivec2(p), vec4(color, 1.0));
}
