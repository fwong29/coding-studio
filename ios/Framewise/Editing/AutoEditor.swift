import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UIKit

/// What came out of one capture.
struct EditedCapture {
    /// JPEG/HEIF bytes of the finished photo.
    let editedData: Data
    /// The untouched camera file, kept only if the user asked for it.
    let originalData: Data?
    let recipe: EditRecipe
    /// Small previews for the review sheet.
    let beforeThumbnail: UIImage?
    let afterThumbnail: UIImage?
    /// How to shoot this scene better next time. Filled in by the controller
    /// after editing, from the analysis snapshot taken at capture.
    var brief: SceneBrief?
}

/// Applies a scene-aware set of corrections to a captured photo.
///
/// The approach is measure-then-decide rather than a fixed look: we take real
/// statistics off the frame, convert them into an `EditRecipe` of explicit
/// numbers, and only then build the filter chain. That ordering is what lets
/// the editor leave a well-exposed frame alone instead of pushing every photo
/// toward the same contrast-and-saturation preset.
final class AutoEditor {

    /// Working colour space is Display P3 — gamma-encoded, so tone decisions
    /// line up with the perceptual statistics we measured, and wide enough not
    /// to clip the camera's gamut the way sRGB would.
    private let context: CIContext = {
        let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(options: [
            .workingColorSpace: space,
            .outputColorSpace: space,
            .cacheIntermediates: false,
        ])
    }()

    private let outputColorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        ?? CGColorSpaceCreateDeviceRGB()

    /// Produces the finished photo.
    ///
    /// - Parameters:
    ///   - data: the camera's own file data.
    ///   - signals: analysis from the moment of capture, for scene kind and
    ///     the roll angle used to straighten.
    ///   - lightPhase: used to decide whether a warm cast is a problem or the
    ///     whole point of the photo.
    func process(data: Data,
                 signals: SceneSignals,
                 lightPhase: LightPhase,
                 crop: CGRect?,
                 settings: EditSettings) -> EditedCapture {

        guard var image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            // Nothing we can do with it — hand the original back untouched
            // rather than losing the shot.
            return EditedCapture(editedData: data,
                                 originalData: settings.keepOriginal ? data : nil,
                                 recipe: EditRecipe(),
                                 beforeThumbnail: nil,
                                 afterThumbnail: nil)
        }

        let before = thumbnail(from: image)
        // Captured before editing: the filter chain does not carry metadata
        // forward, so we re-attach it at encode time.
        let properties = image.properties

        guard settings.autoEdit else {
            return EditedCapture(editedData: data,
                                 originalData: settings.keepOriginal ? data : nil,
                                 recipe: EditRecipe(sceneKind: signals.kind),
                                 beforeThumbnail: before,
                                 afterThumbnail: before)
        }

        var recipe = EditRecipe()
        recipe.sceneKind = signals.kind
        let preset = ScenePreset.preset(for: signals.kind)

        // 1. Straighten first, so later measurements are taken on the final
        //    crop rather than on corners that are about to be cut off.
        if settings.autoStraighten {
            let error = signals.motion.signedLevelErrorDegrees
            // Below a third of a degree nobody can see it; past eight degrees
            // it is far more likely to be a deliberate angle than a mistake.
            if abs(error) > 0.3, abs(error) < 8, signals.motion.isAvailable {
                let filter = CIFilter.straighten()
                filter.inputImage = image
                filter.angle = Float(-error * .pi / 180)
                if let output = filter.outputImage, !output.extent.isEmpty {
                    image = output
                    recipe.straightenDegrees = error
                }
            }
        }

        // 2. Crop to the suggested frame, before any measurement, so the
        //    exposure and colour decisions are made on the photo you are
        //    actually keeping rather than on the parts being thrown away.
        //    Deliberately after straightening: the rotation changes the
        //    extent, and the crop is expressed relative to the final frame.
        if let crop, crop.width < 0.99 || crop.height < 0.99 {
            let extent = image.extent
            // Frame space is top-left origin with y down; Core Image is
            // bottom-left with y up, so the rect flips vertically.
            let pixels = CGRect(
                x: extent.minX + crop.minX * extent.width,
                y: extent.minY + (1 - crop.maxY) * extent.height,
                width: crop.width * extent.width,
                height: crop.height * extent.height)
            let cropped = image.cropped(to: pixels.intersection(extent))
            if cropped.extent.width > 64, cropped.extent.height > 64 {
                // Re-origin so downstream filters see a clean extent.
                image = cropped.transformed(by: CGAffineTransform(
                    translationX: -cropped.extent.origin.x,
                    y: -cropped.extent.origin.y))
                recipe.cropped = true
            }
        }

