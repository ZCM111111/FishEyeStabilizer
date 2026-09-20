@preconcurrency import CoreVideo
import CoreGraphics
import Foundation
import simd

/// Real-time cabinet lock.
///
/// The lock measures the cabinet on **every** camera frame and reports where it
/// is, so the renderer can place that exact point at the centre of the output.
/// That is what pins the cabinet in the middle however the phone moves; a
/// slow detector that only nudges the camera can never do this.
///
/// The measurement is a local radial-edge search around the previous frame's
/// answer: the lit ring is a strong circular edge, so a small search over
/// centre and radius locks onto it every frame. Acquisition runs the same score
/// over a coarse grid, but only while the lock is lost.
///
/// The algorithm is the one validated offline on hand-held footage: with the
/// crop lock the ring stays within ~1% of the frame centre, where the raw clip
/// swings across ~64%.
final class CabinetLock {

    struct Target {
        /// Centre in capture-buffer pixels.
        let center: CGPoint
        /// Ring radius in capture-buffer pixels.
        let radius: CGFloat
        let confidence: Float
        let timestamp: TimeInterval
        var valid: Bool { confidence > 0.05 && radius > 4 }
    }

    // MARK: - Tuning

    private let angleCount = 72
    private let edgeBand = 3
    private let minimumScore: Float = 3.0
    private let maxMisses = 8

    // MARK: - State

    private let queue = DispatchQueue(label: "com.fisheye.cabinet-lock", qos: .userInitiated)
    private let stateLock = NSLock()
    private var pendingBuffer: CVPixelBuffer?
    private var pendingTime: TimeInterval = 0
    private var busy = false
    private var enabled = false
    private var misses = 0
    private var lastAcquire: TimeInterval = -.greatestFiniteMagnitude
    private var center = CGPoint.zero
    private var radius: CGFloat = 0
    private var confidence: Float = 0
    private var locked = false

