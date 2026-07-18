import Foundation
@preconcurrency import CoreVideo
@preconcurrency import Vision

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

    init(presetService: LensPresetService) { self.presetService = presetService }

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
        await updateProgress(1.0)
        let result = DetectionResult(params: params, confidence: matched != nil ? 0.85 : 0.5, matchedPreset: matched, method: .lineAnalysis)
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
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let edges = applyEdgeDetection(to: ciImage) else { return (k1: -0.25, k2: 0.06) }
        let segments = detectLineSegments(in: edges)
        guard segments.count >= 4 else { return (k1: -0.20, k2: 0.04) }
        let curvatures = segments.map { estimateCurvature($0) }
        let avgCurvature = curvatures.reduce(0, +) / Float(curvatures.count)
        return (k1: clamp(-0.50 * avgCurvature - 0.05, min: -0.60, max: -0.05),
                k2: clamp(0.18 * abs(avgCurvature) + 0.02, min: 0.0, max: 0.25))
    }

    private func applyEdgeDetection(to image: CIImage) -> CIImage? {
        let gray = CIFilter(name: "CIPhotoEffectMono"); gray?.setValue(image, forKey: kCIInputImageKey)
        guard let grayImg = gray?.outputImage else { return nil }
        let edges = CIFilter(name: "CIEdges"); edges?.setValue(grayImg, forKey: kCIInputImageKey)
        edges?.setValue(5.0, forKey: kCIInputIntensityKey)
        return edges?.outputImage
    }

    private struct LineSegment { let start: SIMD2<Float>; let end: SIMD2<Float>; let mid: SIMD2<Float>; let length: Float }

    private func detectLineSegments(in edgeImage: CIImage) -> [LineSegment] {
        var segments: [LineSegment] = []
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = true; request.maximumImageDimension = 1024
        try? VNImageRequestHandler(ciImage: edgeImage).perform([request])
        guard let results = request.results else { return segments }
        for observation in results {
            guard let contour = observation.topLevelContours.first else { continue }
            let points = contour.normalizedPathPoints
            guard points.count >= 4 else { continue }
            let start = points.first!, end = points.last!
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 0.05 else { continue }
            let mid = points[points.count / 2]
            segments.append(LineSegment(start: SIMD2<Float>(Float(start.x), Float(start.y)), end: SIMD2<Float>(Float(end.x), Float(end.y)), mid: SIMD2<Float>(Float(mid.x), Float(mid.y)), length: Float(length)))
        }
        return segments
    }

    private func estimateCurvature(_ seg: LineSegment) -> Float {
        let lineVec = seg.end - seg.start, midVec = seg.mid - seg.start
        guard seg.length > 0.0001 else { return 0 }
        let t = simd_dot(midVec, lineVec) / simd_dot(lineVec, lineVec)
        return simd_distance(seg.mid, seg.start + t * lineVec) / seg.length
    }

    func median(_ values: [Float]) -> Float {
        let s = values.sorted(); let m = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[m-1]+s[m])/2 : s[m]
    }
    func estimateScale(k1: Float, k2: Float) -> Float { 1.0 + (abs(k1) + abs(k2) * 2) * 0.5 }
    func clamp(_ v: Float, min: Float, max: Float) -> Float { Swift.min(Swift.max(v, min), max) }
}

private extension CGImage {
    func toPixelBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let w = width, h = height
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buffer
    }
}
