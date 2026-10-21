import CoreGraphics
import Foundation

/// The exact set of adjustments applied to one photo.
///
/// Kept as explicit, inspectable numbers rather than hidden inside the filter
/// chain. That makes the editing decisions reviewable in the capture review
/// sheet, which matters: an auto-editor you cannot question is one you cannot
/// trust or learn from.
struct EditRecipe {
    /// Degrees of rotation applied to level the horizon.
    var straightenDegrees: CGFloat = 0
    /// Exposure change in stops.
    var exposureEV: CGFloat = 0
    /// Per-channel white-balance gains.
    var whiteBalanceGains: (r: CGFloat, g: CGFloat, b: CGFloat) = (1, 1, 1)
    /// 0...1, how much shadow detail was lifted.
    var shadowLift: CGFloat = 0
    /// 0...1 where 1 means highlights untouched.
    var highlightRecovery: CGFloat = 1
    /// Strength of the S-curve.
    var contrast: CGFloat = 0
    /// Black-point lift, to keep night shots from looking washed out.
    var blackPoint: CGFloat = 0
    /// Skin-protecting saturation boost.
    var vibrance: CGFloat = 0
    /// Plain saturation multiplier.
    var saturation: CGFloat = 1
    /// Large-radius local contrast.
    var clarity: CGFloat = 0
    /// Fine detail sharpening.
    var sharpness: CGFloat = 0
    /// Luminance noise reduction.
    var noiseReduction: CGFloat = 0
    /// Corner darkening.
    var vignette: CGFloat = 0

    var sceneKind: SceneKind = .unknown
    var appleAutoEnhanceApplied = false
    /// True when the photo was cropped to the suggested frame.
    var cropped = false

    /// Plain-language summary for the review sheet.
    var summary: [String] {
        var lines: [String] = []
        if cropped { lines.append("Cropped to the suggested frame") }
        if abs(straightenDegrees) > 0.05 {
            lines.append(String(format: "Straightened %.1f°", abs(Double(straightenDegrees))))
        }
        if abs(exposureEV) > 0.03 {
            lines.append(String(format: "Exposure %+.2f stops", Double(exposureEV)))
        }
        let gains = whiteBalanceGains
        if abs(gains.r - gains.b) > 0.015 {
            lines.append(gains.r > gains.b ? "Warmed white balance" : "Cooled white balance")
        }
        if shadowLift > 0.03 {
            lines.append(String(format: "Shadows +%.0f%%", Double(shadowLift * 100)))
        }
        if highlightRecovery < 0.97 {
            lines.append(String(format: "Highlights −%.0f%%", Double((1 - highlightRecovery) * 100)))
        }
        if blackPoint > 0.005 { lines.append("Deepened blacks") }
        if contrast > 0.03 { lines.append("Added contrast") }
        if vibrance > 0.02 { lines.append(String(format: "Vibrance +%.0f%%", Double(vibrance * 100))) }
        if saturation < 0.98 { lines.append("Eased saturation") }
        if clarity > 0.03 { lines.append("Local contrast") }
        if sharpness > 0.03 { lines.append("Sharpened detail") }
        if noiseReduction > 0.02 { lines.append("Noise reduction") }
        if vignette > 0.02 { lines.append("Slight vignette") }
        if appleAutoEnhanceApplied { lines.insert("Apple auto-enhance", at: 0) }
        if lines.isEmpty { lines.append("Nothing needed changing") }
        return lines
    }
}

/// Per-scene editing character.
///
/// The whole point of classifying the scene is here: "looking its best" is a
/// different target for a plate of pasta and a backlit portrait, and a single
/// global auto-enhance has to compromise between them.
struct ScenePreset {
    /// Where we want the median tone to land.
    var targetMedian: CGFloat = 0.46
    var contrast: CGFloat = 0.5
    var vibrance: CGFloat = 0.18
    var clarity: CGFloat = 0.25
    var sharpness: CGFloat = 0.35
    /// How aggressively to neutralise a colour cast. Low values preserve the
    /// mood of the original light.
    var whiteBalanceStrength: CGFloat = 0.6
    var maxShadowLift: CGFloat = 0.55
    var vignette: CGFloat = 0
    /// Portraits need gentler treatment; sharpening and clarity are unkind to
    /// skin, and warm casts on skin usually read as pleasant, not wrong.
    var protectsSkin: Bool = false

    static func preset(for kind: SceneKind) -> ScenePreset {
        var preset = ScenePreset()
        switch kind {
        case .portrait, .groupPortrait:
            preset.targetMedian = 0.50
            preset.contrast = 0.32
            preset.vibrance = 0.12
            preset.clarity = 0.08
            preset.sharpness = 0.20
            preset.whiteBalanceStrength = 0.42
            preset.maxShadowLift = 0.60
            preset.protectsSkin = true
        case .pet:
            preset.targetMedian = 0.48
            preset.contrast = 0.45
            preset.vibrance = 0.16
            preset.clarity = 0.35
            preset.sharpness = 0.50
            preset.maxShadowLift = 0.55
        case .food:
            preset.targetMedian = 0.54
            preset.contrast = 0.48
            preset.vibrance = 0.30
            preset.clarity = 0.38
            preset.sharpness = 0.42
            // Food lit by a warm bulb is appetising; neutralising it makes
            // the dish look grey and cold.
            preset.whiteBalanceStrength = 0.35
            preset.maxShadowLift = 0.45
        case .landscape:
            preset.targetMedian = 0.46
            preset.contrast = 0.62
            preset.vibrance = 0.28
            preset.clarity = 0.48
            preset.sharpness = 0.45
            preset.whiteBalanceStrength = 0.50
            preset.maxShadowLift = 0.50
            preset.vignette = 0.10
        case .architecture:
            preset.targetMedian = 0.47
            preset.contrast = 0.55
            preset.vibrance = 0.14
            preset.clarity = 0.52
            preset.sharpness = 0.55
            preset.whiteBalanceStrength = 0.75
            preset.maxShadowLift = 0.45
        case .street:
            preset.targetMedian = 0.44
            preset.contrast = 0.58
            preset.vibrance = 0.20
            preset.clarity = 0.40
            preset.sharpness = 0.45
            preset.vignette = 0.08
        case .stillLife:
            preset.targetMedian = 0.50
            preset.contrast = 0.46
            preset.vibrance = 0.20
            preset.clarity = 0.32
            preset.sharpness = 0.45
        case .flora:
            preset.targetMedian = 0.49
            preset.contrast = 0.44
            preset.vibrance = 0.26
            preset.clarity = 0.30
            preset.sharpness = 0.42
        case .nightScene:
            // Night shots should stay night shots. Lifting the whole frame to
            // a daylight median is the single most common way auto-edits ruin
            // them, so the target stays low and the blacks get held down.
            preset.targetMedian = 0.26
            preset.contrast = 0.40
            preset.vibrance = 0.18
            preset.clarity = 0.18
            preset.sharpness = 0.25
            preset.whiteBalanceStrength = 0.25
            preset.maxShadowLift = 0.30
            preset.vignette = 0.12
        case .interior:
            preset.targetMedian = 0.44
            preset.contrast = 0.42
            preset.vibrance = 0.16
            preset.clarity = 0.30
            preset.sharpness = 0.40
            preset.whiteBalanceStrength = 0.65
            preset.maxShadowLift = 0.55
        case .unknown:
            break
        }
        return preset
    }
}
