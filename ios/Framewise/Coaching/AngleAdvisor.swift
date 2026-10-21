import CoreGraphics
import Foundation

/// Where the sun is, and where you're pointing.
struct LightContext {
    var sun: SunState = .unknown
    /// Camera bearing, degrees clockwise from true north.
    var headingDegrees: Double?

    /// Sun bearing relative to the camera axis, in -180...180.
    /// 0 means dead ahead — you are shooting straight into it. 180 means it is
    /// directly behind you.
    var relativeSunBearing: Double? {
        guard let heading = headingDegrees,
              sun.azimuthDegrees.isFinite,
              sun.elevationDegrees.isFinite,
              // Below the horizon there is no directional sun to talk about.
              sun.elevationDegrees > -2 else { return nil }
        var delta = sun.azimuthDegrees - heading
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    /// How the sun sits relative to the shot.
    enum SunRelation: Equatable {
        case intoTheSun
        case sideLit(fromLeft: Bool)
        case behindCamera
        case unknown
    }

    var sunRelation: SunRelation {
        guard let bearing = relativeSunBearing else { return .unknown }
        let magnitude = abs(bearing)
        if magnitude < 40 { return .intoTheSun }
        if magnitude > 140 { return .behindCamera }
        // Positive bearing means the sun is clockwise of the camera axis,
        // i.e. off to the photographer's right.
        return .sideLit(fromLeft: bearing < 0)
    }
}

/// One piece of positional advice about a scene.
struct ShotAdvice: Identifiable, Equatable {
    enum Axis: String {
        case light
        case height
        case distance
        case angle
        case background
        case timing

        var symbol: String {
            switch self {
            case .light: return "sun.max"
            case .height: return "arrow.up.and.down"
            case .distance: return "arrow.left.and.right"
            case .angle: return "cube"
            case .background: return "square.3.layers.3d"
            case .timing: return "clock"
            }
        }
    }

    let id: String
    let axis: Axis
    /// Imperative, one line. "Get down to its eye level."
    let headline: String
    /// The reason and the specifics.
    let detail: String
    /// Lower sorts first.
    let priority: Int

    static func == (lhs: ShotAdvice, rhs: ShotAdvice) -> Bool {
        lhs.id == rhs.id && lhs.headline == rhs.headline
    }
}

/// What the advisor makes of the scene in front of the camera.
struct SceneBrief: Equatable {
    /// One line naming what the app thinks it is looking at and in what light.
    /// Shown so you can tell at a glance whether to trust the rest.
    var read: String = "Looking…"
    var advice: [ShotAdvice] = []
    var sceneKind: SceneKind = .unknown

    var isEmpty: Bool { advice.isEmpty }
}

/// Generates where-to-stand and what-angle advice for whatever the camera
/// happens to be looking at.
///
/// This is the counterpart to `CompositionCoach`, and the split is deliberate.
/// The coach handles the last few inches — pan, tilt, level, the corrections
/// you make without moving your feet. The advisor handles the decisions you
/// make *with* your feet: how high to hold the camera, which side to shoot
/// from, where the light should be coming from, whether to come back later.
///
/// Like the coach, it is a pure function of the signals, so the same scene
/// always produces the same advice.
struct AngleAdvisor {

    func brief(signals: SceneSignals, light: LightContext) -> SceneBrief {
        var brief = SceneBrief()
        brief.sceneKind = signals.kind
        brief.read = read(signals: signals, light: light)

        var advice: [ShotAdvice] = []
        advice.append(contentsOf: lightAdvice(signals, light))
        advice.append(contentsOf: heightAdvice(signals))
        advice.append(contentsOf: distanceAdvice(signals))
        advice.append(contentsOf: angleAdvice(signals))
        advice.append(contentsOf: backgroundAdvice(signals))
        advice.append(contentsOf: timingAdvice(signals, light))

        // Four is about as much as anyone can hold in their head while also
        // looking at a subject.
        brief.advice = Array(advice.sorted { $0.priority < $1.priority }.prefix(4))
        return brief
    }

    // MARK: - Scene read

    private func read(signals: SceneSignals, light: LightContext) -> String {
        let subject: String
        switch signals.kind {
        case .unknown:
            subject = signals.hasPeople ? "Someone in frame" : "Not sure what this is yet"
        case .portrait: subject = "A portrait"
        case .groupPortrait: subject = "A group"
        case .pet: subject = "An animal"
        case .food: subject = "Food"
        case .landscape: subject = "A wide view"
        case .architecture: subject = "A building"
        case .street: subject = "A street scene"
        case .stillLife: subject = "An object"
        case .flora: subject = "Plants"
        case .nightScene: subject = "A night scene"
        case .interior: subject = "An interior"
        }

        var parts = [subject]

        switch signals.elevationBand {
        case .straightDown: parts.append("shot straight down")
        case .steeplyDown: parts.append("shot steeply from above")
        case .down: parts.append("shot from above")
        case .level: parts.append("shot level")
        case .up: parts.append("shot from below")
        case .steeplyUp: parts.append("shot steeply upward")
        }

        parts.append("in \(signals.lightDirection.displayName)")
        return parts.joined(separator: ", ")
    }

