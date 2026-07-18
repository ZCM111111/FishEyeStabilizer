import Foundation

// MARK: - 离线视频处理器 (stub for CI)

@MainActor
final class VideoProcessor: ObservableObject {
    let config: ProcessingConfig
    weak var delegate: VideoProcessorDelegate?
    @Published private(set) var progress: Double = 0.0
    @Published private(set) var isProcessing = false
    @Published private(set) var estimatedTimeRemaining: TimeInterval = 0

    init(config: ProcessingConfig, metalRenderer: MetalRenderer,
         fisheyeCorrector: FisheyeCorrector, horizonStabilizer: HorizonStabilizer) {
        self.config = config
    }

    func process(videoURL: URL, outputURL: URL) async throws {
        // 离线处理暂未在 CI 中启用
        throw ProcessorError.noVideoTrack
    }
}

enum ProcessorError: LocalizedError {
    case noVideoTrack
    var errorDescription: String? { "离线处理暂未启用" }
}

protocol VideoProcessorDelegate: AnyObject {
    func videoProcessor(_ processor: VideoProcessor, didUpdateProgress progress: Double)
    func videoProcessorDidFinish(_ processor: VideoProcessor)
}
