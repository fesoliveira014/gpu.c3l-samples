#version 460
#include "generated/shader_abi.glsl"
#include "generated/texture_streaming_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = SLOT_COUNT) in;

layout(buffer_reference, std430) writeonly buffer OutBuf { vec4 texels[]; };
layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    StreamRoot root = StreamRoot(pc.root_gpu);
    uint i = gl_GlobalInvocationID.x;
    if (i >= root.count) return;
    OutBuf(root.output_gpu).texels[i] =
        sample_texture_2d(root.base + i, root.sampler_index, vec2(0.5));
}