    // MARK: - Light

    /// Light advice comes first because it is the thing you cannot fix later
    /// and the thing that most changes the picture.
    private func lightAdvice(_ signals: SceneSignals, _ light: LightContext) -> [ShotAdvice] {
        var result: [ShotAdvice] = []
        let phase = light.sun.phase

        // Backlight is the one condition that actively fights you, so it leads.
        if signals.lightDirection == .backlit {
            if signals.hasPeople {
                result.append(ShotAdvice(
                    id: "light.backlit.people",
                    axis: .light,
                    headline: "Walk around to the lit side",
                    detail: "The light is behind them, so their face is in shadow. Either move until it falls on their face, or stay put and tap their face on screen to expose for it — that keeps the glow and loses the background.",
                    priority: 0))
            } else {
                result.append(ShotAdvice(
                    id: "light.backlit.object",
                    axis: .light,
                    headline: "Move so the light hits the subject",
                    detail: "You're shooting into it. Circle round until the light is beside or behind you — unless the subject is translucent, like a leaf or a drink, in which case stay and let it glow through.",
                    priority: 1))
            }
        }

        // Sun-relative advice, when we know which way we're facing.
        switch light.sunRelation {
        case .intoTheSun where signals.lightDirection != .backlit:
            result.append(ShotAdvice(
                id: "light.intoSun",
                axis: .light,
                headline: "You're shooting into the sun",
                detail: "Turn about 90° so the sun is over your left or right shoulder. Side light gives the subject shape; straight into it gives you flare and a silhouette.",
                priority: 1))

        case .behindCamera:
            result.append(ShotAdvice(
                id: "light.flatFromBehind",
                axis: .light,
                headline: "Move 90° — the light's flat",
                detail: "The sun is behind you, filling in every shadow, which is why this looks a bit lifeless. Walk a quarter circle around the subject so the light rakes across it instead.",
                priority: 3))

        case .sideLit(let fromLeft):
            result.append(ShotAdvice(
                id: "light.sideGood",
                axis: .light,
                headline: "Good light — keep the sun to your \(fromLeft ? "left" : "right")",
                detail: "You've got side light, which is what gives texture and depth. Hold this position and move the subject rather than yourself.",
                priority: 7))

        case .unknown, .intoTheSun:
            break
        }

        // Indoor window light, read off the frame's brightness imbalance.
        if light.sunRelation == .unknown || signals.kind == .interior || signals.kind == .food {
            switch signals.lightDirection {
            case .fromLeft, .fromRight:
                let side = signals.lightDirection == .fromLeft ? "left" : "right"
                result.append(ShotAdvice(
                    id: "light.windowSide",
                    axis: .light,
                    headline: "Light's coming from your \(side)",
                    detail: "That's the good setup — keep it to the side. Put the subject about an arm's length from the window and shoot across the light rather than along it.",
                    priority: 8))
            case .frontal:
                result.append(ShotAdvice(
                    id: "light.frontalFlat",
                    axis: .light,
                    headline: "Find a window and put it to the side",
                    detail: "The light is coming from behind you, so nothing has a shadow and the subject looks flat. Move so a window or lamp is 90° to the subject instead.",
                    priority: 3))
            case .fromAbove where signals.hasPeople:
                result.append(ShotAdvice(
                    id: "light.overheadPeople",
                    axis: .light,
                    headline: "Get them out from under the overhead light",
                    detail: "Light straight down casts shadows into the eye sockets and under the nose. Move to a window, or have them tip their chin up slightly toward the light.",
                    priority: 2))
            default:
                break
            }
        }

        // Hard midday sun.
        if phase == .harshDaylight, signals.hasPeople, signals.tone.highlightClipped > 0.03 {
            result.append(ShotAdvice(
                id: "light.openShade",
                axis: .light,
                headline: "Move into open shade",
                detail: "Find the shaded side of a building or a doorway, stand them just inside it facing out toward the bright sky, and shoot from the shade too. Overhead sun this hard is unkind to faces.",
                priority: 2))
        }

        // Golden hour is worth saying out loud, because it is short.
        if phase == .goldenHour {
            result.append(ShotAdvice(
                id: "light.golden",
                axis: .light,
                headline: "Use the low sun deliberately",
                detail: "Two options from here: put it directly behind the subject for a bright rim around them, or 90° to the side for long shadows and texture. Both beat pointing it at the front of them.",
                priority: 5))
        }

        if phase == .night || signals.kind == .nightScene {
            result.append(ShotAdvice(
                id: "light.nightPool",
                axis: .light,
                headline: "Find one light and stand in the dark",
                detail: "Put the subject inside a single pool of light — a streetlamp, a shop window, a doorway — and keep yourself outside it. Then brace the phone against a wall so the long exposure stays sharp.",
                priority: 2))
        }

        return result
    }

