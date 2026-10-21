import CoreGraphics
import Foundation

/// Searches the frame for the best-looking rectangle.
///
/// This replaces deriving a crop from one detected subject. That approach kept
/// producing boxes the size of the whole screen, because it could only ever
/// say "put the thing I found in the right place" — and when the thing it
/// found was a loose region covering most of the frame, the answer was the
/// frame. Searching instead asks a different question: of all the rectangles
/// in this picture, which one is the best photograph?
///
/// Every candidate is scored in constant time against `FrameMaps`, so a few
/// hundred of them cost almost nothing.
struct AestheticCropFinder {

    /// Crop sizes to try, as a fraction of the frame's width and height.
    /// Nothing below 0.45: a 12 MP capture cropped that hard still yields
    /// about 2.4 MP, and below that the crop costs more than it gains.
    private let scales: [CGFloat] = [0.45, 0.55, 0.65, 0.78, 0.9]
    /// Spacing of candidate positions.
    private let step: CGFloat = 0.07

    func find(maps: FrameMaps, signals: SceneSignals) -> CropSuggestion {
        // A face has to survive the crop intact, so it becomes a hard
        // constraint rather than one term among many.
        let mustContain: CGRect? = signals.primaryFace.map {
            $0.bounds.insetBy(dx: -0.03, dy: -0.04)
        }

        let frameSaliency = maps.totalSaliency
        guard frameSaliency > 0.0001 else { return .fullFrame }

        var best: (rect: CGRect, score: Float)?

        for scale in scales {
            let limit = 1 - scale
            guard limit >= 0 else { continue }

            var y: CGFloat = 0
            while y <= limit + 0.0001 {
                var x: CGFloat = 0
                while x <= limit + 0.0001 {
                    let rect = CGRect(x: min(x, limit), y: min(y, limit),
                                      width: scale, height: scale)

                    if let mustContain, !rect.contains(mustContain) {
                        x += step
                        continue
                    }

                    let score = evaluate(rect: rect,
                                         maps: maps,
                                         frameSaliency: frameSaliency,
                                         signals: signals)
                    if best == nil || score > best!.score {
                        best = (rect, score)
                    }
                    x += step
                }
                y += step
            }
        }

        guard let best else { return .fullFrame }

        // Compare against keeping the whole frame. Cropping has to actually
        // earn its place — if the full frame scores about as well, there is no
        // advice worth giving and the box would just be clutter.
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        let wholeScore = evaluate(rect: whole,
                                  maps: maps,
                                  frameSaliency: frameSaliency,
                                  signals: signals)

        guard best.score > wholeScore * 1.06, best.rect.width <= 0.92 else {
            return CropSuggestion(rect: whole,
                                  confidence: 0,
                                  isFullFrame: true,
                                  reason: "The whole frame works",
                                  label: label(from: signals))
        }

        return CropSuggestion(
            rect: best.rect,
            confidence: CGFloat(min(1, best.score / max(wholeScore, 0.0001) - 1) * 3),
            isFullFrame: false,
            reason: describe(best.rect),
            label: label(from: signals))
    }

    // MARK: - Scoring

    /// Attention a crop may lose before it starts being penalised.
    private let keepThreshold: Float = 0.70
    /// Density gain over the frame average that counts as fully concentrated.
    private let fullConcentration: Float = 3.0

    /// Weighted sum of the things that make a rectangle a better photograph.
    ///
    /// The weights below were tuned against ten synthetic scenes — subjects
    /// small, medium, large, centred, at the edge, doubled, plus a cluttered
    /// room and a blank frame — checking both that a box appears when it
    /// should and that the chosen size tracks the subject's size. Earlier
    /// versions failed that check completely, returning the full frame for
    /// every scene, which is exactly what the app did on device.
    private func evaluate(rect: CGRect,
                          maps: FrameMaps,
                          frameSaliency: Float,
                          signals: SceneSignals) -> Float {

        let frameMean = frameSaliency / Float(FrameMaps.side * FrameMaps.side)
        let mass = maps.saliencyMass(in: rect)
        let density = maps.meanSaliency(in: rect)

        // How concentrated the attention is compared with the frame as a
        // whole. This is the term that rewards cropping in at all.
        let concentration = min(1, max(0, density / max(frameMean, 0.000001) - 1)
                                    / fullConcentration)

        // Penalty for throwing the subject away. Nothing while the crop keeps
        // most of the interest, then steep — a tidy rectangle of background is
        // not an improvement on a messy one containing the subject.
        let captured = mass / frameSaliency
        let loss = max(0, keepThreshold - captured) / keepThreshold

        // Penalty for slicing through something interesting: attention in a
        // thin band just outside the edge. A good crop boundary falls in quiet
        // territory.
        let outer = rect.insetBy(dx: -0.05, dy: -0.05)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let ringMass = max(0, maps.saliencyMass(in: outer) - mass)
        let ringArea = max(0.0001, Float(outer.area - rect.area))
        let cut = min(1, (ringMass / ringArea) / max(density, 0.05))

        // Enough going on to be worth looking at. A crop of blank wall is
        // beautifully clean and completely dull.
        let detail = min(1, maps.meanDetail(in: rect) / 0.09)

        let luma = maps.meanLuma(in: rect)
        let exposure = 1 - min(1, abs(luma - 0.47) / 0.42)
        let clipping = 1 - min(1, maps.clippedFraction(in: rect) / 0.18)

        // Composition: where the attention sits within this crop.
        var composition: Float = 0.5
        if let centroid = maps.saliencyCentroid(in: rect), rect.width > 0 {
            let relative = CGPoint(x: (centroid.x - rect.minX) / rect.width,
                                   y: (centroid.y - rect.minY) / rect.height)
            let wantsCentre = signals.kind == .food
                || signals.kind == .architecture
                || signals.kind == .interior
            if wantsCentre {
                composition = Float(1 - min(1, relative.distance(to: CGPoint(x: 0.5, y: 0.5)) / 0.5))
            } else {
                let nearest = Thirds.intersections
                    .map { relative.distance(to: $0) }
                    .min() ?? 0.5
                composition = Float(1 - min(1, nearest / 0.35))
            }
        }

        // Preference for keeping resolution. Carries real weight: without it
        // the search crops as tightly as it is allowed to, whatever the
        // subject's size.
        let size = Float(rect.width)

        return concentration * 2.2
            + composition * 1.3
            + detail * 0.6
            + exposure * 0.6
            + clipping * 0.5
            + size * 0.8
            - loss * 2.6
            - cut * 1.4
    }

    // MARK: - Wording

    private func describe(_ rect: CGRect) -> String {
        let tightness = rect.width < 0.6 ? "Much tighter" : "Tighter"
        let centre = rect.center
        if centre.x < 0.4 { return "\(tightness), to the left" }
        if centre.x > 0.6 { return "\(tightness), to the right" }
        if centre.y < 0.4 { return "\(tightness), up top" }
        if centre.y > 0.6 { return "\(tightness), down low" }
        return "\(tightness), centred"
    }

    private func label(from signals: SceneSignals) -> String? {
        guard let raw = signals.topLabels.first else {
            if !signals.faces.isEmpty {
                return signals.faces.count > 1 ? "people" : "face"
            }
            return nil
        }
        let cleaned = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !cleaned.isEmpty, cleaned.count <= 34 else { return nil }
        return cleaned
    }
}
