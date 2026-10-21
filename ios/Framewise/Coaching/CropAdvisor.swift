import CoreGraphics
import Foundation

/// The best photo inside the photo you're currently pointing at.
struct CropSuggestion: Equatable {
    /// The suggested frame, in frame space (top-left origin).
    var rect: CGRect
    /// How much we trust it. Low confidence draws a fainter box.
    var confidence: CGFloat
    /// True when the whole frame is already the right crop, so the UI can go
    /// quiet rather than drawing a box around everything.
    var isFullFrame: Bool
    /// One short line explaining the crop.
    var reason: String
    /// What the box is of, in plain words — "glass office facade", "golden
    /// retriever". Naming the subject is what makes the box feel like the app
    /// understood the scene rather than drew a rectangle at random.
    var label: String?

    static let fullFrame = CropSuggestion(
        rect: CGRect(x: 0, y: 0, width: 1, height: 1),
        confidence: 0,
        isFullFrame: true,
        reason: "Whole frame",
        label: nil)
}

// The subject-derived crop that used to live here has been replaced by
// `AestheticCropFinder`, which searches the frame instead. `CropSuggestion`
// above is still the shared result type.
