@preconcurrency import AVFoundation
@preconcurrency import CoreImage
import Combine

// MARK: - 离线视频处理器

/// 对已有视频文件进行鱼眼矫正 + 地平线防抖的离线处理
///
/// 处理流程:
/// 1. AVAssetReader 逐帧读取源视频
/// 2. 每帧经过 Metal 鱼眼矫正 (Compute Shader)
/// 3. 再经过 Metal 地平线防抖 (Vertex/Fragment Shader)
/// 4. AVAssetWriter 写入处理后的视频
/// 5. 保留原始音频（直通）
///
/// 使用方式:
/// ```swift
/// let processor = VideoProcessor(config: config)
/// processor.delegate = self
/// await processor.process(videoURL: inputURL, outputURL: outputURL)
/// ```
@MainActor
final class VideoProcessor: ObservableObject {

    // MARK: - 公开属性

    /// 处理配置
    let config: ProcessingConfig

    /// 进度回调代理
    weak var delegate: VideoProcessorDelegate?

    /// 当前处理进度 [0.0, 1.0]
    @Published private(set) var progress: Double = 0.0

    /// 是否正在处理
    @Published private(set) var isProcessing = false

    /// 估计剩余时间（秒）
    @Published private(set) var estimatedTimeRemaining: TimeInterval = 0

    // MARK: - 内部

    private let metalRenderer: MetalRenderer
    private let fisheyeCorrector: FisheyeCorrector
    private let horizonStabilizer: HorizonStabilizer
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 初始化

    init(
        config: ProcessingConfig,
        metalRenderer: MetalRenderer,
        fisheyeCorrector: FisheyeCorrector,
        horizonStabilizer: HorizonStabilizer
    ) {
        self.config = config
        self.metalRenderer = metalRenderer
        self.fisheyeCorrector = fisheyeCorrector
        self.horizonStabilizer = horizonStabilizer
    }

    // MARK: - 主要处理入口

