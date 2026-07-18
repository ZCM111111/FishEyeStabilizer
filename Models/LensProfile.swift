import Foundation

/// 镜头预设模型，描述一款特定相机的鱼眼畸变特征
struct LensProfile: Codable, Identifiable, Equatable {
    /// 唯一标识
    var id: String { manufacturer + "_" + model }

    /// 制造商（如 DJI、GoPro、Insta360）
    let manufacturer: String

    /// 型号（如 Action 5 Pro、HERO 13 Black）
    let model: String

    /// 镜头类型描述
    let lensType: LensType

    /// 畸变参数
    var distortionParams: DistortionParams

    /// 是否为用户自定义预设
    var isUserCustom: Bool = false

    /// 创建时间
    var createdAt: Date = Date()

    /// 镜头类型枚举
    enum LensType: String, Codable, CaseIterable {
        case standard = "标准镜头"
        case wide = "广角镜头"
        case superWide = "超广角"
        case fisheye = "鱼眼镜头"
        case extremeFisheye = "超鱼眼(220°)"

        /// 对应的大致 FOV 范围
        var approximateFOV: String {
            switch self {
            case .standard:     return "70-90°"
            case .wide:         return "90-120°"
            case .superWide:    return "120-160°"
            case .fisheye:      return "160-200°"
            case .extremeFisheye: return "200°+"
            }
        }
    }

    /// 显示用名称
    var displayName: String {
        "\(manufacturer) \(model) - \(lensType.rawValue)"
    }
}
