import SwiftUI
@preconcurrency import AVFoundation
@preconcurrency import Photos

// MARK: - 处理 ViewModel

/// 编排离线视频处理的全流程
///
/// 流程:
/// 1. 用户选择源视频
/// 2. 自动检测鱼眼参数（或手动选择预设）
/// 3. 配置防抖模式和强度
/// 4. 预览处理效果（单帧采样）
/// 5. 执行全视频处理
/// 6. 导出并保存到相册
///
@MainActor
final class ProcessingViewModel: ObservableObject {

    // MARK: - 服务

    private let metalRenderer = MetalRenderer()
    private let lensPresetService = LensPresetService()
    private let imuService = IMUCaptureService()

    lazy var fisheyeCorrector = FisheyeCorrector(renderer: metalRenderer)
    lazy var horizonStabilizer = HorizonStabilizer(
        imuService: imuService,
        renderer: metalRenderer
    )
    lazy var autoDetector = AutoDetector(presetService: lensPresetService)
    lazy var exporter = VideoExporter()

    /// 视频处理器（按需创建）
    private var videoProcessor: VideoProcessor?

    // MARK: - 处理状态

    /// 当前处理阶段的枚举
    enum Stage {
        case selecting      // 正在选择视频
        case analyzing      // 自动分析鱼眼参数
        case configuring    // 配置矫正和防抖参数
        case previewing     // 单帧预览效果
        case processing     // 正在进行全视频处理
        case completed      // 处理完成
        case failed         // 处理失败
    }

    @Published var stage: Stage = .selecting

    /// 源视频信息
    @Published var sourceVideoURL: URL?
    @Published var sourceVideoTitle: String = ""

    // MARK: - 处理配置

    @Published var config = ProcessingConfig.default

    /// 自动检测结果
    @Published var autoDetectionResult: AutoDetector.DetectionResult?

    /// 处理进度
    @Published var progress: Double = 0.0

    /// 估计剩余时间
    @Published var estimatedTimeRemaining: TimeInterval = 0

    /// 错误信息
    @Published var errorMessage: String?

    // MARK: - 预览

    /// 预览帧（单帧处理后的 CGImage 用于对比显示）
    @Published var previewOriginalImage: UIImage?
    @Published var previewProcessedImage: UIImage?

    /// 是否显示原始/处理后对比
    @Published var showComparison = false

    // MARK: - 输出

    /// 处理后的视频 URL
    @Published var outputVideoURL: URL?

    // MARK: - 初始化

    init() {
        metalRenderer.fisheyeEnabled = true
        metalRenderer.stabilizeEnabled = true
    }

    // MARK: - 选择源视频

    /// 设置源视频
    func setSourceVideo(url: URL, title: String) {
        sourceVideoURL = url
        sourceVideoTitle = title
        stage = .configuring
    }

    /// 通过 PHAsset 获取视频文件 URL
    func loadVideoFromAsset(_ asset: PHAsset) async {
        stage = .selecting

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat

        await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: options
            ) { [weak self] avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    Task { @MainActor in
                        self?.errorMessage = "无法加载视频文件"
                        self?.stage = .failed
                    }
                    continuation.resume()
                    return
                }
                Task { @MainActor in
                    self?.setSourceVideo(
                        url: urlAsset.url,
                        title: "视频 \(asset.creationDate?.formatted() ?? "")"
                    )
                }
                continuation.resume()
            }
        }
    }

    // MARK: - 自动检测

    /// 启动自动鱼眼检测
    func runAutoDetection() async {
        guard let videoURL = sourceVideoURL else {
            errorMessage = "没有选择源视频"
            return
        }

        await MainActor.run { stage = .analyzing }

        do {
            let result = try await autoDetector.detect(from: videoURL)
            await MainActor.run {
                self.autoDetectionResult = result
                // 使用高置信度结果或让用户手动确认
                if result.confidence > 0.6 {
                    self.fisheyeCorrector.applyParams(result.params)
                    self.config.lensProfile = result.matchedPreset
                }
                self.stage = .configuring
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "自动检测失败: \(error.localizedDescription)"
                // 回退到手动选择模式
                self.stage = .configuring
            }
        }
    }

    // MARK: - 预览

    /// 对当前帧生成预览对比
    func generatePreview() async {
        guard let videoURL = sourceVideoURL else { return }

        await MainActor.run { stage = .previewing }

        // 提取一帧
        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let time = CMTime(seconds: 1.0, preferredTimescale: 600)

        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let originalImage = UIImage(cgImage: cgImage)

            // 处理这一帧（通过 Metal）
            if let pixelBuffer = cgImage.toPixelBuffer() {
                let processedTexture = metalRenderer.render(
                    pixelBuffer: pixelBuffer,
                    into: nil
                )
                // 这里可以将处理后的纹理转回 UIImage
                // 实际实现取决于 MetalRenderer 返回的纹理格式
            }

            await MainActor.run {
                self.previewOriginalImage = originalImage
                self.showComparison = true
                self.stage = .configuring
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "预览生成失败: \(error.localizedDescription)"
                self.stage = .configuring
            }
        }
    }

    // MARK: - 执行处理

    /// 开始处理整个视频
    func startProcessing() async {
        guard let videoURL = sourceVideoURL else {
            errorMessage = "没有选择源视频"
            return
        }

        await MainActor.run {
            stage = .processing
            progress = 0.0
        }

        // 创建 VideoProcessor
        let processor = VideoProcessor(
            config: config,
            metalRenderer: metalRenderer,
            fisheyeCorrector: fisheyeCorrector,
            horizonStabilizer: horizonStabilizer
        )
        processor.delegate = self
        self.videoProcessor = processor

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("processed_\(UUID().uuidString).mp4")

        do {
            try await processor.process(videoURL: videoURL, outputURL: outputURL)

            // 导出并保存
            try await exporter.exportAndSave(
                inputURL: outputURL,
                config: config
            )

            await MainActor.run {
                self.outputVideoURL = outputURL
                self.stage = .completed
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.stage = .failed
            }
        }
    }

    // MARK: - 配置更新

    /// 更新防抖模式
    func setStabilizationMode(_ mode: ProcessingConfig.StabilizationMode) {
        config.stabilizationMode = mode
        horizonStabilizer.mode = mode
    }

    /// 更新防抖强度
    func setStabilizationStrength(_ strength: Float) {
        config.stabilizationStrength = strength
        horizonStabilizer.strength = strength
    }

    /// 应用镜头预设
    func applyPreset(_ preset: LensProfile) {
        config.lensProfile = preset
        fisheyeCorrector.applyPreset(preset)
    }
}

// MARK: - VideoProcessorDelegate

extension ProcessingViewModel: VideoProcessorDelegate {

    func videoProcessor(_ processor: VideoProcessor, didUpdateProgress progress: Double) {
        Task { @MainActor in
            self.progress = progress
            self.estimatedTimeRemaining = processor.estimatedTimeRemaining
        }
    }

    func videoProcessorDidFinish(_ processor: VideoProcessor) {
        Task { @MainActor in
            self.progress = 1.0
        }
    }
}
