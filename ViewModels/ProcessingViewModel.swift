import SwiftUI
import Foundation
import UIKit

// MARK: - 处理 ViewModel (stub for CI)

@MainActor
final class ProcessingViewModel: ObservableObject {

    enum Stage {
        case selecting, analyzing, configuring, previewing, processing, completed, failed
    }

    @Published var stage: Stage = .selecting
    @Published var sourceVideoURL: URL?
    @Published var sourceVideoTitle: String = ""
    @Published var config = ProcessingConfig.default
    @Published var autoDetectionResult: AutoDetector.DetectionResult?
    @Published var progress: Double = 0.0
    @Published var estimatedTimeRemaining: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var previewOriginalImage: UIImage?
    @Published var previewProcessedImage: UIImage?
    @Published var showComparison = false
    @Published var outputVideoURL: URL?

    let lensPresetService = LensPresetService()
    let metalRenderer = MetalRenderer()
    private let imuService = IMUCaptureService()

    lazy var fisheyeCorrector = FisheyeCorrector(renderer: metalRenderer)
    lazy var horizonStabilizer = HorizonStabilizer(imuService: imuService, renderer: metalRenderer)
    lazy var exporter = VideoExporter()

    init() {
        metalRenderer.fisheyeEnabled = true
        metalRenderer.stabilizeEnabled = true
    }

    func setSourceVideo(url: URL, title: String) {
        sourceVideoURL = url
        sourceVideoTitle = title
        stage = .configuring
    }

    func applyPreset(_ preset: LensProfile) {
        config.lensProfile = preset
        fisheyeCorrector.applyPreset(preset)
    }

    func setStabilizationMode(_ mode: ProcessingConfig.StabilizationMode) {
        config.stabilizationMode = mode
        horizonStabilizer.mode = mode
    }

    func setStabilizationStrength(_ strength: Float) {
        config.stabilizationStrength = strength
        horizonStabilizer.strength = strength
    }

    func startProcessing() async {
        // CI stub
        stage = .completed
    }
}

extension ProcessingViewModel: VideoProcessorDelegate {
    func videoProcessor(_ processor: VideoProcessor, didUpdateProgress progress: Double) {}
    func videoProcessorDidFinish(_ processor: VideoProcessor) {}
}
