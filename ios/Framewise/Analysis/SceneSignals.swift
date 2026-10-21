import CoreGraphics
import Foundation

/// What kind of photo this appears to be. Drives both the coaching rules and
/// the editing recipe, since "good" means different things for a plate of food
/// and a backlit portrait.
enum SceneKind: String, CaseIterable {
    case portrait
    case groupPortrait
    case pet
    case food
    case landscape
    case architecture
    case street
    case stillLife
    case flora
    case nightScene
    case interior
    case unknown

    var displayName: String {
        switch self {
        case .portrait: return "Portrait"
        case .groupPortrait: return "Group"
        case .pet: return "Pet"
        case .food: return "Food"
        case .landscape: return "Landscape"
        case .architecture: return "Architecture"
        case .street: return "Street"
        case .stillLife: return "Still life"
        case .flora: return "Plants"
        case .nightScene: return "Night"
        case .interior: return "Indoors"
        case .unknown: return "Scene"
        }
    }

    /// Scenes where a leaning phone produces converging verticals that read as
    /// a mistake rather than a choice.
    var caresAboutVerticals: Bool {
        self == .architecture || self == .interior
    }

    /// Scenes that usually have a real horizon worth levelling and placing.
    var hasHorizon: Bool {
        self == .landscape || self == .street
    }
}

/// A single detected face.
struct FaceSignal {
    /// Frame space (top-left origin).
    var bounds: CGRect
    /// Head turn in radians; positive means turned toward frame-right.
    var yaw: CGFloat?
    /// Head tilt in radians.
    var roll: CGFloat?
}

/// Luminance and colour statistics for one frame.
struct ToneSignal {
    var meanLuma: CGFloat = 0.5
    var medianLuma: CGFloat = 0.5
    var p5Luma: CGFloat = 0.1
    var p95Luma: CGFloat = 0.9
    /// Fraction of pixels crushed to black / blown to white.
    var shadowClipped: CGFloat = 0
    var highlightClipped: CGFloat = 0
    /// Channel means over the whole frame (gray-world input).
    var meanRGB: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.5, 0.5, 0.5)
    /// Channel means of the brightest ~5% of pixels (white-patch input).
    var highlightRGB: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.9, 0.9, 0.9)
    /// Rough saturation average, 0...1. Keeps us from over-juicing a frame
    /// that is already vivid.
    var saturation: CGFloat = 0.3
    /// Spread of the mid-tones; a proxy for how flat the light is.
    var contrast: CGFloat = 0.2

    /// Mean luma of each half of the frame, in *frame* orientation (so
    /// `lumaLeft` really is the left of the picture, not the left of the
    /// landscape sensor buffer). The imbalance between them is how we work out
    /// which direction the light is coming from, which is the single most
    /// useful thing to tell someone about where to stand.
    var lumaLeft: CGFloat = 0.5
    var lumaRight: CGFloat = 0.5
    var lumaTop: CGFloat = 0.5
    var lumaBottom: CGFloat = 0.5

    var isDark: Bool { medianLuma < 0.22 }
    var isVeryDark: Bool { medianLuma < 0.12 }
}

/// Which way the light is falling, as read off the frame.
enum LightDirection: String {
    /// Light from frame-left — the classic window-to-the-side setup.
    case fromLeft
    case fromRight
    /// Brighter at the top: overhead sun, or a ceiling light.
    case fromAbove
    /// Behind the subject, pointing at the camera.
    case backlit
    /// Coming from behind the photographer. Technically easy, visually flat —
    /// it fills in every shadow that would have given the subject shape.
    case frontal
    /// No usable direction: overcast, or a big soft source everywhere.
    case even

    var displayName: String {
        switch self {
        case .fromLeft: return "light from the left"
        case .fromRight: return "light from the right"
        case .fromAbove: return "light from above"
        case .backlit: return "backlit"
        case .frontal: return "flat light from behind you"
        case .even: return "even light"
        }
    }
}

/// Device attitude, from CoreMotion.
struct MotionSignal {
    /// Horizon tilt in degrees. Zero when the frame edges are level.
    var rollDegrees: CGFloat = 0
    /// Camera elevation in degrees. Zero when pointing at the horizon,
    /// positive when aimed upward.
    var elevationDegrees: CGFloat = 0
    /// Magnitude of user acceleration, as a shake proxy.
    var shake: CGFloat = 0
    var isAvailable: Bool = false

    /// Degrees away from level, ignoring whether the phone is held in
    /// portrait or landscape.
    var levelErrorDegrees: CGFloat {
        let wrapped = rollDegrees.truncatingRemainder(dividingBy: 90)
        return abs(wrapped) > 45 ? 90 - abs(wrapped) : abs(wrapped)
    }

