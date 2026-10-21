import Foundation
import Vision

/// Turns Vision's image-classification labels into one of our `SceneKind`
/// buckets.
///
/// `VNClassifyImageRequest` returns a long tail of fine-grained labels
/// ("espresso", "golden_retriever", "cathedral"). We only need to know which
/// family of photograph this is, so we match labels against keyword groups and
/// let detected faces and ambient light break ties.
struct SceneClassifier {

    /// Keyword fragments matched as substrings against label identifiers.
    private static let keywords: [(kind: SceneKind, terms: [String])] = [
        (.food, ["food", "meal", "dish", "pizza", "burger", "sushi", "salad", "pasta",
                 "dessert", "cake", "bread", "coffee", "espresso", "cocktail", "drink",
                 "breakfast", "lunch", "dinner", "plate", "fruit", "vegetable", "cheese",
                 "soup", "noodle", "taco", "sandwich", "pastry", "ice_cream", "wine"]),
        (.pet, ["dog", "cat", "puppy", "kitten", "pet", "retriever", "terrier", "poodle",
                "bulldog", "spaniel", "feline", "canine", "rabbit", "hamster", "parrot",
                "bird", "horse"]),
        (.landscape, ["landscape", "mountain", "valley", "beach", "ocean", "sea", "lake",
                      "river", "sunset", "sunrise", "sky", "cloud", "field", "meadow",
                      "desert", "forest", "woodland", "coast", "cliff", "waterfall",
                      "hill", "glacier", "canyon", "horizon", "snow", "lagoon"]),
        (.architecture, ["building", "architecture", "skyscraper", "tower", "bridge",
                         "church", "cathedral", "mosque", "temple", "castle", "palace",
                         "facade", "monument", "stadium", "staircase", "arch", "column",
                         "house", "barn", "lighthouse", "dome"]),
        (.street, ["street", "city", "urban", "alley", "sidewalk", "crosswalk", "traffic",
                   "market", "shop", "storefront", "subway", "train_station", "bus",
                   "crowd", "neon", "graffiti", "taxi", "bicycle"]),
        (.flora, ["flower", "plant", "leaf", "tree", "garden", "blossom", "petal", "rose",
                  "tulip", "orchid", "fern", "succulent", "cactus", "moss", "bouquet"]),
        (.stillLife, ["still_life", "book", "bottle", "vase", "ceramic", "pottery", "watch",
                      "jewelry", "fabric", "texture", "tool", "candle", "stationery",
                      "camera", "instrument", "chair", "table"]),
        (.interior, ["interior", "room", "bedroom", "kitchen", "living_room", "office",
                     "cafe", "restaurant", "library", "museum", "hallway", "lobby",
                     "furniture", "lamp", "window", "indoor"]),
    ]

    /// Combines label evidence with face detection and ambient brightness.
    ///
    /// Order matters. Faces are the strongest cue we have: if someone's face
    /// fills a reasonable part of the frame, this is a portrait no matter what
    /// the classifier says about the wallpaper behind them.
    func classify(labels: [(identifier: String, confidence: Float)],
                  faces: [FaceSignal],
                  bodies: [CGRect],
                  tone: ToneSignal,
                  elevationDegrees: CGFloat) -> (kind: SceneKind, confidence: CGFloat, top: [String]) {

        let top = labels.prefix(8).map(\.identifier)

        // People first.
        let largestFace = faces.map(\.bounds.area).max() ?? 0
        if largestFace > 0.015 {
            let kind: SceneKind = faces.count >= 2 ? .groupPortrait : .portrait
            return (kind, clamp(CGFloat(largestFace) * 12 + 0.45, 0, 1), top)
        }
        if !bodies.isEmpty, (bodies.map(\.area).max() ?? 0) > 0.08 {
            // A body with no detectable face is usually a person in a scene
            // rather than a portrait, so lean on the labels to decide.
            if let scored = bestKeywordMatch(labels), scored.kind == .street {
                return (.street, scored.confidence, top)
            }
            return (.portrait, 0.4, top)
        }

        // Shooting straight down at a table is such a strong signal for food
        // and flat-lay still life that it outranks a weak label match.
        let shootingDownward = elevationDegrees < -55

        if let match = bestKeywordMatch(labels) {
            if shootingDownward, match.kind == .interior || match.kind == .unknown {
                return (.food, 0.4, top)
            }
            // A dark frame that labelled as a cityscape is a night shot, and
            // wants night treatment more than street treatment.
            if tone.isDark, match.kind == .street || match.kind == .architecture || match.kind == .landscape {
                return (.nightScene, max(match.confidence, 0.5), top)
            }
            return (match.kind, match.confidence, top)
        }

        if shootingDownward { return (.stillLife, 0.3, top) }
        if tone.isVeryDark { return (.nightScene, 0.4, top) }
        return (.unknown, 0.15, top)
    }

    private func bestKeywordMatch(_ labels: [(identifier: String, confidence: Float)]) -> (kind: SceneKind, confidence: CGFloat)? {
        var totals: [SceneKind: Float] = [:]

        for (index, label) in labels.prefix(12).enumerated() {
            let identifier = label.identifier.lowercased()
            // Earlier labels are more trustworthy, so weight by rank as well
            // as by the classifier's own confidence.
            let rankWeight = 1.0 / Float(index + 1)
            for group in Self.keywords where group.terms.contains(where: { identifier.contains($0) }) {
                totals[group.kind, default: 0] += label.confidence * rankWeight
                break
            }
        }

        guard let winner = totals.max(by: { $0.value < $1.value }), winner.value > 0.02 else {
            return nil
        }
        return (winner.key, clamp(CGFloat(winner.value) * 2.5, 0.2, 1))
    }
}
