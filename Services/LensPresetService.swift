import Foundation

// MARK: - 镜头预设服务

/// 管理内置镜头预设库 和 用户自定义预设
///
/// 内置预设涵盖主流运动相机（大疆、GoPro、Insta360 等）
/// 预设参数来自社区标定数据和官方畸变参数估算
///
/// 使用方式:
/// ```swift
/// let service = LensPresetService()
/// let presets = service.builtInPresets
/// let match = service.findBestMatch(for: someDetectedParams)
/// ```
@MainActor
final class LensPresetService: ObservableObject {

    // MARK: - 公开属性

    /// 所有可用预设（内置 + 用户自定义）
    @Published var allPresets: [LensProfile] = []

    /// 用户自定义预设
    @Published var userPresets: [LensProfile] = []

    /// 内置预设（从 LensPresets.json 加载）
    private(set) var builtInPresets: [LensProfile] = []

    // MARK: - 初始化

    init() {
        loadBuiltInPresets()
    }

    // MARK: - 加载内置预设

    private func loadBuiltInPresets() {
        // 尝试从 JSON 文件加载
        if let url = Bundle.main.url(
            forResource: "LensPresets",
            withExtension: "json"
        ) {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                builtInPresets = try decoder.decode([LensProfile].self, from: data)
                print("✅ [LensPreset] 从 JSON 加载了 \(builtInPresets.count) 个预设")
            } catch {
                print("⚠️ [LensPreset] JSON 解析失败: \(error)，使用硬编码预设")
                builtInPresets = Self.hardcodedPresets
            }
        } else {
            print("⚠️ [LensPreset] 未找到 LensPresets.json，使用硬编码预设")
            builtInPresets = Self.hardcodedPresets
        }

        refreshAllPresets()
    }

    // MARK: - 预设管理

    /// 添加用户自定义预设
    func addUserPreset(_ profile: LensProfile) {
        var custom = profile
        custom.isUserCustom = true
        custom.createdAt = Date()
        userPresets.append(custom)
        refreshAllPresets()
        saveUserPresets()
    }

    /// 删除用户自定义预设
    func removeUserPreset(_ profile: LensProfile) {
        userPresets.removeAll { $0.id == profile.id }
        refreshAllPresets()
        saveUserPresets()
    }

    /// 查找与给定参数最接近的预设（用于自动检测后的匹配）
    /// - Parameter params: 检测到的畸变参数
    /// - Returns: 最匹配的预设，或 nil（无足够接近的）
    func findBestMatch(for params: DistortionParams) -> LensProfile? {
        var bestMatch: LensProfile?
        var bestScore: Float = .greatestFiniteMagnitude

        for preset in allPresets {
            let score = similarity(
                a: params,
                b: preset.distortionParams
            )
            if score < bestScore {
                bestScore = score
                bestMatch = preset
            }
        }

        // 阈值: 如果最接近的预设相似度仍然太远，不匹配
        let threshold: Float = 0.02
        return bestScore < threshold ? bestMatch : nil
    }

    /// 计算两组畸变参数的相似度
    /// 使用欧几里得距离（越小越相似）
    private func similarity(
        a: DistortionParams,
        b: DistortionParams
    ) -> Float {
        let dk1 = a.k1 - b.k1
        let dk2 = a.k2 - b.k2
        let dk3 = a.k3 - b.k3
        let dcx = a.centerX - b.centerX
        let dcy = a.centerY - b.centerY
        return sqrt(dk1*dk1 + dk2*dk2 + dk3*dk3 + dcx*dcx + dcy*dcy)
    }

    private func refreshAllPresets() {
        allPresets = builtInPresets + userPresets
    }

    private func saveUserPresets() {
        guard let data = try? JSONEncoder().encode(userPresets),
              let url = userPresetsURL else { return }
        try? data.write(to: url)
    }

    private var userPresetsURL: URL? {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first
        return documents?.appendingPathComponent("UserLensPresets.json")
    }
}

// MARK: - 硬编码预设（JSON 加载失败时的后备）

extension LensPresetService {

