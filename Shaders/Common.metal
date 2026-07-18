//
// Common.metal — 公共着色器工具函数
// 所有函数标记为 static，避免被多个 .metal #include 时产生重复符号
//

#include <metal_stdlib>
using namespace metal;

// MARK: - 畸变参数结构体

struct DistortionParams {
    float k1;
    float k2;
    float k3;
    float centerX;
    float centerY;
    float scale;
};

static DistortionParams loadDistortionParams(constant float* params) {
    DistortionParams p;
    p.k1 = params[0];
    p.k2 = params[1];
    p.k3 = params[2];
    p.centerX = params[3];
    p.centerY = params[4];
    p.scale = params[5];
    return p;
}

// MARK: - 畸变换算函数

/// r_d = r * (1 + k1*r² + k2*r⁴ + k3*r⁶)
static float distortRadius(float r, DistortionParams params) {
    float r2 = r * r;
    float r4 = r2 * r2;
    float r6 = r4 * r2;
    return r * (1.0 + params.k1 * r2 + params.k2 * r4 + params.k3 * r6);
}

/// Newton-Raphson 迭代反算畸变半径
static float undistortRadius(float rd, DistortionParams params, uint maxIterations = 5) {
    float r = rd;
    for (uint i = 0; i < maxIterations; i++) {
        float r2 = r * r;
        float r4 = r2 * r2;
        float r6 = r4 * r2;
        float f = r * (1.0 + params.k1 * r2 + params.k2 * r4 + params.k3 * r6) - rd;
        float df = 1.0 + 3.0 * params.k1 * r2 + 5.0 * params.k2 * r4 + 7.0 * params.k3 * r6;
        r = r - f / df;
        r = max(r, 0.0);
    }
    return r;
}

// MARK: - 坐标映射

/// 输出坐标 → 畸变源坐标（鱼眼矫正核心反算）
static float2 undistortCoordinate(float2 normalizedOutputCoord, DistortionParams params) {
    float2 offset = normalizedOutputCoord - float2(params.centerX, params.centerY);
    offset *= params.scale;
    float r = length(offset);
    float rd = distortRadius(r, params);
    float2 distortedOffset = (r > 0.0001) ? offset * (rd / r) : offset;
    return distortedOffset + float2(params.centerX, params.centerY);
}

// MARK: - 纹理采样

static float4 sampleBilinear(texture2d<float, access::sample> tex, float2 uv) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return tex.sample(s, uv);
}

static float4 sampleBilinearClampBlack(texture2d<float, access::sample> tex, float2 uv) {
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return tex.sample(s, uv);
}

// MARK: - 防抖: 3D 旋转

static float3x3 rotationMatrix(float roll, float pitch, float yaw) {
    float cr = cos(roll);
    float sr = sin(roll);
    float3x3 Rz = float3x3(
        float3( cr, -sr, 0.0),
        float3( sr,  cr, 0.0),
        float3(0.0, 0.0, 1.0)
    );
    float cp = cos(pitch);
    float sp = sin(pitch);
    float3x3 Rx = float3x3(
        float3(1.0, 0.0, 0.0),
        float3(0.0,  cp, -sp),
        float3(0.0,  sp,  cp)
    );
    float cy = cos(yaw);
    float sy = sin(yaw);
    float3x3 Ry = float3x3(
        float3( cy, 0.0,  sy),
        float3(0.0, 1.0, 0.0),
        float3(-sy, 0.0,  cy)
    );
    return Rz * Rx * Ry;
}

static float2 project3Dto2D(float3 v) {
    if (abs(v.z) < 0.0001) {
        return v.xy * 10.0;
    }
    return v.xy / v.z;
}