    /// 处理视频文件
    ///
    /// - Parameters:
    ///   - videoURL: 源视频文件 URL
    ///   - outputURL: 输出文件 URL
    func process(videoURL: URL, outputURL: URL) async throws {
        await MainActor.run {
            isProcessing = true
            progress = 0.0
        }

        defer {
            Task { @MainActor in
                isProcessing = false
            }
        }

        // --- 步骤 1: 设置 Reader ---
        let asset = AVAsset(url: videoURL)
        let reader = try AVAssetReader(asset: asset)

        // 视频轨道
        guard let videoTrack = try await asset.loadTracks(withMediaCharacteristic: .visual).first else {
            throw ProcessorError.noVideoTrack
        }
        let videoDuration = try await asset.load(.duration)
        let totalDuration = CMTimeGetSeconds(videoDuration)

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        // 音频轨道（直通）
        let audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            audioOutput = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: nil // 直通（不解码）
            )
            reader.add(audioOutput!)
        } else {
            audioOutput = nil
        }

        guard reader.startReading() else {
            throw ProcessorError.readerStartFailed(reader.error)
        }

        // --- 步骤 2: 设置 Writer ---
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)

        // 视频写入设置
        let videoSize = videoTrack.naturalSize
        let outputSize = config.outputResolution.pixelSize
            ?? (width: Int(videoSize.width), height: Int(videoSize.height))

        let videoWriterInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: outputSize.width,
                AVVideoHeightKey: outputSize.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(config.outputBitrateMbps * 1_000_000),
                    AVVideoExpectedSourceFrameRateKey: config.outputFrameRate,
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel
                ]
            ]
        )
        videoWriterInput.expectsMediaDataInRealTime = false

        // 像素缓冲适配器（将 CVPixelBuffer 写入帧）
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputSize.width,
                kCVPixelBufferHeightKey as String: outputSize.height
            ]
        )

        writer.add(videoWriterInput)

        // 音频直通
        let audioWriterInput: AVAssetWriterInput?
        if audioOutput != nil {
            audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            writer.add(audioWriterInput!)
        } else {
            audioWriterInput = nil
        }

        guard writer.startWriting() else {
            throw ProcessorError.writerStartFailed(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        // --- 步骤 3: 逐帧处理 ---
        var frameCount = 0
        let startTime = Date()

        // 在后台线程处理
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in

            let processingQueue = DispatchQueue(label: "com.fisheye.videoprocessor",
                                                 qos: .userInitiated)

            videoWriterInput.requestMediaDataWhenReady(on: processingQueue) { [weak self] in
                guard let self = self else { return }

                while videoWriterInput.isReadyForMoreMediaData {
                    // 读取下一帧
                    guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
                        // 视频读完 → 标记完成
                        videoWriterInput.markAsFinished()
                        if let audioIn = audioWriterInput {
                            audioIn.markAsFinished()
                        }
                        writer.finishWriting {
                            Task { @MainActor in
                                self.progress = 1.0
                                self.delegate?.videoProcessorDidFinish(self)
                            }
                            continuation.resume()
                        }
                        return
                    }

                    // 处理帧（鱼眼矫正 + 防抖 → RGBA）
                    if let processedBuffer = self.processFrame(sampleBuffer) {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        pixelAdaptor.append(processedBuffer, withPresentationTime: pts)
                        frameCount += 1

                        // 更新进度
                        let currentSeconds = CMTimeGetSeconds(pts)
                        let p = currentSeconds / totalDuration
                        let elapsed = Date().timeIntervalSince(startTime)
                        let estimatedTotal = elapsed / max(p, 0.001)
                        let remaining = estimatedTotal - elapsed

                        Task { @MainActor in
                            self.progress = p
                            self.estimatedTimeRemaining = max(0, remaining)
                            self.delegate?.videoProcessor(self, didUpdateProgress: p)
                        }
                    }
                }

                // 处理音频（同步写入）
                if let audioIn = audioWriterInput, audioIn.isReadyForMoreMediaData {
                    while let audioBuffer = audioOutput?.copyNextSampleBuffer() {
                        audioIn.append(audioBuffer)
                    }
                }
            }
        }

        // --- 步骤 4: 完成 ---
        if writer.status == .failed {
            throw ProcessorError.writerFailed(writer.error)
        }

        print("✅ [VideoProcessor] 处理完成: \(frameCount) 帧")
    }

    // MARK: - 单帧处理

    /// 处理单帧：YUV → Metal 矫正 → Metal 防抖 → RGBA
    private func processFrame(_ sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // 1. 更新防抖参数（根据帧时间戳）
        Task {
            await horizonStabilizer.updateForFrame(timestamp: timestamp.seconds)
        }

        // 2. 通过 Metal 管线处理
        let processedTexture = metalRenderer.render(
            pixelBuffer: pixelBuffer,
            into: nil  // 离线处理，不渲染到屏幕
        )

        // 3. MTLTexture → CVPixelBuffer
        guard let texture = processedTexture else {
            return nil
        }

        return textureToPixelBuffer(texture)
    }

    // MARK: - MTLTexture → CVPixelBuffer

    /// 将 Metal 纹理转换为像素缓冲（用于写入视频）
    private func textureToPixelBuffer(_ texture: MTLTexture) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        let width = texture.width
        let height = texture.height

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferMetalCompatibilityKey: true
            ] as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        // 从 Metal 纹理拷贝数据到像素缓冲
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }

        let region = MTLRegionMake2D(0, 0, width, height)
        texture.getBytes(
            baseAddress,
            bytesPerRow: bytesPerRow,
            from: region,
            mipmapLevel: 0
        )

        return buffer
    }
}

// MARK: - 错误类型

enum ProcessorError: LocalizedError {
    case noVideoTrack
    case readerStartFailed(Error?)
    case writerStartFailed(Error?)
    case writerFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "视频文件中没有找到视频轨道"
        case .readerStartFailed(let err):
            return "无法开始读取视频: \(err?.localizedDescription ?? "未知错误")"
        case .writerStartFailed(let err):
            return "无法创建输出文件: \(err?.localizedDescription ?? "未知错误")"
        case .writerFailed(let err):
            return "视频写入失败: \(err?.localizedDescription ?? "未知错误")"
        }
    }
}

// MARK: - 代理协议

protocol VideoProcessorDelegate: AnyObject {
    func videoProcessor(_ processor: VideoProcessor, didUpdateProgress progress: Double)
    func videoProcessorDidFinish(_ processor: VideoProcessor)
}
