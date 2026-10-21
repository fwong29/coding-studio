import Combine
import CoreLocation
import Foundation

/// Decides what you should be photographing right now, and keeps a queue of
/// alternatives you can swipe through.
///
/// The selection is a scoring pass rather than a random draw, because an
/// assignment that cannot be done — a blue-hour shot at eleven in the morning,
/// an overhead flat lay when you are halfway up a hill — is worse than no
/// suggestion at all.
///
/// Not actor-isolated: it is constructed from a SwiftUI `View` initializer,
/// which is not main-actor isolated. Everything that mutates it already
/// arrives on the main thread — `CLLocationManager` delegate callbacks, the
/// scheduled `Timer`, and UI actions — so no extra hopping is needed.
final class ShotDirector: ObservableObject {

    @Published private(set) var current: ShotAssignment?
    /// Ranked alternatives behind the current one.
    @Published private(set) var queue: [ShotAssignment] = []
    @Published private(set) var sun: SunState = .unknown
    /// Camera bearing from the compass, when available.
    @Published private(set) var heading: Double?

    /// Pushed to the camera controller whenever the light or the bearing
    /// changes. A callback rather than an observed property because
    /// `SunState` carries `NaN` when unknown, and `NaN != NaN` would make an
    /// `onChange` observer fire on every single update.
    var onLightContextChange: ((LightContext) -> Void)?

    var lightContext: LightContext {
        LightContext(sun: sun, headingDegrees: heading)
    }
    /// Set when the user pins an assignment; stops automatic re-selection.
    @Published private(set) var isPinned = false

    private let location = LocationProvider()
    private var cancellables = Set<AnyCancellable>()

    /// Scene kinds seen recently, newest last. Used to match assignments to
    /// what is actually in front of the camera.
    private var recentKinds: [SceneKind] = []
    private var lastSelection: Date = .distantPast
    private var shotsThisSession: Set<String> = []
    private var refreshTimer: Timer?

    /// How long an assignment stays put before we reconsider. Long enough to
    /// actually attempt the shot.
    private let minimumHoldTime: TimeInterval = 45

