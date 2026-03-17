import Foundation
import Locked
import os

#if os(iOS)
  import CoreMotion
#endif

/// Monitors device motion using the accelerometer and reports motion detected / not detected.
/// At rest the accelerometer reads ~1g; significant deviation from that indicates movement.
/// On macOS, the accelerometer is not available (isAvailable = false).
///
/// `@unchecked Sendable` is required because CMMotionManager and OperationQueue
/// are not Sendable, but all mutable state is protected by Locked and the
/// motionQueue serializes accelerometer callbacks.
public nonisolated final class MotionMonitor: @unchecked Sendable {

  /// Callback for motion state changes.
  /// Protected by a lock: written from @MainActor, read from motionQueue.
  private let _onMotionChange = Locked<((Bool) -> Void)?>(initialState: nil)
  public var onMotionChange: ((Bool) -> Void)? {
    get { _onMotionChange.valueUnchecked }
    set { _onMotionChange.valueUnchecked = newValue }
  }

  /// Whether the device has an accelerometer.
  public let isAvailable: Bool

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Sensors", category: "Motion")

  #if os(iOS)
    private let motionManager = CMMotionManager()
  #endif

  public init() {
    #if os(iOS)
      isAvailable = motionManager.isAccelerometerAvailable
    #else
      isAvailable = false
    #endif
  }

  /// Acceleration delta from gravity (in g) required to trigger motion detected.
  public var threshold: Double {
    get { state.withLockUnchecked { $0.threshold } }
    set { state.withLockUnchecked { $0.threshold = newValue } }
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

  #if os(iOS)
    private let motionQueue: OperationQueue = {
      let q = OperationQueue()
      q.name = "\(Bundle.main.bundleIdentifier ?? "Sensors").motion"
      q.maxConcurrentOperationCount = 1
      return q
    }()
  #endif

  public func start() {
    #if os(iOS)
      guard motionManager.isAccelerometerAvailable else {
        logger.warning("Accelerometer not available")
        return
      }
      guard !motionManager.isAccelerometerActive else { return }

      motionManager.accelerometerUpdateInterval = 0.1  // 10 Hz

      motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, error in
        self?.handleAccelerometerUpdate(data: data, error: error)
      }

      logger.debug("Motion monitor started")
    #else
      logger.info("Motion monitor not available on this platform")
    #endif
  }

  #if os(iOS)
    /// Handle accelerometer data on the motionQueue.
    private func handleAccelerometerUpdate(data: CMAccelerometerData?, error: Error?) {
      guard let data else {
        if let error { logger.error("Accelerometer error: \(error)") }
        return
      }

      let accel = data.acceleration
      let magnitude = sqrt(accel.x * accel.x + accel.y * accel.y + accel.z * accel.z)
      let delta = abs(magnitude - 1.0)

      enum MotionEvent {
        case detected
        case cleared(TimeInterval)
      }

      let event: MotionEvent? = state.withLockUnchecked { state in
        if delta > state.threshold {
          state.lastMotionDate = Date()
          if !state.isMotionDetected {
            state.isMotionDetected = true
            return .detected
          }
        } else if state.isMotionDetected {
          let elapsed = Date().timeIntervalSince(state.lastMotionDate)
          if elapsed >= cooldown {
            state.isMotionDetected = false
            return .cleared(elapsed)
          }
        }
        return nil
      }

      switch event {
      case .detected:
        logger.debug("Motion detected (delta=\(delta, format: .fixed(precision: 3))g)")
        onMotionChange?(true)
      case .cleared(let elapsed):
        logger.debug(
          "Motion cleared after \(elapsed, format: .fixed(precision: 1))s cooldown")
        onMotionChange?(false)
      case nil:
        break
      }
    }
  #endif

  public func stop() {
    #if os(iOS)
      motionManager.stopAccelerometerUpdates()
    #endif
    state.withLockUnchecked {
      $0.isMotionDetected = false
      $0.lastMotionDate = .distantPast
    }
    logger.debug("Motion monitor stopped")
  }
}
