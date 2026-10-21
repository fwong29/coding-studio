import CoreVideo
import Foundation
import Vision

/// Runs Vision and tone analysis over live camera frames and publishes a
/// `SceneSignals` snapshot.
///
/// Cost control is the main design concern. Saliency and face detection run at
/// roughly 8 Hz, which is fast enough for the aim marker to feel attached to
/// the subject; whole-image classification is much heavier and only runs about
/// once a second, since what kind of photo you are taking does not change
/// frame to frame.
final class FrameAnalyzer {

    /// Called on an internal queue whenever a new snapshot is ready.
    var onSignals: ((SceneSignals) -> Void)?

    private let motion = MotionMonitor()
    private let classifier = SceneClassifier()

    private let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let humanRequest = VNDetectHumanRectanglesRequest()
    private let classifyRequest = VNClassifyImageRequest()

    private var lastGeometryPass: TimeInterval = 0
    private var lastClassifyPass: TimeInterval = 0
    private var isBusy = false
    private let busyLock = NSLock()

    /// Classification results persist between passes so the scene kind does
    /// not flicker on the frames where we skip the expensive request.
    private var cachedKind: SceneKind = .unknown
    private var cachedKindConfidence: CGFloat = 0
    private var cachedLabels: [String] = []

    private let geometryInterval: TimeInterval = 1.0 / 8.0
    private let classifyInterval: TimeInterval = 1.0

    init() {
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
    }

    func start() { motion.start() }
    func stop() { motion.stop() }

    var motionSignal: MotionSignal { motion.signal }

    /// Entry point from the capture delegate. Returns immediately if a pass is
    /// already running, so a slow frame never backs up the pipeline.
    func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        busyLock.lock()
        if isBusy || timestamp - lastGeometryPass < geometryInterval {
            busyLock.unlock()
            return
        }
        isBusy = true
        lastGeometryPass = timestamp
        busyLock.unlock()

        defer {
            busyLock.lock()
            isBusy = false
            busyLock.unlock()
        }

        var signals = SceneSignals()
        signals.timestamp = timestamp
        signals.motion = motion.signal

        // Tone first: it needs the buffer locked, and it is cheap.
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let measured = ToneAnalyzer.analyze(pixelBuffer: pixelBuffer)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        signals.tone = measured.tone
        signals.edgeClutter = measured.clutter
        signals.sharpness = measured.sharpness