    init(useLocation: Bool) {
        if useLocation {
            location.start()
            location.$coordinate
                .compactMap { $0 }
                .sink { [weak self] coordinate in
                    self?.updateSun(for: coordinate)
                }
                .store(in: &cancellables)

            location.$headingDegrees
                .sink { [weak self] value in
                    guard let self else { return }
                    self.heading = value
                    self.onLightContextChange?(self.lightContext)
                }
                .store(in: &cancellables)
        }
        updateSun(for: location.coordinate)

        // The light changes while you stand there, especially around sunset.
        // Fires on the main run loop, which is where the rest of this class
        // expects to be touched.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updateSun(for: self.location.coordinate)
            self.reselectIfStale()
        }
    }

    deinit {
        refreshTimer?.invalidate()
        location.stop()
    }

    // MARK: - Sun and light

    private func updateSun(for coordinate: CLLocationCoordinate2D?) {
        if let coordinate {
            sun = SunPosition.state(latitude: coordinate.latitude,
                                    longitude: coordinate.longitude)
        } else {
            var fallback = SunState.unknown
            fallback.phase = SunPosition.approximatePhase(from: Date())
            sun = fallback
        }
        onLightContextChange?(lightContext)
        if current == nil { reselect() }
    }

    /// A human-readable line about the light, shown on the assignment card.
    var lightSummary: String {
        var parts: [String] = [sun.phase.displayName]
        if let remaining = sun.goldenHourRemaining {
            parts.append("about \(minutes(remaining)) left")
        } else if let until = sun.timeToGoldenHour, until < 4 * 3600 {
            parts.append("golden hour in \(minutes(until))")
        }
        if sun.elevationDegrees.isFinite, sun.elevationDegrees > -6 {
            parts.append("sun to the \(sun.compassDirection)")
        }
        return parts.joined(separator: " · ")
    }

    private func minutes(_ interval: TimeInterval) -> String {
        let total = Int((interval / 60).rounded())
        if total >= 90 {
            let hours = Double(total) / 60
            return String(format: "%.1f hr", hours)
        }
        return "\(max(1, total)) min"
    }

    // MARK: - Observing the scene

    /// Fed from the camera so assignments can match what you are pointing at.
    func noteScene(_ kind: SceneKind) {
        guard kind != .unknown else { return }
        recentKinds.append(kind)
        if recentKinds.count > 24 { recentKinds.removeFirst() }
        reselectIfStale()
    }

    /// Called after a successful capture, so the same assignment isn't handed
    /// back immediately.
    func markCompleted() {
        if let current {
            shotsThisSession.insert(current.id)
        }
        isPinned = false
        reselect()
    }

    // MARK: - Selection

    func next() {
        guard !queue.isEmpty else { reselect(); return }
        let promoted = queue.removeFirst()
        if let current { queue.append(current) }
        current = promoted
        lastSelection = Date()
        isPinned = true
    }

    func pin() { isPinned = true }

    func unpin() {
        isPinned = false
        reselect()
    }

    private func reselectIfStale() {
        guard !isPinned,
              Date().timeIntervalSince(lastSelection) > minimumHoldTime else { return }
        reselect()
    }

    private func reselect() {
        let ranked = ShotLibrary.all
            .map { (assignment: $0, score: score($0)) }
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }

        guard let best = ranked.first?.assignment else { return }
        current = best
        queue = ranked.dropFirst().prefix(6).map(\.assignment)
        lastSelection = Date()
    }

    /// Scores how well an assignment fits the moment. Zero means impossible
    /// right now and the assignment is dropped.
    private func score(_ assignment: ShotAssignment) -> Double {
        // Light is a hard filter. Telling someone to shoot blue hour at noon
        // is the fastest way to make the app feel stupid.
        let phase = sun.phase
        if phase != .unknown, !assignment.light.contains(phase) {
            // One exception: `.unknown` assignments work in any light.
            if !assignment.light.contains(.unknown) { return 0 }
        }

        var total = 1.0

        // Prefer shots that suit what the camera is already looking at.
        let dominant = dominantKind()
        if let dominant {
            if assignment.sceneKinds.contains(dominant) {
                total += 2.5
            } else if assignment.context == .indoor, dominant == .interior {
                total += 0.5
            }
        }

        // Indoors/outdoors, inferred from the scene rather than asked.
        switch (assignment.context, inferredContext()) {
        case (.indoor, .outdoor), (.outdoor, .indoor):
            total -= 1.4
        case (.indoor, .indoor), (.outdoor, .outdoor):
            total += 0.8
        default:
            break
        }

        // Golden hour is short — push the shots that need it to the front.
        if phase == .goldenHour, assignment.light == [.goldenHour] {
            total += 1.5
        }
        if phase == .blueHour, assignment.light.contains(.blueHour), assignment.light.count <= 2 {
            total += 1.5
        }

        // Don't repeat what we just shot.
        if shotsThisSession.contains(assignment.id) { total -= 3.0 }

        // Mild preference for easier shots, so a cold start isn't daunting.
        total += (4 - Double(assignment.difficulty)) * 0.2

        // A little noise keeps the app from always opening on the same card.
        total += Double.random(in: 0...0.35)

        return max(0, total)
    }

    /// Most frequent recent scene kind.
    private func dominantKind() -> SceneKind? {
        guard !recentKinds.isEmpty else { return nil }
        var tally: [SceneKind: Int] = [:]
        for kind in recentKinds.suffix(12) { tally[kind, default: 0] += 1 }
        return tally.max { $0.value < $1.value }?.key
    }

    private func inferredContext() -> ShootingContext {
        guard let dominant = dominantKind() else { return .either }
        switch dominant {
        case .interior, .food, .stillLife:
            return .indoor
        case .landscape, .architecture, .street:
            return .outdoor
        default:
            return .either
        }
    }
}
