import CoreGraphics
import Foundation

/// Where the subject belongs in the frame.
enum Placement {
    /// Classic rule-of-thirds intersection, chosen to be the nearest one.
    case thirds
    /// Dead centre — right for symmetry, flat-lays and overhead food.
    case centered
    /// Thirds horizontally, but low in the frame, so the subject sits under
    /// space (useful for a figure in a big landscape).
    case lowerThirdHorizontal
    /// On the vertical centre line but high, as for a standing portrait.
    case upperCenter

    func target(subject: CGPoint, gazeX: CGFloat?) -> CGPoint {
        switch self {
        case .thirds:
            return Thirds.target(for: subject, lookingRoom: gazeX)
        case .centered:
            return CGPoint(x: 0.5, y: 0.5)
        case .lowerThirdHorizontal:
            let x: CGFloat = subject.x < 0.5 ? 1.0 / 3.0 : 2.0 / 3.0
            return CGPoint(x: x, y: 2.0 / 3.0)
        case .upperCenter:
            return CGPoint(x: 0.5, y: 0.4)
        }
    }
}

/// Where the horizon should sit, when the scene has one.
enum HorizonRule {
    case none
    /// Sky-heavy: put the horizon on the lower third.
    case lowerThird
    /// Foreground-heavy: put it on the upper third.
    case upperThird
    /// Either third is fine, just not slicing the frame in half.
    case avoidCentre
    /// Deliberately centred, for reflections and symmetry.
    case centred

    var targetY: CGFloat? {
        switch self {
        case .none: return nil
        case .lowerThird: return 2.0 / 3.0
        case .upperThird: return 1.0 / 3.0
        case .avoidCentre: return nil
        case .centred: return 0.5
        }
    }
}

/// The framing contract for a shot: what the coach measures against.
///
/// Each shot assignment carries one of these, and there is a sensible default
/// per `SceneKind` for when the user is just shooting freely without an
/// assignment.
struct FramingTarget {
    /// Fraction of the frame the subject should occupy.
    var subjectArea: ClosedRange<CGFloat> = 0.08...0.45
    var placement: Placement = .thirds
    var horizon: HorizonRule = .avoidCentre
    /// Architecture and interiors want the phone held plumb so verticals stay
    /// parallel; most other scenes do not care.
    var wantsLevelVerticals: Bool = false
    /// Portraits get an eye-line rule instead of a generic placement rule.
    var usesEyeLine: Bool = false
    /// Target height for the eye line, as a fraction from the top.
    var eyeLineY: CGFloat = 0.36
    /// Night and indoor shots legitimately run darker; don't nag.
    var targetMedianLuma: CGFloat = 0.45
    /// How tight the aim tolerance is. Tighter for deliberate, static subjects.
    var aimTolerance: CGFloat = 0.09

    /// Sensible defaults when there is no assignment driving the frame.
    static func `default`(for kind: SceneKind) -> FramingTarget {
        var target = FramingTarget()
        switch kind {
        case .portrait:
            target.subjectArea = 0.10...0.42
            target.placement = .thirds
            target.usesEyeLine = true
            target.horizon = .none
        case .groupPortrait:
            target.subjectArea = 0.12...0.60
            target.placement = .centered
            target.usesEyeLine = true
            target.eyeLineY = 0.40
            target.horizon = .none
        case .pet:
            target.subjectArea = 0.12...0.55
            target.placement = .thirds
            target.aimTolerance = 0.12   // pets move; don't be fussy
        case .food:
            target.subjectArea = 0.25...0.75
            target.placement = .centered
            target.horizon = .none
            target.targetMedianLuma = 0.52
            target.aimTolerance = 0.07
        case .landscape:
            target.subjectArea = 0.04...0.40
            target.placement = .thirds
            target.horizon = .avoidCentre
        case .architecture:
            target.subjectArea = 0.20...0.85
            target.placement = .centered
            target.wantsLevelVerticals = true
            target.horizon = .none
        case .street:
            target.subjectArea = 0.06...0.45
            target.placement = .thirds
            target.horizon = .avoidCentre
            target.aimTolerance = 0.13   // candid moments won't wait
        case .stillLife:
            target.subjectArea = 0.15...0.65
            target.placement = .thirds
            target.horizon = .none
            target.aimTolerance = 0.07
        case .flora:
            target.subjectArea = 0.12...0.60
            target.placement = .thirds
            target.horizon = .none
        case .nightScene:
            target.subjectArea = 0.06...0.60
            target.horizon = .avoidCentre
            target.targetMedianLuma = 0.26
        case .interior:
            target.subjectArea = 0.15...0.80
            target.placement = .centered
            target.wantsLevelVerticals = true
            target.horizon = .none
            target.targetMedianLuma = 0.40
        case .unknown:
            break
        }
        return target
    }
}