    // MARK: - Camera height

    /// Height is the correction that most often transforms a snapshot, and
    /// almost nobody makes it unprompted: people shoot everything from standing
    /// eye level because that is where their eyes already are.
    private func heightAdvice(_ signals: SceneSignals) -> [ShotAdvice] {
        var result: [ShotAdvice] = []
        let band = signals.elevationBand

        switch signals.kind {
        case .pet:
            if band == .down || band == .steeplyDown || band == .straightDown {
                result.append(ShotAdvice(
                    id: "height.petEyeLevel",
                    axis: .height,
                    headline: "Get down to its eye level",
                    detail: "Kneel, or lie down. Shooting down at an animal gives you the top of its head and makes it look small and far away; at its own level you get its face and its expression.",
                    priority: 1))
            }

        case .portrait, .groupPortrait:
            if band == .down || band == .steeplyDown {
                result.append(ShotAdvice(
                    id: "height.portraitTooHigh",
                    axis: .height,
                    headline: "Come down to their eye height",
                    detail: "You're above them, which shrinks them and foreshortens the face. Match your lens to their eyes — crouch if they're sitting or shorter than you.",
                    priority: 2))
            } else if band == .up || band == .steeplyUp {
                result.append(ShotAdvice(
                    id: "height.portraitTooLow",
                    axis: .height,
                    headline: "You're shooting up at them",
                    detail: "From below you get nostrils and a looming jaw. Stand up or step back until the phone is level with their eyes.",
                    priority: 2))
            }

        case .food:
            // The angles that work for food are the two extremes. The middle
            // is the one to get out of.
            if band == .steeplyDown {
                result.append(ShotAdvice(
                    id: "height.foodCommit",
                    axis: .height,
                    headline: "Pick one: straight down, or down at the table",
                    detail: "This in-between angle flattens the food without giving you the graphic overhead look. Either stand right over it and hold the phone flat, or drop to about 30° above the table — the angle you'd see your own plate from.",
                    priority: 2))
            } else if band == .level || band == .up {
                result.append(ShotAdvice(
                    id: "height.foodTooLow",
                    axis: .height,
                    headline: "Come up to about 30°",
                    detail: "From table level you mostly see the rim of the plate. Lift to roughly 30° above the surface so you can see into the dish.",
                    priority: 3))
            }

        case .flora, .stillLife:
            if band == .down || band == .steeplyDown {
                result.append(ShotAdvice(
                    id: "height.smallSubjectLevel",
                    axis: .height,
                    headline: "Crouch to its level",
                    detail: "Looking down on a small thing is how everyone photographs it and why those photos look like records rather than pictures. Get the phone level with it and the background drops away behind.",
                    priority: 2))
            }

        case .architecture, .interior:
            if band == .up || band == .steeplyUp {
                result.append(ShotAdvice(
                    id: "height.architectureTilt",
                    axis: .height,
                    headline: "Back up instead of tilting up",
                    detail: "Tilting makes the verticals converge so the building looks like it's toppling. Walk back until the whole thing fits with the phone held plumb — across the street if you have to.",
                    priority: 2))
            }

        case .landscape:
            if band == .level, signals.subjectBounds == nil {
                result.append(ShotAdvice(
                    id: "height.landscapeLow",
                    axis: .height,
                    headline: "Get low and find a foreground",
                    detail: "A wide view from standing height reads flat. Crouch down and put something close to the lens — a rock, a flower, a puddle — so the picture has a near, middle and far.",
                    priority: 3))
            }

        case .street, .nightScene, .unknown:
            break
        }

        return result
    }

    // MARK: - Distance

    private func distanceAdvice(_ signals: SceneSignals) -> [ShotAdvice] {
        guard let box = signals.subjectBounds, signals.subjectConfidence > 0.3 else { return [] }
        let target = FramingTarget.default(for: signals.kind)
        let area = box.area

        if area < target.subjectArea.lowerBound * 0.75 {
            let ratio = target.subjectArea.lowerBound / max(area, 0.001)
            // Area scales with the square of distance, so halving your distance
            // roughly quadruples the subject's share of the frame.
            let closerBy = sqrt(Double(ratio))
            let phrase = closerBy > 2.4 ? "a lot closer" : "two or three steps closer"
            return [ShotAdvice(
                id: "distance.closer",
                axis: .distance,
                headline: "Get \(phrase)",
                detail: String(format: "The subject is only about %.0f%% of the frame. Walk in rather than zooming — moving your feet changes the perspective and drops the background away, zooming just crops.", Double(area) * 100),
                priority: 4)]
        }

        if area > target.subjectArea.upperBound * 1.3 {
            return [ShotAdvice(
                id: "distance.back",
                axis: .distance,
                headline: "Take a step back",
                detail: "The subject is filling the frame to the edges, so there's nowhere for the eye to rest. Give it some space around it, or commit fully and go in much closer for a detail.",
                priority: 5)]
        }

        return []
    }