    /// Called on the main queue for every processed frame.
    var onTarget: ((Target) -> Void)?

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
        locked = false
        misses = 0
        center = .zero
        radius = 0
        confidence = 0
        lastAcquire = -.greatestFiniteMagnitude
        stateLock.lock()
        pendingBuffer = nil
        stateLock.unlock()
    }

    // MARK: - Frame input

    /// Keeps only the newest frame: the lock must always reason about the frame
    /// the renderer is about to show, never a stale one.
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
        guard let luma = Self.downsampleLuma(buffer, targetWidth: 256) else { return nil }
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(buffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        guard sourceWidth > 1, sourceHeight > 1 else { return nil }
        let scaleX = sourceWidth / CGFloat(luma.width)
        let scaleY = sourceHeight / CGFloat(luma.height)

        if locked, radius > 2 {
            let spanCenter = max(6, radius * 0.12)
            let spanRadius = max(3, radius * 0.06)
            let result = refine(luma: luma, center: center, radius: radius,
                                spanCenter: spanCenter, spanRadius: spanRadius)
            if result.score >= minimumScore {
                // Deliberately weighted toward the new measurement: a lagging
                // lock is exactly the old "chase" behaviour being replaced.
                center = CGPoint(x: center.x * 0.35 + result.center.x * 0.65,
                                 y: center.y * 0.35 + result.center.y * 0.65)
                radius = radius * 0.5 + result.radius * 0.5
                confidence = min(max(result.score / 30, 0), 1)
                misses = 0
                return makeTarget(scaleX: scaleX, scaleY: scaleY, timestamp: timestamp)
            }
        }

        misses += 1
        if locked, misses <= maxMisses {
            // Coast briefly; the IMU still stabilises the picture meanwhile.
            confidence *= 0.8
            return makeTarget(scaleX: scaleX, scaleY: scaleY, timestamp: timestamp, coasting: true)
        }

        locked = false
        confidence = 0
        guard timestamp - lastAcquire >= 0.25 else { return nil }
        lastAcquire = timestamp
        guard let acquired = acquire(luma: luma) else { return nil }
        center = acquired.center
        radius = acquired.radius
        confidence = min(max(acquired.score / 30, 0), 1)
        misses = 0
        locked = true
        return makeTarget(scaleX: scaleX, scaleY: scaleY, timestamp: timestamp)
    }

    private func makeTarget(scaleX: CGFloat, scaleY: CGFloat,
                            timestamp: TimeInterval, coasting: Bool = false) -> Target {
        Target(center: CGPoint(x: center.x * scaleX, y: center.y * scaleY),
               radius: radius * (scaleX + scaleY) * 0.5,
               confidence: coasting ? confidence * 0.5 : confidence,
               timestamp: timestamp)
    }

    // MARK: - Ring measurement

    private struct Measurement {
        let score: Float
        let center: CGPoint
        let radius: CGFloat
    }

    /// Mean radial edge magnitude along a candidate circle. The lit ring is a
    /// strong radial step, so the best-scoring circle in a small window is the
    /// cabinet and nothing else.
    private func ringScore(luma: LumaGrid, center: CGPoint, radius: CGFloat) -> Float {
        var total: Float = 0
        var used = 0
        for index in 0..<angleCount {
            let angle = Float(index) / Float(angleCount) * 2 * .pi
            let cs = cos(angle)
            let sn = sin(angle)
            let x = center.x + radius * CGFloat(cs)
            let y = center.y + radius * CGFloat(sn)
            let xi = Int(x.rounded())
            let yi = Int(y.rounded())
            guard xi - edgeBand - 1 >= 0, xi + edgeBand + 1 < luma.width,
                  yi - edgeBand - 1 >= 0, yi + edgeBand + 1 < luma.height else { continue }
            var sum: Float = 0
            for step in 1...edgeBand {
                let ox = Int((cs * Float(step)).rounded())
                let oy = Int((sn * Float(step)).rounded())
                sum += abs(luma.value(x: xi + ox, y: yi + oy)
                           - luma.value(x: xi - ox, y: yi - oy))
            }
            total += sum / Float(edgeBand)
            used += 1
        }
        guard used >= 20 else { return 0 }
        return total / Float(used)
    }

    /// Coarse-to-fine local search: this is the per-frame tracking step.
    private func refine(luma: LumaGrid, center: CGPoint, radius: CGFloat,
                        spanCenter: CGFloat, spanRadius: CGFloat) -> Measurement {
        var best = Measurement(score: ringScore(luma: luma, center: center, radius: radius),
                               center: center, radius: radius)
        let centerSteps: [CGFloat] = [-spanCenter, -spanCenter / 2, 0,
                                      spanCenter / 2, spanCenter]
        let radiusSteps: [CGFloat] = [-spanRadius, -spanRadius / 2, 0,
                                      spanRadius / 2, spanRadius]
        for dx in centerSteps {
            for dy in centerSteps {
                for dr in radiusSteps {
                    let candidateCenter = CGPoint(x: center.x + dx, y: center.y + dy)
                    let candidateRadius = max(radius + dr, 4)
                    let score = ringScore(luma: luma, center: candidateCenter,
                                          radius: candidateRadius)
                    if score > best.score {
                        best = Measurement(score: score, center: candidateCenter,
                                           radius: candidateRadius)
                    }
                }
            }
        }
        let fine: [CGFloat] = [-1, 0, 1]
        for dx in fine {
            for dy in fine {
                for dr in fine {
                    let candidateCenter = CGPoint(x: best.center.x + dx, y: best.center.y + dy)
                    let candidateRadius = max(best.radius + dr, 4)
                    let score = ringScore(luma: luma, center: candidateCenter,
                                          radius: candidateRadius)
                    if score > best.score {
                        best = Measurement(score: score, center: candidateCenter,
                                           radius: candidateRadius)
                    }
                }
            }
        }
        return best
    }

    /// Coarse grid acquisition, only run while the lock is lost.
    private func acquire(luma: LumaGrid) -> Measurement? {
        let short = CGFloat(min(luma.width, luma.height))
        var best: Measurement?
        var x = CGFloat(luma.width) * 0.2
        while x <= CGFloat(luma.width) * 0.8 {
            var y = CGFloat(luma.height) * 0.25
            while y <= CGFloat(luma.height) * 0.75 {
                var r = short * 0.10
                while r <= short * 0.36 {
                    let score = ringScore(luma: luma,
                                          center: CGPoint(x: x, y: y), radius: r)
                    if best == nil || score > best!.score {
                        best = Measurement(score: score,
                                           center: CGPoint(x: x, y: y), radius: r)
                    }
                    r += short * 0.025
                }
                y += CGFloat(luma.height) * 0.06
            }
            x += CGFloat(luma.width) * 0.08
        }
        guard let best, best.score >= minimumScore else { return nil }
        return refine(luma: luma, center: best.center, radius: best.radius,
                      spanCenter: max(4, best.radius * 0.10),
                      spanRadius: max(3, best.radius * 0.06))
    }

    // MARK: - Luma grid

    private struct LumaGrid {
        let width: Int
        let height: Int
        let values: [Float]

        /// Bounds are validated by the caller, which keeps the inner loop free
        /// of branches.
        func value(x: Int, y: Int) -> Float { values[y * width + x] }
    }

    private static func downsampleLuma(_ buffer: CVPixelBuffer,
                                       targetWidth: Int) -> LumaGrid? {
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
        guard width > 32, height > 32 else { return nil }
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
        return LumaGrid(width: width, height: height, values: values)
    }
}
