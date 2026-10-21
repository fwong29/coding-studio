import CoreLocation
import Foundation

/// Supplies a coarse location, used only to work out where the sun is.
///
/// Deliberately low precision and never stored: we need to know roughly what
/// latitude you are at to compute golden hour, which does not require knowing
/// which building you are in.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Which way the back camera is pointing, in degrees clockwise from true
    /// north. Combined with the sun's azimuth this is what lets the app say
    /// "you're shooting into the sun — put it over your shoulder" instead of
    /// just "the light is bad".
    @Published private(set) var headingDegrees: Double?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 5000
        authorization = manager.authorizationStatus
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
            startHeading()
        default:
            break
        }
    }

    func stop() {
        manager.stopUpdatingHeading()
    }

    private func startHeading() {
        guard CLLocationManager.headingAvailable() else { return }
        // Five degrees is well inside the usable precision of a phone compass
        // and keeps the advice from rewriting itself as you breathe.
        manager.headingFilter = 5
        manager.headingOrientation = .portrait
        manager.startUpdatingHeading()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.requestLocation()
            startHeading()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // True heading needs a location fix; magnetic is the fallback and is
        // close enough for "which way is the sun".
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        guard heading >= 0, newHeading.headingAccuracy >= 0 else { return }
        headingDegrees = heading
    }

    func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        // Never interrupt the viewfinder with the figure-of-eight calibration
        // sheet; stale heading just means we skip sun-relative advice.
        false
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        coordinate = last.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to recover: without a fix we fall back to clock-only light
        // estimation, which is good enough to pick a sensible assignment.
    }
}
