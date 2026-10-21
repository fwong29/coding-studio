import AVFoundation
import Combine
import CoreImage
import Foundation
import QuartzCore
import UIKit

/// Owns the capture session, the analysis loop and the capture pipeline.
///
/// Threading: `AVCaptureSession` configuration happens on `sessionQueue`,
/// frame analysis on `analysisQueue`, and every `@Published` write is hopped
/// back to the main queue. Nothing crosses those boundaries without going
/// through one of those three places.
final class CameraController: NSObject, ObservableObject {

    // MARK: - Published state

    @Published private(set) var coaching = CoachingState()
    @Published private(set) var directive: Directive?
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var permissionDenied = false
    /// Displayed video aspect ratio (width / height) for overlay mapping.
    @Published private(set) var videoAspect: CGFloat = 3.0 / 4.0
    @Published private(set) var lastCapture: EditedCapture?
    @Published private(set) var toast: String?
    @Published private(set) var zoomFactor: CGFloat = 1
    /// Where-to-stand advice for whatever the camera is looking at right now.
    @Published private(set) var brief = SceneBrief()

    let session = AVCaptureSession()

    // MARK: - Private

    private let sessionQueue = DispatchQueue(label: "framewise.session")
    private let analysisQueue = DispatchQueue(label: "framewise.analysis", qos: .userInitiated)
    private let editQueue = DispatchQueue(label: "framewise.edit", qos: .userInitiated)

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var deviceInput: AVCaptureDeviceInput?

    private let analyzer = FrameAnalyzer()
    private let coach = CompositionCoach()
    /// Damps Vision's frame-to-frame wobble before anything is shown.
    private var smoother = SignalSmoother()
    private let advisor = AngleAdvisor()
    private let stabilizer = DirectiveStabilizer()
    private let editor = AutoEditor()
    private let saver = PhotoSaver()
    private let voice = VoiceCoach()

    /// Keyed by `AVCapturePhotoSettings.uniqueID` so each in-flight capture
    /// keeps its delegate alive.
    private var processors: [Int64: PhotoCaptureProcessor] = [:]
    private let processorLock = NSLock()

    /// Most recent analysis, handed to the editor at capture time.
    private var latestSignals = SceneSignals()
    /// The crop that was on screen when the shutter fired, so what you get is
    /// what the box showed.
    private var latestCrop: CGRect?
    private let signalsLock = NSLock()

    /// Vertical field of view of the active format, for horizon geometry.
    private var verticalFOV: CGFloat = 63

    /// Set when an assignment is active; otherwise we fall back to the
    /// per-scene default so free shooting still gets coached.
    private var assignmentTarget: FramingTarget?

    // Auto-shutter bookkeeping.
    private var readySince: TimeInterval?
    private var lastCaptureAt: TimeInterval = 0
    private var wasReady = false

    var autoShutterEnabled = false
    var hapticsEnabled = true
    private var cropToSuggestion = true
    private var editSettings = EditSettings(autoEdit: true,
                                            autoStraighten: true,
                                            keepOriginal: false,
                                            useAppleAutoEnhance: false)
    private var albumName = "Framewise"
    private var lightContext = LightContext()
    /// The brief is recomputed about once a second rather than on every
    /// analysed frame: positional advice that rewrites itself eight times a
    /// second is unreadable, and the underlying facts barely change that fast.
    private var lastBriefAt: TimeInterval = 0
    private let briefInterval: TimeInterval = 1.0

    /// Called when a photo has been saved, so the assignment can be retired.
    var onSaved: (() -> Void)?

    // MARK: - Lifecycle

    override init() {
        super.init()
        analyzer.onSignals = { [weak self] signals in
            self?.handle(signals: signals)
        }
    }

    func applySettings(_ settings: AppSettings) {
        autoShutterEnabled = settings.autoShutter
        hapticsEnabled = settings.hapticFeedback
        voice.isEnabled = settings.spokenDirections
        editSettings = EditSettings(autoEdit: settings.autoEdit,
                                    autoStraighten: settings.autoStraighten,
                                    keepOriginal: settings.keepOriginal,
                                    useAppleAutoEnhance: settings.useAppleAutoEnhance)
        albumName = settings.effectiveAlbumName
        cropToSuggestion = settings.cropToSuggestion
        Haptics.shared.enabled = settings.hapticFeedback
    }

