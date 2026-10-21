import Combine
import Foundation

/// User-facing preferences, persisted in `UserDefaults`.
///
/// Written with explicit `@Published` properties and manual persistence rather
/// than `@AppStorage`. `@AppStorage` is a `DynamicProperty` built for views: on
/// an `ObservableObject` it writes to defaults but never fires
/// `objectWillChange`, so nothing observing this object would redraw and the
/// toggles in Settings would appear stuck.
final class AppSettings: ObservableObject {

    private let defaults: UserDefaults

    /// Off by default. Having the shutter fire on its own is startling when
    /// you are still deciding, and it takes the one decision that is genuinely
    /// yours — when the moment is right — away from you.
    @Published var autoShutter: Bool { didSet { persist(autoShutter, Keys.autoShutter) } }

    /// Crop captures to the suggested box.
    @Published var cropToSuggestion: Bool { didSet { persist(cropToSuggestion, Keys.cropToSuggestion) } }
    @Published var spokenDirections: Bool { didSet { persist(spokenDirections, Keys.spokenDirections) } }
    @Published var keepOriginal: Bool { didSet { persist(keepOriginal, Keys.keepOriginal) } }
    @Published var autoEdit: Bool { didSet { persist(autoEdit, Keys.autoEdit) } }
    @Published var autoStraighten: Bool { didSet { persist(autoStraighten, Keys.autoStraighten) } }
    @Published var showGrid: Bool { didSet { persist(showGrid, Keys.showGrid) } }
    @Published var showHorizon: Bool { didSet { persist(showHorizon, Keys.showHorizon) } }
    @Published var hapticFeedback: Bool { didSet { persist(hapticFeedback, Keys.hapticFeedback) } }
    @Published var useLocation: Bool { didSet { persist(useLocation, Keys.useLocation) } }

    /// When true, the top panel hands out shots from the assignment library
    /// instead of reading the scene in front of you. Off by default: reacting
    /// to whatever you point at is the more useful behaviour, and being told
    /// to go find a window portrait is not much help when you are stood in a
    /// field.
    @Published var useAssignments: Bool { didSet { persist(useAssignments, Keys.useAssignments) } }

    /// Apple's own `autoAdjustmentFilters` run before our scene-aware stack.
    /// Off by default: it is face-aware and decent, but it has no idea which
    /// kind of photo this is, and stacking it under our own tone work tends to
    /// double-correct. Exposed for people who prefer its look.
    @Published var useAppleAutoEnhance: Bool { didSet { persist(useAppleAutoEnhance, Keys.useAppleAutoEnhance) } }

    @Published var albumName: String {
        didSet {
            // An empty album name would create an untitled album, so fall
            // back rather than letting a half-typed field through.
            let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? Defaults.albumName : trimmed, forKey: Keys.albumName)
        }
    }

    /// Album name with the empty case already handled, for the saver.
    var effectiveAlbumName: String {
        let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Defaults.albumName : trimmed
    }

    /// The parameter is named `store` rather than `defaults` on purpose: the
    /// helper below must close over the local, not over `self.defaults`, since
    /// `self` is not yet fully initialized at that point.
    init(defaults store: UserDefaults = .standard) {
        self.defaults = store
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            store.object(forKey: key) as? Bool ?? fallback
        }
        autoShutter = bool(Keys.autoShutter, false)
        cropToSuggestion = bool(Keys.cropToSuggestion, true)
        spokenDirections = bool(Keys.spokenDirections, false)
        keepOriginal = bool(Keys.keepOriginal, false)
        autoEdit = bool(Keys.autoEdit, true)
        autoStraighten = bool(Keys.autoStraighten, true)
        showGrid = bool(Keys.showGrid, true)
        showHorizon = bool(Keys.showHorizon, true)
        hapticFeedback = bool(Keys.hapticFeedback, true)
        useLocation = bool(Keys.useLocation, true)
        useAssignments = bool(Keys.useAssignments, false)
        useAppleAutoEnhance = bool(Keys.useAppleAutoEnhance, false)
        albumName = store.string(forKey: Keys.albumName) ?? Defaults.albumName
    }

    private func persist(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private enum Defaults {
        static let albumName = "Framewise"
    }

    enum Keys {
        static let autoShutter = "autoShutter"
        static let cropToSuggestion = "cropToSuggestion"
        static let spokenDirections = "spokenDirections"
        static let keepOriginal = "keepOriginal"
        static let autoEdit = "autoEdit"
        static let autoStraighten = "autoStraighten"
        static let showGrid = "showGrid"
        static let showHorizon = "showHorizon"
        static let hapticFeedback = "hapticFeedback"
        static let useLocation = "useLocation"
        static let useAssignments = "useAssignments"
        static let useAppleAutoEnhance = "useAppleAutoEnhance"
        static let albumName = "albumName"
    }
}