    // MARK: - Shooting angle

    private func angleAdvice(_ signals: SceneSignals) -> [ShotAdvice] {
        var result: [ShotAdvice] = []

        switch signals.kind {
        case .portrait:
            if let face = signals.primaryFace, let yaw = face.yaw, abs(yaw) < 0.12 {
                result.append(ShotAdvice(
                    id: "angle.portraitSquare",
                    axis: .angle,
                    headline: "Turn them off square",
                    detail: "Dead-on reads like a passport photo. Have them angle their shoulders away from you and bring just their face back toward the lens — that one adjustment does more than anything else here.",
                    priority: 6))
            }

        case .architecture, .stillLife, .interior:
            if signals.elevationBand == .level, signals.edgeClutter < 0.5 {
                result.append(ShotAdvice(
                    id: "angle.corner",
                    axis: .angle,
                    headline: "Shoot the corner, not the face",
                    detail: "Straight-on gives you a flat rectangle. Move round so you can see two sides meeting at an edge and it reads as a solid object — unless you're after deliberate symmetry, in which case line up exactly.",
                    priority: 6))
            }

        case .pet:
            result.append(ShotAdvice(
                id: "angle.petFront",
                axis: .angle,
                headline: "Come at it from the front, slightly off-centre",
                detail: "Head-on but a few degrees to one side gives you both eyes and some shape to the muzzle. Make a noise just before you shoot to get the ears up.",
                priority: 7))

        case .food:
            if signals.elevationBand == .straightDown {
                result.append(ShotAdvice(
                    id: "angle.foodFlat",
                    axis: .angle,
                    headline: "Hold the phone genuinely flat",
                    detail: "Overhead only works if it's exact — a few degrees of tilt reads as a mistake rather than a style. Also turn the plate so the light crosses it instead of coming over your shoulder.",
                    priority: 5))
            }

        case .landscape, .street, .flora, .nightScene, .groupPortrait, .unknown:
            break
        }

        return result
    }

    // MARK: - Background

    private func backgroundAdvice(_ signals: SceneSignals) -> [ShotAdvice] {
        guard signals.edgeClutter > 0.55 else { return [] }

        // With a small subject the fix is to move in; with a large one the
        // subject is fine and it's the surround that needs changing.
        let subjectIsSmall = (signals.subjectBounds?.area ?? 0) < 0.2

        return [ShotAdvice(
            id: "background.clutter",
            axis: .background,
            headline: subjectIsSmall ? "Move in to lose the clutter" : "Change what's behind it",
            detail: subjectIsSmall
                ? "The edges of the frame are busy and they're pulling the eye off the subject. Getting closer crops the distraction out and softens whatever is left."
                : "The background is competing with the subject. One step sideways usually finds a plainer wall; getting low and shooting slightly upward puts sky or ceiling behind it instead.",
            priority: 6)]
    }

    // MARK: - Timing

    private func timingAdvice(_ signals: SceneSignals, _ light: LightContext) -> [ShotAdvice] {
        var result: [ShotAdvice] = []

        // Only worth suggesting you come back for scenes that are not going
        // anywhere. A pet or a plate of food will not wait for better light.
        let isStaticScene = [SceneKind.landscape, .architecture, .street].contains(signals.kind)

        if light.sun.phase == .harshDaylight,
           isStaticScene,
           let until = light.sun.timeToGoldenHour,
           until < 4 * 3600 {
            result.append(ShotAdvice(
                id: "timing.comeBack",
                axis: .timing,
                headline: "Worth coming back in \(minutesPhrase(until))",
                detail: "This scene will look completely different in low side light — long shadows, warm colour, actual depth. Midday sun from overhead is the flattest light of the day.",
                priority: 9))
        }

        if light.sun.phase == .goldenHour, let remaining = light.sun.goldenHourRemaining {
            result.append(ShotAdvice(
                id: "timing.goldenRemaining",
                axis: .timing,
                headline: "About \(minutesPhrase(remaining)) of this light left",
                detail: "Golden hour closes fast and the last ten minutes are usually the best of it. Shoot the thing you most want now and experiment afterwards.",
                priority: 9))
        }

        return result
    }

    private func minutesPhrase(_ interval: TimeInterval) -> String {
        let total = Int((interval / 60).rounded())
        if total >= 90 { return String(format: "%.1f hours", Double(total) / 60) }
        return "\(max(1, total)) min"
    }
}
