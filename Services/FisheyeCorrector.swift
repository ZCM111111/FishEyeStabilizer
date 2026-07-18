import Foundation
import Combine

// MARK: - 鱼眼矫正器

/// 鱼眼畸变矫正的高级封装
///
/// 核心职责:
/// - 管理畸变参数的曲线变化（渐变过渡，避免突变）
/// - 向 MetalRenderer 提供当前帧的畸变参数
/// - 支持手动微调和预设切换
///
/// 使用方式:
/// ```swift
/// let corrector = FisheyeCorrector(renderer: metalRenderer)
/// corrector.applyPreset(.standardFisheye)
/// corrector.fineTune(k1: -0.02) // 微调
/// ```
@MainActor
final class FisheyeCorrector: ObservableObject {

    // MARK: - 公开属性

    /// 当前畸变参数
    @Published private(set) var currentParams: DistortionParams = .zero

    /// 目标畸变参数（动画过渡的目标）
    @Published private(set) var targetParams: DistortionParams = .zero

    /// 当前选中的镜头预设
    @Published var selectedPreset: LensProfile?

    /// 是否启用矫正
    @Published var isEnabled: Bool = true {
        didSet { renderer?.fisheyeEnabled = isEnabled }
    }

    /// 矫正强度 [0.0, 1.0]，用于混合原始/矫正画面
    @Published var strength: Float = 1.0

    // MARK: - 内部引用

    private weak var renderer: MetalRenderer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    init(renderer: MetalRenderer?) {
        self.renderer = renderer
        setupBindings()
    }

    /// 绑定畸变参数到 MetalRenderer
    private func setupBindings() {
        $currentParams
            .sink { [weak self] params in
                self?.renderer?.distortionParams = params
            }
            .store(in: &cancellables)
    }

    // MARK: - 预设管理

    /// 应用镜头预设
    func applyPreset(_ profile: LensProfile) {
        selectedPreset = profile
        targetParams = profile.distortionParams
        // 直接应用（未来可以加动画过渡）
        currentParams = targetParams
        isEnabled = true
    }

    /// 应用原始畸变参数
    func applyParams(_ params: DistortionParams) {
        selectedPreset = nil
        targetParams = params
        currentParams = params
        isEnabled = true
    }

    /// 关闭矫正（直通模式）
    func disable() {
        isEnabled = false
        currentParams = .zero
        targetParams = .zero
    }

    // MARK: - 手动微调

    /// 微调 k1 参数（相对偏移）
    func fineTune(deltaK1: Float) {
        targetParams.k1 += deltaK1
        currentParams.k1 += deltaK1
    }

    /// 微调 k2 参数（相对偏移）
    func fineTune(deltaK2: Float) {
        targetParams.k2 += deltaK2
        currentParams.k2 += deltaK2
    }

    /// 微调缩放（相对偏移）
    func fineTune(deltaScale: Float) {
        targetParams.scale = max(0.8, min(1.5, targetParams.scale + deltaScale))
        currentParams.scale = targetParams.scale
    }

    // MARK: - 渐变过渡

    /// 以动画方式过渡到新参数
    /// - Parameters:
    ///   - newParams: 目标参数
    ///   - duration: 过渡时长（秒）
    func animateTo(_ newParams: DistortionParams, duration: TimeInterval = 0.5) {
        let startParams = currentParams
        targetParams = newParams
        let steps = Int(duration / 0.016) // 约 60fps
        let delay = duration / Double(steps)

        for step in 1...steps {
            let t = Float(step) / Float(steps)
            // easeInOutCubic 缓动
            let eased = t < 0.5 ? 4*t*t*t : 1 - pow(-2*t + 2, 3) / 2

            DispatchQueue.main.asyncAfter(deadline: .now() + delay * Double(step)) { [weak self] in
                self?.currentParams = DistortionParams(
                    k1: startParams.k1 + (newParams.k1 - startParams.k1) * eased,
                    k2: startParams.k2 + (newParams.k2 - startParams.k2) * eased,
                    k3: startParams.k3 + (newParams.k3 - startParams.k3) * eased,
                    centerX: startParams.centerX + (newParams.centerX - startParams.centerX) * eased,
                    centerY: startParams.centerY + (newParams.centerY - startParams.centerY) * eased,
                    scale: startParams.scale + (newParams.scale - startParams.scale) * eased
                )
            }
        }

        // 确保最后精确到达目标
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.currentParams = newParams
        }
    }
}