        // The rear camera delivers buffers in landscape-right regardless of how
        // the phone is held; the app is portrait-locked, so `.right` is the
        // orientation that makes Vision's output line up with what is on screen.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .right,
                                            options: [:])

        let runClassifier = timestamp - lastClassifyPass >= classifyInterval
        var requests: [VNRequest] = [saliencyRequest, faceRequest, humanRequest]
        if runClassifier {
            lastClassifyPass = timestamp
            requests.append(classifyRequest)
        }

        do {
            try handler.perform(requests)
        } catch {
            // A failed pass is not worth reporting: the next frame is 125ms
            // away. Publish what we have so levelling still works.
            onSignals?(signals)
            return
        }

        // Faces.
        if let faces = faceRequest.results {
            signals.faces = faces.map { observation in
                FaceSignal(bounds: FrameSpace.fromVision(observation.boundingBox),
                           yaw: observation.yaw.map { CGFloat($0.doubleValue) },
                           roll: observation.roll.map { CGFloat($0.doubleValue) })
            }
        }

        // Human bodies.
        if let humans = humanRequest.results {
            signals.humanBodies = humans.map { FrameSpace.fromVision($0.boundingBox) }
        }

        let saliencyObservation = saliencyRequest.results?.first as? VNSaliencyImageObservation

        // Low-resolution maps for the crop search. Built once per pass and
        // queried a few hundred times, so the cost is in here rather than in
        // the search.
        signals.maps = FrameMaps(pixelBuffer: pixelBuffer, saliency: saliencyObservation)

        // Saliency also gives a single subject anchor, for the coaching rules.
        if let saliency = saliencyObservation {
            if let box = primarySalientBox(saliency) {
                signals.subjectBounds = box.rect
                signals.subjectPoint = box.rect.center
                signals.subjectConfidence = box.confidence
            } else if let centroid = heatmapCentroid(saliency) {
                signals.subjectPoint = centroid
                signals.subjectConfidence = 0.3
            }
        }

        // A face, when present, is a better anchor than raw saliency: people
        // look at faces, and saliency often latches onto a bright background.
        if let face = signals.primaryFace {
            signals.subjectBounds = face.bounds
            signals.subjectPoint = CGPoint(x: face.bounds.midX, y: face.bounds.midY)
            signals.subjectConfidence = max(signals.subjectConfidence, 0.8)
        }

        // Classification.
        if runClassifier, let results = classifyRequest.results {
            let labels = results
                .filter { $0.confidence > 0.08 }
                .prefix(16)
                .map { (identifier: $0.identifier, confidence: $0.confidence) }
            let outcome = classifier.classify(labels: Array(labels),
                                              faces: signals.faces,
                                              bodies: signals.humanBodies,
                                              tone: signals.tone,
                                              elevationDegrees: signals.motion.elevationDegrees)
            cachedKind = outcome.kind
            cachedKindConfidence = outcome.confidence
            cachedLabels = outcome.top
        }
        signals.kind = cachedKind
        signals.kindConfidence = cachedKindConfidence
        signals.topLabels = cachedLabels

        // Backlight check: compare the subject's own brightness against the
        // frame. Done on the sampled grid rather than a second Core Image pass
        // to keep the live path cheap.
        if let box = signals.subjectBounds {
            signals.subjectIsDarkerThanFrame = isSubjectDark(box: box,
                                                             pixelBuffer: pixelBuffer,
                                                             frameMean: signals.tone.meanLuma)
        }

        onSignals?(signals)
    }

    // MARK: - Saliency helpers

    private func primarySalientBox(_ observation: VNSaliencyImageObservation) -> (rect: CGRect, confidence: CGFloat)? {
        guard let objects = observation.salientObjects, !objects.isEmpty else { return nil }
        // Prefer the biggest salient region over the most confident one: a
        // large, moderately salient subject is what a person would call "the
        // thing in the photo".
        guard let best = objects.max(by: { $0.boundingBox.area < $1.boundingBox.area }) else { return nil }
        let rect = FrameSpace.fromVision(best.boundingBox)
        guard rect.width > 0.01, rect.height > 0.01 else { return nil }
        return (rect, clamp(CGFloat(best.confidence), 0, 1))
    }

    /// Intensity-weighted centroid of the saliency heat map, used when Vision
    /// does not isolate a discrete object (open landscapes, textures).
    private func heatmapCentroid(_ observation: VNSaliencyImageObservation) -> CGPoint? {
        let buffer = observation.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 1, height > 1,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float
        else { return nil }

        var weightedX: Float = 0
        var weightedY: Float = 0
        var total: Float = 0

        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                let weight = max(0, row[x])
                weightedX += weight * Float(x)
                weightedY += weight * Float(y)
                total += weight
            }
        }
        guard total > 0.0001 else { return nil }

        // The heat map shares Vision's bottom-left origin, so flip y.
        let normalized = CGPoint(x: CGFloat(weightedX / total) / CGFloat(width - 1),
                                 y: CGFloat(weightedY / total) / CGFloat(height - 1))
        return CGPoint(x: normalized.x, y: 1 - normalized.y)
    }

    /// Samples the subject rectangle directly out of the camera buffer.
    private func isSubjectDark(box: CGRect, pixelBuffer: CVPixelBuffer, frameMean: CGFloat) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        // Vision reported the box in portrait frame space, which is the
        // landscape buffer rotated 90 degrees clockwise. Undoing that
        // rotation maps a frame point (fx, fy) back to the buffer as:
        //   bufferX = fy * (width - 1)
        //   bufferY = (1 - fx) * (height - 1)
        let steps = 12
        var sum: Float = 0
        var count: Float = 0

        for i in 0..<steps {
            for j in 0..<steps {
                let fx = box.minX + box.width * (CGFloat(i) + 0.5) / CGFloat(steps)
                let fy = box.minY + box.height * (CGFloat(j) + 0.5) / CGFloat(steps)
                let bx = Int(fy * CGFloat(width - 1))
                let by = Int((1 - fx) * CGFloat(height - 1))
                guard bx >= 0, bx < width, by >= 0, by < height else { continue }
                let px = pointer.advanced(by: by * bytesPerRow + bx * 4)
                sum += 0.2126 * Float(px[2]) / 255
                    + 0.7152 * Float(px[1]) / 255
                    + 0.0722 * Float(px[0]) / 255
                count += 1
            }
        }
        guard count > 0 else { return false }
        let subjectMean = CGFloat(sum / count)
        // A third of a stop is noise; half the frame's brightness is backlight.
        return subjectMean < frameMean * 0.62
    }
}
