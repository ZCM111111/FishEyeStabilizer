import Foundation
import CoreVideo

final class AutoDetector: ObservableObject {
    struct DetectionResult {
        let params: DistortionParams
        let confidence: Float
        let matchedPreset: LensProfile?
        enum DetectionMethod: String { case lineAnalysis, presetMatch, manual }
        let method: DetectionMethod
    }
    let presetService: LensPresetService
    @Published private(set) var isDetecting = false
    @Published private(set) var progress: Double = 0.0
    @Published private(set) var lastResult: DetectionResult?
    init(presetService: LensPresetService) { self.presetService = presetService }
}
