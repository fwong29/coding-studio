import Accelerate
import CoreImage
import CoreVideo
import Foundation

/// Computes luminance/colour statistics for a frame.
///
/// Both the live coach and the editor need the same numbers, so the maths
/// lives in one place with two front doors: one that samples a camera
/// `CVPixelBuffer` directly, and one that goes through Core Image for a
/// captured still.
///
/// Note on gamma: camera BGRA and the bitmaps we render are sRGB-encoded, so
/// the luma below is perceptual rather than linear. That is what we want —
/// exposure and clipping decisions should track how bright something *looks*.
enum ToneAnalyzer {

    /// Resolution of the sampling grid. 64x64 is plenty for percentiles and
    /// cheap enough to run on every analysed frame.
    private static let gridSide = 64

    // MARK: - Live camera frames

    /// Samples a BGRA pixel buffer on the CPU. Assumes the buffer is already
    /// locked by the caller.
    static func analyze(pixelBuffer: CVPixelBuffer) -> (tone: ToneSignal, clutter: CGFloat, sharpness: CGFloat) {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return (ToneSignal(), 0, 1)
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 8, height > 8 else { return (ToneSignal(), 0, 1) }

        let pointer = base.assumingMemoryBound(to: UInt8.self)
        let side = gridSide
        var samples = [Sample](repeating: Sample(), count: side * side)

        for gy in 0..<side {
            // +0.5 samples the middle of each cell rather than its corner.
            let y = min(height - 1, Int((CGFloat(gy) + 0.5) / CGFloat(side) * CGFloat(height)))
            let row = pointer.advanced(by: y * bytesPerRow)
            for gx in 0..<side {
                let x = min(width - 1, Int((CGFloat(gx) + 0.5) / CGFloat(side) * CGFloat(width)))
                let px = row.advanced(by: x * 4)
                // BGRA byte order.
                samples[gy * side + gx] = Sample(r: Float(px[2]) / 255,
                                                 g: Float(px[1]) / 255,
                                                 b: Float(px[0]) / 255)
            }
        }

        let tone = statistics(from: samples)
        let clutter = borderEnergy(samples, side: side)
        let sharp = centreSharpness(pointer: pointer,
                                    bytesPerRow: bytesPerRow,
                                    width: width,
                                    height: height)
        return (tone, clutter, sharp)
    }

    // MARK: - Captured stills

    /// Renders a small bitmap through Core Image, then runs the same maths.
    static func analyze(image: CIImage, context: CIContext) -> ToneSignal {
        let side = gridSide
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, extent.isInfinite == false else {
            return ToneSignal()
        }

        // Scale the whole frame down into a `side` x `side` box. Squashing the
        // aspect ratio is fine: we only want a population of pixel values.
        let scaleX = CGFloat(side) / extent.width
        let scaleY = CGFloat(side) / extent.height
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            context.render(scaled,
                           toBitmap: baseAddress,
                           rowBytes: side * 4,
                           bounds: CGRect(x: 0, y: 0, width: side, height: side),
                           format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }

        var samples = [Sample](repeating: Sample(), count: side * side)
        for i in 0..<(side * side) {
            samples[i] = Sample(r: Float(bytes[i * 4 + 0]) / 255,
                                g: Float(bytes[i * 4 + 1]) / 255,
                                b: Float(bytes[i * 4 + 2]) / 255)
        }
        return statistics(from: samples)
    }

    /// Mean luma of one region, used to decide whether a subject is sitting in
    /// shadow against a bright background.
    static func meanLuma(image: CIImage, region: CGRect, context: CIContext) -> CGFloat? {
        let cropped = image.cropped(to: region)
        guard cropped.extent.width >= 2, cropped.extent.height >= 2 else { return nil }
        return CGFloat(statistics(from: samples(of: cropped, context: context, side: 16)).meanLuma)
    }

