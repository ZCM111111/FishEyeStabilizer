@preconcurrency import CoreVideo
import CoreGraphics
import Foundation
import Vision
import simd

/// Real-time cabinet lock.
///
/// This is not a per-frame detector and it is not a slow nudge. It tracks the
/// cabinet on every camera frame and reports its position in source pixels, so
/// the renderer can place that exact point at the centre of the output. The
/// result is the reference behaviour: however the phone shakes or turns, the
/// cabinet stays pinned in the middle.
final class CabinetLock {

    struct Target {
        /// Centre in capture-buffer pixels.
        let center: CGPoint
        /// Cabinet screen radius in capture-buffer pixels.
        let radius: CGFloat
        let confidence: Float
        let timestamp: TimeInterval
        var valid: Bool { confidence > 0.05 && radius > 4 }
    }

    private let queue = DispatchQueue(label: "com.fisheye.cabinet-lock", qos: .userInitiated)
    private let stateLock = NSLock()
    private var pendingBuffer: CVPixelBuffer?
    private var pendingTime: TimeInterval = 0
    private var busy = false
    private var enabled = false

    /// Called on the main queue for every processed frame.
    var onTarget: ((Target) -> Void)?

    private var sequence = VNSequenceRequestHandler()
    private var trackRequest: VNTrackObjectRequest?
    private var center = CGPoint.zero
    private var velocity = CGPoint.zero
    private var radius: CGFloat = 0
    private var confidence: Float = 0
    private var lastTimestamp: TimeInterval = 0
    private var lastAcquire: TimeInterval = -.greatestFiniteMagnitude
    private var misses = 0
    private var locked = false

    private let acquireInterval: TimeInterval = 0.20
    private let maxMisses = 6

    // MARK: - Lifecycle

    func setEnabled(_ value: Bool) {
        queue.sync {
            enabled = value
            if !value { resetLocked() }
        }
    }

    func reset() {
        queue.sync { resetLocked() }
    }

    private func resetLocked() {
        trackRequest = nil
        sequence = VNSequenceRequestHandler()
        center = .zero
        velocity = .zero
        radius = 0
        confidence = 0
        lastTimestamp = 0
        lastAcquire = -.greatestFiniteMagnitude
        misses = 0
        locked = false
        stateLock.lock()
        pendingBuffer = nil
        stateLock.unlock()
    }

    // MARK: - Frame input