        // 3. Optionally let Apple's own auto-adjustment have first pass.
        if settings.useAppleAutoEnhance {
            let filters = image.autoAdjustmentFilters(options: [.enhance: true, .redEye: true])
            for filter in filters {
                filter.setValue(image, forKey: kCIInputImageKey)
                if let output = filter.outputImage { image = output }
            }
            recipe.appleAutoEnhanceApplied = true
        }

        // 4. Measure the image we are actually going to edit.
        let stats = ToneAnalyzer.analyze(image: image, context: context)

        // 5. Turn measurements into numbers.
        //
        // ISO comes from the capture's own EXIF rather than being guessed from
        // brightness. How noisy a frame is and how dark it looks are different
        // questions — a bright scene shot indoors at ISO 2000 is full of grain,
        // and a deliberately dark night shot at ISO 100 is clean.
        recipe = decide(recipe: recipe,
                        stats: stats,
                        preset: preset,
                        signals: signals,
                        lightPhase: lightPhase,
                        iso: isoSpeed(fromImageData: data))

        // 6. Apply.
        image = apply(recipe: recipe, to: image, preset: preset)

        let after = thumbnail(from: image)
        let encoded = encode(image, carryingMetadataFrom: properties) ?? data

        return EditedCapture(editedData: encoded,
                             originalData: settings.keepOriginal ? data : nil,
                             recipe: recipe,
                             beforeThumbnail: before,
                             afterThumbnail: after)
    }

    // MARK: - Decisions

    /// Reads ISO out of the capture's EXIF.
    ///
    /// Goes to the encoded bytes through `CGImageSource` rather than reading
    /// `CIImage.properties`. The latter is not reliably populated once the
    /// image has been constructed with orientation applied, and when it came
    /// back empty the noise estimate fell through to a brightness proxy — so a
    /// well-lit room shot at ISO 2000 was treated as a clean frame and got the
    /// full dose of clarity and sharpening. That is what made indoor photos
    /// look crunchy.
    private func isoSpeed(fromImageData data: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        else { return nil }

        if let ratings = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
           let first = ratings.first {
            return CGFloat(first.doubleValue)
        }
        if let single = exif[kCGImagePropertyExifISOSpeedRatings as String] as? NSNumber {
            return CGFloat(single.doubleValue)
        }
        // Some devices report only the newer photographic sensitivity key.
        if let sensitivity = exif[kCGImagePropertyExifPhotographicSensitivity as String] as? NSNumber {
            return CGFloat(sensitivity.doubleValue)
        }
        return nil
    }

    private func decide(recipe input: EditRecipe,
                        stats: ToneSignal,
                        preset: ScenePreset,
                        signals: SceneSignals,
                        lightPhase: LightPhase,
                        iso: CGFloat?) -> EditRecipe {
        var recipe = input

        // How grainy the source is, 0 (clean) to 1 (very noisy).
        // ISO 100 reads 0, ISO 3200 reads 1, on a log scale because that is
        // how sensor noise actually grows.
        let noiseFactor: CGFloat
        if let iso, iso > 0 {
            noiseFactor = clamp(log2(max(iso, 50) / 100) / 5, 0, 1)
        } else {
            // No EXIF at all. Assume a middling amount of noise rather than
            // none: guessing "clean" and sharpening hard is a visible,
            // irreversible mistake, while guessing "noisy" and being gentle
            // just leaves the photo close to how it arrived.
            noiseFactor = max(0.45, clamp((0.3 - min(stats.medianLuma, 0.3)) * 2.0, 0, 1))
        }

        // --- Exposure -------------------------------------------------
        // Drive the median toward the scene's target, in stops. Clamped
        // asymmetrically: brightening is usually safe, while pulling a frame
        // down tends to mean the highlights were already gone.
        let median = max(stats.medianLuma, 0.01)
        var ev = log2(preset.targetMedian / median)

        // Brightening is where grain comes from: every stop up is a stop of
        // noise up with it. On a noisy frame, accept a darker photo rather
        // than a loud one — underexposure reads as mood, grain reads as a
        // mistake.
        let brightenCap = 1.3 * (1 - noiseFactor * 0.6)
        ev = clamp(ev, -0.7, brightenCap)

        // Back off brightening when the highlights are already at the edge,
        // or we trade recoverable shadow for unrecoverable white.
        if stats.highlightClipped > 0.03, ev > 0 {
            ev *= clamp(1 - stats.highlightClipped * 4, 0.1, 1)
        }
        // A backlit subject is the exception worth brightening into: the
        // background is meant to blow out.
        if signals.isBacklit, ev > 0 {
            ev = min(ev + 0.25, 1.4)
        }
        recipe.exposureEV = ev

        // --- White balance --------------------------------------------
        recipe.whiteBalanceGains = whiteBalanceGains(stats: stats,
                                                     preset: preset,
                                                     lightPhase: lightPhase,
                                                     kind: signals.kind)

        // --- Shadows and highlights -----------------------------------
        // Lift shadows in proportion to how much of the frame is actually
        // crushed, not as a fixed amount.
        let shadowNeed = clamp((0.14 - stats.p5Luma) / 0.14, 0, 1)
        // Lifting shadows is the single noisiest operation in the stack: the
        // darkest pixels are where the sensor had least signal, so pulling
        // them up amplifies almost pure noise. Back off hard on grainy frames.
        recipe.shadowLift = shadowNeed * preset.maxShadowLift * (1 - noiseFactor * 0.75)
        if signals.isBacklit {
            recipe.shadowLift = min(1, recipe.shadowLift + 0.25)
        }

        // Pull highlights back only when a meaningful area is clipping.
        let highlightNeed = clamp((stats.highlightClipped - 0.01) / 0.12, 0, 1)
        recipe.highlightRecovery = 1 - highlightNeed * 0.55

        // --- Contrast -------------------------------------------------
        // Flat frames want help; already-contrasty ones do not.
        let flatness = clamp((0.62 - stats.contrast) / 0.5, 0, 1)
        recipe.contrast = flatness * preset.contrast

        // Lifting shadows washes the blacks out, so put a real black point back
        // under it: anything below this input level is driven to true black.
        // That is what keeps shadows looking like shadows instead of grey
        // mush, and it hides the noise living down there rather than
        // displaying it. Grainier frames get a slightly firmer floor.
        if recipe.shadowLift > 0.15 || signals.kind == .nightScene || noiseFactor > 0.3 {
            recipe.blackPoint = min(0.05, 0.015 + recipe.shadowLift * 0.03 + noiseFactor * 0.025)
        }

        // --- Colour ---------------------------------------------------
        // Scale the vibrance boost by how saturated the frame already is: a
        // vivid sunset needs none, a flat overcast street needs the full dose.
        let saturationHeadroom = clamp((0.42 - stats.saturation) / 0.42, 0, 1)
        recipe.vibrance = preset.vibrance * saturationHeadroom
        // Pull back anything already over-saturated rather than pushing more.
        recipe.saturation = stats.saturation > 0.55 ? 0.95 : 1.0

        // --- Detail ---------------------------------------------------
        // Clarity and sharpening do not distinguish between detail and grain;
        // they amplify whichever is there. On a noisy frame they are what
        // turns acceptable grain into obvious grain, so both scale down as
        // the noise goes up.
        recipe.clarity = preset.clarity * (1 - noiseFactor * 0.85)
        recipe.sharpness = preset.sharpness * (1 - noiseFactor * 0.7)
        recipe.noiseReduction = noiseFactor * 0.85

        // Past a certain amount of grain, clarity and sharpening have nothing
        // left to find: everything fine-grained in the frame is noise, so all
        // they can do is make it louder. Stop entirely rather than applying a
        // small amount of something actively harmful.
        if noiseFactor > 0.5 {
            recipe.clarity = 0
            recipe.sharpness = 0
        }

        // A crop is a magnification: the same grain is now spread over more
        // of the final picture, so ease off the detail work again.
        if recipe.cropped {
            recipe.clarity *= 0.75
            recipe.sharpness *= 0.75
            recipe.noiseReduction = min(1, recipe.noiseReduction * 1.25)
        }

        // Skin does not want clarity or much sharpening.
        if preset.protectsSkin, signals.hasPeople {
            recipe.clarity *= 0.45
            recipe.sharpness *= 0.65
        }

        recipe.vignette = preset.vignette
        return recipe
    }

    /// Gray-world blended with white-patch, applied at partial strength.
    ///
    /// Neither estimator is reliable alone: gray-world is thrown off by a
    /// frame dominated by one colour (grass, a red wall), and white-patch is
    /// thrown off by a specular highlight. The geometric mean of the two is
    /// considerably steadier than either.
    private func whiteBalanceGains(stats: ToneSignal,
                                   preset: ScenePreset,
                                   lightPhase: LightPhase,
                                   kind: SceneKind) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        func gains(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
            let gray = (rgb.r + rgb.g + rgb.b) / 3
            guard gray > 0.01 else { return (1, 1, 1) }
            return (gray / max(rgb.r, 0.01),
                    gray / max(rgb.g, 0.01),
                    gray / max(rgb.b, 0.01))
        }

        let world = gains(stats.meanRGB)
        let patch = gains(stats.highlightRGB)
        // Geometric mean of the two estimates.
        var combined = (r: sqrt(world.0 * patch.0),
                        g: sqrt(world.1 * patch.1),
                        b: sqrt(world.2 * patch.2))

        var strength = preset.whiteBalanceStrength

        // Golden hour and night are warm on purpose. Correcting them to
        // neutral is technically right and photographically wrong — it turns
        // a sunset into an overcast afternoon.
        let isWarmFrame = stats.meanRGB.r > stats.meanRGB.b * 1.06
        if isWarmFrame {
            switch lightPhase {
            case .goldenHour: strength *= 0.3
            case .night, .blueHour: strength *= 0.45
            default: break
            }
            if kind == .food || kind == .interior { strength *= 0.7 }
        }
        // Blue hour is meant to be blue.
        if lightPhase == .blueHour, stats.meanRGB.b > stats.meanRGB.r * 1.06 {
            strength *= 0.35
        }

        // Partial correction, then clamped. A gain outside this range is
        // almost always the estimator being fooled rather than a genuine cast.
        func temper(_ gain: CGFloat) -> CGFloat {
            clamp(pow(max(gain, 0.05), strength), 0.82, 1.22)
        }
        combined = (temper(combined.r), temper(combined.g), temper(combined.b))

        // Renormalise so the correction shifts colour without shifting
        // overall brightness — exposure is handled separately.
        let mean = (combined.r + combined.g + combined.b) / 3
        guard mean > 0.01 else { return (1, 1, 1) }
        return (combined.r / mean, combined.g / mean, combined.b / mean)
    }

    // MARK: - Application

    private func apply(recipe: EditRecipe, to input: CIImage, preset: ScenePreset) -> CIImage {
        var image = input

        if abs(recipe.exposureEV) > 0.02 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(recipe.exposureEV)
            image = filter.outputImage ?? image
        }

        let gains = recipe.whiteBalanceGains
        if abs(gains.r - 1) > 0.004 || abs(gains.b - 1) > 0.004 {
            let filter = CIFilter.colorMatrix()
            filter.inputImage = image
            filter.rVector = CIVector(x: gains.r, y: 0, z: 0, w: 0)
            filter.gVector = CIVector(x: 0, y: gains.g, z: 0, w: 0)
            filter.bVector = CIVector(x: 0, y: 0, z: gains.b, w: 0)
            filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            image = filter.outputImage ?? image
        }

        if recipe.shadowLift > 0.01 || recipe.highlightRecovery < 0.99 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.shadowAmount = Float(recipe.shadowLift)
            filter.highlightAmount = Float(recipe.highlightRecovery)
            filter.radius = 12
            image = filter.outputImage ?? image
        }

        if recipe.contrast > 0.01 || recipe.blackPoint > 0.002 {
            // Symmetrical S-curve pivoting on the mid-tone, with a black
            // point at the bottom end.
            //
            // point0 maps INPUT blackPoint to OUTPUT zero, so everything below
            // that input level is crushed to true black. Writing it the other
            // way round — (0, blackPoint) — lifts blacks to grey instead,
            // which washes the image out and puts every bit of shadow noise on
            // display. That was the bug here.
            let bend = recipe.contrast * 0.085
            let filter = CIFilter.toneCurve()
            filter.inputImage = image
            filter.point0 = CGPoint(x: recipe.blackPoint, y: 0)
            filter.point1 = CGPoint(x: 0.25, y: clamp(0.25 - bend, 0.02, 0.5))
            filter.point2 = CGPoint(x: 0.5, y: 0.5)
            filter.point3 = CGPoint(x: 0.75, y: clamp(0.75 + bend, 0.5, 0.98))
            filter.point4 = CGPoint(x: 1, y: 1)
            image = filter.outputImage ?? image
        }

        if recipe.vibrance > 0.01 {
            // Vibrance rather than saturation: it leaves already-saturated
            // colours and skin tones largely alone.
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(recipe.vibrance)
            image = filter.outputImage ?? image
        }

        if abs(recipe.saturation - 1) > 0.01 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = Float(recipe.saturation)
            filter.brightness = 0
            filter.contrast = 1
            image = filter.outputImage ?? image
        }

        if recipe.clarity > 0.01 {
            // Large radius, low intensity: local contrast rather than edge
            // sharpening, which is what gives a photo "presence" without
            // looking crunchy. The multiplier is deliberately conservative —
            // an auto-edit that is occasionally too timid is a much smaller
            // failure than one that is occasionally too heavy, because nobody
            // notices the first and everybody notices the second.
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = 12
            filter.intensity = Float(recipe.clarity * 0.32)
            image = filter.outputImage ?? image
        }

        if recipe.noiseReduction > 0.01 {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = image
            // CINoiseReduction's own `sharpness` re-sharpens after denoising;
            // keeping it low avoids undoing the work we just did.
            filter.noiseLevel = Float(recipe.noiseReduction * 0.045)
            filter.sharpness = Float(0.25 + recipe.sharpness * 0.35)
            image = filter.outputImage ?? image
        }

        if recipe.sharpness > 0.01 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(recipe.sharpness * 0.45)
            filter.radius = 1.4
            image = filter.outputImage ?? image
        }

        if recipe.vignette > 0.01 {
            let filter = CIFilter.vignette()
            filter.inputImage = image
            filter.intensity = Float(recipe.vignette)
            filter.radius = 1.6
            image = filter.outputImage ?? image
        }

        return image
    }

    // MARK: - Output

    /// Encodes to HEIF where available, falling back to JPEG.
    ///
    /// EXIF, TIFF and GPS dictionaries are carried across so the saved asset
    /// keeps its capture date, lens data and location.
    private func encode(_ image: CIImage, carryingMetadataFrom properties: [String: Any]) -> Data? {
        var options: [CIImageRepresentationOption: Any] = [:]
        for key in [kCGImagePropertyExifDictionary,
                    kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary] {
            if let value = properties[key as String] {
                options[CIImageRepresentationOption(rawValue: key as String)] = value
            }
        }

        if let heif = context.heifRepresentation(of: image,
                                                 format: .RGBA8,
                                                 colorSpace: outputColorSpace,
                                                 options: options) {
            return heif
        }

        var jpegOptions = options
        jpegOptions[CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)] = 0.95
        return context.jpegRepresentation(of: image,
                                          colorSpace: outputColorSpace,
                                          options: jpegOptions)
    }

    private func thumbnail(from image: CIImage, maxDimension: CGFloat = 480) -> UIImage? {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, extent.isInfinite == false else { return nil }
        let scale = min(1, maxDimension / max(extent.width, extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The editor's slice of user settings, passed in so `AutoEditor` does not
/// depend on the settings object directly.
struct EditSettings {
    var autoEdit: Bool
    var autoStraighten: Bool
    var keepOriginal: Bool
    var useAppleAutoEnhance: Bool
}
