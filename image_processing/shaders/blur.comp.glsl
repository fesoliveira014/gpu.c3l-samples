#version 460
#include "generated/shader_abi.glsl"
#include "generated/image_processing_abi.glsl"
#include "descriptor_heap.glsl"

// Separable gaussian over a shared-memory strip: each 64-wide workgroup loads
// its span plus a BLUR_RADIUS halo on both ends, then convolves from shared.
// `horizontal` in the root swaps row/column indexing — one shader, two passes.
layout(local_size_x = BLUR_TILE) in;
layout(push_constant) uniform Push { RootPush pc; };

const float WEIGHTS[BLUR_RADIUS + 1] = float[](
    0.1006, 0.0977, 0.0894, 0.0771, 0.0626, 0.0479, 0.0345, 0.0234, 0.0150);

shared vec3 strip[BLUR_TILE + 2 * BLUR_RADIUS];

ivec2 coord(BlurRoot root, int along, int across) {
    return root.horizontal != 0 ? ivec2(along, across) : ivec2(across, along);
}

void main() {
    BlurRoot root = BlurRoot(pc.root_gpu);
    int size = int(root.size);
    int across = int(gl_WorkGroupID.y);
    int base = int(gl_WorkGroupID.x) * int(BLUR_TILE);
    int local = int(gl_LocalInvocationID.x);

    // Cooperative load: strip span + halos, clamped at the image edges.
    for (int i = local; i < int(BLUR_TILE) + 2 * int(BLUR_RADIUS); i += int(BLUR_TILE)) {
        int along = clamp(base + i - int(BLUR_RADIUS), 0, size - 1);
        strip[i] = load_storage_texture(root.src, coord(root, along, across)).rgb;
    }
    barrier();

    int along = base + local;
    if (along >= size) return;
    vec3 sum = strip[local + int(BLUR_RADIUS)] * WEIGHTS[0];
    for (int r = 1; r <= int(BLUR_RADIUS); r++) {
        sum += strip[local + int(BLUR_RADIUS) - r] * WEIGHTS[r];
        sum += strip[local + int(BLUR_RADIUS) + r] * WEIGHTS[r];
    }
    store_storage_texture(root.dst, coord(root, along, across), vec4(sum, 1.0));
}
