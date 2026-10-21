import CoreGraphics
import Foundation

/// The best photo inside the photo you're currently pointing at.
struct CropSuggestion: Equatable {
    /// The suggested frame, in frame space (top-left origin).
    var rect: CGRect
    /// How much we trust it. Low confidence draws a fainter box.
    var confidence: CGFloat
    /// True when the whole frame is already the right crop, so the UI can go
    /// quiet rather than drawing a box around everything.
    var isFullFrame: Bool
    /// One short line explaining the crop.
    var reason: String
    /// What the box is of, in plain words — "glass office facade", "golden
    /// retriever". Naming the subject is what makes the box feel like the app
    /// understood the scene rather than drew a rectangle at random.
    var label: String?

    static let fullFrame = CropSuggestion(
        rect: CGRect(x: 0, y: 0, width: 1, height: 1),
        confidence: 0,
        isFullFrame: true,
        reason: "Whole frame",
        label: nil)
}

/// Works out which rectangle inside the live frame would make the better
/// photograph, rather than asking you to move until the whole frame is right.
///
/// This is the lazier and often more useful half of composition: you are
/// already pointing at the subject, and the picture you want is usually a
/// rectangle somewhere inside what you can see. Finding it is a cheap
/// geometric problem once the subject is known.
struct CropAdvisor {

    /// Never crop below this fraction of the frame's width and height.
    ///
    /// At 0.6 a 12 MP capture still yields about 4.3 MP, which prints and
    /// shares fine. Going tighter starts trading real resolution for framing,
    /// and at that point you should move your feet instead.
    private let minimumScale: CGFloat = 0.6

    func suggest(signals: SceneSignals, target: FramingTarget) -> CropSuggestion {
        guard let bounds = signals.subjectBounds,
              let subject = signals.subjectPoint,
              signals.subjectConfidence > 0.3,
              bounds.area > 0.0005 else {
            return .fullFrame
        }

        // How much of the crop the subject should fill. The middle of the
        // scene's acceptable range, so we aim for comfortable rather than
        // either extreme.
        let targetShare = clamp((target.subjectArea.lowerBound + target.subjectArea.upperBound) / 2,
                                0.05, 0.75)

        // Subject area is a fraction of the *full* frame. If it should instead
        // be `targetShare` of the crop, the crop covers subjectArea/targetShare
        // of the frame — and since we keep the frame's aspect ratio, each side
        // scales by the square root of that.
        var scale = sqrt(bounds.area / targetShare)

        // Where the subject belongs inside the crop. Passing the subject's
        // full-frame position as the hint makes the placement rule pick the
        // nearest third, so the crop moves as little as possible.
        var anchor = subject
        var ideal = target.placement.target(subject: subject, gazeX: signals.gazeX)

        // Portraits compose on the eye line, not the middle of the head.
        if target.usesEyeLine, let face = signals.primaryFace {
            anchor = CGPoint(x: face.bounds.midX,
                             y: face.bounds.minY + face.bounds.height * 0.38)
            ideal.y = target.eyeLineY
        }

        // The subject has to fit, with a little air around it.
        let needed = bounds.insetBy(dx: -0.025, dy: -0.025)
        scale = max(scale, needed.width, needed.height)
        scale = clamp(scale, minimumScale, 1)

        var rect = CGRect(x: anchor.x - ideal.x * scale,
                          y: anchor.y - ideal.y * scale,
                          width: scale,
                          height: scale)

        // Slide back inside the frame rather than shrinking — the composition
        // degrades more gracefully off-ideal than it does over-cropped.
        rect.origin.x = clamp(rect.origin.x, 0, 1 - scale)
        rect.origin.y = clamp(rect.origin.y, 0, 1 - scale)

        // If sliding still leaves the subject clipped, nudge to cover it.
        if needed.minX < rect.minX { rect.origin.x = max(0, needed.minX) }
        if needed.maxX > rect.maxX { rect.origin.x = min(1 - scale, needed.maxX - scale) }
        if needed.minY < rect.minY { rect.origin.y = max(0, needed.minY) }
        if needed.maxY > rect.maxY { rect.origin.y = min(1 - scale, needed.maxY - scale) }

        let isFull = scale > 0.94
        return CropSuggestion(
            rect: rect,
            confidence: signals.subjectConfidence,
            isFullFrame: isFull,
            reason: isFull ? "Whole frame" : reason(for: rect, scale: scale, target: target),
            label: label(from: signals))
    }

    /// Turns Vision's top classification label into something readable.
    ///
    /// The classifier emits identifiers like `glass_office_facade` or
    /// `golden_retriever`; underscores and all-lowercase read as debug output,
    /// so they get cleaned up before being shown.
    private func label(from signals: SceneSignals) -> String? {
        guard let raw = signals.topLabels.first else {
            // No classification yet — fall back to naming the detected thing.
            if !signals.faces.isEmpty {
                return signals.faces.count > 1 ? "people" : "face"
            }
            return nil
        }
        let cleaned = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !cleaned.isEmpty, cleaned.count <= 34 else { return nil }
        return cleaned
    }

    private func reason(for rect: CGRect, scale: CGFloat, target: FramingTarget) -> String {
        let centre = rect.center
        let side: String
        if centre.x < 0.42 { side = "left" }
        else if centre.x > 0.58 { side = "right" }
        else { side = "centre" }

        let tightness = scale < 0.75 ? "Much tighter" : "Tighter"
        switch target.placement {
        case .centered:
            return "\(tightness), centred"
        default:
            return "\(tightness), subject toward the \(side)"
        }
    }
}
