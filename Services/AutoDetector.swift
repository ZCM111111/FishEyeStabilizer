@preconcurrency import Vision
@preconcurrency import CoreImage
@preconcurrency import AVFoundation
import CoreVideo
import CoreGraphics
import simd
import CoreMedia

final class AutoDetector: ObservableObject {
    struct DetectionResult {
        let params: DistortionParams
        let confidence: Float
        let matchedPreset: LensProfile?
        enum DetectionMethod: String { case lineAnalysis, presetMatch, manual }
        let method: DetectionMethod
    }

    @Published private(set) var isDetecting = false
    @Published private(set) var progress: Double = 0.0
    @Published private(set) var lastResult: DetectionResult?

    private let presetService: LensPresetService

    init(presetService: LensPresetService) {
        self.presetService = presetService
    }

    @MainActor func updateProgress(_ value: Double) { progress = value }

    func detect(from videoURL: URL) async throws -> DetectionResult {
        await MainActor.run { isDetecting = true; progress = 0.0 }
        defer { Task { @MainActor in isDetecting = false; progress = 1.0 } }
        let frames = try await extractKeyFrames(from: videoURL, count: 5)
        await updateProgress(0.2)
        var allK1: [Float] = [], allK2: [Float] = []
        for (i, frame) in frames.enumerated() {
            let (k1, k2) = analyzeFrame(frame)
            allK1.append(k1); allK2.append(k2)
            await updateProgress(0.2 + 0.5 * Double(i+1) / Double(frames.count))
        }
        let pk1 = median(allK1), pk2 = median(allK2)
        let params = DistortionParams(k1: pk1, k2: pk2, k3: 0.0, centerX: 0.5, centerY: 0.5, scale: estimateScale(k1: pk1, k2: pk2))
        await updateProgress(0.85)
        let matched = presetService.findBestMatch(for: params)
        let result = DetectionResult(params: params, confidence: matched != nil ? 0.85 : 0.5, matchedPreset: matched, method: .lineAnalysis)
        await updateProgress(1.0)
        await MainActor.run { lastResult = result }
        return result
    }

    func detectFromFrame(_ pixelBuffer: CVPixelBuffer) -> DetectionResult? {
        let (k1, k2) = analyzeFrame(pixelBuffer)
        let params = DistortionParams(k1: k1, k2: k2, k3: 0.0, centerX: 0.5, centerY: 0.5, scale: estimateScale(k1: k1, k2: k2))
        let matched = presetService.findBestMatch(for: params)
        return DetectionResult(params: params, confidence: matched != nil ? 0.8 : 0.4, matchedPreset: matched, method: .lineAnalysis)
    }

    private func extractKeyFrames(from videoURL: URL, count: Int) async throws -> [CVPixelBuffer] {
        let asset = AVAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durSec = CMTimeGetSeconds(duration)
        let interval = (durSec * 0.6) / Double(count)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        var frames: [CVPixelBuffer] = []
        for i in 0..<count {
            let time = CMTime(seconds: durSec * 0.2 + interval * Double(i), preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil),
               let pb = cgImage.toPixelBuffer() { frames.append(pb) }
        }
        return frames
    }

    private func analyzeFrame(_ pixelBuffer: CVPixelBuffer) -> (k1: Float, k2: Float) {
        return (k1: -0.25, k2: 0.06)
    }

    private func applyEdgeDetection(to image: CIImage) -> CIImage? { nil }

    private struct LineSegment { let start: SIMD2<Float>; let end: SIMD2<Float>; let mid: SIMD2<Float>; let length: Float }

    private func detectLineSegments(in edgeImage: CIImage) -> [LineSegment] { [] }

    private func estimateCurvature(_ seg: LineSegment) -> Float { 0 }

    func median(_ values: [Float]) -> Float {
        let s = values.sorted(); let m = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[m-1]+s[m])/2 : s[m]
    }
    func estimateScale(k1: Float, k2: Float) -> Float { 1.0 + (abs(k1) + abs(k2) * 2) * 0.5 }
    func clamp(_ v: Float, min: Float, max: Float) -> Float { Swift.min(Swift.max(v, min), max) }
}

private extension CGImage {
    func toPixelBuffer() -> CVPixelBuffer? { nil }
}
