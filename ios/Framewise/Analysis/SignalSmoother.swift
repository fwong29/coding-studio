import CoreGraphics
import Foundation

/// Damps the frame-to-frame noise in Vision's output.
///
/// Saliency and face boxes wobble by a few percent every frame even on a
/// perfectly still subject, and the classifier flips between neighbouring
/// labels. Fed straight to the UI that reads as the app being indecisive — a
/// box that shivers and advice that rewrites itself. None of that jitter is
/// information, so it gets filtered out here rather than being shown.
struct SignalSmoother {

    /// How fast smoothed values chase the new reading. Low is calm.
    private let follow: CGFloat = 0.22
    /// A jump bigger than this means the subject genuinely changed, so snap
    /// rather than sliding slowly across the frame.
    private let snapDistance: CGFloat = 0.28
    /// Consecutive disagreeing classifications before the scene kind changes.
    private let kindSwitchVotes = 3

    /// Analysed frames with no detection before the held subject is dropped.
    /// At roughly 8 Hz this is about a second — long enough to ride out a
    /// blink in the detector, short enough that the marker doesn't sit on a
    /// subject that has left the frame.
    private let maxMisses = 8

    private var point: CGPoint?
    private var bounds: CGRect?
    private var confidence: CGFloat = 0
    private var misses = 0

    private var stableKind: SceneKind = .unknown
    private var pendingKind: SceneKind = .unknown
    private var pendingVotes = 0

    mutating func smooth(_ input: SceneSignals) -> SceneSignals {
        var output = input

        // --- Subject position and box -------------------------------------
        if input.subjectPoint == nil {
            misses += 1
            if misses > maxMisses {
                // Let it go. Holding the last known subject indefinitely meant
                // the coach kept composing around something that was no longer
                // there, and never reported having lost it.
                point = nil
                bounds = nil
                confidence = 0
            }
        } else {
            misses = 0
        }

        if let incoming = input.subjectPoint {
            if let previous = point, previous.distance(to: incoming) < snapDistance {
                point = CGPoint(x: previous.x + (incoming.x - previous.x) * follow,
                                y: previous.y + (incoming.y - previous.y) * follow)
            } else {
                point = incoming
            }
            output.subjectPoint = point
        } else {
            // Hold the last position briefly instead of dropping the marker
            // the instant a detection misses.
            output.subjectPoint = point
        }

        if let incoming = input.subjectBounds {
            if let previous = bounds, previous.center.distance(to: incoming.center) < snapDistance {
                bounds = CGRect(
                    x: previous.minX + (incoming.minX - previous.minX) * follow,
                    y: previous.minY + (incoming.minY - previous.minY) * follow,
                    width: previous.width + (incoming.width - previous.width) * follow,
                    height: previous.height + (incoming.height - previous.height) * follow)
            } else {
                bounds = incoming
            }
            output.subjectBounds = bounds
        } else {
            output.subjectBounds = bounds
        }

        confidence += (input.subjectConfidence - confidence) * follow
        output.subjectConfidence = confidence

        // --- Scene kind ----------------------------------------------------
        // A single frame is never enough to change what kind of photo this is.
        // Switching on one reading is what makes the advice feel random.
        if input.kind == stableKind {
            pendingVotes = 0
        } else if input.kind == pendingKind {
            pendingVotes += 1
            if pendingVotes >= kindSwitchVotes {
                stableKind = pendingKind
                pendingVotes = 0
            }
        } else {
            pendingKind = input.kind
            pendingVotes = 1
        }
        output.kind = stableKind

        return output
    }

    mutating func reset() {
        point = nil
        bounds = nil
        confidence = 0
        stableKind = .unknown
        pendingKind = .unknown
        pendingVotes = 0
    }
}
