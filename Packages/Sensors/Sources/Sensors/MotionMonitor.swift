import CoreMotion
import Locked
import os

/// Monitors device motion using the accelerometer and reports motion detected / not detected.
/// At rest the accelerometer reads ~1g; significant deviation from that indicates movement.
public nonisolated final class MotionMonitor: @unchecked Sendable {

  /// Callback for motion state changes.
  /// Protected by a lock: written from @MainActor, read from motionQueue.
  private let _onMotionChange = Locked<((Bool) -> Void)?>(initialState: nil)
  public var onMotionChange: ((Bool) -> Void)? {
    get { _onMotionChange.withLock { $0 } }
    set { _onMotionChange.withLock { $0 = newValue } }
  }

  /// Whether the device has an accelerometer.
  /// Cached at init so it can be safely read from any queue (CMMotionManager is not thread-safe).
  /// Safe: CMMotionManager init + isAccelerometerAvailable is a single-threaded read at init time,
  /// before the instance is shared across queues.
  public let isAvailable: Bool

  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Motion")
  private let motionManager = CMMotionManager()

  public init() {
    isAvailable = motionManager.isAccelerometerAvailable
  }

  /// Acceleration delta from gravity (in g) required to trigger motion detected.
  public var threshold: Double {
    get { state.withLock { $0.threshold } }
    set { state.withLock { $0.threshold = newValue } }
  }

  /// Seconds of calm required before reporting no motion.
  private let cooldown: TimeInterval = 3.0

  /// Thread-safe mutable state, protected by an unfair lock.
  private struct State {
    var isMotionDetected = false
    var lastMotionDate = Date.distantPast
    var threshold: Double = 0.15
  }

  private let state = Locked(initialState: State())

  private let motionQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "\(Bundle.main.bundleIdentifier!).motion"
    q.maxConcurrentOperationCount = 1
    return q
  }()

  @MainActor public func start() {
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

      enum MotionEvent {
        case detected
        case cleared(TimeInterval)
      }

      let event: MotionEvent? = self.state.withLock { state in
        if delta > state.threshold {
          state.lastMotionDate = Date()
          if !state.isMotionDetected {
            state.isMotionDetected = true
            return .detected
          }
        } else if state.isMotionDetected {
          let elapsed = Date().timeIntervalSince(state.lastMotionDate)
          if elapsed >= self.cooldown {
            state.isMotionDetected = false
            return .cleared(elapsed)
          }
        }
        return nil
      }

      switch event {
      case .detected:
        self.logger.debug("Motion detected (delta=\(delta, format: .fixed(precision: 3))g)")
        self.onMotionChange?(true)
      case .cleared(let elapsed):
        self.logger.debug(
          "Motion cleared after \(elapsed, format: .fixed(precision: 1))s cooldown")
        self.onMotionChange?(false)
      case nil:
        break
      }
    }

    logger.info("Motion monitor started")
  }

  @MainActor public func stop() {
    motionManager.stopAccelerometerUpdates()
    state.withLock { $0.isMotionDetected = false }
    logger.info("Motion monitor stopped")
  }
}
