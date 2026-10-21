import CoreGraphics
import Foundation

/// Turns measured scene signals into one piece of actionable advice plus a
/// readiness score.
///
/// Deliberately a pure value type with no stored state: given the same signals
/// and the same framing target it always produces the same answer, which makes
/// the rules easy to reason about and to test. Smoothing and anti-flicker live
/// in `DirectiveStabilizer`, one layer up.
struct CompositionCoach {

    private let cropFinder = AestheticCropFinder()

    func evaluate(signals: SceneSignals,
                  target: FramingTarget,
                  verticalFOVDegrees: CGFloat) -> CoachingState {

        var state = CoachingState()
        state.sceneKind = signals.kind
        state.rollDegrees = signals.motion.rollDegrees
        state.levelErrorDegrees = signals.motion.levelErrorDegrees
        state.subjectBounds = signals.subjectBounds
        state.horizonY = signals.horizonY(verticalFOVDegrees: verticalFOVDegrees)

        var checks: [Check] = []

        checks.append(contentsOf: exposureChecks(signals, target))
        checks.append(levelCheck(signals))
        if target.wantsLevelVerticals {
            checks.append(verticalsCheck(signals))
        }
        if let clipped = clippingCheck(signals) {
            checks.append(clipped)
        }
        if let backlight = backlightCheck(signals) {
            checks.append(backlight)
        }
        checks.append(shakeCheck(signals))
        if let focus = focusCheck(signals) {
            checks.append(focus)
        }
        checks.append(clutterCheck(signals))

        // Subject-dependent rules.
        if let subject = signals.subjectPoint {
            let aimTarget = target.placement.target(subject: subject, gazeX: signals.gazeX)
            state.aimTarget = aimTarget
            state.aimCurrent = subject

            if let sizeCheck = subjectSizeCheck(signals, target) {
                checks.append(sizeCheck)
            }

            if target.usesEyeLine, let face = signals.primaryFace {
                checks.append(eyeLineCheck(face: face, target: target))
                checks.append(horizontalPlacementCheck(subject: subject,
                                                       aimTarget: aimTarget,
                                                       target: target))
                // With an eye-line rule the aim ring belongs on the eyes, not
                // the centre of the head — that is what the user is matching.
                let eyeY = face.bounds.minY + face.bounds.height * 0.38
                state.aimCurrent = CGPoint(x: face.bounds.midX, y: eyeY)
                state.aimTarget = CGPoint(x: aimTarget.x, y: target.eyeLineY)
            } else {
                checks.append(placementCheck(subject: subject,
                                             aimTarget: aimTarget,
                                             target: target))
            }
        } else {
            checks.append(Check(id: .noSubject,
                                score: 0.35,
                                weight: 0.6,
                                // Critical. Without a subject there is nothing
                                // to compose around, so the frame cannot be
                                // "ready" however level and steady it is.
                                isCritical: true,
                                passThreshold: 0.5,
                                directive: Directive(id: .noSubject,
                                                     text: "Find your subject",
                                                     reason: "Nothing is standing out yet — move so one thing clearly dominates the frame",
                                                     nudge: .none,
                                                     priority: 13)))
        }

        if let horizonCheck = horizonPlacementCheck(signals, target, state.horizonY) {
            checks.append(horizonCheck)
        }

        state.checks = checks
        // Search the frame for the best-looking rectangle. Falls back to the
        // whole frame until the first analysis pass has produced maps.
        state.crop = signals.maps.map { cropFinder.find(maps: $0, signals: signals) }
            ?? .fullFrame

        // Readiness is the weighted average of every rule.
        let totalWeight = checks.reduce(0) { $0 + $1.weight }
        state.readiness = totalWeight > 0
            ? checks.reduce(0) { $0 + $1.score * $1.weight } / totalWeight
            : 0

        if let aimTarget = state.aimTarget, let current = state.aimCurrent {
            state.aimAligned = current.distance(to: aimTarget) <= target.aimTolerance
        }

        // Ready means every critical rule passes, not merely a good average:
        // a frame can average well while still being visibly crooked.
        //
        // It also requires a subject that is actually on its mark. Without
        // that last condition, pointing at nothing in particular while holding
        // the phone level passed every critical check there was — level and
        // steady — and the app cheerfully announced "That's the shot" at a
        // blank wall. Saying so is a claim about the composition, and there is
        // no composition without a subject.
        // Readiness is now measured by how little cropping is left to do.
        // That is the honest definition: the suggested crop shrinks as you
        // frame the subject properly yourself, so needing no crop means you
        // have already got it. It also gives the reading a visible cause —
        // the box on screen — rather than an invisible tolerance check.
        let criticalsPass = checks.filter(\.isCritical).allSatisfy(\.passes)
        let hasSubject = signals.subjectPoint != nil && signals.subjectConfidence > 0.25
        state.isReady = criticalsPass
            && state.readiness >= 0.80
            && hasSubject
            && state.crop.isFullFrame

        // Pick the single most urgent failing rule.
        state.directive = checks
            .filter { !$0.passes }
            .compactMap(\.directive)
            .min { lhs, rhs in lhs.priority < rhs.priority }

        return state
    }