    private static func samples(of image: CIImage, context: CIContext, side: Int) -> [Sample] {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return [] }
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(side) / extent.width,
                                               y: CGFloat(side) / extent.height))
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            context.render(scaled,
                           toBitmap: baseAddress,
                           rowBytes: side * 4,
                           bounds: CGRect(x: 0, y: 0, width: side, height: side),
                           format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return (0..<(side * side)).map {
            Sample(r: Float(bytes[$0 * 4]) / 255,
                   g: Float(bytes[$0 * 4 + 1]) / 255,
                   b: Float(bytes[$0 * 4 + 2]) / 255)
        }
    }

    // MARK: - Core maths

    private struct Sample {
        var r: Float = 0
        var g: Float = 0
        var b: Float = 0
        /// Rec.709 luma weights.
        var luma: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    }

    private static func statistics(from samples: [Sample]) -> ToneSignal {
        var tone = ToneSignal()
        guard !samples.isEmpty else { return tone }

        var lumas = samples.map(\.luma)
        var sumR: Float = 0, sumG: Float = 0, sumB: Float = 0
        var sumSaturation: Float = 0

        for s in samples {
            sumR += s.r; sumG += s.g; sumB += s.b
            let maxC = max(s.r, max(s.g, s.b))
            let minC = min(s.r, min(s.g, s.b))
            // HSV-style saturation, guarded against black pixels.
            sumSaturation += maxC > 0.02 ? (maxC - minC) / maxC : 0
        }

        let n = Float(samples.count)
        tone.meanRGB = (CGFloat(sumR / n), CGFloat(sumG / n), CGFloat(sumB / n))
        tone.saturation = CGFloat(sumSaturation / n)
        tone.meanLuma = CGFloat(lumas.reduce(0, +) / n)

        // Percentiles need the samples in order.
        lumas.sort()
        func percentile(_ p: Float) -> CGFloat {
            let idx = Int(clamp(p, 0, 1) * Float(lumas.count - 1))
            return CGFloat(lumas[idx])
        }
        tone.p5Luma = percentile(0.05)
        tone.medianLuma = percentile(0.5)
        tone.p95Luma = percentile(0.95)
        tone.contrast = tone.p95Luma - tone.p5Luma

        // Clipping. The thresholds are deliberately not 0 and 1: detail is
        // already unrecoverable well before the extremes.
        let shadowCount = lumas.prefix { $0 < 0.02 }.count
        let highlightCount = lumas.reversed().prefix { $0 > 0.98 }.count
        tone.shadowClipped = CGFloat(shadowCount) / CGFloat(lumas.count)
        tone.highlightClipped = CGFloat(highlightCount) / CGFloat(lumas.count)

        // White-patch estimate: average colour of the brightest 5%, which is
        // the best guess at what the light source actually looks like.
        let cutoff = percentile(0.95)
        var hr: Float = 0, hg: Float = 0, hb: Float = 0, hc: Float = 0
        for s in samples where CGFloat(s.luma) >= cutoff {
            hr += s.r; hg += s.g; hb += s.b; hc += 1
        }
        if hc > 0 {
            tone.highlightRGB = (CGFloat(hr / hc), CGFloat(hg / hc), CGFloat(hb / hc))
        } else {
            tone.highlightRGB = tone.meanRGB
        }
        return tone
    }

    /// Gradient energy in the outer eighth of the frame.
    ///
    /// A busy border pulls the eye off the subject and is the single easiest
    /// composition problem to fix by taking one step sideways, so it is worth
    /// measuring even though the signal is crude.
    private static func borderEnergy(_ samples: [Sample], side: Int) -> CGFloat {
        guard samples.count == side * side else { return 0 }
        let margin = max(1, side / 8)
        var energy: Float = 0
        var count: Float = 0

        for y in 0..<side {
            for x in 0..<side {
                let isBorder = x < margin || x >= side - margin || y < margin || y >= side - margin
                guard isBorder, x + 1 < side, y + 1 < side else { continue }
                let here = samples[y * side + x].luma
                let right = samples[y * side + x + 1].luma
                let down = samples[(y + 1) * side + x].luma
                energy += abs(here - right) + abs(here - down)
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        // 0.25 average gradient is already a very busy edge.
        return clamp(CGFloat(energy / count) / 0.25, 0, 1)
    }

    /// Laplacian variance over a native-resolution window at the centre.
    ///
    /// Sampled at full resolution on purpose: the downsampled grid has no
    /// high-frequency detail left, so it cannot tell a sharp frame from a
    /// blurred one.
    private static func centreSharpness(pointer: UnsafePointer<UInt8>,
                                        bytesPerRow: Int,
                                        width: Int,
                                        height: Int) -> CGFloat {
        let window = 96
        guard width > window + 2, height > window + 2 else { return 1 }
        let startX = (width - window) / 2
        let startY = (height - window) / 2

        var values = [Float](repeating: 0, count: window * window)
        for y in 0..<window {
            let row = pointer.advanced(by: (startY + y) * bytesPerRow)
            for x in 0..<window {
                let px = row.advanced(by: (startX + x) * 4)
                values[y * window + x] = 0.2126 * Float(px[2]) / 255
                    + 0.7152 * Float(px[1]) / 255
                    + 0.0722 * Float(px[0]) / 255
            }
        }

        var sum: Float = 0
        var sumSq: Float = 0
        var count: Float = 0
        for y in 1..<(window - 1) {
            for x in 1..<(window - 1) {
                let i = y * window + x
                let laplacian = 4 * values[i]
                    - values[i - 1] - values[i + 1]
                    - values[i - window] - values[i + window]
                sum += laplacian
                sumSq += laplacian * laplacian
                count += 1
            }
        }
        guard count > 1 else { return 1 }
        let mean = sum / count
        let variance = max(0, sumSq / count - mean * mean)
        // Empirically a focused, textured frame lands well above 0.0015.
        return clamp(CGFloat(variance) / 0.0015, 0, 1)
    }
}