    /// Keeps only the newest frame: a slow tracker must never make the camera
    /// aim at an outdated picture.
    func submit(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        stateLock.lock()
        pendingBuffer = pixelBuffer
        pendingTime = timestamp
        if busy {
            stateLock.unlock()
            return
        }
        busy = true
        stateLock.unlock()
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            stateLock.lock()
            let buffer = pendingBuffer
            let time = pendingTime
            pendingBuffer = nil
            stateLock.unlock()
            guard let buffer, enabled else {
                stateLock.lock()
                busy = false
                stateLock.unlock()
                return
            }
            if let target = process(buffer: buffer, timestamp: time) {
                DispatchQueue.main.async { [weak self] in self?.onTarget?(target) }
            }
        }
    }

    // MARK: - Per-frame processing

    private func process(buffer: CVPixelBuffer, timestamp: TimeInterval) -> Target? {
        defer { lastTimestamp = timestamp }
        let dt = lastTimestamp > 0
            ? min(max(timestamp - lastTimestamp, 1.0 / 240.0), 0.25)
            : 1.0 / 60.0

        // 1. Track the current request on this exact frame.
        if let tracked = track(request: trackRequest, on: buffer) {
            let predicted = CGPoint(x: center.x + velocity.x * CGFloat(dt),
                                    y: center.y + velocity.y * CGFloat(dt))
            let gate = max(radius * 0.55, 24)
            let moved = hypot(tracked.center.x - predicted.x, tracked.center.y - predicted.y)
            if moved <= gate {
                update(to: tracked.center, radius: tracked.radius,
                       confidence: tracked.confidence, dt: dt)
                misses = 0
                return makeTarget(timestamp: timestamp)
            }
        }

        // 2. Tracking failed on this frame.
        misses += 1

        if locked, misses <= maxMisses {
            // Coast with the last velocity so a brief occlusion does not make
            // the picture jump; the IMU keeps stabilising meanwhile.
            center = CGPoint(x: center.x + velocity.x * CGFloat(dt),
                             y: center.y + velocity.y * CGFloat(dt))
            confidence *= 0.85
            return makeTarget(timestamp: timestamp, coasting: true)
        }

        // 3. Lost: re-acquire, rate limited.
        locked = false
        trackRequest = nil
        confidence = 0
        guard timestamp - lastAcquire >= acquireInterval,
              let acquired = acquire(in: buffer) else {
            return nil
        }
        lastAcquire = timestamp
        center = acquired.center
        radius = acquired.radius
        velocity = .zero
        confidence = acquired.confidence
        misses = 0
        locked = true
        reanchor(size: CGSize(width: CVPixelBufferGetWidth(buffer),
                              height: CVPixelBufferGetHeight(buffer)))
        return makeTarget(timestamp: timestamp)
    }

    private func update(to newCenter: CGPoint, radius newRadius: CGFloat,
                        confidence newConfidence: Float, dt: TimeInterval) {
        // One smoothing constant for both position and size: short enough that
        // the lock feels instantaneous, long enough to swallow tracker noise.
        let positionAlpha = CGFloat(1 - exp(-dt / 0.045))
        let radiusAlpha = CGFloat(1 - exp(-dt / 0.12))
        let old = center
        let oldRadius = radius > 4 ? radius : newRadius
        center = CGPoint(x: center.x + (newCenter.x - center.x) * positionAlpha,
                         y: center.y + (newCenter.y - center.y) * positionAlpha)
        radius = oldRadius + (newRadius - oldRadius) * radiusAlpha
        if dt > 0 {
            let measured = CGPoint(x: (center.x - old.x) / CGFloat(dt),
                                   y: (center.y - old.y) / CGFloat(dt))
            velocity = CGPoint(x: velocity.x * 0.8 + measured.x * 0.2,
                               y: velocity.y * 0.8 + measured.y * 0.2)
        }
        confidence = min(max(confidence * 0.6 + newConfidence * 0.4, 0), 1)
        locked = true
    }

    private func makeTarget(timestamp: TimeInterval, coasting: Bool = false) -> Target {
        Target(center: center,
               radius: radius,
               confidence: coasting ? confidence * 0.6 : confidence,
               timestamp: timestamp)
    }

    // MARK: - Vision tracking

    private struct Tracked {
        let center: CGPoint
        let radius: CGFloat
        let confidence: Float
    }

    private func track(request: VNTrackObjectRequest?, on buffer: CVPixelBuffer) -> Tracked? {
        guard let request else { return nil }
        do {
            try sequence.perform([request], on: buffer, orientation: .up)
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNDetectedObjectObservation else {
            return nil
        }
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        let box = observation.boundingBox
        let center = CGPoint(x: box.midX * width, y: (1 - box.midY) * height)
        let side = min(box.width * width, box.height * height)
        let confidence = observation.confidence.isFinite
            ? Float(observation.confidence) : 0.5
        // Re-seed the request from this frame's result, which is how Vision's
        // sequence tracker is meant to be advanced.
        trackRequest = VNTrackObjectRequest(detectedObjectObservation: observation)
        trackRequest?.trackingLevel = .accurate
        return Tracked(center: center,
                       radius: max(side * 0.5 / 1.25, 4),
                       confidence: confidence)
    }

    private func reanchor(size: CGSize) {
        guard size.width > 1, size.height > 1, radius > 4 else { return }
        let boxSide = min(max(radius * 2 * 1.35, 24), min(size.width, size.height))
        let x = min(max(center.x - boxSide * 0.5, 0), size.width - boxSide)
        let y = min(max(center.y - boxSide * 0.5, 0), size.height - boxSide)
        let observation = VNDetectedObjectObservation(
            boundingBox: CGRect(x: x / size.width,
                                y: 1 - (y + boxSide) / size.height,
                                width: boxSide / size.width,
                                height: boxSide / size.height))
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        trackRequest = request
        sequence = VNSequenceRequestHandler()
    }

    // MARK: - Acquisition

    /// Cheap acquisition: the lit button ring is the brightest large structure
    /// in the frame, and its centroid is the cabinet centre. This is only run
    /// when the lock is lost, never as the steady-state driver.
    private func acquire(in buffer: CVPixelBuffer) -> (center: CGPoint, radius: CGFloat, confidence: Float)? {
        guard let luma = Self.downsampleLuma(buffer, targetWidth: 240) else { return nil }
        let width = luma.width
        let height = luma.height
        let count = width * height
        guard count > 64 else { return nil }

        var histogram = [Int](repeating: 0, count: 256)
        for value in luma.values { histogram[min(max(Int(value), 0), 255)] += 1 }
        var threshold = 255
        var accumulated = 0
        let wanted = max(count / 40, 1)
        for level in stride(from: 255, through: 0, by: -1) {
            accumulated += histogram[level]
            if accumulated >= wanted { threshold = level; break }
        }
        guard threshold > 60 else { return nil }

        var visited = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        var blob: [Int] = []
        var best: (score: Float, cx: Float, cy: Float, r: Float)?

        for start in 0..<count where !visited[start] && luma.values[start] >= Float(threshold) {
            blob.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            while let index = stack.popLast() {
                blob.append(index)
                let x = index % width
                let y = index / width
                if x > 0 { push(index - 1, &visited, &stack, luma, threshold) }
                if x < width - 1 { push(index + 1, &visited, &stack, luma, threshold) }
                if y > 0 { push(index - width, &visited, &stack, luma, threshold) }
                if y < height - 1 { push(index + width, &visited, &stack, luma, threshold) }
            }
            let pixels = blob.count
            guard pixels >= 40 else { continue }

            var sumX: Float = 0, sumY: Float = 0
            for index in blob {
                sumX += Float(index % width)
                sumY += Float(index / width)
            }
            let cx = sumX / Float(pixels)
            let cy = sumY / Float(pixels)

            var sumR: Float = 0
            for index in blob {
                let dx = Float(index % width) - cx
                let dy = Float(index / width) - cy
                sumR += (dx * dx + dy * dy).squareRoot()
            }
            let meanR = sumR / Float(pixels)

            var sumDeviation: Float = 0
            for index in blob {
                let dx = Float(index % width) - cx
                let dy = Float(index / width) - cy
                let d = (dx * dx + dy * dy).squareRoot()
                sumDeviation += abs(d - meanR)
            }
            let thickness = (sumDeviation / Float(pixels)) / max(meanR, 1)

            // A lit ring is thin for its radius; a filled blob is not.
            guard meanR > Float(min(width, height)) * 0.06,
                  meanR < Float(min(width, height)) * 0.55,
                  thickness < 0.42 else { continue }
            let score = Float(pixels) * (1 - thickness)
            if best == nil || score > best!.score {
                best = (score, cx, cy, meanR)
            }
        }
        guard let best else { return nil }

        let scaleX = CGFloat(CVPixelBufferGetWidth(buffer)) / CGFloat(width)
        let scaleY = CGFloat(CVPixelBufferGetHeight(buffer)) / CGFloat(height)
        let centre = CGPoint(x: CGFloat(best.cx) * scaleX, y: CGFloat(best.cy) * scaleY)
        let radiusPixels = CGFloat(best.r) * (scaleX + scaleY) * 0.5
        let confidence = min(max(Float(best.score) / 400, 0.2), 1)
        return (centre, radiusPixels * 1.15, confidence)
    }
    private func push(_ index: Int, _ visited: inout [Bool],
                      _ stack: inout [Int], _ luma: (width: Int, height: Int, values: [Float]),
                      _ threshold: Int) {
        if !visited[index], luma.values[index] >= Float(threshold) {
            visited[index] = true
            stack.append(index)
        }
    }

    // MARK: - Luma

    private static func downsampleLuma(_ buffer: CVPixelBuffer,
                                       targetWidth: Int) -> (width: Int, height: Int, values: [Float])? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        let isBGRA = !planar || CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
        let sourceWidth = isBGRA ? CVPixelBufferGetWidth(buffer) : CVPixelBufferGetWidthOfPlane(buffer, 0)
        let sourceHeight = isBGRA ? CVPixelBufferGetHeight(buffer) : CVPixelBufferGetHeightOfPlane(buffer, 0)
        let base = isBGRA ? CVPixelBufferGetBaseAddress(buffer)
            : CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        let stride = isBGRA ? CVPixelBufferGetBytesPerRow(buffer)
            : CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let base, sourceWidth > 32, sourceHeight > 32, stride > 0 else { return nil }
        let step = max(1, sourceWidth / max(targetWidth, 32))
        let width = sourceWidth / step
        let height = sourceHeight / step
        var values = [Float](repeating: 0, count: width * height)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = y * step * stride
            for x in 0..<width {
                let column = x * step
                values[y * width + x] = isBGRA
                    ? Float(bytes[row + column * 4 + 1])
                    : Float(bytes[row + column])
            }
        }
        return (width, height, values)
    }
}
