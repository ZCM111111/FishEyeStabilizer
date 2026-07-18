import Foundation

/// 视频处理配置，控制矫正和防抖的各项参数
struct ProcessingConfig: Codable, Equatable {
    /// 当前选用的镜头预设（为 nil 表示不矫正）
    var lensProfile: LensProfile?

    /// 防抖模式
    var stabilizationMode: StabilizationMode = .horizonLevel

    /// 防抖强度（0.0 = 不防抖, 1.0 = 满强度）
    var stabilizationStrength: Float = 0.8

    /// 低通滤波截止频率（Hz），数值越低越平滑但响应越慢
    /// 默认 2Hz 意味着超过 2Hz 的抖动被滤除
    var lowPassCutoffHz: Float = 2.0

    /// 输出分辨率
    var outputResolution: OutputResolution = .matchInput

    /// 输出帧率
    var outputFrameRate: Int = 60

    /// 输出视频码率 (Mbps)
    var outputBitrateMbps: Float = 50.0

    // MARK: - 嵌套类型

    /// 防抖模式枚举
    enum StabilizationMode: String, Codable, CaseIterable {
        /// 关闭防抖
        case off = "关闭"

        /// 标准电子防抖（平滑抖动，但地平线可能倾斜）
        case standard = "标准防抖"

        /// 地平线防抖（始终保持水平，类似大疆 HorizonSteady）
        case horizonLevel = "地平线防抖"

        /// 地平线防抖 + 俯仰锁定（锁死 roll 和 pitch）
        case fullLock = "完全锁定"
    }

    /// 输出分辨率选项
    enum OutputResolution: String, Codable, CaseIterable {
        case matchInput = "原始分辨率"
        case uhd4K = "4K (3840×2160)"
        case hd1080p = "1080p (1920×1080)"
        case hd720p = "720p (1280×720)"

        var pixelSize: (width: Int, height: Int)? {
            switch self {
            case .matchInput: return nil
            case .uhd4K:      return (3840, 2160)
            case .hd1080p:    return (1920, 1080)
            case .hd720p:     return (1280, 720)
            }
        }
    }

    // MARK: - 默认配置

    static let `default` = ProcessingConfig()
}
