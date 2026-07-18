import SwiftUI
@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import Combine
@preconcurrency import Photos
import Metal
import VideoToolbox

// MARK: - 相机 ViewModel

/// 管理实时拍摄页面的所有状态和逻辑
///
/// 协调以下组件:
/// - CameraManager: 相机采集
/// - IMUCaptureService: 运动数据采集
/// - MetalRenderer: 实时视频处理渲染
/// - FisheyeCorrector: 鱼眼矫正参数
/// - HorizonStabilizer: 地平线防抖参数
/// - AVAssetWriter: 视频录制
///
@MainActor
final class CameraViewModel: ObservableObject {

    // MARK: - 服务引用

    let cameraManager = CameraManager()
    let imuService = IMUCaptureService()
    let renderer = MetalRenderer()
    let lensPresetService = LensPresetService()

    lazy var fisheyeCorrector = FisheyeCorrector(renderer: renderer)
    lazy var horizonStabilizer = HorizonStabilizer(
        imuService: imuService,
        renderer: renderer
    )

    // MARK: - 录制状态

    /// 是否正在录制
    @Published var isRecording = false
    /// 录制时长（秒）
    @Published var recordingDuration: TimeInterval = 0
    /// 最近一次录制的视频 URL
    @Published var lastRecordedVideoURL: URL?

    /// 录制计时器
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?

    // MARK: - UI 状态

    /// 是否显示镜头预设选择器
    @Published var showPresetPicker = false
    /// 是否显示校准引导
    @Published var showCalibration = false
    /// 是否显示参数微调面板
    @Published var showFineTune = false
    /// 错误信息
    @Published var errorMessage: String?

    // MARK: - 处理配置

    @Published var processingConfig = ProcessingConfig.default

    // MARK: - 录制相关

    private var assetWriter: AVAssetWriter?
    private var assetWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isWriterReady = false
    private var recordedFrames: Int = 0

    /// 用于 Metal → CVPixelBuffer 高效拷贝的共享缓冲区
    private var sharedCopyBuffer: MTLBuffer?
    private var copyBufferLength: Int = 0

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    init() {
        setupDelegates()
        setupFrameCompletionHandler()
    }

    private func setupDelegates() {
        cameraManager.delegate = self
    }

    /// GPU 帧处理完成时的回调（后台线程）
    /// 用于录制：此时 GPU 已完成写入，纹理可安全读取
    private func setupFrameCompletionHandler() {
        renderer.onFrameCompleted = { [weak self] texture in
            guard let self, self.isRecording, let texture, self.isWriterReady else { return }
            self.writeFrame(texture: texture)
        }
    }

    // MARK: - 会话控制

    /// 启动相机预览
    func startCamera() {
        cameraManager.startSession()
        imuService.startCapture(frequency: 120.0)
    }

    /// 停止相机预览
    func stopCamera() {
        cameraManager.stopSession()
        imuService.stopCapture()
        if isRecording {
            stopRecording()
        }
    }

    // MARK: - 录制控制

    /// 开始录制
    func startRecording() {
        guard !isRecording else { return }
        guard setupAssetWriter() else {
            errorMessage = "无法初始化视频写入器"
            return
        }

        isRecording = true
        recordedFrames = 0
        recordingStartTime = Date()
        startRecordingTimer()
        print("🔴 [CameraViewModel] 开始录制")
    }

    /// 停止录制
    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        stopRecordingTimer()

        assetWriterInput?.markAsFinished()

        assetWriter?.finishWriting { [weak self] in
            Task { @MainActor in
                self?.lastRecordedVideoURL = self?.assetWriter?.outputURL
                print("⏹ [CameraViewModel] 录制完成，\(self?.recordedFrames ?? 0) 帧")
            }
        }

