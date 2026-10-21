import AVFoundation
import Foundation

/// Speaks directions aloud, for when your eye is on the subject rather than
/// the screen.
///
/// Spoken guidance is only useful if it is sparse. We never interrupt
/// ourselves, never repeat the same instruction inside a cooldown, and keep
/// the phrasing to two or three words so it lands before the moment passes.
final class VoiceCoach {

    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpoken: String?
    private var lastSpokenAt: TimeInterval = 0
    /// Minimum gap before the same phrase may be repeated.
    private let repeatCooldown: TimeInterval = 4.0
    /// Minimum gap between any two utterances.
    private let minimumGap: TimeInterval = 1.2

    var isEnabled = false

    /// Configures the audio session to mix with whatever is already playing,
    /// and to duck it rather than stop it.
    func activate() {
        guard isEnabled else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback,
                                    mode: .voicePrompt,
                                    options: [.duckOthers, .mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            // Non-fatal: the visual coaching is the primary channel.
        }
    }

    func deactivate() {
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func say(_ directive: Directive, now: TimeInterval) {
        guard isEnabled else { return }
        speak(phrase(for: directive), now: now)
    }

    func announce(_ text: String, now: TimeInterval) {
        guard isEnabled else { return }
        speak(text, now: now)
    }

    private func speak(_ text: String, now: TimeInterval) {
        guard !synthesizer.isSpeaking else { return }
        guard now - lastSpokenAt >= minimumGap else { return }
        if text == lastSpoken, now - lastSpokenAt < repeatCooldown { return }

        activate()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)

        lastSpoken = text
        lastSpokenAt = now
    }

    /// Spoken wording is shorter and blunter than the on-screen text; "Off by
    /// four degrees" is useless when you are mid-shot.
    private func phrase(for directive: Directive) -> String {
        switch directive.id {
        case .level: return "Level it"
        case .placement:
            switch directive.nudge {
            case .panLeft: return "Pan left"
            case .panRight: return "Pan right"
            case .tiltUp: return "Tilt up"
            case .tiltDown: return "Tilt down"
            default: return "Hold there"
            }
        case .eyeLine: return directive.nudge == .tiltDown ? "Tilt down" : "Tilt up"
        case .subjectSize: return directive.nudge == .moveCloser ? "Closer" : "Back up"
        case .subjectClipped: return "Cut off, pull back"
        case .exposureDark: return "Too dark"
        case .exposureBlown: return "Too bright"
        case .backlight: return "Backlit"
        case .shake: return "Hold still"
        case .focus: return "Tap to focus"
        case .horizonPlacement: return directive.nudge == .tiltUp ? "Tilt up" : "Tilt down"
        case .edgeClutter: return "Busy edges"
        case .noSubject: return "Find a subject"
        case .verticals: return "Hold it plumb"
        }
    }
}