    // MARK: - Exposure

    private func exposureChecks(_ signals: SceneSignals, _ target: FramingTarget) -> [Check] {
        var result: [Check] = []
        let tone = signals.tone

        // Underexposure. Judged against the scene's own target, so a night
        // shot is not told off for being dark.
        let shortfall = max(0, target.targetMedianLuma - tone.medianLuma)
        let darkScore = score(shortfall, good: 0.10, bad: 0.32)
        let veryDark = shortfall > 0.22
        result.append(Check(
            id: .exposureDark,
            score: darkScore,
            weight: 1.3,
            isCritical: veryDark,
            passThreshold: 0.45,
            directive: Directive(
                id: .exposureDark,
                text: veryDark ? "Too dark" : "Needs more light",
                reason: veryDark
                    ? "Turn toward a window or a light, or move somewhere brighter"
                    : "Open up the light a little — shadows this deep will go noisy",
                nudge: .none,
                priority: veryDark ? 0 : 6)))

        // Blown highlights. Only worth mentioning once a real area of the
        // frame is gone, not for a specular glint on a fork.
        let blownScore = score(tone.highlightClipped, good: 0.02, bad: 0.16)
        result.append(Check(
            id: .exposureBlown,
            score: blownScore,
            weight: 0.9,
            isCritical: false,
            passThreshold: 0.45,
            directive: Directive(
                id: .exposureBlown,
                text: "Highlights clipping",
                reason: "Tap the bright area to meter for it — blown white can't be recovered later",
                nudge: .none,
                priority: 10)))

        return result
    }

    private func backlightCheck(_ signals: SceneSignals) -> Check? {
        guard signals.isBacklit else { return nil }
        return Check(
            id: .backlight,
            score: 0.25,
            weight: 1.0,
            isCritical: false,
            passThreshold: 0.5,
            directive: Directive(
                id: .backlight,
                text: "Subject is backlit",
                reason: signals.hasPeople
                    ? "Turn them to face the light, or tap their face to meter for it"
                    : "Move around so the light falls on the subject instead of behind it",
                nudge: .none,
                priority: 2))
    }

    // MARK: - Geometry

    private func levelCheck(_ signals: SceneSignals) -> Check {
        let error = signals.motion.levelErrorDegrees
        let signed = signals.motion.signedLevelErrorDegrees
        // A positive signed error means the phone is rotated clockwise, so the
        // correction is counter-clockwise.
        let nudge: PhoneNudge = signed > 0 ? .rotateCounterClockwise : .rotateClockwise

        return Check(
            id: .level,
            score: score(error, good: 1.2, bad: 7.0),
            weight: 1.4,
            isCritical: true,
            passThreshold: 0.55,
            directive: Directive(
                id: .level,
                text: "Level it up",
                reason: String(format: "Off by %.0f°", Double(error)),
                nudge: nudge,
                priority: 4))
    }

    private func verticalsCheck(_ signals: SceneSignals) -> Check {
        // Pointing up or down at a building makes its verticals converge. Held
        // plumb, they stay parallel.
        let tilt = abs(signals.motion.elevationDegrees)
        let nudge: PhoneNudge = signals.motion.elevationDegrees > 0 ? .tiltDown : .tiltUp
        return Check(
            id: .verticals,
            score: score(tilt, good: 2.5, bad: 16),
            weight: 1.1,
            isCritical: false,
            passThreshold: 0.5,
            directive: Directive(
                id: .verticals,
                text: "Hold the phone plumb",
                reason: "Tilting makes the verticals lean — stand back and keep the phone upright instead",
                nudge: nudge,
                priority: 5))
    }

