@preconcurrency import CoreVideo
import Foundation
import QuartzCore
import simd

/// New scheme-1 visual servo. It does not use the legacy cabinet detector.
/// The valid target is the pair of inner/outer boundaries whose four gaps are
/// close to equal, matching the reference video (75/75/75/75).
final class TwoBoundaryServo {
    enum Phase: Equatable { case searching, tracking, lost }

    struct Result {
        let phase: Phase
        let centerOffset: SIMD2<Float>
        let gapSpread: Float
        let timestamp: TimeInterval
        let summary: String
        var found: Bool { phase == .tracking }
    }

    private struct Frame {
        let buffer: CVPixelBuffer
        let timestamp: TimeInterval
    }

    private struct Luma {
        let width: Int
        let height: Int
        let values: [Float]

        func sample(_ x: Float, _ y: Float) -> Float? {
            guard x >= 0, y >= 0, x < Float(width), y < Float(height) else { return nil }
            let x0 = Int(x), y0 = Int(y)
            let x1 = min(x0 + 1, width - 1)
            let y1 = min(y0 + 1, height - 1)
            let fx = x - Float(x0), fy = y - Float(y0)
            let a = values[y0 * width + x0]
            let b = values[y0 * width + x1]
            let c = values[y1 * width + x0]
            let d = values[y1 * width + x1]
            return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
        }
    }

    private struct Ring {
        let radii: [Float]
        let support: Float
        let mean: Float
    }

    private struct Candidate {
        let center: SIMD2<Float>
        let inner: Ring
        let spread: Float
        let score: Float
    }

    private let queue = DispatchQueue(label: "com.fisheye.two-boundary", qos: .utility)
    private let lock = NSLock()
    private var pending: Frame?
    private var processing = false
    private var enabled = false
    private var phase: Phase = .searching
    private var lastTimestamp: TimeInterval = 0
    private var lastSearch: TimeInterval = -.greatestFiniteMagnitude
    private var misses = 0
    private var center = SIMD2<Float>.zero
    private var velocity = SIMD2<Float>.zero
    private var innerRadius: Float = 0
    private var gapSpread: Float = 1
    private var lumaSize = SIMD2<Float>(256, 144)
    private let angleCount = 40

    var onResult: ((Result) -> Void)?

    func setEnabled(_ value: Bool) {
        queue.sync {
            enabled = value
            if !value { resetState() }
        }
    }

    func submit(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        let frame = Frame(buffer: pixelBuffer,
                          timestamp: timestamp.isFinite ? timestamp : CACurrentMediaTime())
        lock.lock()
        if processing {
            pending = frame
            lock.unlock()
            return
        }
        processing = true
        lock.unlock()
        queue.async { [weak self] in self?.processLoop(first: frame) }
    }

    private func processLoop(first: Frame) {
        var next: Frame? = first
        while let frame = next {
            if let result = process(frame) {
                DispatchQueue.main.async { [weak self] in self?.onResult?(result) }
            }
            lock.lock()
            if let queued = pending {
                pending = nil
                lock.unlock()
                next = queued
            } else {
                processing = false
                lock.unlock()
                next = nil
            }
        }
    }

    private func resetState() {
        phase = .searching
        lastTimestamp = 0
        lastSearch = -.greatestFiniteMagnitude
        misses = 0
        center = .zero
        velocity = .zero
        innerRadius = 0
        gapSpread = 1
    }

    private func process(_ frame: Frame) -> Result? {
        guard enabled, let luma = makeLuma(frame.buffer) else { return nil }
        lumaSize = SIMD2<Float>(Float(luma.width), Float(luma.height))
        let dt = lastTimestamp > 0
            ? min(max(frame.timestamp - lastTimestamp, 1.0 / 120.0), 0.5)
            : 1.0 / 12.0
        lastTimestamp = frame.timestamp
        let interval: TimeInterval = phase == .tracking ? 0.25 : 0.12
        guard frame.timestamp - lastSearch >= interval || dt > 0.12 || misses > 0 else { return nil }
        lastSearch = frame.timestamp

        let predicted = center + velocity * Float(dt)
        if let candidate = search(luma, predicted: predicted),
           phase != .tracking || isConsistent(candidate, predicted: predicted) {
            accept(candidate, dt: dt)
            misses = 0
            return result(at: frame.timestamp)
        }

        misses += 1
        if phase == .tracking, misses <= 5 {
            center = predicted
            return result(at: frame.timestamp, source: "预测")
        }

        phase = .lost
        misses = 0
        return Result(phase: .lost, centerOffset: .zero, gapSpread: gapSpread,
                      timestamp: frame.timestamp, summary: "双边界丢失 · 重新搜索")
    }

