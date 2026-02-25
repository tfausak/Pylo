import CoreMotion
import os

/// Monitors device motion using the accelerometer and reports motion detected / not detected.
/// At rest the accelerometer reads ~1g; significant deviation from that indicates movement.
final class MotionMonitor {

  var onMotionChange: ((Bool) -> Void)?

  /// Whether the device has an accelerometer.
  var isAvailable: Bool { motionManager.isAccelerometerAvailable }

  private let logger = Logger(subsystem: "com.example.hap", category: "Motion")
  private let motionManager = CMMotionManager()

  /// Acceleration delta from gravity (in g) required to trigger motion detected.
  private let threshold: Double = 0.15

  /// Seconds of calm required before reporting no motion.
  private let cooldown: TimeInterval = 3.0

  private var isMotionDetected = false
  private var lastMotionDate = Date.distantPast

  func start() {
    guard motionManager.isAccelerometerAvailable else {
      logger.warning("Accelerometer not available")
      return
    }
    guard !motionManager.isAccelerometerActive else { return }

    motionManager.accelerometerUpdateInterval = 0.1  // 10 Hz

    let queue = OperationQueue()
    queue.name = "com.example.hap.motion"
    queue.maxConcurrentOperationCount = 1

    motionManager.startAccelerometerUpdates(to: queue) { [weak self] data, error in
      guard let self, let data else {
        if let error { self?.logger.error("Accelerometer error: \(error)") }
        return
      }

      let accel = data.acceleration
      // Magnitude of the acceleration vector; subtract 1g (gravity at rest)
      let magnitude = sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)
      let delta = abs(magnitude - 1.0)

      if delta > self.threshold {
        self.lastMotionDate = Date()
        if !self.isMotionDetected {
          self.isMotionDetected = true
          self.logger.debug("Motion detected (delta=\(delta, format: .fixed(precision: 3))g)")
          self.onMotionChange?(true)
        }
      } else if self.isMotionDetected {
        let elapsed = Date().timeIntervalSince(self.lastMotionDate)
        if elapsed >= self.cooldown {
          self.isMotionDetected = false
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
    isMotionDetected = false
    logger.info("Motion monitor stopped")
  }
}
