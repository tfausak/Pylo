import UIKit
import os

/// Shared mutable container for battery state, referenced by all accessories.
/// Thread-safe: written on the main thread by BatteryMonitor, read on the
/// HAP server queue by accessory characteristic handlers.
nonisolated final class BatteryState {
  private struct State {
    var level: Int = 0
    var chargingState: Int = 0
    var statusLowBattery: Int = 0
  }

  private let lock = OSAllocatedUnfairLock(initialState: State())

  /// Battery level as a percentage (0-100).
  var level: Int {
    get { lock.withLock { $0.level } }
    set { lock.withLock { $0.level = newValue } }
  }
  /// HAP ChargingState: 0=Not Charging, 1=Charging, 2=Not Chargeable.
  var chargingState: Int {
    get { lock.withLock { $0.chargingState } }
    set { lock.withLock { $0.chargingState = newValue } }
  }
  /// HAP StatusLowBattery: 0=Normal, 1=Low Battery.
  var statusLowBattery: Int {
    get { lock.withLock { $0.statusLowBattery } }
    set { lock.withLock { $0.statusLowBattery = newValue } }
  }

  /// Atomically update all three fields so concurrent reads never observe
  /// a partially-updated state.
  func update(level: Int, chargingState: Int, statusLowBattery: Int) {
    lock.withLock { s in
      s.level = level
      s.chargingState = chargingState
      s.statusLowBattery = statusLowBattery
    }
  }
}

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
