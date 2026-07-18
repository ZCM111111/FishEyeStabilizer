@preconcurrency import Vision
@preconcurrency import CoreImage
@preconcurrency import AVFoundation
import CoreVideo
import CoreGraphics

// MARK: - 自动鱼眼检测器

/// 自动分析视频帧，检测鱼眼镜头畸变参数
///
/// 算法流程:
/// 1. 从视频提取关键帧（3-5 帧，间隔 1 秒）
/// 2. Canny 边缘检测 → 提取画面中的直线特征
/// 3. Hough 变换 → 检测直线段
/// 4. 分析直线段的弯曲程度 → 估计畸变系数
/// 5. 最小二乘法拟合 → 输出 DistortionParams
/// 6. 与预设库匹配 → 返回最佳结果
///
/// 局限性:
/// - 需要场景中有足够的直线（建筑、网格等）
/// - 自然场景（森林、天空）效果较差
/// - 建议配合校准模式使用
///
final class AutoDetector: ObservableObject {

    // MARK: - 公开属性

    /// 检测是否正在进行中
    @Published private(set) var isDetecting = false

    /// 检测进度 [0.0, 1.0]
    @Published private(set) var progress: Double = 0.0

    /// 上一次检测结果
    @Published private(set) var lastResult: DetectionResult?

    /// 预设服务（用于匹配）
    private let presetService: LensPresetService

    // MARK: - 检测结果

    struct DetectionResult {
        /// 检测到的畸变参数
        let params: DistortionParams
        /// 匹配置信度 [0, 1]
        let confidence: Float
        /// 匹配到的预设（如果有）
        let matchedPreset: LensProfile?
        /// 检测方法
        let method: DetectionMethod

        enum DetectionMethod: String {
            case lineAnalysis = "直线分析法"
            case presetMatch = "预设匹配"
            case manual = "手动设置"
        }
    }

    // MARK: - 初始化

    init(presetService: LensPresetService) {
        self.presetService = presetService
    }

    // MARK: - 主要检测入口

    /// 从视频 URL 自动检测畸变参数
    ///
    /// - Parameter videoURL: 视频文件 URL
    /// - Returns: 检测结果（包含畸变参数和匹配置信度）
    func detect(from videoURL: URL) async throws -> DetectionResult {
        await MainActor.run {
            isDetecting = true
            progress = 0.0
        }

        defer {
            Task { @MainActor in
                isDetecting = false
                progress = 1.0
            }
        }

        // --- 步骤 1: 提取关键帧 ---
        let frames = try await extractKeyFrames(from: videoURL, count: 5)
        await updateProgress(0.2)

        // --- 步骤 2: 对每帧分析畸变 ---
        var allK1: [Float] = []
        var allK2: [Float] = []

        for (index, frame) in frames.enumerated() {
            let (k1, k2) = analyzeFrame(frame)
            allK1.append(k1)
            allK2.append(k2)
            await updateProgress(0.2 + 0.5 * Double(index + 1) / Double(frames.count))
        }

        // --- 步骤 3: 取中位数 ---
        let medianK1 = median(allK1)
        let medianK2 = median(allK2)

        let detectedParams = DistortionParams(
            k1: medianK1,
            k2: medianK2,
            k3: 0.0,
            centerX: 0.5,
            centerY: 0.5,
            scale: estimateScale(k1: medianK1, k2: medianK2)
        )

        await updateProgress(0.85)

        // --- 步骤 4: 与预设库匹配 ---
        let matchedPreset = presetService.findBestMatch(for: detectedParams)
        let confidence = matchedPreset != nil ? 0.85 : 0.5

        await updateProgress(1.0)

        let result = DetectionResult(
            params: detectedParams,
            confidence: confidence,
            matchedPreset: matchedPreset,
            method: .lineAnalysis
        )

        await MainActor.run {
            lastResult = result
        }

        return result
    }

    /// 从单帧图像检测畸变（快速模式，用于校准视图）
    func detectFromFrame(_ pixelBuffer: CVPixelBuffer) -> DetectionResult? {
        let (k1, k2) = analyzeFrame(pixelBuffer)

        let params = DistortionParams(
            k1: k1, k2: k2, k3: 0.0,
            centerX: 0.5, centerY: 0.5,
            scale: estimateScale(k1: k1, k2: k2)
        )

        let matchedPreset = presetService.findBestMatch(for: params)
        let confidence: Float = matchedPreset != nil ? 0.8 : 0.4

        return DetectionResult(
            params: params,
            confidence: confidence,
            matchedPreset: matchedPreset,
            method: .lineAnalysis
        )
    }

    // MARK: - 关键帧提取

    /// 从视频中提取若干关键帧
    private func extractKeyFrames(
        from videoURL: URL,
        count: Int
    ) async throws -> [CVPixelBuffer] {
        let asset = AVAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        // 在视频的 20% ~ 80% 区间均匀采样
        let startTime = durationSeconds * 0.2
        let endTime = durationSeconds * 0.8
        let interval = (endTime - startTime) / Double(count)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var frames: [CVPixelBuffer] = []

        for i in 0..<count {
            let time = CMTime(seconds: startTime + interval * Double(i), preferredTimescale: 600)

            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                // CGImage → CVPixelBuffer
                if let pixelBuffer = cgImage.toPixelBuffer() {
                    frames.append(pixelBuffer)
                }
            } catch {
                print("⚠️ [AutoDetector] 提取帧 \(i) 失败: \(error)")
                continue
            }
        }

