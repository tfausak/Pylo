import AVFoundation
import CryptoKit
import Foundation
import HAP
import Locked
import os

// MARK: - HAP Accessory

nonisolated final class HAPAccessory: HAPAccessoryProtocol, @unchecked Sendable {

  let name: String
  let model: String
  let manufacturer: String
  let serialNumber: String
  let firmwareRevision: String
  let aid: Int

  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "Accessory")

  // MARK: - Lightbulb State

  private struct LightState {
    var isOn: Bool = false
    var brightness: Int = 100
  }
  private let lightState = Locked(initialState: LightState())

  private(set) var isOn: Bool {
    get { lightState.withLock { $0.isOn } }
    set {
      lightState.withLock { $0.isOn = newValue }
      applyTorchState()
    }
  }

  /// Update the on/off state programmatically and notify HomeKit subscribers.
  func updateOn(_ on: Bool) {
    lightState.withLock { $0.isOn = on }
    applyTorchState()
    onStateChange?(aid, Self.iidOn, .bool(on))
  }

  private(set) var brightness: Int {
    get { lightState.withLock { $0.brightness } }
    set {
      lightState.withLock { $0.brightness = newValue }
      applyTorchState()
    }
  }

  /// Shared battery state — nil means no battery, omit battery service.
  /// Protected by a lock: written from @MainActor during setup, read on the server queue.
  private let _batteryState = Locked<BatteryState?>(initialState: nil)
  var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  /// In-progress identify blink task, cancelled on server stop to avoid
  /// leaving the torch in an unexpected state.
  private let _identifyTask = Locked<Task<Void, Never>?>(initialState: nil)

  /// Callback for notifying the server of state changes (for EVENT notifications).
  /// Protected by a lock: written from @MainActor, read from sensor/server callbacks.
  private let _onStateChange = Locked<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  init(
    aid: Int,
    name: String = "Pylo Flashlight",
    model: String = "iPhone Light",
    manufacturer: String = "Pylo",
    serialNumber: String = "000001",
    firmwareRevision: String = "1.0.0"
  ) {
    self.aid = aid
    self.name = name
    self.model = model
    self.manufacturer = manufacturer
    self.serialNumber = serialNumber
    self.firmwareRevision = firmwareRevision
  }

  // MARK: - Instance IDs (iid)

  static let iidLightbulbService = 8
  static let iidOn = 9
  static let iidBrightness = 10

  // MARK: - Lightbulb HAP Service/Characteristic UUIDs (shortened form)

  static let uuidLightbulb = HKServiceUUID.lightbulb
  static let uuidOn = HKCharacteristicUUID.on
  static let uuidBrightness = HKCharacteristicUUID.brightness

  // MARK: - Read Characteristic

  func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case ProtocolInfoIID.version: return .string(hapProtocolVersion)
    case Self.iidOn: return .bool(isOn)
    case Self.iidBrightness: return .int(brightness)
    case BatteryIID.batteryLevel: return .int(batteryState?.level ?? 0)
    case BatteryIID.chargingState: return .int(batteryState?.chargingState ?? 0)
    case BatteryIID.statusLowBattery: return .int(batteryState?.statusLowBattery ?? 0)
    default: return nil
    }
  }

  // MARK: - Write Characteristic

  /// Returns true if the write was accepted.
  @discardableResult
  func writeCharacteristic(iid: Int, value: HAPValue, sharedSecret: SharedSecret? = nil) -> Bool {
    switch iid {
    case AccessoryInfoIID.identify:
      identify()
      return true
    case Self.iidOn:
      switch value {
      case .bool(let v):
        isOn = v
        onStateChange?(aid, iid, .bool(v))
        logger.info("Light \(v ? "ON" : "OFF")")
        return true
      case .int(let v):
        let boolV = (v != 0)
        isOn = boolV
        onStateChange?(aid, iid, .bool(boolV))
        return true
      default:
        return false
      }
    case Self.iidBrightness:
      if case .int(let v) = value {
        let clamped = max(0, min(100, v))
        brightness = clamped
        onStateChange?(aid, iid, .int(clamped))
        logger.info("Brightness: \(self.brightness)%")
        return true
      }
      return false
    default:
      return false
    }
  }

  // MARK: - Identify

  func identify() {
    logger.info("Identify requested — blinking torch")
    _identifyTask.withLock { task in
      task?.cancel()
      task = Task { @MainActor [weak self] in
        for _ in 0..<3 {
          guard !Task.isCancelled else { break }
          self?.setTorch(on: true, level: 1.0)
          try? await Task.sleep(nanoseconds: 200_000_000)
          self?.setTorch(on: false, level: 0)
          try? await Task.sleep(nanoseconds: 200_000_000)
        }
      }
    }
  }

  /// Cancel any in-progress identify blink.
  func cancelIdentify() {
    _identifyTask.withLock {
      $0?.cancel()
      $0 = nil
    }
  }

  // MARK: - Torch Control

  private func applyTorchState() {
    // Snapshot both values under the lock to avoid stale captures.
    let (on, level) = lightState.withLock { (state: inout LightState) -> (Bool, Float) in
      (state.isOn, state.isOn ? Float(state.brightness) / 100.0 : 0.0)
    }
    Task { @MainActor in
      setTorch(on: on, level: level)
    }
  }

  @MainActor
  private func setTorch(on: Bool, level: Float) {
    guard let device = AVCaptureDevice.default(for: .video),
      device.hasTorch
    else {
      logger.warning("No torch available on this device")
      return
    }

    do {
      try device.lockForConfiguration()
      if on && level > 0 {
        try device.setTorchModeOn(level: max(0.01, level))  // min level is ~0.01
      } else {
        device.torchMode = .off
      }
      device.unlockForConfiguration()
    } catch {
      logger.error("Torch error: \(error)")
    }
  }

  // MARK: - JSON Serialization (for GET /accessories)

  func toJSON() -> [String: Any] {
    var services: [[String: Any]] = [
      accessoryInformationServiceJSON(),
      protocolInformationServiceJSON(),
      // Lightbulb Service
      [
        "iid": Self.iidLightbulbService,
        "type": Self.uuidLightbulb,
        "characteristics": [
          characteristicJSON(
            iid: Self.iidOn, type: Self.uuidOn, format: "bool",
            perms: ["pr", "pw", "ev"], value: .bool(isOn)),
          characteristicJSON(
            iid: Self.iidBrightness, type: Self.uuidBrightness,
            format: "int", perms: ["pr", "pw", "ev"], value: .int(brightness),
            minValue: .int(0), maxValue: .int(100), unit: "percentage"),
        ],
      ],
    ]
    services.append(batteryServiceJSON(state: batteryState))
    return ["aid": aid, "services": services]
  }

  private func characteristicJSON(
    iid: Int,
    type: String,
    format: String,
    perms: [String],
    value: HAPValue?,
    minValue: HAPValue? = nil,
    maxValue: HAPValue? = nil,
    unit: String? = nil
  ) -> [String: Any] {
    var json: [String: Any] = [
      "iid": iid,
      "type": type,
      "format": format,
      "perms": perms,
    ]
    if let value { json["value"] = value.jsonValue }
    if let minValue { json["minValue"] = minValue.jsonValue }
    if let maxValue { json["maxValue"] = maxValue.jsonValue }
    if let unit { json["unit"] = unit }
    return json
  }
}
