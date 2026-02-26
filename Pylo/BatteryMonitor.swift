import UIKit
import os

/// Shared mutable container for battery state, referenced by all accessories.
final class BatteryState {
  /// Battery level as a percentage (0-100).
  var level: Int = 0
  /// HAP ChargingState: 0=Not Charging, 1=Charging, 2=Not Chargeable.
  var chargingState: Int = 0
  /// HAP StatusLowBattery: 0=Normal, 1=Low Battery.
  var statusLowBattery: Int = 0
}

/// Monitors the host device's battery level and charging state via UIDevice notifications.
final class BatteryMonitor {

  var onBatteryChange: ((BatteryState) -> Void)?

  /// Whether the device reports a valid battery level (false on Mac Catalyst / Simulator without battery).
  private(set) var isAvailable = false

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Battery")

  /// Low battery threshold (percentage).
  private let lowThreshold = 20

  func start() {
    UIDevice.current.isBatteryMonitoringEnabled = true
    isAvailable = UIDevice.current.batteryLevel >= 0

    guard isAvailable else {
      logger.info("Battery monitoring not available on this device")
      return
    }

    NotificationCenter.default.addObserver(
      self, selector: #selector(batteryDidChange),
      name: UIDevice.batteryLevelDidChangeNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(batteryDidChange),
      name: UIDevice.batteryStateDidChangeNotification, object: nil)

    logger.info("Battery monitor started")
  }

  func stop() {
    NotificationCenter.default.removeObserver(self)
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

  @objc private func batteryDidChange() {
    let state = currentState()
    logger.debug(
      "Battery: \(state.level)%, charging=\(state.chargingState), low=\(state.statusLowBattery)")
    onBatteryChange?(state)
  }
}
