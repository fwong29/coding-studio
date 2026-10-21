import CoreMotion
import Foundation

/// Reads device attitude so the coach can talk about levelling and tilt.
///
/// We derive angles from the gravity vector rather than from
/// `attitude.roll`/`.pitch` because gravity stays meaningful at every
/// orientation, including straight down at a plate of food, where Euler
/// angles get ambiguous.
final class MotionMonitor {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    /// Latest reading. Written on `queue`, read on the analysis queue, so
    /// access goes through a lock.
    private var _signal = MotionSignal()
    private let lock = NSLock()

    var signal: MotionSignal {
        lock.lock()
        defer { lock.unlock() }
        return _signal
    }

    init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.ingest(motion)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    private func ingest(_ motion: CMDeviceMotion) {
        let g = motion.gravity

        // Device axes: +x right, +y toward the top of the screen, +z out of
        // the screen. The rear camera looks along -z.
        //
        // Held upright in portrait aimed at the horizon, gravity is (0,-1,0):
        //   roll      = atan2(x, -y) = 0
        //   elevation = asin(z)      = 0
        // Laid flat on a table screen-up, gravity is (0,0,-1), so elevation
        // reads -90 degrees — the camera is pointing at the floor. Correct.
        let roll = atan2(g.x, -g.y) * 180 / .pi
        let elevation = asin(clamp(g.z, -1, 1)) * 180 / .pi

        let accel = motion.userAcceleration
        let shake = sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)

        lock.lock()
        // Smooth the shake reading; raw per-sample values spike constantly
        // even when the phone is being held reasonably still.
        _signal.shake = _signal.shake * 0.8 + CGFloat(shake) * 0.2
        _signal.rollDegrees = CGFloat(roll)
        _signal.elevationDegrees = CGFloat(elevation)
        _signal.isAvailable = true
        lock.unlock()
    }
}
