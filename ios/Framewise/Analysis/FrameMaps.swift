import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Low-resolution maps of the frame, in frame orientation, with integral
/// images so any rectangle can be scored in constant time.
///
/// This is what lets the app search the frame for the best-looking rectangle
/// rather than deriving one from a single detected subject. A few hundred
/// candidate crops get scored per pass, and without integral images that would
/// mean re-summing overlapping regions hundreds of times.
struct FrameMaps {

    /// Grid resolution. Normalized coordinates are uniform in both axes, so a
    /// square grid keeps the rectangle maths simple; each cell just covers a
    /// 3:4-shaped patch of pixels.
    static let side = 32

    /// Visual attention, 0...1.
    private(set) var saliency: [Float]
    /// Perceptual brightness, 0...1.
    private(set) var luma: [Float]
    /// Local gradient magnitude — texture, edges, busyness.
    private(set) var detail: [Float]

    private var saliencyIntegral: [Float]
    private var lumaIntegral: [Float]
    private var detailIntegral: [Float]
    /// Integral of a clipped-pixel indicator, for penalising blown regions.
    private var clippedIntegral: [Float]

    private let side = FrameMaps.side

    // MARK: - Building

    /// Samples the camera buffer and Vision's saliency map into frame space.
    ///
    /// The camera buffer is landscape-native while the frame is portrait, so
    /// every sample is rotated on the way in:
    ///   bufferX = frameY,  bufferY = 1 - frameX
    init(pixelBuffer: CVPixelBuffer, saliency saliencyObservation: VNSaliencyImageObservation?) {
        let n = FrameMaps.side
        var lumaGrid = [Float](repeating: 0.5, count: n * n)
        var detailGrid = [Float](repeating: 0, count: n * n)
        var clippedGrid = [Float](repeating: 0, count: n * n)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let pointer = base.assumingMemoryBound(to: UInt8.self)

            for fy in 0..<n {
                for fx in 0..<n {
                    // Centre of this cell in frame space.
                    let nx = (Float(fx) + 0.5) / Float(n)
                    let ny = (Float(fy) + 0.5) / Float(n)
                    let bx = min(width - 1, max(0, Int(ny * Float(width - 1))))
                    let by = min(height - 1, max(0, Int((1 - nx) * Float(height - 1))))
                    let px = pointer.advanced(by: by * rowBytes + bx * 4)
                    // BGRA
                    let value = 0.2126 * Float(px[2]) / 255
                        + 0.7152 * Float(px[1]) / 255
                        + 0.0722 * Float(px[0]) / 255
                    lumaGrid[fy * n + fx] = value
                    clippedGrid[fy * n + fx] = (value > 0.97 || value < 0.02) ? 1 : 0
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        // Detail: gradient magnitude on the luma grid.
        for y in 0..<n {
            for x in 0..<n {
                let here = lumaGrid[y * n + x]
                let right = lumaGrid[y * n + min(x + 1, n - 1)]
                let down = lumaGrid[min(y + 1, n - 1) * n + x]
                detailGrid[y * n + x] = abs(here - right) + abs(here - down)
            }
        }

        self.luma = lumaGrid
        self.detail = detailGrid
        self.saliency = FrameMaps.resampleSaliency(saliencyObservation, side: n)

        self.lumaIntegral = FrameMaps.integral(of: lumaGrid, side: n)
        self.detailIntegral = FrameMaps.integral(of: detailGrid, side: n)
        self.clippedIntegral = FrameMaps.integral(of: clippedGrid, side: n)
        self.saliencyIntegral = FrameMaps.integral(of: self.saliency, side: n)
    }

    /// Reads Vision's saliency heat map into a frame-oriented grid.
    ///
    /// Vision reports in the upright image's space with a bottom-left origin,
    /// so only the vertical axis needs flipping here — the rotation from the
    /// camera buffer was already applied before Vision saw it.
    private static func resampleSaliency(_ observation: VNSaliencyImageObservation?,
                                         side n: Int) -> [Float] {
        var grid = [Float](repeating: 0, count: n * n)
        guard let observation else { return grid }

        let buffer = observation.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float
        else { return grid }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 1, height > 1 else { return grid }

        for fy in 0..<n {
            for fx in 0..<n {
                let nx = (Float(fx) + 0.5) / Float(n)
                let ny = (Float(fy) + 0.5) / Float(n)
                let sx = min(width - 1, max(0, Int(nx * Float(width - 1))))
                let sy = min(height - 1, max(0, Int((1 - ny) * Float(height - 1))))
                let row = base.advanced(by: sy * rowBytes).assumingMemoryBound(to: Float.self)
                grid[fy * n + fx] = max(0, row[sx])
            }
        }

        // Normalise BOTH ends, not just the top.
        //
        // Saliency is relative within a frame, and these maps carry a
        // substantial non-zero floor across the background. Scaling only by
        // the peak leaves that floor intact, and because the background is
        // most of the picture it then dominates the frame's total attention —
        // which made "how much of the interest does this crop keep?"
        // meaningless, since every crop looked like it was throwing most of it
        // away. Subtracting a background level first makes the measure
        // actually about the subject.
        //
        // The 60th percentile is the background level: more than half of a
        // typical frame is not the subject.
        var sorted = grid.sorted()
        let floor = sorted[Int(0.60 * Float(sorted.count - 1))]
        let peak = sorted[sorted.count - 1]
        let span = max(0.000001, peak - floor)
        for i in grid.indices {
            grid[i] = max(0, (grid[i] - floor) / span)
        }
        return grid
    }

    /// Summed-area table with a zero row and column, so a rectangle sum is
    /// four lookups.
    private static func integral(of grid: [Float], side n: Int) -> [Float] {
        var table = [Float](repeating: 0, count: (n + 1) * (n + 1))
        for y in 0..<n {
            var rowSum: Float = 0
            for x in 0..<n {
                rowSum += grid[y * n + x]
                table[(y + 1) * (n + 1) + (x + 1)] = table[y * (n + 1) + (x + 1)] + rowSum
            }
        }
        return table
    }

    // MARK: - Querying

    private func sum(_ table: [Float], _ rect: CGRect) -> (total: Float, cells: Float) {
        let n = side
        let x0 = min(n, max(0, Int((rect.minX * CGFloat(n)).rounded(.down))))
        let y0 = min(n, max(0, Int((rect.minY * CGFloat(n)).rounded(.down))))
        let x1 = min(n, max(x0 + 1, Int((rect.maxX * CGFloat(n)).rounded(.up))))
        let y1 = min(n, max(y0 + 1, Int((rect.maxY * CGFloat(n)).rounded(.up))))

        let stride = n + 1
        let total = table[y1 * stride + x1]
            - table[y0 * stride + x1]
            - table[y1 * stride + x0]
            + table[y0 * stride + x0]
        return (total, Float((x1 - x0) * (y1 - y0)))
    }

    func meanSaliency(in rect: CGRect) -> Float {
        let (total, cells) = sum(saliencyIntegral, rect)
        return cells > 0 ? total / cells : 0
    }

    /// Total attention inside the rectangle, not averaged — how much of the
    /// frame's interest the crop actually captures.
    func saliencyMass(in rect: CGRect) -> Float {
        sum(saliencyIntegral, rect).total
    }

    var totalSaliency: Float {
        sum(saliencyIntegral, CGRect(x: 0, y: 0, width: 1, height: 1)).total
    }

    func meanLuma(in rect: CGRect) -> Float {
        let (total, cells) = sum(lumaIntegral, rect)
        return cells > 0 ? total / cells : 0.5
    }

    func meanDetail(in rect: CGRect) -> Float {
        let (total, cells) = sum(detailIntegral, rect)
        return cells > 0 ? total / cells : 0
    }

    func clippedFraction(in rect: CGRect) -> Float {
        let (total, cells) = sum(clippedIntegral, rect)
        return cells > 0 ? total / cells : 0
    }

    /// Attention-weighted centroid within a rectangle, in frame space.
    func saliencyCentroid(in rect: CGRect) -> CGPoint? {
        let n = side
        let x0 = max(0, Int(rect.minX * CGFloat(n)))
        let x1 = min(n, max(x0 + 1, Int(rect.maxX * CGFloat(n))))
        let y0 = max(0, Int(rect.minY * CGFloat(n)))
        let y1 = min(n, max(y0 + 1, Int(rect.maxY * CGFloat(n))))

        var wx: Float = 0, wy: Float = 0, total: Float = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let w = saliency[y * n + x]
                wx += w * (Float(x) + 0.5)
                wy += w * (Float(y) + 0.5)
                total += w
            }
        }
        guard total > 0.0001 else { return nil }
        return CGPoint(x: CGFloat(wx / total) / CGFloat(n),
                       y: CGFloat(wy / total) / CGFloat(n))
    }
}
