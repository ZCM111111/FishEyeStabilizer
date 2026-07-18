//
// Common.metal — 公共着色器工具函数
// 提供各着色器共用的坐标转换、插值采样等基础函数
//

#include <metal_stdlib>
using namespace metal;

// MARK: - 畸变参数结构体

/// 鱼眼畸变参数，与 Swift 端 DistortionParams.metalArray 对应
/// 布局: [k1, k2, k3, centerX, centerY, scale]
struct DistortionParams {
    float k1;
    float k2;
    float k3;
    float centerX;
    float centerY;
    float scale;
};

/// 从 float 数组构造畸变参数（用于 constant buffer 传入）
DistortionParams loadDistortionParams(constant float* params) {
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

/// 正向畸变: 无畸变半径 -> 畸变后半径
/// 公式: r_d = r * (1 + k1*r² + k2*r⁴ + k3*r⁶)
float distortRadius(float r, DistortionParams params) {
    float r2 = r * r;
    float r4 = r2 * r2;
    float r6 = r4 * r2;
    return r * (1.0 + params.k1 * r2 + params.k2 * r4 + params.k3 * r6);
}

/// 逆向畸变（数值迭代法）: 畸变后半径 -> 无畸变半径
/// 使用 Newton-Raphson 迭代近似逆函数，通常 5 次迭代足够精确
float undistortRadius(float rd, DistortionParams params, uint maxIterations = 5) {
    // 初始猜测：假设畸变不大，用 rd 本身作为起点
    float r = rd;

    for (uint i = 0; i < maxIterations; i++) {
        float r2 = r * r;
        float r4 = r2 * r2;
        float r6 = r4 * r2;

        // f(r) = r * (1 + k1*r² + k2*r⁴ + k3*r⁶) - rd
        float f = r * (1.0 + params.k1 * r2 + params.k2 * r4 + params.k3 * r6) - rd;

        // f'(r) = 1 + 3*k1*r² + 5*k2*r⁴ + 7*k3*r⁶
        float df = 1.0 + 3.0 * params.k1 * r2 + 5.0 * params.k2 * r4 + 7.0 * params.k3 * r6;

        // Newton 迭代: r_{n+1} = r_n - f(r_n) / f'(r_n)
        r = r - f / df;

        // 防止负值
        r = max(r, 0.0);
    }

    return r;
}

// MARK: - 坐标映射

/// 将输出图像的归一化坐标 [0,1] 映射回畸变源图像的归一化坐标 [0,1]
/// 这是鱼眼矫正的核心：从"直线"的输出像素位置，反算"弯曲"的输入像素位置
float2 undistortCoordinate(float2 normalizedOutputCoord, DistortionParams params) {
    // 1. 计算相对于畸变中心的偏移
    float2 offset = normalizedOutputCoord - float2(params.centerX, params.centerY);

    // 2. 缩放调整
    offset *= params.scale;

    // 3. 当前到中心的距离（无畸变距离）
    float r = length(offset);

    // 4. 反算畸变后的距离
    float rd = distortRadius(r, params);

    // 5. 沿原方向伸展到畸变距离
    float2 distortedOffset = (r > 0.0001) ? offset * (rd / r) : offset;

    // 6. 回到畸变图像坐标
    float2 distortedCoord = distortedOffset + float2(params.centerX, params.centerY);

    return distortedCoord;
}

// MARK: - 纹理采样（带边界处理）

/// 双线性插值采样，自动 clamp 到边界
float4 sampleBilinear(texture2d<float, access::sample> tex, float2 uv) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return tex.sample(s, uv);
}

/// 双线性插值采样，超出边界返回黑色
float4 sampleBilinearClampBlack(texture2d<float, access::sample> tex, float2 uv) {
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return tex.sample(s, uv);
}

// MARK: - 防抖相关: 3D 旋转

/// 构建 3D 旋转矩阵（用于地平线防抖）
/// roll, pitch, yaw 单位为弧度
float3x3 rotationMatrix(float roll, float pitch, float yaw) {
    // Roll — 绕 Z 轴（画面平面内旋转，这是地平线矫正的核心）
    float cr = cos(roll);
    float sr = sin(roll);
    float3x3 Rz = float3x3(
        float3( cr, -sr, 0.0),
        float3( sr,  cr, 0.0),
        float3(0.0, 0.0, 1.0)
    );

    // Pitch — 绕 X 轴
    float cp = cos(pitch);
    float sp = sin(pitch);
    float3x3 Rx = float3x3(
        float3(1.0, 0.0, 0.0),
        float3(0.0,  cp, -sp),
        float3(0.0,  sp,  cp)
    );

    // Yaw — 绕 Y 轴
    float cy = cos(yaw);
    float sy = sin(yaw);
    float3x3 Ry = float3x3(
        float3( cy, 0.0,  sy),
        float3(0.0, 1.0, 0.0),
        float3(-sy, 0.0,  cy)
    );

    // 组合旋转: R = Rz * Rx * Ry
    return Rz * Rx * Ry;
}

/// 将单位球面上的 3D 点投影到 2D 归一化坐标（等距投影）
float2 project3Dto2D(float3 v) {
    if (abs(v.z) < 0.0001) {
        // 避免除以零
        return v.xy * 10.0; // 推到远处
    }
    return v.xy / v.z;
}
