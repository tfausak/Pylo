import UIKit
import os

/// Monitors the iPhone's proximity sensor via UIDevice notifications.
/// Maps proximity state to HomeKit contact sensor: near = closed, far = open.
/// All UIDevice access must happen on the main actor.
@MainActor final class ProximitySensor {

  var onContactChange: ((Bool) -> Void)?

  /// Whether the device supports proximity monitoring.
  private(set) var isAvailable = false

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier!, category: "ProximitySensor")

  private var observer: NSObjectProtocol?

  func start() {
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

    logger.info("Proximity sensor started")
  }

  func stop() {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
    observer = nil
    UIDevice.current.isProximityMonitoringEnabled = false
    isAvailable = false
    logger.info("Proximity sensor stopped")
  }

  /// Current contact state: true = contact detected (near), false = no contact (far).
  var isContactDetected: Bool {
    UIDevice.current.proximityState
  }

  private func proximityDidChange() {
    let near = UIDevice.current.proximityState
    logger.debug("Proximity: \(near ? "near (contact)" : "far (no contact)")")
    onContactChange?(near)
  }
}
