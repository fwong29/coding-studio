import AVFoundation
import Foundation

/// One-shot delegate for a single `capturePhoto` call.
///
/// `AVCapturePhotoOutput` keeps only a weak reference to its delegate, so each
/// in-flight capture needs an owner that outlives the round trip. The
/// controller holds these in a dictionary keyed by the settings' unique ID and
/// drops them when the capture finishes.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {

    let requestedSettingsID: Int64
    /// Scene analysis as it stood at the instant of capture — the editor needs
    /// the scene kind and the roll angle from *then*, not from whenever the
    /// edit happens to run.
    let signals: SceneSignals

    private let onWillCapture: () -> Void
    private let onFinish: (Result<Data, Error>, SceneSignals) -> Void

    init(settingsID: Int64,
         signals: SceneSignals,
         onWillCapture: @escaping () -> Void,
         onFinish: @escaping (Result<Data, Error>, SceneSignals) -> Void) {
        self.requestedSettingsID = settingsID
        self.signals = signals
        self.onWillCapture = onWillCapture
        self.onFinish = onFinish
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onWillCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            onFinish(.failure(error), signals)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            onFinish(.failure(CaptureError.noData), signals)
            return
        }
        onFinish(.success(data), signals)
    }
}

enum CaptureError: LocalizedError {
    case noData
    case cameraUnavailable
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .noData: return "The camera returned an empty frame."
        case .cameraUnavailable: return "No usable camera on this device."
        case .notAuthorized: return "Framewise needs camera access. Enable it in Settings › Privacy › Camera."
        }
    }
}
