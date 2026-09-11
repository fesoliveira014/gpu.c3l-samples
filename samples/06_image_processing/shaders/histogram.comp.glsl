#version 460
#include "generated/shader_abi.glsl"
#include "generated/image_processing_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = GEN_TILE, local_size_y = GEN_TILE) in;

layout(buffer_reference, std430) buffer Bins { uint counts[]; };
layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    HistogramRoot root = HistogramRoot(pc.root_gpu);
    uvec2 p = gl_GlobalInvocationID.xy;
    if (p.x >= root.size || p.y >= root.size) return;

    vec3 c = load_storage_texture(root.src, ivec2(p)).rgb;
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
    uint bin = min(uint(luma * float(HISTOGRAM_BINS)), HISTOGRAM_BINS - 1u);
    atomicAdd(Bins(root.bins_gpu).counts[bin], 1u);
}
