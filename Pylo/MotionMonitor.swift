import CoreMotion
import os

/// Monitors device motion using the accelerometer and reports motion detected / not detected.
/// At rest the accelerometer reads ~1g; significant deviation from that indicates movement.
final class MotionMonitor {

  var onMotionChange: ((Bool) -> Void)?

  /// Whether the device has an accelerometer.
  var isAvailable: Bool { motionManager.isAccelerometerAvailable }

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Motion")
  private let motionManager = CMMotionManager()

  /// Acceleration delta from gravity (in g) required to trigger motion detected.
  var threshold: Double = 0.15

  /// Seconds of calm required before reporting no motion.
  private let cooldown: TimeInterval = 3.0

  /// Thread-safe mutable state, protected by an unfair lock.
  private struct State {
    var isMotionDetected = false
    var lastMotionDate = Date.distantPast
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  private let motionQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "me.fausak.taylor.Pylo.motion"
    q.maxConcurrentOperationCount = 1
    return q
  }()

  func start() {
    guard motionManager.isAccelerometerAvailable else {
      logger.warning("Accelerometer not available")
      return
    }
    guard !motionManager.isAccelerometerActive else { return }

    motionManager.accelerometerUpdateInterval = 0.1  // 10 Hz

    motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, error in
      guard let self, let data else {
        if let error { self?.logger.error("Accelerometer error: \(error)") }
        return
      }

      let accel = data.acceleration
      // Magnitude of the acceleration vector; subtract 1g (gravity at rest)
      let magnitude = sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)
      let delta = abs(magnitude - 1.0)

      if delta > self.threshold {
        let shouldNotify = self.state.withLock { state in
          state.lastMotionDate = Date()
          if !state.isMotionDetected {
            state.isMotionDetected = true
            return true
          }
          return false
        }
        if shouldNotify {
          self.logger.debug("Motion detected (delta=\(delta, format: .fixed(precision: 3))g)")
          self.onMotionChange?(true)
        }
      } else {
        let elapsed: TimeInterval? = self.state.withLock { state in
          guard state.isMotionDetected else { return nil }
          let elapsed = Date().timeIntervalSince(state.lastMotionDate)
          if elapsed >= self.cooldown {
            state.isMotionDetected = false
            return elapsed
          }
          return nil
        }
        if let elapsed {
          self.logger.debug(
            "Motion cleared after \(elapsed, format: .fixed(precision: 1))s cooldown")
          self.onMotionChange?(false)
        }
      }
    }

    logger.info("Motion monitor started")
  }

  func stop() {
    motionManager.stopAccelerometerUpdates()
    state.withLock { $0.isMotionDetected = false }
    logger.info("Motion monitor stopped")
  }
}
