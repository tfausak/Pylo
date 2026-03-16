import Foundation
import os

#if os(iOS)
  import UIKit
#endif

/// Monitors the iPhone's proximity sensor via UIDevice notifications.
/// Maps proximity state to HomeKit contact sensor: near = closed, far = open.
/// All UIDevice access must happen on the main actor.
/// On macOS, the sensor is never available (no hardware).
@MainActor public final class ProximitySensor {

  public var onContactChange: ((Bool) -> Void)?

  /// Whether the device supports proximity monitoring.
  public private(set) var isAvailable = false

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Sensors", category: "ProximitySensor")

  private var observer: NSObjectProtocol?

  public init() {}

  public func start() {
    #if os(iOS)
      UIDevice.current.isProximityMonitoringEnabled = true
      // If the device doesn't support proximity monitoring, it resets to false.
      isAvailable = UIDevice.current.isProximityMonitoringEnabled

      guard isAvailable else {
        logger.info("Proximity monitoring not available on this device")
        return
      }

      observer = NotificationCenter.default.addObserver(
        forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.proximityDidChange() } }

      logger.debug("Proximity sensor started")
    #else
      isAvailable = false
      logger.info("Proximity monitoring not available on this platform")
    #endif
  }

  public func stop() {
    #if os(iOS)
      if let observer {
        NotificationCenter.default.removeObserver(observer)
      }
      observer = nil
      UIDevice.current.isProximityMonitoringEnabled = false
    #endif
    isAvailable = false
    logger.debug("Proximity sensor stopped")
  }

  /// Current contact state: true = contact detected (near), false = no contact (far).
  public var isContactDetected: Bool {
    #if os(iOS)
      return UIDevice.current.proximityState
    #else
      return false
    #endif
  }

  #if os(iOS)
    private func proximityDidChange() {
      let near = UIDevice.current.proximityState
      logger.debug("Proximity: \(near ? "near (contact)" : "far (no contact)")")
      onContactChange?(near)
    }
  #endif
}
