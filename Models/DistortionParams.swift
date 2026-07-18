import Foundation

/// 鱼眼镜头畸变参数模型
/// 使用 Brown-Conrady 径向畸变模型: r_d = r * (1 + k1*r² + k2*r⁴ + k3*r⁶)
struct DistortionParams: Codable, Equatable {
    /// 径向畸变系数 k1（一阶），控制桶形/枕形畸变的主要分量
    /// 正值 = 枕形畸变，负值 = 桶形畸变（鱼眼）
    var k1: Float = 0.0

    /// 径向畸变系数 k2（二阶）
    var k2: Float = 0.0

    /// 径向畸变系数 k3（三阶），用于极端鱼眼
    var k3: Float = 0.0

    /// 畸变中心 X 坐标（归一化，0.5 = 图像中心）
    var centerX: Float = 0.5

    /// 畸变中心 Y 坐标（归一化，0.5 = 图像中心）
    var centerY: Float = 0.5

    /// 缩放因子，矫正后画面可能需要缩放以填充边缘
    var scale: Float = 1.0

    // MARK: - 便捷初始化

    /// 零畸变参数（直通，无矫正）
    static let zero = DistortionParams()

    /// 通用运动相机鱼眼预设（轻微桶形畸变）
    static let mildFisheye = DistortionParams(
        k1: -0.15,
        k2: 0.02,
        k3: 0.0,
        centerX: 0.5,
        centerY: 0.5,
        scale: 1.05
    )

    /// 典型鱼眼镜头预设（中等畸变）
    static let standardFisheye = DistortionParams(
        k1: -0.30,
        k2: 0.08,
        k3: -0.01,
        centerX: 0.5,
        centerY: 0.5,
        scale: 1.15
    )

    /// 超广角鱼眼预设（严重畸变，如 220° 鱼眼）
    static let extremeFisheye = DistortionParams(
        k1: -0.50,
        k2: 0.20,
        k3: -0.05,
        centerX: 0.5,
        centerY: 0.5,
        scale: 1.30
    )

    // MARK: - 计算辅助

    /// 判定当前参数是否有效（非零畸变）
    var hasDistortion: Bool {
        k1 != 0.0 || k2 != 0.0 || k3 != 0.0
    }

    /// 获取适合传给 Metal shader 的参数数组
    /// 返回: [k1, k2, k3, centerX, centerY, scale]
    var metalArray: [Float] {
        [k1, k2, k3, centerX, centerY, scale]
    }
}
