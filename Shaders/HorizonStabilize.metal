//
// HorizonStabilize.metal — 地平线防抖着色器
//
// 原理: 将输出画面的每个像素通过逆旋转矩阵，投影回输入画面，
// 利用 IMU 提供的 roll/pitch 角度对画面进行反向旋转，
// 使地平线始终保持水平。
//
// 类似于大疆 HorizonSteady 的处理方式。
//

#include <metal_stdlib>
#include "Common.metal"
using namespace metal;

// MARK: - 防抖参数结构体

struct StabilizeParams {
    /// 反向旋转 roll 角（弧度），即需要抵消的倾斜量
    float roll;
    /// 反向旋转 pitch 角（弧度），平滑后的俯仰补偿
    float pitch;
    /// 反向旋转 yaw 角（弧度），平滑后的偏航补偿
    float yaw;
    /// 裁剪边距比例 [0, 0.3]，旋转后边缘填充区域的比例
    float cropMargin;
    /// 虚拟焦距（像素），控制透视投影的视场角
    /// 越大 = 裁剪越多 = 旋转余量越少
    float focalLength;
};

// MARK: - 顶点结构体

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// MARK: - 顶点着色器

/// 顶点着色器: 计算防抖后的纹理坐标
///
/// 核心逻辑:
/// 1. 将输出纹理的四个角视为在 3D 空间中的一个平面
/// 2. 对该平面施加逆旋转（抵消设备的倾斜）
/// 3. 将旋转后的 3D 点投影回 2D，得到在源纹理中的采样坐标
///
vertex VertexOut horizonStabilizeVertex(
    uint vertexID [[vertex_id]],
    constant StabilizeParams& params [[buffer(0)]]
) {
    // --- 四个角的归一化坐标 (NDC: -1 到 1) ---
    // Metal 的 clip space: x∈[-1,1], y∈[-1,1]
    const float2 corners[6] = {
        float2(-1.0, -1.0), // 左下
        float2( 1.0, -1.0), // 右下
        float2(-1.0,  1.0), // 左上
        float2( 1.0, -1.0), // 右下 (第二个三角形)
        float2( 1.0,  1.0), // 右上
        float2(-1.0,  1.0), // 左上 (第二个三角形)
    };

    float2 ndc = corners[vertexID];

    VertexOut out;
    // 输出位置不变 — 始终是满屏四边形
    out.position = float4(ndc, 0.0, 1.0);

    // --- 核心: 计算受旋转影响的纹理坐标 ---
    // 将 NDC 映射到 3D 空间（Z = focalLength 即"屏幕深度"）
    float3 point3D = float3(ndc * params.focalLength, params.focalLength);

    // 构建逆旋转矩阵（抵消设备旋转）
    // 注意: 对角度的符号取反，因为我们做的是逆旋转
    float3x3 rotMatrix = rotationMatrix(-params.roll, -params.pitch, -params.yaw);

    // 对 3D 点施加旋转
    float3 rotatedPoint = rotMatrix * point3D;

    // 透视投影回 2D
    float2 projectedUV = project3Dto2D(rotatedPoint);

    // 映射到 [0, 1] 纹理坐标
    // projectedUV 在未旋转时范围约为 [-1, 1]（取决于 focalLength）
    float2 texCoord = projectedUV / (2.0 * params.focalLength) + 0.5;

    // 考虑裁剪边距: 放大纹理坐标以裁掉边缘空白
    float scale = 1.0 / (1.0 - params.cropMargin);
    texCoord = (texCoord - 0.5) * scale + 0.5;

    out.texCoord = texCoord;

    return out;
}

// MARK: - 片段着色器

/// 片段着色器: 采样矫正/防抖后的纹理
fragment float4 horizonStabilizeFragment(
    VertexOut in [[stage_in]],
    texture2d<float, access::sample> sourceTexture [[texture(0)]]
) {
    // 处理超出 [0,1] 范围的坐标 — 显示为黑色
    if (in.texCoord.x < 0.0 || in.texCoord.x > 1.0 ||
        in.texCoord.y < 0.0 || in.texCoord.y > 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return sourceTexture.sample(s, in.texCoord);
}

// MARK: - 简化版: Compute Kernel（用于离线处理）

/// Compute kernel 版本的防抖处理
/// 每个线程处理一个输出像素，适合与鱼眼矫正串联的离线管线
kernel void horizonStabilizeCompute(
    texture2d<float, access::sample>  inTexture   [[texture(0)]],
    texture2d<float, access::write>   outTexture  [[texture(1)]],
    constant StabilizeParams& params               [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = outTexture.get_width();
    uint height = outTexture.get_height();

    if (gid.x >= width || gid.y >= height) {
        return;
    }

    // --- 输出像素 -> 归一化坐标 [0, 1] ---
    float2 outputUV = float2(
        (float(gid.x) + 0.5) / float(width),
        (float(gid.y) + 0.5) / float(height)
    );

    // --- 归一化坐标 -> NDC [-1, 1] ---
    float2 ndc = (outputUV - 0.5) * 2.0;

    // --- NDC -> 3D 空间 ---
    float3 point3D = float3(ndc * params.focalLength, params.focalLength);

    // --- 逆旋转 ---
    float3x3 rotMatrix = rotationMatrix(-params.roll, -params.pitch, -params.yaw);
    float3 rotatedPoint = rotMatrix * point3D;

    // --- 3D -> 2D 投影 ---
    float2 projectedUV = project3Dto2D(rotatedPoint);
    float2 texCoord = projectedUV / (2.0 * params.focalLength) + 0.5;

    // --- 裁剪缩放 ---
    float scale = 1.0 / (1.0 - params.cropMargin);
    texCoord = (texCoord - 0.5) * scale + 0.5;

    // --- 采样 + 写入 ---
    float4 color = sampleBilinearClampBlack(inTexture, texCoord);
    outTexture.write(color, gid);
}
