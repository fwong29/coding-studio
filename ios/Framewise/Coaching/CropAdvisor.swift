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

        // How much of the crop the subject should fill.
        //
        // Deliberately higher than the share used for "move your feet"
        // coaching. Cropping exists to make the subject dominate, so aiming at
        // the middle of the comfortable range meant that for any subject
        // bigger than about a quarter of the frame the solved scale came out
        // above 1, got clamped, and the box silently never appeared. Vision's
        // salient-object boxes are generous, so that was nearly always.
        let targetShare = clamp(target.subjectArea.upperBound * 1.25, 0.30, 0.70)

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

        // Whether the crop is obliged to contain the whole detected region.
        //
        // For a person it is: cropping through someone's head is never the
        // suggestion you wanted. For everything else it is not, because
        // Vision's salient-object boxes are loose regions rather than tight
        // outlines — forcing the crop to swallow one whole is what made the
        // box balloon out to the edges of the screen and stop meaning
        // anything.
        let mustContainWholeSubject = !signals.faces.isEmpty || !signals.humanBodies.isEmpty
        let needed = bounds.insetBy(dx: -0.025, dy: -0.025)
        if mustContainWholeSubject {
            scale = max(scale, needed.width, needed.height)
        }
        scale = clamp(scale, minimumScale, 1)

        // A crop is worth suggesting for either of two reasons: to tighten, or
        // to reposition. If the subject is already big enough that tightening
        // would do nothing, but it is sitting well away from where it belongs,
        // a modest crop that moves it onto its anchor is still an improvement.
        let placementError = anchor.distance(to: ideal)
        if scale > 0.92, placementError > 0.12, needed.width < 0.9, needed.height < 0.9 {
            scale = 0.90
        }

        var rect = CGRect(x: anchor.x - ideal.x * scale,
                          y: anchor.y - ideal.y * scale,
                          width: scale,
                          height: scale)

        // Slide back inside the frame rather than shrinking — the composition
        // degrades more gracefully off-ideal than it does over-cropped.
        rect.origin.x = clamp(rect.origin.x, 0, 1 - scale)
        rect.origin.y = clamp(rect.origin.y, 0, 1 - scale)

        // If sliding still leaves a person clipped, nudge to cover them.
        if mustContainWholeSubject {
            if needed.minX < rect.minX { rect.origin.x = max(0, needed.minX) }
            if needed.maxX > rect.maxX { rect.origin.x = min(1 - scale, needed.maxX - scale) }
            if needed.minY < rect.minY { rect.origin.y = max(0, needed.minY) }
            if needed.maxY > rect.maxY { rect.origin.y = min(1 - scale, needed.maxY - scale) }
        }

        let isFull = scale > 0.92
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