        assetWriter = nil
        assetWriterInput = nil
        pixelBufferAdaptor = nil
        isWriterReady = false
        copyBufferLength = 0
        sharedCopyBuffer = nil
    }

    /// 设置 AVAssetWriter（录制用）
    private func setupAssetWriter() -> Bool {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording_\(Date().timeIntervalSince1970).mp4")

        guard let writer = try? AVAssetWriter(url: outputURL, fileType: .mp4) else {
            return false
        }

        // 使用 HEVC 编码
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 3840,
            AVVideoHeightKey: 2160,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 50_000_000,  // 50 Mbps
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel
            ]
        ]

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        input.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 3840,
                kCVPixelBufferHeightKey as String: 2160
            ]
        )

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.assetWriter = writer
        self.assetWriterInput = input
        self.pixelBufferAdaptor = adaptor
        self.isWriterReady = true

        return true
    }

    // MARK: - 计时器

    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if let start = self?.recordingStartTime {
                    self?.recordingDuration = Date().timeIntervalSince(start)
                }
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - 操作

    /// 切换前后摄像头
    func toggleCamera() {
        cameraManager.toggleCamera()
    }

    /// 选择镜头预设
    func selectPreset(_ preset: LensProfile) {
        fisheyeCorrector.applyPreset(preset)
        processingConfig.lensProfile = preset
        showPresetPicker = false
    }

    /// 切换防抖模式
    func setStabilizationMode(_ mode: ProcessingConfig.StabilizationMode) {
        processingConfig.stabilizationMode = mode
        horizonStabilizer.mode = mode
    }
}

// MARK: - CameraFrameDelegate

extension CameraViewModel: @preconcurrency CameraFrameDelegate {

    func cameraManager(
        _ manager: CameraManager,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        // Metal 渲染提交（异步，立即返回 — 不再阻塞）
        renderer.render(pixelBuffer: pixelBuffer, into: nil)

        // IMU 防抖更新在后台 Task 执行（中等优先级，不抢占 UI）
        let stabilizer = horizonStabilizer
        Task.detached(priority: .medium) {
            await stabilizer.updateForFrame(timestamp: timestamp.seconds)
        }
    }

    /// 将 Metal 纹理写入 AVAssetWriter（在 onFrameCompleted 回调中调用）
    /// 此时 GPU 已完成对该纹理的写入，数据安全可读
    private func writeFrame(texture: MTLTexture) {
        guard let input = assetWriterInput,
              input.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor else {
            return
        }

        // MTLTexture → CVPixelBuffer（使用 Metal blit 代替 getBytes）
        guard let pixelBuffer = textureToPixelBufferBlit(texture) else { return }

        adaptor.append(pixelBuffer, withPresentationTime: .zero)
        recordedFrames += 1
    }

    /// 使用 Metal Blit Encoder + 共享缓冲区高效拷贝纹理到 CVPixelBuffer
    /// 比直接 getBytes() 快 3-5x，且不阻塞 CPU
    private func textureToPixelBufferBlit(_ texture: MTLTexture) -> CVPixelBuffer? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4  // RGBA8 = 4 bytes/pixel
        let totalBytes = bytesPerRow * height

        // 按需分配/扩展共享缓冲区
        if sharedCopyBuffer == nil || copyBufferLength < totalBytes {
            sharedCopyBuffer = rendererDevice()?.makeBuffer(
                length: totalBytes,
                options: .storageModeShared
            )
            copyBufferLength = totalBytes
        }

        guard let sharedBuffer = sharedCopyBuffer,
              let device = rendererDevice(),
              let commandQueue = rendererCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            // 回退方案：使用 getBytes（仅在 blit 路径不可用时）
            return textureToPixelBufferFallback(texture)
        }

        // Blit: GPU private texture → shared buffer（GPU 内部高效拷贝）
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: sharedBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: totalBytes
        )
        blitEncoder.endEncoding()

        // 等待 blit 完成（blit 很快，通常 <1ms）
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 从共享缓冲区拷贝到 CVPixelBuffer
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let pixelBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        // 逐行拷贝（处理可能的 stride 差异）
        let srcPtr = sharedBuffer.contents().assumingMemoryBound(to: UInt8.self)
        let dstPtr = baseAddress.assumingMemoryBound(to: UInt8.self)

        for row in 0..<height {
            let srcRow = srcPtr.advanced(by: row * bytesPerRow)
            let dstRow = dstPtr.advanced(by: row * pixelBytesPerRow)
            dstRow.update(from: srcRow, count: min(bytesPerRow, pixelBytesPerRow))
        }

        return buffer
    }

    /// 回退方案：直接用 getBytes（仅在 blit 路径不可用时）
    private func textureToPixelBufferFallback(_ texture: MTLTexture) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let width = texture.width
        let height = texture.height

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        texture.getBytes(baseAddress, bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0)

        return buffer
    }

    /// 获取 Metal 设备
    private func rendererDevice() -> MTLDevice? {
        MTLCreateSystemDefaultDevice()
    }

    /// 获取 Metal 命令队列
    private func rendererCommandQueue() -> MTLCommandQueue? {
        rendererDevice()?.makeCommandQueue()
    }
}