    func setLightContext(_ context: LightContext) {
        lightContext = context
        // Recompute immediately: the sun moving into golden hour, or the
        // compass settling, both change the advice straight away.
        lastBriefAt = 0
    }

    /// Installs the framing contract from the active assignment. Pass `nil` to
    /// go back to scene-derived defaults.
    func setAssignmentTarget(_ target: FramingTarget?) {
        assignmentTarget = target
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.permissionDenied = true }
                return
            }
            self.sessionQueue.async {
                self.configureIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async {
                    self.isRunning = self.session.isRunning
                    Haptics.shared.prepare()
                }
            }
            self.analyzer.start()
        }
    }

    func stop() {
        analyzer.stop()
        voice.deactivate()
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    // MARK: - Session configuration

    private var isConfigured = false

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        // `.photo` gives the full sensor resolution for stills while still
        // feeding the video data output for analysis.
        session.sessionPreset = .photo

        guard let device = bestRearCamera() else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.toast = CaptureError.cameraUnavailable.localizedDescription }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            deviceInput = input
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async { self.toast = error.localizedDescription }
            return
        }

        photoOutput.maxPhotoQualityPrioritization = .quality
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()

        configureDevice(device)
        updateGeometry(for: device)
    }

    /// Prefers a multi-lens virtual device so the zoom range is continuous and
    /// the system can pick the sharpest lens for the distance.
    private func bestRearCamera() -> AVCaptureDevice? {
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: preferred,
                                                         mediaType: .video,
                                                         position: .back)
        for type in preferred {
            if let match = discovery.devices.first(where: { $0.deviceType == type }) {
                return match
            }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
        } catch {
            // Non-fatal; the defaults are reasonable.
        }
    }

    private func updateGeometry(for device: AVCaptureDevice) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else { return }

        // The sensor delivers landscape frames; the app is portrait-locked, so
        // the displayed aspect is the inverse.
        let aspect = CGFloat(dimensions.height) / CGFloat(dimensions.width)

        // `videoFieldOfView` is measured across the sensor's wider axis, which
        // becomes the screen's vertical axis in portrait.
        let fov = CGFloat(device.activeFormat.videoFieldOfView)

        DispatchQueue.main.async {
            self.videoAspect = aspect > 0 ? aspect : 3.0 / 4.0
        }
        verticalFOV = fov > 1 ? fov : 63
    }

    // MARK: - Interaction

    /// Tap to focus and meter at a point in frame space.
    func focus(atFrameSpacePoint point: CGPoint) {
        sessionQueue.async {
            guard let device = self.deviceInput?.device else { return }
            // `focusPointOfInterest` is expressed in the sensor's native
            // landscape space, where (0,0) is the top-left with the home
            // button on the right. Portrait frame space is that space rotated
            // 90 degrees clockwise, so inverting the rotation gives:
            //   deviceX = frameY,  deviceY = 1 - frameX
            let devicePoint = CGPoint(x: point.y, y: 1 - point.x)
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                // Ignore: focus is best-effort.
            }
        }
    }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async {
            guard let device = self.deviceInput?.device else { return }
            let clamped = clamp(factor, device.minAvailableVideoZoomFactor,
                                min(device.maxAvailableVideoZoomFactor, 8))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped }
            } catch {
                // Ignore.
            }
        }
    }

    // MARK: - Analysis loop

    private func handle(signals rawSignals: SceneSignals) {
        // Smooth before anything else so the coach, the advisor and the UI all
        // see the same calm view of the scene.
        let signals = smoother.smooth(rawSignals)

        signalsLock.lock()
        latestSignals = signals
        signalsLock.unlock()

        // An assignment's framing contract wins; otherwise fall back to the
        // default for whatever the camera thinks it's looking at.
        let target = assignmentTarget ?? FramingTarget.default(for: signals.kind)

        let state = coach.evaluate(signals: signals,
                                   target: target,
                                   verticalFOVDegrees: verticalFOV)

        signalsLock.lock()
        latestCrop = state.crop.isFullFrame ? nil : state.crop.rect
        signalsLock.unlock()

        let now = CACurrentMediaTime()
        let (stable, changed) = stabilizer.update(with: state.directive, now: now)

        var newBrief: SceneBrief?
        if now - lastBriefAt >= briefInterval {
            lastBriefAt = now
            newBrief = advisor.brief(signals: signals, light: lightContext)
        }

        var published = state
        published.directive = stable

        // Auto-shutter: the frame has to hold "ready" for a beat, so we don't
        // fire on a frame that passed by accident while the phone was moving.
        var shouldFire = false
        if state.isReady {
            if readySince == nil { readySince = now }
            let heldLongEnough = now - (readySince ?? now) >= 0.40
            let pastCooldown = now - lastCaptureAt >= 2.5
            shouldFire = autoShutterEnabled && heldLongEnough && pastCooldown
        } else {
            readySince = nil
        }

        let becameReady = state.isReady && !wasReady
        wasReady = state.isReady

        DispatchQueue.main.async {
            self.coaching = published
            self.directive = stable
            if let newBrief, newBrief != self.brief {
                self.brief = newBrief
            }

            if becameReady {
                Haptics.shared.lock()
            } else if changed, stable != nil {
                Haptics.shared.directiveChanged()
            }

            if changed, let stable {
                self.voice.say(stable, now: now)
            }
        }

        if shouldFire {
            lastCaptureAt = now
            readySince = nil
            capture()
        }
    }

    // MARK: - Capture

    func capture() {
        // The outer closure captures `self` weakly too. Declaring `[weak self]`
        // only on the inner closures, under an enclosing closure that captured
        // `self` strongly, is a contradiction the compiler warns about — and a
        // pointless one, since the strong outer capture keeps the object alive
        // regardless of what the inner ones say.
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }

            self.signalsLock.lock()
            let signals = self.latestSignals
            let crop = self.cropToSuggestion ? self.latestCrop : nil
            self.signalsLock.unlock()

            let settings = self.makePhotoSettings()
            let id = settings.uniqueID

            let processor = PhotoCaptureProcessor(
                settingsID: id,
                signals: signals,
                onWillCapture: { [weak self] in
                    DispatchQueue.main.async {
                        self?.isCapturing = true
                        Haptics.shared.shutter()
                    }
                },
                onFinish: { [weak self] result, capturedSignals in
                    guard let self else { return }
                    self.processorLock.lock()
                    self.processors[id] = nil
                    self.processorLock.unlock()
                    self.finishCapture(result: result, signals: capturedSignals, crop: crop)
                })

            self.processorLock.lock()
            self.processors[id] = processor
            self.processorLock.unlock()

            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func makePhotoSettings() -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        // HEIF where the device supports it: better quality per byte, and
        // Photos handles it natively.
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .quality
        settings.flashMode = .off
        return settings
    }

    private func finishCapture(result: Result<Data, Error>,
                               signals: SceneSignals,
                               crop: CGRect?) {
        switch result {
        case .failure(let error):
            DispatchQueue.main.async {
                self.isCapturing = false
                self.toast = error.localizedDescription
                Haptics.shared.failure()
            }

        case .success(let data):
            editQueue.async {
                var processed = self.editor.process(data: data,
                                                    signals: signals,
                                                    lightPhase: self.lightContext.sun.phase,
                                                    crop: crop,
                                                    settings: self.editSettings)
                // Advice for the frame as it was actually shot, so the review
                // sheet can say how to shoot it again.
                processed.brief = self.advisor.brief(signals: signals,
                                                     light: self.lightContext)

                // Frozen into a `let` before the Task picks it up. A `var`
                // referenced from concurrently-executing code is a warning
                // today and an error under Swift 6, and rightly so — nothing
                // should be able to mutate this out from under the save.
                let finished = processed

                Task {
                    do {
                        try await self.saver.save(finished, albumName: self.albumName)
                        await MainActor.run {
                            self.isCapturing = false
                            self.lastCapture = finished
                            self.toast = "Saved to Photos"
                            Haptics.shared.saved()
                            self.onSaved?()
                        }
                    } catch {
                        await MainActor.run {
                            self.isCapturing = false
                            self.lastCapture = finished
                            self.toast = error.localizedDescription
                            Haptics.shared.failure()
                        }
                    }
                }
            }
        }
    }

    func clearToast() {
        toast = nil
    }

    func clearLastCapture() {
        lastCapture = nil
    }
}

// MARK: - Frame delivery

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        // The analyzer throttles internally and bails if a pass is still
        // running, so it's safe to hand it every frame.
        analyzer.process(pixelBuffer: pixelBuffer,
                         timestamp: timestamp.isFinite ? timestamp : CACurrentMediaTime())
    }
}
