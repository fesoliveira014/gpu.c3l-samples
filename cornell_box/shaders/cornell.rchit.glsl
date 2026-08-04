#version 460
#extension GL_GOOGLE_include_directive : require
#include "ray_tracing.glsl"
#include "include/cornell_common.glsl"

layout(push_constant) uniform Push {
    uint64_t root_gpu;
} pc;

layout(location = 0) rayPayloadInEXT RadiancePayload payload;
layout(location = 1) rayPayloadEXT uint shadow_visible;
hitAttributeEXT vec2 barycentrics;

void main() {
    CornellRoot root = CornellRoot(pc.root_gpu);
    uint primitive = uint(gl_PrimitiveID);
    uint material = CornellMaterials(root.material_gpu).values[primitive];
    if (material == 3u) {
        payload.color = vec3(15.0, 12.0, 8.0);
        return;
    }

    CornellVertices vertices = CornellVertices(root.vertex_gpu);
    vec3 a = vertices.values[primitive * 3u].xyz;
    vec3 b = vertices.values[primitive * 3u + 1u].xyz;
    vec3 c = vertices.values[primitive * 3u + 2u].xyz;
    vec3 normal = normalize(cross(b - a, c - a));
    if (dot(normal, gl_WorldRayDirectionEXT) > 0.0) normal = -normal;
    vec3 hit = gl_WorldRayOriginEXT
        + gl_HitTEXT * gl_WorldRayDirectionEXT;

    uint random_state = root.seed
        ^ (gl_LaunchIDEXT.x * 1973u + gl_LaunchIDEXT.y * 9277u
            + root.sample_index * 26699u + primitive * 31847u);
    vec2 light_uv = vec2(
        cornell_random(random_state),
        cornell_random(random_state));
    vec3 light = vec3(
        mix(213.0, 343.0, light_uv.x),
        548.3,
        mix(227.0, 332.0, light_uv.y));
    vec3 to_light = light - hit;
    float distance_squared = dot(to_light, to_light);
    float distance_to_light = sqrt(distance_squared);
    vec3 light_direction = to_light / distance_to_light;

    shadow_visible = 0u;
    traceRayEXT(
        GPU_ACCELERATION_STRUCTURE(root.tlas),
        gl_RayFlagsTerminateOnFirstHitEXT
            | gl_RayFlagsOpaqueEXT
            | gl_RayFlagsSkipClosestHitShaderEXT,
        0xff,
        0,
        0,
        1,
        hit + normal * 0.5,
        0.0,
        light_direction,
        distance_to_light - 1.0,
        1);

    float surface_cosine = max(dot(normal, light_direction), 0.0);
    float light_cosine = max(light_direction.y, 0.0);
    float light_area = 130.0 * 105.0;
    float irradiance = 15.0 * light_area * surface_cosine * light_cosine
        / max(distance_squared, 1.0);
    vec3 ambient = cornell_albedo(material) * 0.015;
    vec3 direct = cornell_albedo(material)
        * irradiance * float(shadow_visible) / 3.14159265;
    payload.color = ambient + direct;
}
