@preconcurrency import CoreMotion
import Foundation

// MARK: - IMU 采集服务

/// 采集设备运动数据（陀螺仪 + 加速度计），用于地平线防抖
/// 以 120Hz 采集 CMDeviceMotion，维护环形缓冲区供帧同步查询
///
/// 注意: 不再标注 @MainActor — CoreMotion 数据采集在专用后台队列执行，
/// 避免 120Hz 回调轰炸主线程导致 UI 卡顿。
final class IMUCaptureService: ObservableObject {

    private let motionManager = CMMotionManager()
    private let buffer = IMUBuffer(maxAge: 3.0)

    /// 回调在后台队列，@Published 需手动调度到 MainActor
    @Published private(set) var latestData: IMUDataPoint?
    @Published private(set) var isCapturing = false

    private var referenceAttitude: CMAttitude?

    /// IMU 数据回调专用后台队列
    private let imuQueue = OperationQueue()
    private let dataLock = NSLock()

    init() {
        imuQueue.name = "com.fisheye.imu"
        imuQueue.maxConcurrentOperationCount = 1
        imuQueue.qualityOfService = .userInitiated

        if !motionManager.isDeviceMotionAvailable {
            print("⚠️ [IMU] 当前设备不支持 DeviceMotion")
        }
    }

    // MARK: - 采集控制

    func startCapture(frequency: Double = 120.0) {
        guard motionManager.isDeviceMotionAvailable, !isCapturing else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / frequency

        // 关键修复: 回调改为后台队列，不再用 .main
        // 120Hz 回调在主线程会导致 UI 严重卡顿
        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: imuQueue
        ) { [weak self] motion, error in
            guard let self else {
                if let error { print("❌ [IMU] 采集错误: \(error)") }
                return
            }

            if self.referenceAttitude == nil {
                self.referenceAttitude = motion?.attitude
            }

            guard let motion else { return }

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

            // 在后台线程更新 @Published（SwiftUI 会自动调度到主线程渲染）
            self.latestData = dataPoint

            // buffer 是 actor，异步写入
            let buf = self.buffer
            Task.detached { [dataPoint, buf] in
                await buf.append(dataPoint)
            }
        }

        isCapturing = true
        print("✅ [IMU] 开始采集 @ \(frequency)Hz（后台队列）")
    }

    func stopCapture() {
        motionManager.stopDeviceMotionUpdates()
        isCapturing = false
        print("⏸ [IMU] 已停止采集")
    }

    // MARK: - 数据查询

    func getIMUData(for timestamp: TimeInterval) async -> IMUDataPoint? {
        await buffer.findClosest(to: timestamp)
    }

    func getRelativeRotation(timestamp: TimeInterval) async -> (roll: Double, pitch: Double, yaw: Double)? {
        guard let data = await getIMUData(for: timestamp) else { return nil }

        if let ref = referenceAttitude {
            return (data.roll - ref.roll, data.pitch - ref.pitch, data.yaw - ref.yaw)
        }
        return (data.roll, data.pitch, data.yaw)
    }

    func resetReference() {
        referenceAttitude = nil
    }
}

// MARK: - 低通滤波器

/// 一阶低通滤波器，用于平滑 IMU 角度变化
/// alpha = dt / (dt + 1/(2*pi*cutoffHz))，较小的 alpha = 更强平滑
final class LowPassFilter: @unchecked Sendable {
    private var alpha: Double = 0.1
    private var filteredValue: Double = 0.0
    private var isInitialized = false
    private let lock = NSLock()

    func configure(cutoffHz: Double, sampleRateHz: Double) {
        let dt = 1.0 / sampleRateHz
        let tau = 1.0 / (2.0 * Double.pi * cutoffHz)
        alpha = dt / (dt + tau)
    }

    func filter(_ value: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        if !isInitialized {
            filteredValue = value
            isInitialized = true
        } else {
            filteredValue = alpha * value + (1.0 - alpha) * filteredValue
        }
        return filteredValue
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        isInitialized = false
        filteredValue = 0.0
    }
}