    /// 硬编码的常见运动相机预设
    /// 当 LensPresets.json 加载失败时使用
    static let hardcodedPresets: [LensProfile] = [
        // --- 大疆 (DJI) ---
        LensProfile(
            manufacturer: "DJI",
            model: "Action 5 Pro",
            lensType: .superWide,
            distortionParams: DistortionParams(
                k1: -0.22, k2: 0.05, k3: -0.005,
                centerX: 0.5, centerY: 0.5, scale: 1.10
            )
        ),
        LensProfile(
            manufacturer: "DJI",
            model: "Action 4",
            lensType: .superWide,
            distortionParams: DistortionParams(
                k1: -0.24, k2: 0.06, k3: -0.008,
                centerX: 0.5, centerY: 0.5, scale: 1.12
            )
        ),
        LensProfile(
            manufacturer: "DJI",
            model: "Action 3",
            lensType: .superWide,
            distortionParams: DistortionParams(
                k1: -0.25, k2: 0.07, k3: -0.01,
                centerX: 0.5, centerY: 0.5, scale: 1.12
            )
        ),
        LensProfile(
            manufacturer: "DJI",
            model: "Osmo Action",
            lensType: .wide,
            distortionParams: DistortionParams(
                k1: -0.18, k2: 0.03, k3: 0.0,
                centerX: 0.5, centerY: 0.5, scale: 1.06
            )
        ),
        LensProfile(
            manufacturer: "DJI",
            model: "Pocket 3",
            lensType: .wide,
            distortionParams: DistortionParams(
                k1: -0.12, k2: 0.01, k3: 0.0,
                centerX: 0.5, centerY: 0.5, scale: 1.04
            )
        ),

        // --- GoPro ---
        LensProfile(
            manufacturer: "GoPro",
            model: "HERO 13 Black",
            lensType: .superWide,
            distortionParams: DistortionParams(
                k1: -0.26, k2: 0.08, k3: -0.012,
                centerX: 0.5, centerY: 0.5, scale: 1.14
            )
        ),
        LensProfile(
            manufacturer: "GoPro",
            model: "HERO 12 Black",
            lensType: .superWide,
            distortionParams: DistortionParams(
                k1: -0.27, k2: 0.08, k3: -0.012,
                centerX: 0.5, centerY: 0.5, scale: 1.14
            )
        ),
        LensProfile(
            manufacturer: "GoPro",
            model: "HERO 11 Black",
            lensType: .superWide,
            distortionParams: DistortionParams(
                k1: -0.28, k2: 0.09, k3: -0.015,
                centerX: 0.5, centerY: 0.5, scale: 1.15
            )
        ),
        LensProfile(
            manufacturer: "GoPro",
            model: "HERO 10 Black",
            lensType: .superWide,
            distortionParams: DistortionParams(
                k1: -0.28, k2: 0.09, k3: -0.015,
                centerX: 0.5, centerY: 0.5, scale: 1.15
            )
        ),
        LensProfile(
            manufacturer: "GoPro",
            model: "HERO 9 Black",
            lensType: .superWide,
            distortionParams: DistortionParams(
                k1: -0.30, k2: 0.10, k3: -0.018,
                centerX: 0.5, centerY: 0.5, scale: 1.18
            )
        ),
        LensProfile(
            manufacturer: "GoPro",
            model: "HERO 8 Black",
            lensType: .superWide,
            distortionParams: DistortionParams(
                k1: -0.31, k2: 0.11, k3: -0.02,
                centerX: 0.5, centerY: 0.5, scale: 1.18
            )
        ),
        LensProfile(
            manufacturer: "GoPro",
            model: "MAX (单镜头模式)",
            lensType: .fisheye,
            distortionParams: DistortionParams(
                k1: -0.42, k2: 0.16, k3: -0.04,
                centerX: 0.5, centerY: 0.5, scale: 1.25
            )
        ),

        // --- Insta360 ---
        LensProfile(
            manufacturer: "Insta360",
            model: "X4 (单镜头)",
            lensType: .extremeFisheye,
            distortionParams: DistortionParams(
                k1: -0.55, k2: 0.22, k3: -0.06,
                centerX: 0.5, centerY: 0.5, scale: 1.35
            )
        ),
        LensProfile(
            manufacturer: "Insta360",
            model: "X3 (单镜头)",
            lensType: .extremeFisheye,
            distortionParams: DistortionParams(
                k1: -0.56, k2: 0.23, k3: -0.065,
                centerX: 0.5, centerY: 0.5, scale: 1.35
            )
        ),
        LensProfile(
            manufacturer: "Insta360",
            model: "GO 3",
            lensType: .fisheye,
            distortionParams: DistortionParams(
                k1: -0.40, k2: 0.14, k3: -0.03,
                centerX: 0.5, centerY: 0.5, scale: 1.22
            )
        ),
        LensProfile(
            manufacturer: "Insta360",
            model: "ONE RS (4K)",
            lensType: .superWide,
            distortionParams: DistortionParams(
                k1: -0.23, k2: 0.05, k3: -0.008,
                centerX: 0.5, centerY: 0.5, scale: 1.10
            )
        ),

        // --- SONY ---
        LensProfile(
            manufacturer: "SONY",
            model: "RX0 II",
            lensType: .wide,
            distortionParams: DistortionParams(
                k1: -0.14, k2: 0.02, k3: 0.0,
                centerX: 0.5, centerY: 0.5, scale: 1.05
            )
        ),
        LensProfile(
            manufacturer: "SONY",
            model: "FDR-X3000",
            lensType: .wide,
            distortionParams: DistortionParams(
                k1: -0.20, k2: 0.04, k3: -0.005,
                centerX: 0.5, centerY: 0.5, scale: 1.08
            )
        ),

        // --- 通用预设 ---
        LensProfile(
            manufacturer: "通用",
            model: "运动相机标广角",
            lensType: .wide,
            distortionParams: DistortionParams(
                k1: -0.15, k2: 0.02, k3: 0.0,
                centerX: 0.5, centerY: 0.5, scale: 1.05
            )
        ),
        LensProfile(
            manufacturer: "通用",
            model: "运动相机超广角",
            lensType: .superWide,
            distortionParams: DistortionParams(
                k1: -0.30, k2: 0.08, k3: -0.01,
                centerX: 0.5, centerY: 0.5, scale: 1.15
            )
        ),
        LensProfile(
            manufacturer: "通用",
            model: "手机超广角",
            lensType: .wide,
            distortionParams: DistortionParams(
                k1: -0.10, k2: 0.01, k3: 0.0,
                centerX: 0.5, centerY: 0.5, scale: 1.03
            )
        ),
        LensProfile(
            manufacturer: "通用",
            model: "220° 鱼眼",
            lensType: .extremeFisheye,
            distortionParams: DistortionParams(
                k1: -0.50, k2: 0.20, k3: -0.05,
                centerX: 0.5, centerY: 0.5, scale: 1.30
            )
        ),
    ]
}
