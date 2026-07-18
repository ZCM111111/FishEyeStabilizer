import CoreMotion
import Foundation

// MARK: - IMU 采集服务

/// 采集设备运动数据（陀螺仪 + 加速度计），用于地平线防抖
///
/// 核心职责:
/// - 以高频 (120Hz) 采集 CMDeviceMotion 数据
/// - 维护 IMU 数据的环形缓冲区
/// - 提供按时间戳查询最近 IMU 数据的方法
///
/// 大疆 HorizonSteady 的核心就是利用 IMU 数据对每帧进行反向旋转
///
/// 使用方式:
/// ```swift
/// let imu = IMUCaptureService()
/// imu.startCapture()
/// // ... 在帧回调中 ...
/// let data = await imu.getIMUData(for: frameTimestamp)
/// ```
final class IMUCaptureService: ObservableObject {

    // MARK: - 核心对象

    private let motionManager = CMMotionManager()
    /// IMU 数据环形缓冲区（actor 保证线程安全）
    private let buffer = IMUBuffer(maxAge: 3.0)

    /// 最近一次采集的 IMU 数据（快速访问，不查 buffer）
    @Published private(set) var latestData: IMUDataPoint?

    /// 是否正在采集
    @Published private(set) var isCapturing = false

    /// 预设参考姿态（用于相对计算）
    private var referenceAttitude: CMAttitude?

    // MARK: - 初始化

    init() {
        // 检查设备是否支持运动数据
        if !motionManager.isDeviceMotionAvailable {
            print("⚠️ [IMU] 当前设备不支持 DeviceMotion")
        }
    }

    // MARK: - 采集控制

    /// 启动 IMU 数据采集
    /// - Parameter frequency: 采集频率 (Hz)，默认 120Hz
    func startCapture(frequency: Double = 120.0) {
        guard motionManager.isDeviceMotionAvailable, !isCapturing else {
            return
        }

        // 设置采集频率
        motionManager.deviceMotionUpdateInterval = 1.0 / frequency

        // 使用 CMAttitudeReferenceFrame.xArbitraryZVertical
        // Z 轴指向重力方向（垂直），X 轴为任意水平方向
        // 这样 roll 角就代表地平线倾斜程度
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: .main
        ) { [weak self] motion, error in
            guard let self = self, let motion = motion else {
                if let error = error {
                    print("❌ [IMU] 采集错误: \(error)")
                }
                return
            }

            // --- 保存参考姿态（首次采集时） ---
            if self.referenceAttitude == nil {
                self.referenceAttitude = motion.attitude
            }

            // --- 构造 IMU 数据点 ---
            let dataPoint = IMUDataPoint(
                timestamp: Date().timeIntervalSince1970,
                roll: motion.attitude.roll,
                pitch: motion.attitude.pitch,
                yaw: motion.attitude.yaw,
                gravityX: motion.gravity.x,
                gravityY: motion.gravity.y,
                gravityZ: motion.gravity.z,
                rotationRateX: motion.rotationRate.x,
                rotationRateY: motion.rotationRate.y,
                rotationRateZ: motion.rotationRate.z
            )

            // --- 存储到缓冲区和最新值 ---
            Task {
                await self.buffer.append(dataPoint)
                await MainActor.run {
                    self.latestData = dataPoint
                }
            }
        }

        isCapturing = true
        print("✅ [IMU] 开始采集 @ \(frequency)Hz")
    }

    /// 停止 IMU 数据采集
    func stopCapture() {
        motionManager.stopDeviceMotionUpdates()
        isCapturing = false
        print("⏸ [IMU] 已停止采集")
    }

    // MARK: - 数据查询

    /// 获取与指定时间戳最接近的 IMU 数据
    /// - Parameter timestamp: 视频帧的时间戳（秒）
    /// - Returns: 匹配的 IMU 数据，如果缓冲区为空则返回 nil
    func getIMUData(for timestamp: TimeInterval) async -> IMUDataPoint? {
        return await buffer.findClosest(to: timestamp)
    }

    /// 计算相对参考姿态的偏移
    /// 用于在录制过程中累积旋转量
    func getRelativeRotation(timestamp: TimeInterval) async -> (roll: Double, pitch: Double, yaw: Double)? {
        guard let data = await getIMUData(for: timestamp) else {
            return nil
        }

        // 如果有参考姿态，计算相对偏移；否则返回绝对角度
        if let ref = referenceAttitude {
            return (
                roll: data.roll - ref.roll,
                pitch: data.pitch - ref.pitch,
                yaw: data.yaw - ref.yaw
            )
        }

        return (data.roll, data.pitch, data.yaw)
    }

    /// 重置参考姿态
    /// 调用后，后续的相对旋转以当前姿态为零点
    func resetReference() {
        referenceAttitude = nil
    }
}

// MARK: - 低通滤波器（用于平滑防抖参数）

/// 一阶低通滤波器，用于平滑 IMU 角度变化
/// 截止频率决定平滑程度：频率越低 → 越平滑，但响应越慢
struct LowPassFilter {
    /// 滤波系数 alpha [0, 1]
    /// alpha = dt / (dt + 1/(2*pi*cutoffHz))
    /// 较小的 alpha = 更强的平滑
    private var alpha: Double = 0.1
    private var filteredValue: Double = 0.0
    private var isInitialized = false

    /// 更新滤波系数
    /// - Parameters:
    ///   - cutoffHz: 截止频率 (Hz)，典型值 0.5 ~ 5.0
    ///   - sampleRateHz: 采样率 (Hz)
    mutating func configure(cutoffHz: Double, sampleRateHz: Double) {
        let dt = 1.0 / sampleRateHz
        let tau = 1.0 / (2.0 * Double.pi * cutoffHz)
        alpha = dt / (dt + tau)
    }

    /// 对输入值进行滤波
    mutating func filter(_ value: Double) -> Double {
        if !isInitialized {
            filteredValue = value
            isInitialized = true
        } else {
            filteredValue = alpha * value + (1.0 - alpha) * filteredValue
        }
        return filteredValue
    }

    /// 重置滤波器
    mutating func reset() {
        isInitialized = false
        filteredValue = 0.0
    }
}
