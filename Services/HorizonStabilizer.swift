import Foundation
import Combine

// MARK: - 地平线防抖器

/// 地平线防抖的高级封装，模拟大疆 HorizonSteady 效果
///
/// 核心原理:
/// 1. 实时读取 IMU 数据（roll/pitch/yaw）
/// 2. 对 roll 角完全反向旋转 → 地平线始终保持水平
/// 3. 对 pitch/yaw 做低通滤波 → 平滑抖动但保留运镜
/// 4. 输出防抖参数给 Metal shader
///
/// 与大疆 HorizonSteady 的对应关系:
/// - HorizonSteady 的「地平线锁定」= roll 完全反旋
/// - 「增稳」= pitch/yaw 低通滤波
/// - 「超级增稳」= roll 全锁 + pitch 部分锁定 + 更大裁剪
///
/// 使用方式:
/// ```swift
/// let stabilizer = HorizonStabilizer(imu: imuService, renderer: metalRenderer)
/// stabilizer.mode = .horizonLevel
/// // 每帧调用:
/// await stabilizer.updateForFrame(timestamp: frameTime)
/// ```
///
/// 注意: 不再标注 @MainActor — 每帧更新在后台线程执行，通过 NSLock 保护滤波器状态。
/// @Published 属性在后台线程写入时，SwiftUI 会自动处理主线程调度。
final class HorizonStabilizer: ObservableObject {

    // MARK: - 公开属性

    /// 防抖模式
    @Published var mode: ProcessingConfig.StabilizationMode = .horizonLevel {
        didSet { updateModeConfig() }
    }

    /// 防抖强度 [0.0, 1.0]（控制滤波强度）
    @Published var strength: Float = 0.8 {
        didSet { updateFilterConfig() }
    }

    /// 是否启用防抖
    @Published var isEnabled: Bool = true {
        didSet { renderer?.stabilizeEnabled = isEnabled }
    }

    // MARK: - 内部

    private weak var renderer: MetalRenderer?
    private let imuService: IMUCaptureService

    /// 三个角度的独立低通滤波器
    private var rollFilter = LowPassFilter()
    private var pitchFilter = LowPassFilter()
    private var yawFilter = LowPassFilter()

    /// 是否完全锁定 roll（地平线模式）
    private var lockRoll: Bool = true

    /// 是否锁定 pitch
    private var lockPitch: Bool = false

    /// 线程安全锁（updateForFrame 在后台线程调用）
    private let stateLock = NSLock()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    init(imuService: IMUCaptureService, renderer: MetalRenderer?) {
        self.imuService = imuService
        self.renderer = renderer
        updateFilterConfig()
        updateModeConfig()
    }

    // MARK: - 配置更新

    private func updateModeConfig() {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch mode {
        case .off:
            lockRoll = false
            lockPitch = false

        case .standard:
            lockRoll = false
            lockPitch = false

        case .horizonLevel:
            lockRoll = true
            lockPitch = false

        case .fullLock:
            lockRoll = true
            lockPitch = true
        }
    }

    private func updateFilterConfig() {
        let cutoffHz = Double(5.0 - strength * 4.5)  // [0.5, 5.0]

        rollFilter.configure(cutoffHz: cutoffHz, sampleRateHz: 120.0)
        pitchFilter.configure(cutoffHz: cutoffHz, sampleRateHz: 120.0)
        yawFilter.configure(cutoffHz: cutoffHz * 1.5, sampleRateHz: 120.0)
    }

    // MARK: - 每帧更新

    /// 根据视频帧时间戳更新防抖参数
    /// 每帧调用一次（现在在后台线程调用，不再阻塞 MainActor）
    ///
    /// - Parameter timestamp: 视频帧的时间戳（秒）
    func updateForFrame(timestamp: TimeInterval) async {
        guard isEnabled else {
            renderer?.stabilizeParams = .zero
            return
        }

        // --- 获取该帧对应的 IMU 数据 ---
        guard let imuData = await imuService.getIMUData(for: timestamp) else {
            renderer?.stabilizeParams = .zero
            return
        }

        stateLock.lock()
        let _lockRoll = lockRoll
        let _lockPitch = lockPitch
        stateLock.unlock()

        // --- 处理 Roll（地平线） ---
        let stabilizedRoll: Float
        if _lockRoll {
            stabilizedRoll = -Float(imuData.roll)
        } else {
            let filtered = rollFilter.filter(imuData.roll)
            stabilizedRoll = -Float(imuData.roll - filtered)
        }

        // --- 处理 Pitch ---
        let stabilizedPitch: Float
        if _lockPitch {
            stabilizedPitch = -Float(imuData.pitch)
        } else {
            let filtered = pitchFilter.filter(imuData.pitch)
            stabilizedPitch = -Float(imuData.pitch - filtered)
        }

        // --- 处理 Yaw ---
        let filteredYaw = yawFilter.filter(imuData.yaw)
        let stabilizedYaw = -Float(imuData.yaw - filteredYaw)

        // --- 裁剪边距 ---
        let cropMargin: Float = _lockRoll ? 0.12 : 0.08

        // --- 更新渲染参数 ---
        renderer?.stabilizeParams = StabilizeParams(
            roll: stabilizedRoll,
            pitch: stabilizedPitch,
            yaw: stabilizedYaw,
            cropMargin: cropMargin,
            focalLength: 500.0
        )
    }

    /// 重置滤波器（切换场景时调用，避免拖尾）
    func resetFilters() {
        rollFilter.reset()
        pitchFilter.reset()
        yawFilter.reset()
    }
}
