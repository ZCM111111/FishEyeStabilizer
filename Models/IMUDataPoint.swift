import Foundation

/// 单帧 IMU（惯性测量单元）数据点
/// 用于地平线防抖：记录每帧拍摄时设备的空间姿态
struct IMUDataPoint: Codable {
    /// 时间戳（秒），与视频帧的 PTS 对齐
    let timestamp: TimeInterval

    /// Roll — 绕前后轴旋转（弧度），即「水平倾斜角」
    /// 正值 = 右侧向下倾斜，这是地平线防抖的核心参数
    let roll: Double

    /// Pitch — 绕左右轴旋转（弧度），即「俯仰角」
    /// 正值 = 设备向上仰
    let pitch: Double

    /// Yaw — 绕垂直轴旋转（弧度），即「偏航角」
    /// 正值 = 向右转
    let yaw: Double

    /// 重力加速度向量（x, y, z），可以作为 roll/pitch 的冗余参考
    let gravityX: Double
    let gravityY: Double
    let gravityZ: Double

    /// 旋转速率（弧度/秒），用于检测快速抖动
    let rotationRateX: Double
    let rotationRateY: Double
    let rotationRateZ: Double
}

// MARK: - 环形缓冲区

/// IMU 数据环形缓冲区，线程安全
/// 保持最近 N 秒的 IMU 数据，支持按时间戳查询
actor IMUBuffer {
    private var buffer: [IMUDataPoint] = []
    private let maxAge: TimeInterval // 最大保留时长（秒）

    init(maxAge: TimeInterval = 2.0) {
        self.maxAge = maxAge
    }

    /// 追加新的 IMU 数据点
    func append(_ point: IMUDataPoint) {
        buffer.append(point)
        prune()
    }

    /// 查找最接近给定时间戳的 IMU 数据点
    /// - Parameter timestamp: 目标时间戳
    /// - Returns: 最接近的 IMU 数据点，如果缓冲区为空则返回 nil
    func findClosest(to timestamp: TimeInterval) -> IMUDataPoint? {
        guard !buffer.isEmpty else { return nil }
        return buffer.min(by: { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) })
    }

    /// 清除过期数据
    private func prune() {
        guard let newest = buffer.last?.timestamp else { return }
        let cutoff = newest - maxAge
        buffer = buffer.filter { $0.timestamp >= cutoff }
    }

    /// 当前缓冲数据点数量
    var count: Int { buffer.count }
}
