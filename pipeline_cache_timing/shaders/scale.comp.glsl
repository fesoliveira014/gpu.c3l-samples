#version 460
#include "generated/shader_abi.glsl"
#include "generated/pipeline_cache_timing_abi.glsl"

layout(local_size_x = 64) in;

layout(buffer_reference, std430) readonly buffer Input { float data[]; };
layout(buffer_reference, std430) writeonly buffer Output { float data[]; };

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    ScaleRoot root = ScaleRoot(pc.root_gpu);
    uint i = gl_GlobalInvocationID.x;
    if (i >= root.count) return;
    Output(root.output_gpu).data[i] = Input(root.input_gpu).data[i] * 3.0;
}