    private func clippingCheck(_ signals: SceneSignals) -> Check? {
        guard let box = signals.subjectBounds, box.area > 0.04 else { return nil }
        // How far the subject box runs past each edge.
        let overflow = max(max(0 - box.minX, box.maxX - 1),
                           max(0 - box.minY, box.maxY - 1))
        guard overflow > 0.001 else { return nil }

        // Which way to move to bring it back in.
        var nudge = PhoneNudge.none
        if box.minX < 0 { nudge = .panLeft }
        else if box.maxX > 1 { nudge = .panRight }
        else if box.minY < 0 { nudge = .tiltUp }
        else if box.maxY > 1 { nudge = .tiltDown }

        return Check(
            id: .subjectClipped,
            score: score(overflow, good: 0.01, bad: 0.12),
            weight: 1.3,
            isCritical: true,
            passThreshold: 0.6,
            directive: Directive(
                id: .subjectClipped,
                text: "Subject is cut off",
                reason: "Pull back until the whole subject sits inside the frame",
                nudge: nudge,
                priority: 1))
    }

    private func subjectSizeCheck(_ signals: SceneSignals, _ target: FramingTarget) -> Check? {
        guard let box = signals.subjectBounds, signals.subjectConfidence > 0.25 else { return nil }
        let area = box.area
        let range = target.subjectArea

        if area < range.lowerBound {
            // Score on the ratio, not the difference: going from 2% to 4% of
            // the frame matters as much as 20% to 40%.
            let ratio = range.lowerBound / max(area, 0.001)
            return Check(
                id: .subjectSize,
                score: score(ratio, good: 1.15, bad: 3.0),
                weight: 1.2,
                isCritical: true,
                passThreshold: 0.45,
                directive: Directive(
                    id: .subjectSize,
                    text: ratio > 2.2 ? "Much closer" : "Step closer",
                    reason: "The subject is small in the frame — fill it with the thing you care about",
                    nudge: .moveCloser,
                    priority: 7))
        }
        if area > range.upperBound {
            let ratio = area / max(range.upperBound, 0.001)
            return Check(
                id: .subjectSize,
                score: score(ratio, good: 1.15, bad: 2.4),
                weight: 1.0,
                isCritical: false,
                passThreshold: 0.45,
                directive: Directive(
                    id: .subjectSize,
                    text: "Back up a little",
                    reason: "Give the subject some room to breathe",
                    nudge: .moveBack,
                    priority: 7))
        }
        return Check(id: .subjectSize, score: 1, weight: 1.2,
                     isCritical: true, passThreshold: 0.45, directive: nil)
    }

    private func placementCheck(subject: CGPoint, aimTarget: CGPoint, target: FramingTarget) -> Check {
        let distance = subject.distance(to: aimTarget)
        let dx = aimTarget.x - subject.x
        let dy = aimTarget.y - subject.y

        // Move along whichever axis is further off, so the advice is one
        // simple action rather than a diagonal.
        var nudge = PhoneNudge.none
        if abs(dx) > abs(dy) {
            // Subject must travel left in frame => pan the camera right.
            if abs(dx) > target.aimTolerance * 0.7 { nudge = dx < 0 ? .panRight : .panLeft }
        } else {
            // Subject must travel up in frame => tilt the camera down.
            if abs(dy) > target.aimTolerance * 0.7 { nudge = dy < 0 ? .tiltDown : .tiltUp }
        }

        return Check(
            id: .placement,
            score: score(distance, good: target.aimTolerance, bad: target.aimTolerance + 0.24),
            weight: 1.5,
            isCritical: true,
            passThreshold: 0.5,
            directive: Directive(
                id: .placement,
                text: placementText(nudge),
                reason: "Move so the yellow box fills more of the frame",
                nudge: nudge,
                priority: 8))
    }

    private func horizontalPlacementCheck(subject: CGPoint, aimTarget: CGPoint, target: FramingTarget) -> Check {
        let dx = aimTarget.x - subject.x
        let nudge: PhoneNudge = abs(dx) <= target.aimTolerance
            ? .none
            : (dx < 0 ? .panRight : .panLeft)
        return Check(
            id: .placement,
            score: score(abs(dx), good: target.aimTolerance, bad: target.aimTolerance + 0.22),
            weight: 1.2,
            isCritical: true,
            passThreshold: 0.5,
            directive: Directive(
                id: .placement,
                text: placementText(nudge),
                reason: "Leave the space on the side they're looking toward",
                nudge: nudge,
                priority: 8))
    }

    private func placementText(_ nudge: PhoneNudge) -> String {
        switch nudge {
        case .panLeft: return "Pan left"
        case .panRight: return "Pan right"
        case .tiltUp: return "Tilt up"
        case .tiltDown: return "Tilt down"
        default: return "Hold it there"
        }
    }