    /// Signed version of the above, for telling the user which way to rotate.
    var signedLevelErrorDegrees: CGFloat {
        let nearest = (rollDegrees / 90).rounded() * 90
        return rollDegrees - nearest
    }
}

/// Everything one analysed frame tells us. The coach is a pure function of
/// this plus the active assignment, which makes its behaviour easy to reason
/// about and to unit test.
struct SceneSignals {
    var timestamp: TimeInterval = 0

    /// Centre of visual attention, from Vision's saliency map. This is the
    /// anchor the aim marker tracks.
    var subjectPoint: CGPoint?
    /// Bounding box of the salient subject, in frame space.
    var subjectBounds: CGRect?
    /// How confident we are that there is a single clear subject at all.
    var subjectConfidence: CGFloat = 0

    var faces: [FaceSignal] = []
    var humanBodies: [CGRect] = []

    var kind: SceneKind = .unknown
    var kindConfidence: CGFloat = 0
    var topLabels: [String] = []

    var tone = ToneSignal()
    var motion = MotionSignal()

    /// Edge energy in the outer border of the frame — high values mean a busy,
    /// distracting edge.
    var edgeClutter: CGFloat = 0
    /// Overall sharpness proxy; low means blur from motion or bad focus.
    var sharpness: CGFloat = 1

    var hasPeople: Bool { !faces.isEmpty || !humanBodies.isEmpty }

    /// The subject's facing direction in frame-space x, if we can tell.
    /// Positive means facing frame-right.
    var gazeX: CGFloat? {
        guard let primary = primaryFace, let yaw = primary.yaw else { return nil }
        // Vision's yaw is in radians; ±0.6 rad is a strong turn.
        return clamp(yaw / 0.6, -1, 1)
    }

    /// The face we should compose around: the largest one.
    var primaryFace: FaceSignal? {
        faces.max { $0.bounds.area < $1.bounds.area }
    }

    /// Where the true horizon falls in the frame, derived from camera
    /// elevation and the lens's vertical field of view.
    ///
    /// This is more dependable than trying to find a horizon line in the
    /// pixels: it works on a featureless sky, through a window, or when the
    /// actual skyline is hidden behind buildings.
    func horizonY(verticalFOVDegrees: CGFloat) -> CGFloat? {
        guard motion.isAvailable, verticalFOVDegrees > 1 else { return nil }
        let elevation = motion.elevationDegrees * .pi / 180
        let halfFOV = (verticalFOVDegrees / 2) * .pi / 180
        guard abs(elevation) < .pi / 2 - 0.01 else { return nil }
        let y = 0.5 + tan(elevation) / (2 * tan(halfFOV))
        return y.isFinite ? y : nil
    }

    /// True when the subject is markedly darker than the frame as a whole —
    /// the signature of shooting into the light.
    var isBacklit: Bool {
        guard let box = subjectBounds, box.area > 0.02 else { return false }
        return tone.highlightClipped > 0.04 && subjectIsDarkerThanFrame
    }

    var subjectIsDarkerThanFrame: Bool = false

    /// Reads the light direction off the frame's brightness distribution.
    ///
    /// Order matters: backlight is checked first because it is the one case
    /// that actively fights you, and it shows up as a dark subject against a
    /// clipping background rather than as a left/right imbalance.
    var lightDirection: LightDirection {
        if isBacklit { return .backlit }

        let horizontal = tone.lumaLeft - tone.lumaRight
        let vertical = tone.lumaTop - tone.lumaBottom

        // A tenth of the luma range is about the point where a side-lit frame
        // starts to look side-lit rather than evenly lit.
        if abs(horizontal) > 0.10, abs(horizontal) > abs(vertical) {
            return horizontal > 0 ? .fromLeft : .fromRight
        }
        if vertical > 0.12 { return .fromAbove }

        // Light from behind the camera leaves no shadows anywhere, which shows
        // up as an unusually narrow tonal range.
        if tone.contrast < 0.26 { return .frontal }
        return .even
    }

    /// Coarse bands for camera elevation, which is what positional advice is
    /// actually keyed off.
    enum Elevation {
        case straightDown
        case steeplyDown
        case down
        case level
        case up
        case steeplyUp
    }

    var elevationBand: Elevation {
        guard motion.isAvailable else { return .level }
        switch motion.elevationDegrees {
        case ..<(-72): return .straightDown
        case ..<(-38): return .steeplyDown
        case ..<(-14): return .down
        case ..<14: return .level
        case ..<45: return .up
        default: return .steeplyUp
        }
    }
}
