import CoreGraphics
import Foundation

/// Which way the user should move the phone.
///
/// Sign conventions, written down because they are easy to invert:
/// panning the camera right sweeps the scene LEFT across the frame, and
/// tilting the camera down sweeps the scene UP. So to move a subject toward
/// the left third you pan right.
enum PhoneNudge: Equatable {
    case panLeft
    case panRight
    case tiltUp
    case tiltDown
    case rotateClockwise
    case rotateCounterClockwise
    case moveCloser
    case moveBack
    case none

    var symbol: String {
        switch self {
        case .panLeft: return "arrow.left"
        case .panRight: return "arrow.right"
        case .tiltUp: return "arrow.up"
        case .tiltDown: return "arrow.down"
        case .rotateClockwise: return "arrow.clockwise"
        case .rotateCounterClockwise: return "arrow.counterclockwise"
        case .moveCloser: return "arrow.down.right.and.arrow.up.left"
        case .moveBack: return "arrow.up.left.and.arrow.down.right"
        case .none: return "checkmark"
        }
    }
}

/// Identifies what a check is about, so the UI can style it and the
/// stabilizer can tell "same advice" from "new advice".
enum CheckID: String {
    case exposureDark
    case exposureBlown
    case backlight
    case subjectClipped
    case level
    case verticals
    case subjectSize
    case placement
    case eyeLine
    case horizonPlacement
    case shake
    case focus
    case edgeClutter
    case noSubject
}

/// One piece of advice, shown as the single large line over the viewfinder.
///
/// Only ever one is displayed. Photographers can act on one correction at a
/// time, and a list of six complaints is paralysing rather than helpful.
struct Directive: Equatable {
    let id: CheckID
    /// Imperative and short — this is rendered large.
    let text: String
    /// Optional second line explaining the reason, shown smaller.
    let reason: String?
    let nudge: PhoneNudge
    /// Lower sorts first. Set from how badly the issue damages the photo.
    let priority: Int

    static func == (lhs: Directive, rhs: Directive) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text
    }
}

/// Result of one composition rule.
struct Check {
    let id: CheckID
    /// 0 = badly wrong, 1 = good.
    let score: CGFloat
    /// Relative contribution to overall readiness.
    let weight: CGFloat
    /// Critical checks gate the "ready" state and auto-shutter regardless of
    /// how good the overall average looks.
    let isCritical: Bool
    /// Score this check has to reach to count as passing.
    let passThreshold: CGFloat
    let directive: Directive?

    var passes: Bool { score >= passThreshold }
}

/// What the coach publishes for the UI to draw.
struct CoachingState {
    var directive: Directive?
    /// 0...1, drives the ring around the shutter.
    var readiness: CGFloat = 0
    /// True when every critical rule passes — auto-shutter waits for this.
    var isReady: Bool = false

    /// Where the subject should sit, in frame space.
    var aimTarget: CGPoint?
    /// Where the subject actually is.
    var aimCurrent: CGPoint?
    /// True once the two are close enough.
    var aimAligned: Bool = false
    var subjectBounds: CGRect?

    /// Horizon line position and tilt, for the level indicator.
    var horizonY: CGFloat?
    var rollDegrees: CGFloat = 0
    var levelErrorDegrees: CGFloat = 0

    var sceneKind: SceneKind = .unknown
    var checks: [Check] = []

    /// The rectangle inside the current frame that would make the better
    /// photograph. Drawn on the preview, and applied on capture.
    var crop: CropSuggestion = .fullFrame

    /// Short status line: either the scene we think this is, or nothing.
    var sceneLabel: String? {
        sceneKind == .unknown ? nil : sceneKind.displayName
    }
}
