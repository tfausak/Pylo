import AVFoundation
import CryptoKit
import Foundation
import os

// MARK: - HAP Accessory

nonisolated final class HAPAccessory: HAPAccessoryProtocol, @unchecked Sendable {

  let name: String
  let model: String
  let manufacturer: String
  let serialNumber: String
  let firmwareRevision: String
  let aid: Int

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Accessory")

  // MARK: - Lightbulb State

  private struct LightState {
    var isOn: Bool = false
    var brightness: Int = 100
  }
  private let lightState = OSAllocatedUnfairLock(initialState: LightState())

  private(set) var isOn: Bool {
    get { lightState.withLock { $0.isOn } }
    set {
      lightState.withLock { $0.isOn = newValue }
      applyTorchState()
    }
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
  private let _batteryState = OSAllocatedUnfairLock<BatteryState?>(initialState: nil)
  var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  /// Callback for notifying the server of state changes (for EVENT notifications).
  /// Protected by a lock: written from @MainActor, read from sensor/server callbacks.
  private let _onStateChange = OSAllocatedUnfairLock<
    ((_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  var onStateChange: ((_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  init(
    aid: Int,
    name: String = "Pylo Flashlight",
    model: String = "iPhone Light",
    manufacturer: String = "HAP PoC",
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

  static let uuidLightbulb = "43"
  static let uuidOn = "25"
  static let uuidBrightness = "8"

  // MARK: - Read Characteristic

  func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case Self.iidOn: return .bool(isOn)
    case Self.iidBrightness: return .int(brightness)
    case BatteryIID.batteryLevel: return batteryState.map { .int($0.level) }
    case BatteryIID.chargingState: return batteryState.map { .int($0.chargingState) }
    case BatteryIID.statusLowBattery: return batteryState.map { .int($0.statusLowBattery) }
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
    // Blink the torch 3 times
    Task { @MainActor in
      for _ in 0..<3 {
        setTorch(on: true, level: 1.0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        setTorch(on: false, level: 0)
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
  }

  // MARK: - Torch Control

  private func applyTorchState() {
    let level = isOn ? Float(brightness) / 100.0 : 0.0
    Task { @MainActor in
      setTorch(on: isOn, level: level)
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
    if let battery = batteryServiceJSON(state: batteryState) {
      services.append(battery)
    }
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
