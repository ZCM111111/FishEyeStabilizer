//
// FisheyeCorrection.metal — 鱼眼畸变矫正 Compute Shader
//
// 对每个输出像素，计算它在畸变源图像中的对应坐标，
// 然后从源纹理采样。这实现了"逆映射"矫正。
//

#include <metal_stdlib>
#include "Common.metal"
using namespace metal;

// MARK: - YUV→RGB 转换 + 矫正（用于相机实时预览）

/// 将 YUV 420v (NV12) 双平面纹理矫正为 RGBA 纹理
///
/// 输入:
///   - textureY: Y（亮度）平面
///   - textureUV: UV（色度）平面 (交错存储)
///   - params: 畸变参数
///
/// 输出:
///   - outTexture: 矫正后的 RGBA 纹理
///
/// 线程布局: 每个线程处理一个输出像素 (2D grid)
kernel void fisheyeCorrectYUVtoRGBA(
    // 输入: Y 平面纹理 (R8)
    texture2d<float, access::sample> textureY    [[texture(0)]],
    // 输入: UV 平面纹理 (RG8 — 交错)
    texture2d<float, access::sample> textureUV   [[texture(1)]],
    // 输出: RGBA 纹理 (RGBA8Unorm)
    texture2d<float, access::write>  outTexture  [[texture(2)]],
    // 畸变参数
    constant float* distortionParams             [[buffer(0)]],
    // 线程在 2D grid 中的位置
    uint2 gid [[thread_position_in_grid]]
) {
    // 获取输出纹理尺寸
    uint outputWidth = outTexture.get_width();
    uint outputHeight = outTexture.get_height();

    // 边界检查
    if (gid.x >= outputWidth || gid.y >= outputHeight) {
        return;
    }

    // --- 加载畸变参数 ---
    DistortionParams params = loadDistortionParams(distortionParams);

    // --- 计算归一化输出坐标 [0, 1] ---
    float2 outputUV = float2(
        (float(gid.x) + 0.5) / float(outputWidth),
        (float(gid.y) + 0.5) / float(outputHeight)
    );

    // --- 逆向畸变: 输出坐标 -> 畸变源坐标 ---
    float2 distortedUV = undistortCoordinate(outputUV, params);

    // --- 从 Y+UV 纹理采样 ---
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float Y = textureY.sample(s, distortedUV).r;

    // UV 纹理的宽度是 Y 纹理的一半 (4:2:0 子采样)
    float2 uv = textureUV.sample(s, distortedUV).rg;

    // --- YUV -> RGB 转换 (BT.601 标准) ---
    // Y 范围: [0, 1]   , Cb/Cr 偏移到 [-0.5, 0.5]
    float Cb = uv.r - 0.5;
    float Cr = uv.g - 0.5;

    float r = Y + 1.402   * Cr;
    float g = Y - 0.34414 * Cb - 0.71414 * Cr;
    float b = Y + 1.772   * Cb;

    // Clamp 到 [0, 1]
    float4 rgba = float4(clamp(r, 0.0, 1.0),
                         clamp(g, 0.0, 1.0),
                         clamp(b, 0.0, 1.0),
                         1.0);

    // --- 写入输出 ---
    outTexture.write(rgba, gid);
}

// MARK: - RGBA→RGBA 矫正（用于离线视频处理）

/// 将已经解码的 RGBA 纹理进行鱼眼矫正
/// 用于后期处理模式（离线条纹式处理）
kernel void fisheyeCorrectRGBAtoRGBA(
    texture2d<float, access::sample>  inTexture   [[texture(0)]],
    texture2d<float, access::write>   outTexture  [[texture(1)]],
    constant float* distortionParams               [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = outTexture.get_width();
    uint height = outTexture.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    DistortionParams params = loadDistortionParams(distortionParams);

    float2 outputUV = float2(
        (float(gid.x) + 0.5) / float(width),
        (float(gid.y) + 0.5) / float(height)
    );

    float2 distortedUV = undistortCoordinate(outputUV, params);

    // 双线性采样（超出边界为黑色）
    float4 color = sampleBilinearClampBlack(inTexture, distortedUV);

    outTexture.write(color, gid);
}
