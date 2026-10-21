import UIKit

/// Thin wrapper over UIKit feedback generators.
///
/// Haptics carry real information here: the lock tap tells you the frame is
/// right without making you read anything, which matters when your eye is on
/// the subject rather than the screen.
///
/// Feedback generators must be driven from the main thread, and callers here
/// are spread across the session, analysis and capture queues, so every entry
/// point hops to main itself rather than making each call site remember.
final class Haptics {
    static let shared = Haptics()

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let selection = UISelectionFeedbackGenerator()
    private let notice = UINotificationFeedbackGenerator()

    var enabled = true

    private init() {}

    private func onMain(_ work: @escaping () -> Void) {
        guard enabled else { return }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func prepare() {
        onMain {
            self.light.prepare()
            self.medium.prepare()
            self.rigid.prepare()
        }
    }

    /// Fired the moment composition locks up.
    func lock() {
        onMain { self.rigid.impactOccurred(intensity: 0.9) }
    }

    /// Fired when the active directive changes, as a cue to glance down.
    func directiveChanged() {
        onMain { self.selection.selectionChanged() }
    }

    func shutter() {
        onMain { self.medium.impactOccurred() }
    }

    func saved() {
        onMain { self.notice.notificationOccurred(.success) }
    }

    func failure() {
        onMain { self.notice.notificationOccurred(.error) }
    }
}
