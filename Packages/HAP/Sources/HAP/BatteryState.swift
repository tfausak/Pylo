import Foundation
import Locked
import os

/// Shared mutable container for battery state, referenced by all accessories.
/// Thread-safe: written on the main thread by BatteryMonitor, read on the
/// HAP server queue by accessory characteristic handlers.
public final class BatteryState: @unchecked Sendable {
  private struct State: Sendable {
    var level: Int = 0
    var chargingState: Int = 0
    var statusLowBattery: Int = 0
  }

  private let lock = Locked(initialState: State())

  public init() {}

  /// Battery level as a percentage (0-100).
  ///
  /// Individual setters are each atomic but do not compose — a concurrent reader
  /// may observe a partially-updated state. Prefer `update(level:chargingState:
  /// statusLowBattery:)` when writing to a shared instance.
  public var level: Int {
    get { lock.withLock { $0.level } }
    set { lock.withLock { $0.level = newValue } }
  }
  /// HAP ChargingState: 0=Not Charging, 1=Charging, 2=Not Chargeable.
  public var chargingState: Int {
    get { lock.withLock { $0.chargingState } }
    set { lock.withLock { $0.chargingState = newValue } }
  }
  /// HAP StatusLowBattery: 0=Normal, 1=Low Battery.
  public var statusLowBattery: Int {
    get { lock.withLock { $0.statusLowBattery } }
    set { lock.withLock { $0.statusLowBattery = newValue } }
  }

  /// Atomically update all three fields so concurrent reads never observe
  /// a partially-updated state.
  public func update(level: Int, chargingState: Int, statusLowBattery: Int) {
    lock.withLock { s in
      s.level = level
      s.chargingState = chargingState
      s.statusLowBattery = statusLowBattery
    }
  }
}
