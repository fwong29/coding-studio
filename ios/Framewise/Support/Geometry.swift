import CoreGraphics
import Foundation

// MARK: - Normalized frame coordinates
//
// Everything in the coaching layer speaks "frame space": x and y in 0...1,
// origin at the TOP-LEFT of the upright (as-displayed) frame, y growing
// downward. That matches SwiftUI and keeps the overlay math readable.
//
// Vision hands back the opposite convention (origin bottom-left, y up), so
// every value crossing that boundary goes through `fromVision`.

enum FrameSpace {
    /// Converts a Vision point (bottom-left origin) into frame space.
    static func fromVision(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: 1 - point.y)
    }

    /// Converts a Vision bounding box (bottom-left origin) into frame space.
    static func fromVision(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x,
               y: 1 - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }
}

// MARK: - Rule-of-thirds

enum Thirds {
    static let lines: [CGFloat] = [1.0 / 3.0, 2.0 / 3.0]

    /// The four classic thirds intersections, in frame space.
    static let intersections: [CGPoint] = [
        CGPoint(x: 1.0 / 3.0, y: 1.0 / 3.0),
        CGPoint(x: 2.0 / 3.0, y: 1.0 / 3.0),
        CGPoint(x: 1.0 / 3.0, y: 2.0 / 3.0),
        CGPoint(x: 2.0 / 3.0, y: 2.0 / 3.0),
    ]

    /// Picks the intersection a subject should move to.
    ///
    /// Two things steer the choice. First, we prefer the intersection the
    /// subject is already nearest, so the app never asks for a big swing when
    /// a small one will do. Second, if we know which way a face is turned we
    /// bias toward leaving the empty space *in front of* the subject — the
    /// standard "looking room" rule — because a person pressed up against the
    /// edge they are facing reads as cramped.
    static func target(for subject: CGPoint, lookingRoom gazeX: CGFloat?) -> CGPoint {
        var best = intersections[0]
        var bestCost = CGFloat.greatestFiniteMagnitude

        for candidate in intersections {
            var cost = hypot(candidate.x - subject.x, candidate.y - subject.y)

            if let gazeX, abs(gazeX) > 0.15 {
                // gazeX > 0 means the subject faces frame-right, so they
                // belong on the LEFT third. Penalize the wrong side.
                let wantsLeft = gazeX > 0
                let isLeft = candidate.x < 0.5
                if wantsLeft != isLeft { cost += 0.45 }
            }
            if cost < bestCost {
                bestCost = cost
                best = candidate
            }
        }
        return best
    }
}

// MARK: - Aspect-fill preview mapping
//
// The preview layer uses `resizeAspectFill`, so the video frame is scaled up
// until it covers the view and the overflow is clipped. Any overlay drawn on
// top has to apply exactly the same transform, or the aim marker will sit
// somewhere the subject isn't.

struct PreviewMapper {
    let viewSize: CGSize
    /// Displayed aspect ratio of the video (width / height).
    let contentAspect: CGFloat

    private var contentSize: CGSize {
        guard viewSize.width > 0, viewSize.height > 0, contentAspect > 0 else { return viewSize }
        // Scale so the content covers the view in both axes.
        let scale = max(viewSize.width / contentAspect, viewSize.height)
        return CGSize(width: contentAspect * scale, height: scale)
    }

    private var origin: CGPoint {
        let size = contentSize
        return CGPoint(x: (viewSize.width - size.width) / 2,
                       y: (viewSize.height - size.height) / 2)
    }

    /// Frame-space point -> view point.
    func point(_ normalized: CGPoint) -> CGPoint {
        let size = contentSize
        let o = origin
        return CGPoint(x: o.x + normalized.x * size.width,
                       y: o.y + normalized.y * size.height)
    }

    /// View point -> frame-space point. The inverse of `point(_:)`, used to
    /// turn a tap into a focus target.
    func normalized(_ viewPoint: CGPoint) -> CGPoint {
        let size = contentSize
        let o = origin
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: clamp((viewPoint.x - o.x) / size.width, 0, 1),
                       y: clamp((viewPoint.y - o.y) / size.height, 0, 1))
    }

    /// Frame-space rect -> view rect.
    func rect(_ normalized: CGRect) -> CGRect {
        let a = point(CGPoint(x: normalized.minX, y: normalized.minY))
        let b = point(CGPoint(x: normalized.maxX, y: normalized.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
}

// MARK: - Small numeric helpers

@inlinable func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
    min(max(value, low), high)
}

/// Maps `value` onto 1...0 as it travels from `good` to `bad`.
/// Used everywhere a measured error needs to become a 0...1 score.
func score(_ value: CGFloat, good: CGFloat, bad: CGFloat) -> CGFloat {
    guard bad != good else { return value <= good ? 1 : 0 }
    let t = (value - good) / (bad - good)
    return clamp(1 - t, 0, 1)
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var area: CGFloat { width * height }
}

/// Exponential smoothing, so on-screen values glide instead of jitter.
struct Smoothed {
    private(set) var value: CGFloat
    private let factor: CGFloat

    init(_ initial: CGFloat = 0, factor: CGFloat = 0.25) {
        self.value = initial
        self.factor = factor
    }

    mutating func update(_ newValue: CGFloat) {
        guard newValue.isFinite else { return }
        value += (newValue - value) * factor
    }
}
