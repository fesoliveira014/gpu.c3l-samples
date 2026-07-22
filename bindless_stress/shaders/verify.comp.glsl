#version 460
#include "generated/shader_abi.glsl"
#include "generated/bindless_stress_abi.glsl"
#include "descriptor_heap.glsl"

layout(local_size_x = 64) in;

layout(buffer_reference, std430) readonly buffer Indices { uint data[]; };
layout(buffer_reference, std430) writeonly buffer Results { vec4 data[]; };

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    StressRoot root = StressRoot(pc.root_gpu);
    uint i = gl_GlobalInvocationID.x;
    if (i >= root.count) return;
    uint tex = Indices(root.indices_gpu).data[i];
    Results(root.output_gpu).data[i] = sample_texture_2d(tex, root.heap_sampler, vec2(0.5));
}
