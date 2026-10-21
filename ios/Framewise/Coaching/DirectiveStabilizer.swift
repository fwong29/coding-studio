import Foundation

/// Keeps the on-screen directive from flickering.
///
/// The raw coach re-evaluates eight times a second, and near a threshold two
/// rules will trade places constantly. Text that rewrites itself three times a
/// second is unreadable and makes the app feel like it is guessing, so a new
/// directive has to hold for a moment before it replaces the current one —
/// unless it is clearly more urgent, in which case waiting would be worse.
final class DirectiveStabilizer {

    /// How long a candidate must persist before it takes over.
    private let dwellTime: TimeInterval = 0.45
    /// How long "all clear" must hold before the directive disappears.
    private let clearTime: TimeInterval = 0.2
    /// A candidate this many priority steps more urgent cuts the queue.
    private let urgentMargin = 3

    private(set) var current: Directive?
    private var candidate: Directive?
    private var candidateSince: TimeInterval = 0
    private var clearSince: TimeInterval?

    /// Returns the directive the UI should display, and whether it just
    /// changed (so the caller can fire a haptic or speak it).
    func update(with incoming: Directive?, now: TimeInterval) -> (directive: Directive?, changed: Bool) {
        guard let incoming else {
            // Nothing wrong. Hold the last directive briefly so a momentary
            // pass doesn't blink the text away and back.
            if clearSince == nil { clearSince = now }
            if let since = clearSince, now - since >= clearTime {
                let changed = current != nil
                current = nil
                candidate = nil
                return (nil, changed)
            }
            return (current, false)
        }

        clearSince = nil

        // Same advice as we're already showing: nothing to do.
        if let current, current == incoming {
            candidate = nil
            return (current, false)
        }

        // Clearly more urgent than what's on screen — switch now.
        if let current, incoming.priority + urgentMargin <= current.priority {
            self.current = incoming
            candidate = nil
            return (incoming, true)
        }

        // Nothing on screen yet — show it immediately.
        if current == nil {
            current = incoming
            candidate = nil
            return (incoming, true)
        }

        // Otherwise make it earn the slot.
        if candidate != incoming {
            candidate = incoming
            candidateSince = now
            return (current, false)
        }
        if now - candidateSince >= dwellTime {
            current = incoming
            candidate = nil
            return (incoming, true)
        }
        return (current, false)
    }

    func reset() {
        current = nil
        candidate = nil
        clearSince = nil
    }
}
