#include <metal_stdlib>
using namespace metal;
struct Vertex { float4 position [[position]]; float2 uv; };
struct ViewUniforms {
    float4 camera; // yaw, pitch, tan(vertical field / 2), aspect
    float4 mode; // right eye, fisheye
    float4 transformX;
    float4 transformY;
};
vertex Vertex fullscreenVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * 2 - 1, 0, 1), float2(p.x, 1 - p.y)};
}
fragment half4 project180(Vertex in [[stage_in]], texture2d<half> image [[texture(0)]], constant ViewUniforms &v [[buffer(0)]]) {
    float2 screen = float2(in.uv.x * 2 - 1, 1 - in.uv.y * 2);
    float3 ray = normalize(float3(screen.x * v.camera.w * v.camera.z, screen.y * v.camera.z, -1));
    float cp = cos(v.camera.y), sp = sin(v.camera.y);
    ray = float3(ray.x, cp * ray.y - sp * ray.z, sp * ray.y + cp * ray.z);
    float cy = cos(v.camera.x), sy = sin(v.camera.x);
    ray = float3(cy * ray.x - sy * ray.z, ray.y, sy * ray.x + cy * ray.z);
    float2 uv;
    if (v.mode.y > 0.5) {
        float theta = acos(clamp(-ray.z, -1.0, 1.0));
        float radius = theta / M_PI_F;
        float lengthXY = length(ray.xy);
        uv = float2(0.5) + (lengthXY > 0.00001 ? float2(ray.x, -ray.y) / lengthXY * radius : float2(0));
        if (theta > M_PI_F / 2) return half4(0,0,0,1);
    } else {
        uv = float2(0.5 + atan2(ray.x, -ray.z) / M_PI_F, 0.5 - asin(clamp(ray.y, -1.0, 1.0)) / M_PI_F);
    }
    if (any(uv < 0) || any(uv > 1)) return half4(0,0,0,1);
    float2 halfTexel = 0.5 / float2(image.get_width(), image.get_height());
    uv.x = clamp((uv.x + v.mode.x) * 0.5, v.mode.x * 0.5 + halfTexel.x, (v.mode.x + 1) * 0.5 - halfTexel.x);
    uv.y = clamp(uv.y, halfTexel.y, 1 - halfTexel.y);
    uv = float2(dot(v.transformX.xyz, float3(uv,1)), dot(v.transformY.xyz, float3(uv,1)));
    // Clamp inside the chosen eye to prevent interpolation across the stereo seam.
    constexpr sampler sampleFilter(coord::normalized, address::clamp_to_edge, filter::linear);
    return half4(image.sample(sampleFilter, uv).rgb, 1);
}
