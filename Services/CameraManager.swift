import AVFoundation
import CoreVideo
import Combine

// MARK: - 相机管理器

/// 管理 AVCaptureSession 的生命周期、配置和视频帧输出
///
/// 核心职责:
/// - 配置前后摄像头、分辨率、帧率
/// - 启动/停止采集会话
/// - 通过 delegate 回调输出每一帧 CVPixelBuffer
///
/// 使用方式:
/// ```swift
/// let camera = CameraManager()
/// camera.delegate = self
/// camera.startSession()
/// // 在 delegate 回调中接收帧
/// camera.stopSession()
/// ```
final class CameraManager: NSObject, ObservableObject {

    // MARK: - 公开属性

    /// 当前采集会话
    private(set) var session: AVCaptureSession

    /// 当前使用的摄像头设备
    private(set) var videoDevice: AVCaptureDevice?

    /// 视频帧输出
    private let videoOutput = AVCaptureVideoDataOutput()

    /// 视频帧代理（接收每一帧的 CVPixelBuffer）
    weak var delegate: CameraFrameDelegate?

    /// 相机会话是否正在运行
    @Published private(set) var isSessionRunning = false

    /// 当前使用的摄像头位置
    @Published var cameraPosition: AVCaptureDevice.Position = .back

    /// 采集分辨率预设
    var sessionPreset: AVCaptureSession.Preset = .hd4K3840x2160

    /// 目标帧率
    var targetFrameRate: Int32 = 60

    /// 相机处理用的串行队列
    private let cameraQueue = DispatchQueue(
        label: "com.fisheye.camera",
        qos: .userInteractive
    )

    /// 用于 Combine 的内存管理
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    override init() {
        self.session = AVCaptureSession()
        super.init()
        configureSession()
    }

    // MARK: - 会话配置

    /// 配置 AVCaptureSession 的输入和输出
    private func configureSession() {
        session.beginConfiguration()

        // 设置采集分辨率
        if session.canSetSessionPreset(sessionPreset) {
            session.sessionPreset = sessionPreset
        }

        // --- 视频输入 ---
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: cameraPosition
        ) else {
            print("❌ [CameraManager] 无法访问摄像头")
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                // 移除旧输入
                session.inputs.forEach { session.removeInput($0) }
                session.addInput(input)
                self.videoDevice = camera
                print("✅ [CameraManager] 视频输入: \(camera.localizedName)")

                // 配置相机参数（帧率、防抖等）
                try configureCameraDevice(camera)
            }
        } catch {
            print("❌ [CameraManager] 创建视频输入失败: \(error)")
        }

        // --- 视频帧输出 ---
        if session.canAddOutput(videoOutput) {
            session.outputs.forEach { session.removeOutput($0) }
            session.addOutput(videoOutput)
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange // NV12 格式
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: cameraQueue)
        }

        session.commitConfiguration()
    }

    /// 配置相机设备参数：帧率和防抖
    private func configureCameraDevice(_ device: AVCaptureDevice) throws {
        try device.lockForConfiguration()

        // --- 设置帧率 ---
        // 查找设备支持的最高帧率格式
        if let format = findBestFormat(for: device, targetFPS: targetFrameRate) {
            device.activeFormat = format

            // 设置帧率范围
            let fpsRange = CMTimeMake(value: 1, timescale: targetFrameRate)
            device.activeVideoMinFrameDuration = fpsRange
            device.activeVideoMaxFrameDuration = fpsRange
            print("✅ [CameraManager] 帧率设置为 \(targetFrameRate)fps")
        }

        // --- 关闭系统视频防抖 ---
        // 重要: 系统防抖会与我们的自定义防抖冲突
        // 我们使用 IMU 数据自己做地平线防抖
        if device.isVideoStabilizationModeSupported(.off) {
            // 系统防抖由 AVCaptureConnection 控制，这里只是设备级设置
        }

        // 关闭平滑对焦（避免对焦呼吸效应干扰防抖）
        if device.isSmoothAutoFocusSupported {
            device.isSmoothAutoFocusEnabled = false
        }

        device.unlockForConfiguration()
    }

    /// 查找支持目标帧率的最佳格式
    /// - Parameters:
    ///   - device: 摄像头设备
    ///   - targetFPS: 目标帧率
    /// - Returns: 最佳格式，如果没有找到则返回 nil
    private func findBestFormat(
        for device: AVCaptureDevice,
        targetFPS: Int32
    ) -> AVCaptureDevice.Format? {
        var bestFormat: AVCaptureDevice.Format?
        var bestPixels: Int32 = 0

        for format in device.formats {
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription
            )

            // 只考虑 4K 分辨率（约 3840 像素宽）
            guard dimensions.width >= 3840 else { continue }

            // 检查是否支持目标帧率
            for range in format.videoSupportedFrameRateRanges {
                if Int32(range.maxFrameRate) >= targetFPS &&
                   Int32(range.minFrameRate) <= targetFPS &&
                   dimensions.width > bestPixels {

                    bestFormat = format
                    bestPixels = dimensions.width
                }
            }
        }

        return bestFormat
    }

    // MARK: - 会话控制

    /// 启动相机会话（异步，在后台队列执行）
    func startSession() {
        guard !session.isRunning else {
            print("⚠️ [CameraManager] 会话已在运行")
            return
        }

        cameraQueue.async { [weak self] in
            self?.session.startRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = true
            }
            print("✅ [CameraManager] 会话已启动")
        }
    }

    /// 停止相机会话
    func stopSession() {
        guard session.isRunning else { return }

        cameraQueue.async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = false
            }
            print("⏸ [CameraManager] 会话已停止")
        }
    }

    /// 切换前后摄像头
    func toggleCamera() {
        cameraPosition = (cameraPosition == .back) ? .front : .back

        session.beginConfiguration()
        // 移除旧输入
        session.inputs.forEach { session.removeInput($0) }

        guard let newCamera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: cameraPosition
        ) else {
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: newCamera)
            if session.canAddInput(input) {
                session.addInput(input)
                self.videoDevice = newCamera
                try configureCameraDevice(newCamera)
            }
        } catch {
            print("❌ [CameraManager] 切换摄像头失败: \(error)")
        }

        session.commitConfiguration()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // 提取 CVPixelBuffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // 提取时间戳
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // 通知代理
        delegate?.cameraManager(
            self,
            didOutputPixelBuffer: pixelBuffer,
            timestamp: timestamp
        )
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // 帧被丢弃时（性能跟不上）—— 可以在这里记录性能指标
        #if DEBUG
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        print("⚠️ [CameraManager] 帧被丢弃 @ \(timestamp.seconds)")
        #endif
    }
}

// MARK: - 帧代理协议

/// 相机帧输出代理协议
protocol CameraFrameDelegate: AnyObject {
    /// 当新帧到达时调用
    /// - Parameters:
    ///   - manager: 相机管理器实例
    ///   - pixelBuffer: NV12 (BiPlanar Full Range) 格式的像素缓冲
    ///   - timestamp: 帧的呈现时间戳
    func cameraManager(
        _ manager: CameraManager,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    )
}
