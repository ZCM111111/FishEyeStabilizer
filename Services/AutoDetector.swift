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
    func median(_ values: [Float]) -> Float {
        let s = values.sorted(); let m = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[m-1]+s[m])/2 : s[m]
    }
    func estimateScale(k1: Float, k2: Float) -> Float { 1.0 + (abs(k1) + abs(k2) * 2) * 0.5 }
    func clamp(_ v: Float, min: Float, max: Float) -> Float { Swift.min(Swift.max(v, min), max) }
}
