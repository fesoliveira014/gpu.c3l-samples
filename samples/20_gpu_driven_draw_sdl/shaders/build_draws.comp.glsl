#version 460
#include "generated/shader_abi.glsl"
#include "generated/gpu_driven_abi.glsl"

layout(local_size_x = BUILD_WORKGROUP) in;

layout(buffer_reference, std430) readonly buffer Instances { Instance items[]; };
layout(buffer_reference, std430) writeonly buffer Args { DrawIndexedIndirectCommand cmds[]; };
layout(buffer_reference, std430) writeonly buffer GeneratedRecords { GeneratedDrawIndexedRecord records[]; };
layout(buffer_reference, std430) writeonly buffer DrawRoots { DrawRoot roots[]; };
layout(buffer_reference, std430) writeonly buffer FragmentRoots { FragmentRoot roots[]; };
layout(buffer_reference, std430) writeonly buffer CountBuf { uint value; };
layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

void main() {
    BuildRoot root = BuildRoot(pc.root_gpu);
    uint i = gl_GlobalInvocationID.x;
    if (i >= root.instance_count) return;

    Instance inst = Instances(root.instances_gpu).items[i];
    vec2 spotlight = vec2(cos(root.time) * 0.5, sin(root.time * 0.7) * 0.5);
    bool visible = distance(inst.pos, spotlight) < 0.55;

    if (root.use_generated == 0u) {
        Args(root.args_gpu).cmds[i] = DrawIndexedIndirectCommand(
            6u,
            visible ? 1u : 0u,
            0u,
            0,
            i);
        return;
    }
    if (!visible) return;

    uint slot = atomicAdd(CountBuf(root.count_gpu).value, 1u);
    DrawRoots(root.generated_draw_roots_gpu).roots[slot] = DrawRoot(
        root.corners_gpu,
        root.instances_gpu + uint64_t(i) * uint64_t(INSTANCE_STRIDE));
    FragmentRoots(root.generated_fragment_roots_gpu).roots[slot] = FragmentRoot(
        vec4(0.75 + 0.25 * inst.color.rgb, 1.0));

    uint64_t draw_root_gpu = root.generated_draw_roots_gpu
        + uint64_t(slot) * uint64_t(DRAW_ROOT_STRIDE);
    uint64_t fragment_root_gpu = root.generated_fragment_roots_gpu
        + uint64_t(slot) * uint64_t(FRAGMENT_ROOT_STRIDE);
    GeneratedRecords(root.generated_records_gpu).records[slot] = GeneratedDrawIndexedRecord(
        draw_root_gpu,
        fragment_root_gpu,
        DrawIndexedIndirectCommand(6u, 1u, 0u, 0, 0u),
        0u);
}