    private func eyeLineCheck(face: FaceSignal, target: FramingTarget) -> Check {
        // Eyes sit roughly 38% down a detected face box.
        let eyeY = face.bounds.minY + face.bounds.height * 0.38
        let error = eyeY - target.eyeLineY
        // Eyes need to move up in frame => tilt the camera down.
        let nudge: PhoneNudge = abs(error) <= 0.05 ? .none : (error > 0 ? .tiltDown : .tiltUp)

        let reason: String
        if error > 0.05 {
            reason = "Their eyes are low in the frame — too much space above their head"
        } else if error < -0.05 {
            reason = "Their eyes are high — give a little headroom back"
        } else {
            reason = "Eye line is on the upper third"
        }

        return Check(
            id: .eyeLine,
            score: score(abs(error), good: 0.05, bad: 0.26),
            weight: 1.3,
            isCritical: true,
            passThreshold: 0.5,
            directive: Directive(id: .eyeLine,
                                 text: nudge == .tiltDown ? "Tilt down" : "Tilt up",
                                 reason: reason,
                                 nudge: nudge,
                                 priority: 7))
    }

    private func horizonPlacementCheck(_ signals: SceneSignals,
                                       _ target: FramingTarget,
                                       _ horizonY: CGFloat?) -> Check? {
        guard target.horizon != .none,
              let y = horizonY,
              y > 0.05, y < 0.95 else { return nil }

        let errorValue: CGFloat
        let wantsLower: Bool

        if let wanted = target.horizon.targetY {
            errorValue = abs(y - wanted)
            wantsLower = y < wanted
        } else {
            // .avoidCentre — only complain inside a band around the middle.
            let offCentre = abs(y - 0.5)
            guard offCentre < 0.10 else {
                return Check(id: .horizonPlacement, score: 1, weight: 0.8,
                             isCritical: false, passThreshold: 0.5, directive: nil)
            }
            errorValue = 0.10 - offCentre
            // Push it further out the way it is already leaning, not back
            // toward the middle: a horizon just above centre should go up.
            wantsLower = y > 0.5
        }

        // Moving the horizon DOWN the frame means tilting the camera UP.
        let nudge: PhoneNudge = wantsLower ? .tiltUp : .tiltDown

        return Check(
            id: .horizonPlacement,
            score: score(errorValue, good: 0.03, bad: 0.18),
            weight: 0.9,
            isCritical: false,
            passThreshold: 0.5,
            directive: Directive(
                id: .horizonPlacement,
                text: nudge == .tiltUp ? "Tilt up slightly" : "Tilt down slightly",
                reason: "A horizon through the middle splits the picture in two — put it on a third",
                nudge: nudge,
                priority: 9))
    }

    // MARK: - Technical

    private func shakeCheck(_ signals: SceneSignals) -> Check {
        let shake = signals.motion.shake
        let severe = shake > 0.22
        return Check(
            id: .shake,
            score: score(shake, good: 0.05, bad: 0.40),
            weight: 1.0,
            isCritical: true,
            passThreshold: 0.4,
            directive: Directive(
                id: .shake,
                text: "Hold still",
                reason: "Brace your elbows, or rest the phone on something",
                nudge: .none,
                priority: severe ? 3 : 11))
    }

    private func focusCheck(_ signals: SceneSignals) -> Check? {
        // Sharpness is unreliable on genuinely smooth scenes — a clear sky or
        // a white wall reads as blur. Only trust it when the frame has detail
        // to resolve and the phone is otherwise steady, so we're not just
        // re-reporting shake.
        guard signals.tone.contrast > 0.18, signals.motion.shake < 0.12 else { return nil }
        return Check(
            id: .focus,
            score: score(1 - signals.sharpness, good: 0.45, bad: 0.85),
            weight: 0.7,
            isCritical: false,
            passThreshold: 0.4,
            directive: Directive(
                id: .focus,
                text: "Looks soft",
                reason: "Tap your subject to lock focus on it",
                nudge: .none,
                priority: 11))
    }

    private func clutterCheck(_ signals: SceneSignals) -> Check {
        Check(
            id: .edgeClutter,
            score: score(signals.edgeClutter, good: 0.42, bad: 0.92),
            weight: 0.5,
            isCritical: false,
            passThreshold: 0.35,
            directive: Directive(
                id: .edgeClutter,
                text: "Busy edges",
                reason: "One step sideways usually clears the clutter out of the border",
                nudge: .none,
                priority: 12))
    }
}
