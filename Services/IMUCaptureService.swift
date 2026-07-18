import CoreMotion
import Foundation

// MARK: - IMU 采集服务

/// 采集设备运动数据（陀螺仪 + 加速度计），用于地平线防抖
/// 以 120Hz 采集 CMDeviceMotion，维护环形缓冲区供帧同步查询
@MainActor
final class IMUCaptureService: ObservableObject {

    private let motionManager = CMMotionManager()
    private let buffer = IMUBuffer(maxAge: 3.0)

    @Published private(set) var latestData: IMUDataPoint?
    @Published private(set) var isCapturing = false

    private var referenceAttitude: CMAttitude?

    init() {
        if !motionManager.isDeviceMotionAvailable {
            print("⚠️ [IMU] 当前设备不支持 DeviceMotion")
        }
    }

    // MARK: - 采集控制

    func startCapture(frequency: Double = 120.0) {
        guard motionManager.isDeviceMotionAvailable, !isCapturing else { return }

        motionManager.deviceMotionUpdateInterval = 1.0 / frequency

        motionManager.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: .main
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

            self.latestData = dataPoint

            // buffer 是 actor，需要异步写入
            Task.detached { [dataPoint] in
                await self.buffer.append(dataPoint)
            }
        }

        isCapturing = true
        print("✅ [IMU] 开始采集 @ \(frequency)Hz")
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

    func configure(cutoffHz: Double, sampleRateHz: Double) {
        let dt = 1.0 / sampleRateHz
        let tau = 1.0 / (2.0 * Double.pi * cutoffHz)
        alpha = dt / (dt + tau)
    }

    func filter(_ value: Double) -> Double {
        if !isInitialized {
            filteredValue = value
            isInitialized = true
        } else {
            filteredValue = alpha * value + (1.0 - alpha) * filteredValue
        }
        return filteredValue
    }

    func reset() {
        isInitialized = false
        filteredValue = 0.0
    }
}
