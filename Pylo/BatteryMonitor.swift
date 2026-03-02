import UIKit
import os

/// Monitors the host device's battery level and charging state via UIDevice notifications.
final class BatteryMonitor {

  var onBatteryChange: ((BatteryState) -> Void)?

  /// Whether the device reports a valid battery level (false on Mac Catalyst / Simulator without battery).
  private(set) var isAvailable = false

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Battery")

  /// Low battery threshold (percentage).
  private let lowThreshold = 20

  private var observers: [NSObjectProtocol] = []

  func start() {
    UIDevice.current.isBatteryMonitoringEnabled = true
    isAvailable = UIDevice.current.batteryLevel >= 0

    guard isAvailable else {
      logger.info("Battery monitoring not available on this device")
      return
    }

    observers.append(
      NotificationCenter.default.addObserver(
        forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.batteryDidChange() })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.batteryDidChange() })

    logger.info("Battery monitor started")
  }

  func stop() {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
    UIDevice.current.isBatteryMonitoringEnabled = false
    isAvailable = false
    logger.info("Battery monitor stopped")
  }

  /// Read the current battery state from UIDevice.
  func currentState() -> BatteryState {
    let state = BatteryState()
    let rawLevel = UIDevice.current.batteryLevel  // 0.0–1.0, or -1 if unknown
    state.level = max(0, min(100, Int(rawLevel * 100)))

    switch UIDevice.current.batteryState {
    case .charging, .full:
      state.chargingState = 1  // Charging
    case .unplugged:
      state.chargingState = 0  // Not Charging
    default:
      state.chargingState = 2  // Not Chargeable
    }

    state.statusLowBattery = state.level <= lowThreshold ? 1 : 0
    return state
  }

  private func batteryDidChange() {
    let state = currentState()
    logger.debug(
      "Battery: \(state.level)%, charging=\(state.chargingState), low=\(state.statusLowBattery)")
    onBatteryChange?(state)
  }
}