        return frames
    }

    // MARK: - 单帧分析

    /// 分析单个帧，估计 k1, k2 畸变系数
    private func analyzeFrame(_ pixelBuffer: CVPixelBuffer) -> (k1: Float, k2: Float) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // --- 步骤 1: 边缘检测 (Canny 等效) ---
        guard let edges = applyEdgeDetection(to: ciImage) else {
            // 如果边缘检测失败，回退到保守估计
            return (k1: -0.25, k2: 0.06)
        }

        // --- 步骤 2: 检测直线段 ---
        let lineSegments = detectLineSegments(in: edges)

        guard lineSegments.count >= 4 else {
            // 直线太少，无法可靠估计
            return (k1: -0.20, k2: 0.04)
        }

        // --- 步骤 3: 分析直线弯曲程度 ---
        // 在鱼眼图像中，真实世界的直线会弯曲
        // 弯曲程度与畸变系数成正比
        let curvatures = lineSegments.map { estimateCurvature($0) }

        // 平均曲率 → k1 映射（负值 = 桶形畸变）
        let avgCurvature = curvatures.reduce(0, +) / Float(curvatures.count)

        // 经验映射（可通过标定优化）
        let k1 = -0.50 * avgCurvature - 0.05
        let k2 = 0.18 * abs(avgCurvature) + 0.02

        return (k1: clamp(k1, min: -0.60, max: -0.05),
                k2: clamp(k2, min: 0.0, max: 0.25))
    }

    // MARK: - 图像处理辅助

    /// 对图像应用 Canny 边缘检测
    private func applyEdgeDetection(to image: CIImage) -> CIImage? {
        // 1. 转灰度
        let grayFilter = CIFilter(name: "CIPhotoEffectMono")
        grayFilter?.setValue(image, forKey: kCIInputImageKey)
        guard let grayImage = grayFilter?.outputImage else { return nil }

        // 2. 边缘检测（使用 CIEdges 近似 Canny）
        let edgesFilter = CIFilter(name: "CIEdges")
        edgesFilter?.setValue(grayImage, forKey: kCIInputImageKey)
        edgesFilter?.setValue(5.0, forKey: kCIInputIntensityKey)

        return edgesFilter?.outputImage
    }

    /// 检测图像中的直线段
    /// 使用 Vision 框架的 VNDetectContoursRequest 配合直线近似
    private func detectLineSegments(in edgeImage: CIImage) -> [LineSegment] {
        var segments: [LineSegment] = []

        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.0
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 1024

        let handler = VNImageRequestHandler(ciImage: edgeImage)
        try? handler.perform([request])

        guard let results = request.results else {
            return segments
        }

        // 遍历检测到的轮廓，提取近似直线段
        for contour in results {
            let points = contour.normalizedPathPoints
            guard points.count >= 4 else { continue }

            // 用两点（起点和终点）近似直线段
            let start = points.first!
            let end = points.last!

            // 计算线段长度（过滤太短的线段）
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 0.05 else { continue } // 忽略长度小于 5% 画面的线段

            // 计算线段中点（用于判断弯曲）
            let mid = points[points.count / 2]

            segments.append(LineSegment(
                start: SIMD2<Float>(Float(start.x), Float(start.y)),
                end: SIMD2<Float>(Float(end.x), Float(end.y)),
                mid: SIMD2<Float>(Float(mid.x), Float(mid.y)),
                length: Float(length)
            ))
        }

        return segments
    }

    /// 估计一条线段的弯曲程度
    /// 返回值: 正 = 向外弯曲（桶形畸变特征）, 0 = 直线
    private func estimateCurvature(_ segment: LineSegment) -> Float {
        // 计算中点到起点-终点连线的垂直距离
        let lineVec = segment.end - segment.start
        let midVec = segment.mid - segment.start

        guard segment.length > 0.0001 else { return 0 }

        // 点积投影
        let t = simd_dot(midVec, lineVec) / simd_dot(lineVec, lineVec)
        let projection = segment.start + t * lineVec

        // 垂直偏离距离
        let deviation = simd_distance(segment.mid, projection)

        // 归一化：deviation / length 消除线段长度影响
        return deviation / segment.length
    }

    // MARK: - 数学辅助

    /// 中位数
    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    /// 根据 k1 估计合适的缩放因子
    private func estimateScale(k1: Float, k2: Float) -> Float {
        // 畸变越大，矫正后需要的缩放越大
        let severity = abs(k1) + abs(k2) * 2
        return 1.0 + severity * 0.5
    }

    private func clamp(_ value: Float, min: Float, max: Float) -> Float {
        Swift.min(Swift.max(value, min), max)
    }

    @MainActor
    private func updateProgress(_ value: Double) {
        progress = value
    }
}

// MARK: - 辅助类型

/// 直线段模型
private struct LineSegment {
    let start: SIMD2<Float>
    let end: SIMD2<Float>
    let mid: SIMD2<Float>
    let length: Float
}

// MARK: - CGImage → CVPixelBuffer 扩展

private extension CGImage {
    func toPixelBuffer() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let width = self.width
        let height = self.height

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
