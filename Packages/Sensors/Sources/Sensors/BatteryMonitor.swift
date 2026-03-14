import Foundation
import HAP
import os

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import IOKit.ps
#endif

/// Monitors the host device's battery level and charging state.
/// On iOS uses UIDevice notifications; on macOS uses IOKit Power Sources.
/// All access must happen on the main actor.
@MainActor public final class BatteryMonitor {

  public var onBatteryChange: ((BatteryState) -> Void)?

  /// Whether the device reports a valid battery level (false on desktops without battery).
  public private(set) var isAvailable = false

  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Battery")

  /// Low battery threshold (percentage).
  private let lowThreshold = 20

  private var observers: [Any] = []

  public init() {}

  public func start() {
    #if os(iOS)
      UIDevice.current.isBatteryMonitoringEnabled = true
      isAvailable = UIDevice.current.batteryLevel >= 0
    #elseif os(macOS)
      // Check if this Mac has a battery (MacBooks do, desktops don't)
      isAvailable = macOSBatteryLevel() != nil
    #endif

    guard isAvailable else {
      logger.info("Battery monitoring not available on this device")
      return
    }

    #if os(iOS)
      observers.append(
        NotificationCenter.default.addObserver(
          forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
          guard let self else { return }
          Task { @MainActor in self.batteryDidChange() }
        })
      observers.append(
        NotificationCenter.default.addObserver(
          forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
          guard let self else { return }
          Task { @MainActor in self.batteryDidChange() }
        })
    #elseif os(macOS)
      // IOKit power source change notifications are delivered via CFRunLoop.
      // Poll on a timer instead for simplicity — battery state changes slowly.
      let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
        guard let self else { return }
        Task { @MainActor in self.batteryDidChange() }
      }
      observers.append(timer as AnyObject)
    #endif

    logger.info("Battery monitor started")
  }

  public func stop() {
    for observer in observers {
      if let timer = observer as? Timer {
        timer.invalidate()
      } else if let token = observer as? NSObjectProtocol {
        NotificationCenter.default.removeObserver(token)
      }
    }
    observers.removeAll()
    #if os(iOS)
      UIDevice.current.isBatteryMonitoringEnabled = false
    #endif
    isAvailable = false
    logger.info("Battery monitor stopped")
  }

  /// Read the current battery state.
  public func currentState() -> BatteryState {
    let state = BatteryState()
    #if os(iOS)
      let rawLevel = UIDevice.current.batteryLevel  // 0.0–1.0, or -1 if unknown
      let level = max(0, min(100, Int(rawLevel * 100)))

      let charging: Int
      switch UIDevice.current.batteryState {
      case .charging, .full:
        charging = 1  // Charging
      case .unplugged:
        charging = 0  // Not Charging
      default:
        charging = 2  // Not Chargeable
      }
    #elseif os(macOS)
      let level = max(0, min(100, macOSBatteryLevel() ?? 0))
      let charging = macOSIsCharging() ? 1 : 0
    #endif

    state.update(
      level: level,
      chargingState: charging,
      statusLowBattery: level <= lowThreshold ? 1 : 0)
    return state
  }

  private func batteryDidChange() {
    let state = currentState()
    logger.debug(
      "Battery: \(state.level)%, charging=\(state.chargingState), low=\(state.statusLowBattery)")
    onBatteryChange?(state)
  }

  // MARK: - macOS IOKit Power Sources

  #if os(macOS)
    private func macOSBatteryLevel() -> Int? {
      guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
        let first = sources.first,
        let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue()
          as? [String: Any],
        let capacity = desc[kIOPSCurrentCapacityKey] as? Int
      else { return nil }
      return capacity
    }

    private func macOSIsCharging() -> Bool {
      guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
        let first = sources.first,
        let desc = IOPSGetPowerSourceDescription(snapshot, first)?.takeUnretainedValue()
          as? [String: Any],
        let charging = desc[kIOPSIsChargingKey] as? Bool
      else { return false }
      return charging
    }
  #endif
}
