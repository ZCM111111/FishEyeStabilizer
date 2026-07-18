import SwiftUI
@preconcurrency import AVFoundation
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

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    init() {
        setupDelegates()
    }

    private func setupDelegates() {
        cameraManager.delegate = self
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

extension CameraViewModel: CameraFrameDelegate {

    nonisolated func cameraManager(
        _ manager: CameraManager,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        // 更新防抖参数（每帧）
        Task {
            await horizonStabilizer.updateForFrame(timestamp: timestamp.seconds)
        }

        // Metal 渲染
        let processedTexture = renderer.render(pixelBuffer: pixelBuffer, into: nil)

        // 如果正在录制，写入处理后的帧
        if isRecording, let texture = processedTexture, isWriterReady {
            writeFrame(texture: texture, timestamp: timestamp)
        }
    }

    private func writeFrame(texture: MTLTexture, timestamp: CMTime) {
        guard let input = assetWriterInput,
              input.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor else {
            return
        }

        // MTLTexture → CVPixelBuffer
        guard let pixelBuffer = textureToPixelBuffer(texture) else { return }

        adaptor.append(pixelBuffer, withPresentationTime: timestamp)
        recordedFrames += 1
    }

    private func textureToPixelBuffer(_ texture: MTLTexture) -> CVPixelBuffer? {
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
}