    private func search(_ frame: Luma, predicted: SIMD2<Float>) -> Candidate? {
        let short = Float(min(frame.width, frame.height))
        let tracking = phase == .tracking && innerRadius > 1
        let xs: [Float] = tracking ? [-0.10, 0, 0.10] : [0.35, 0.50, 0.65]
        let ys: [Float] = tracking ? [-0.10, 0, 0.10] : [0.35, 0.50, 0.65]
        let radii: [Float] = tracking
            ? [innerRadius * 0.90, innerRadius, innerRadius * 1.10]
            : [short * 0.12, short * 0.18, short * 0.24, short * 0.30, short * 0.36]
        let ratios: [Float] = [1.15, 1.30, 1.48, 1.65]
        var best: Candidate?

        for x in xs {
            for y in ys {
                let c = tracking
                    ? predicted + SIMD2<Float>(x * short, y * short)
                    : SIMD2<Float>(x * Float(frame.width), y * Float(frame.height))
                for expected in radii {
                    guard let inner = ring(frame, center: c, expected: expected,
                                           tolerance: expected * 0.16) else { continue }
                    for ratio in ratios {
                        guard let outer = ring(frame, center: c,
                                               expected: inner.mean * ratio,
                                               tolerance: inner.mean * ratio * 0.12) else { continue }
                        let gaps = [
                            max(outer.radii[0] - inner.radii[0], 0),
                            max(outer.radii[angleCount / 4] - inner.radii[angleCount / 4], 0),
                            max(outer.radii[angleCount / 2] - inner.radii[angleCount / 2], 0),
                            max(outer.radii[angleCount * 3 / 4] - inner.radii[angleCount * 3 / 4], 0)
                        ]
                        guard let low = gaps.min(), let high = gaps.max(), low > 1 else { continue }
                        let spread = high / low
                        let support = min(inner.support, outer.support)
                        let prior = tracking
                            ? max(0, 1 - simd_distance(c, predicted) / (short * 0.30))
                            : 1
                        let score = support * 0.75 + prior * 0.25 - max(0, spread - 1) * 0.9
                        let candidate = Candidate(center: c, inner: inner,
                                                 spread: spread, score: score)
                        if best == nil || candidate.score > best!.score { best = candidate }
                    }
                }
            }
        }
        guard let best, best.score > 0.15, best.inner.support > 0.18 else { return nil }
        return best
    }

    private func ring(_ frame: Luma, center: SIMD2<Float>, expected: Float,
                      tolerance: Float) -> Ring? {
        var radii = [Float](repeating: expected, count: angleCount)
        var support: Float = 0
        for i in 0..<angleCount {
            let angle = Float(i) / Float(angleCount) * 2 * .pi
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            var bestEdge: Float = 0
            var selected = expected
            var radius = max(4, expected - tolerance)
            while radius <= expected + tolerance {
                if let a = frame.sample(center.x + direction.x * (radius - 2), center.y + direction.y * (radius - 2)),
                   let b = frame.sample(center.x + direction.x * (radius + 2), center.y + direction.y * (radius + 2)) {
                    let edge = abs(b - a) / 255
                    if edge > bestEdge { bestEdge = edge; selected = radius }
                }
                radius += max(1, expected * 0.025)
            }
            radii[i] = selected
            if bestEdge > 0.07 { support += 1 }
        }
        support /= Float(angleCount)
        guard support > 0.10 else { return nil }
        return Ring(radii: radii, support: support,
                    mean: radii.reduce(0, +) / Float(angleCount))
    }

    private func isConsistent(_ candidate: Candidate, predicted: SIMD2<Float>) -> Bool {
        simd_distance(candidate.center, predicted) < max(innerRadius * 0.70, 18)
            && candidate.spread <= 1.55
    }

    private func accept(_ candidate: Candidate, dt: TimeInterval) {
        let old = center
        let alpha = min(max(Float(1 - exp(-dt / 0.08)), 0.20), 0.85)
        center += (candidate.center - center) * alpha
        innerRadius = innerRadius > 1
            ? innerRadius + (candidate.inner.mean - innerRadius) * 0.20
            : candidate.inner.mean
        velocity = velocity * 0.70 + ((center - old) / max(Float(dt), 0.001)) * 0.30
        gapSpread = candidate.spread
        phase = .tracking
    }

    private func result(at timestamp: TimeInterval, source: String = "双边界") -> Result {
        let frameCenter = lumaSize * 0.5
        let scale = max(min(lumaSize.x, lumaSize.y) * 0.5, 1)
        let offset = (center - frameCenter) / scale
        let confidence = min(max(1 - (gapSpread - 1) * 2, 0), 1)
        return Result(phase: phase, centerOffset: offset, gapSpread: gapSpread,
                      timestamp: timestamp,
                      summary: String(format: "双边界锁定 · 四边间隙 %.1f%% · %@",
                                      Double(max(0, (gapSpread - 1) * 100)), source))
    }

    private func makeLuma(_ buffer: CVPixelBuffer) -> Luma? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let planar = CVPixelBufferIsPlanar(buffer)
        let bgra = !planar || CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
        let base = bgra ? CVPixelBufferGetBaseAddress(buffer) : CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        let stride = bgra ? CVPixelBufferGetBytesPerRow(buffer) : CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let base, width > 32, height > 32, stride > 0 else { return nil }
        let step = max(1, width / 256)
        let w = width / step, h = height / step
        var data = [Float](repeating: 0, count: w * h)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let row = y * step * stride, col = x * step
            data[y * w + x] = bgra ? Float(bytes[row + col * 4 + 1]) : Float(bytes[row + col])
        }}
        return Luma(width: w, height: h, values: data)
    }
}
