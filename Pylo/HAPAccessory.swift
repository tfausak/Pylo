import AVFoundation
import Foundation
import os

// MARK: - Accessory Category (Table 12-3 in HAP R2 spec)

nonisolated enum HAPAccessoryCategory: Int {
  case other = 1
  case bridge = 2
  case fan = 3
  case garageDoor = 4
  case lightbulb = 5
  case doorLock = 6
  case outlet = 7
  case `switch` = 8
  case thermostat = 9
  case sensor = 10
  case securitySystem = 11
  case door = 12
  case window = 13
  case windowCovering = 14
  case programmableSwitch = 15
  case ipCamera = 17
}

// MARK: - Type-safe Characteristic Value

/// Type-safe wrapper for HAP characteristic values, replacing untyped `Any`.
nonisolated enum HAPValue: Equatable {
  case bool(Bool)
  case int(Int)
  case float(Float)
  case string(String)

  /// Convert to a JSON-serializable value for `JSONSerialization`.
  var jsonValue: Any {
    switch self {
    case .bool(let v): return v
    case .int(let v): return v
    case .float(let v): return v
    case .string(let v): return v
    }
  }

  /// Create from a JSON-deserialized value (from `JSONSerialization`).
  init?(fromJSON value: Any) {
    if let s = value as? String {
      self = .string(s)
      return
    }
    if let n = value as? NSNumber {
      if CFGetTypeID(n) == CFBooleanGetTypeID() {
        self = .bool(n.boolValue)
      } else if CFNumberIsFloatType(n) {
        self = .float(n.floatValue)
      } else {
        self = .int(n.intValue)
      }
      return
    }
    return nil
  }
}

// MARK: - HAP Accessory Protocol

/// Common interface for all accessories served by the HAP server.
nonisolated protocol HAPAccessoryProtocol: AnyObject {
  var aid: Int { get }
  var name: String { get }
  var model: String { get }
  var manufacturer: String { get }
  var serialNumber: String { get }
  var firmwareRevision: String { get }
  var onStateChange: ((_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? { get set }
  func readCharacteristic(iid: Int) -> HAPValue?
  @discardableResult func writeCharacteristic(iid: Int, value: HAPValue) -> Bool
  func identify()
  func toJSON() -> [String: Any]
}

// MARK: - Shared Accessory Information IIDs

/// Instance IDs for the Accessory Information service, shared by all accessories.
nonisolated enum AccessoryInfoIID {
  static let service = 1
  static let identify = 2
  static let manufacturer = 3
  static let model = 4
  static let name = 5
  static let serialNumber = 6
  static let firmwareRevision = 7
}

// MARK: - Shared Battery Service IIDs & UUIDs

/// Instance IDs for the Battery Service, shared by all accessories.
/// IIDs 100-103 are safely above all current accessory IIDs.
nonisolated enum BatteryIID {
  static let service = 100
  static let batteryLevel = 101
  static let chargingState = 102
  static let statusLowBattery = 103
}

/// HAP short-form UUIDs for the Battery Service and its characteristics.
nonisolated enum BatteryUUID {
  static let service = "96"
  static let level = "68"
  static let chargingState = "8F"
  static let lowBattery = "79"
}

nonisolated extension HAPAccessoryProtocol {
  /// Builds the Accessory Information service JSON (iid 1, characteristics 2-7).
  /// Shared by all accessories to avoid duplicating this boilerplate.
  func accessoryInformationServiceJSON() -> [String: Any] {
    [
      "iid": AccessoryInfoIID.service,
      "type": HAPAccessory.uuidAccessoryInformation,
      "characteristics": [
        [
          "iid": AccessoryInfoIID.identify,
          "type": HAPAccessory.uuidIdentify, "format": "bool",
          "perms": ["pw"],
        ],
        [
          "iid": AccessoryInfoIID.manufacturer,
          "type": HAPAccessory.uuidManufacturer, "format": "string",
          "perms": ["pr"], "value": manufacturer,
        ],
        [
          "iid": AccessoryInfoIID.model,
          "type": HAPAccessory.uuidModel, "format": "string",
          "perms": ["pr"], "value": model,
        ],
        [
          "iid": AccessoryInfoIID.name,
          "type": HAPAccessory.uuidName, "format": "string",
          "perms": ["pr"], "value": name,
        ],
        [
          "iid": AccessoryInfoIID.serialNumber,
          "type": HAPAccessory.uuidSerialNumber, "format": "string",
          "perms": ["pr"], "value": serialNumber,
        ],
        [
          "iid": AccessoryInfoIID.firmwareRevision,
          "type": HAPAccessory.uuidFirmwareRevision, "format": "string",
          "perms": ["pr"], "value": firmwareRevision,
        ],
      ],
    ]
  }

  /// Builds the Battery Service JSON (iid 100, characteristics 101-103).
  /// Returns nil if the given `BatteryState` is nil (no battery on this device).
  func batteryServiceJSON(state: BatteryState?) -> [String: Any]? {
    guard let state else { return nil }
    return [
      "iid": BatteryIID.service,
      "type": BatteryUUID.service,
      "characteristics": [
        [
          "iid": BatteryIID.batteryLevel,
          "type": BatteryUUID.level, "format": "uint8",
          "perms": ["pr", "ev"], "value": state.level,
          "minValue": 0, "maxValue": 100, "minStep": 1,
          "unit": "percentage",
        ],
        [
          "iid": BatteryIID.chargingState,
          "type": BatteryUUID.chargingState, "format": "uint8",
          "perms": ["pr", "ev"], "value": state.chargingState,
          "minValue": 0, "maxValue": 2,
        ],
        [
          "iid": BatteryIID.statusLowBattery,
          "type": BatteryUUID.lowBattery, "format": "uint8",
          "perms": ["pr", "ev"], "value": state.statusLowBattery,
          "minValue": 0, "maxValue": 1,
        ],
      ],
    ]
  }
}

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

  // MARK: - HAP Service/Characteristic UUIDs (shortened form)
  // HAP uses Apple-defined UUIDs of the form 000000XX-0000-1000-8000-0026BB765291.
  // The JSON representation uses just the short hex string.

  static let uuidAccessoryInformation = "3E"
  static let uuidIdentify = "14"
  static let uuidManufacturer = "20"
  static let uuidModel = "21"
  static let uuidName = "23"
  static let uuidSerialNumber = "30"
  static let uuidFirmwareRevision = "52"

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
  func writeCharacteristic(iid: Int, value: HAPValue) -> Bool {
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
        isOn = (v != 0)
        onStateChange?(aid, iid, .bool(isOn))
        return true
      default:
        return false
      }
    case Self.iidBrightness:
      if case .int(let v) = value {
        brightness = max(0, min(100, v))
        onStateChange?(aid, iid, .int(brightness))
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

// MARK: - Bridge Info Accessory

/// Lightweight accessory representing the bridge itself (aid=1).
/// Only exposes the Accessory Information service.
nonisolated final class HAPBridgeInfo: HAPAccessoryProtocol, @unchecked Sendable {

  let aid: Int = 1
  let name: String
  let model: String
  let manufacturer: String
  let serialNumber: String
  let firmwareRevision: String

  private let _onStateChange = OSAllocatedUnfairLock<
    ((_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  var onStateChange: ((_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  init(
    name: String = "Pylo Bridge",
    model: String = "iPhone Bridge",
    manufacturer: String = "DIY",
    serialNumber: String = "000000",
    firmwareRevision: String = "0.1.0"
  ) {
    self.name = name
    self.model = model
    self.manufacturer = manufacturer
    self.serialNumber = serialNumber
    self.firmwareRevision = firmwareRevision
  }

  func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    default: return nil
    }
  }

  @discardableResult
  func writeCharacteristic(iid: Int, value: HAPValue) -> Bool {
    if iid == AccessoryInfoIID.identify {
      identify()
      return true
    }
    return false
  }

  func identify() {
    // Bridge identify — no-op (sub-accessories handle their own)
  }

  func toJSON() -> [String: Any] {
    [
      "aid": aid,
      "services": [
        accessoryInformationServiceJSON()
      ],
    ]
  }
}

// MARK: - Light Sensor Accessory

/// Standalone light sensor accessory for the bridge.
nonisolated final class HAPLightSensorAccessory: HAPAccessoryProtocol, @unchecked Sendable {

  let aid: Int
  let name: String
  let model: String
  let manufacturer: String
  let serialNumber: String
  let firmwareRevision: String

  private let _onStateChange = OSAllocatedUnfairLock<
    ((_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  var onStateChange: ((_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  /// Shared battery state — nil means no battery, omit battery service.
  private let _batteryState = OSAllocatedUnfairLock<BatteryState?>(initialState: nil)
  var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  private let _ambientLightLevel = OSAllocatedUnfairLock(initialState: Float(1.0))
  var ambientLightLevel: Float {
    _ambientLightLevel.withLock { $0 }
  }

  static let iidLightSensorService = 8
  static let iidAmbientLightLevel = 9

  private static let uuidLightSensor = "84"
  private static let uuidAmbientLightLevel = "6B"

  init(
    aid: Int,
    name: String = "Pylo Light Sensor",
    model: String = "HAP-PoC",
    manufacturer: String = "DIY",
    serialNumber: String = "000001",
    firmwareRevision: String = "0.1.0"
  ) {
    self.aid = aid
    self.name = name
    self.model = model
    self.manufacturer = manufacturer
    self.serialNumber = serialNumber
    self.firmwareRevision = firmwareRevision
  }

  func updateAmbientLight(_ lux: Float) {
    _ambientLightLevel.withLock { $0 = lux }
    onStateChange?(aid, Self.iidAmbientLightLevel, .float(lux))
  }

  func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case Self.iidAmbientLightLevel: return .float(ambientLightLevel)
    case BatteryIID.batteryLevel: return batteryState.map { .int($0.level) }
    case BatteryIID.chargingState: return batteryState.map { .int($0.chargingState) }
    case BatteryIID.statusLowBattery: return batteryState.map { .int($0.statusLowBattery) }
    default: return nil
    }
  }

  @discardableResult
  func writeCharacteristic(iid: Int, value: HAPValue) -> Bool {
    if iid == AccessoryInfoIID.identify {
      identify()
      return true
    }
    return false
  }

  func identify() {}

  func toJSON() -> [String: Any] {
    var services: [[String: Any]] = [
      accessoryInformationServiceJSON(),
      [
        "iid": Self.iidLightSensorService,
        "type": Self.uuidLightSensor,
        "characteristics": [
          [
            "iid": Self.iidAmbientLightLevel,
            "type": Self.uuidAmbientLightLevel, "format": "float",
            "perms": ["pr", "ev"], "value": ambientLightLevel,
            "minValue": Float(0.0001), "maxValue": Float(100000),
            "unit": "lux",
          ]
        ],
      ],
    ]
    if let battery = batteryServiceJSON(state: batteryState) {
      services.append(battery)
    }
    return ["aid": aid, "services": services]
  }
}

// MARK: - Motion Sensor Accessory

/// Standalone motion sensor accessory for the bridge.
nonisolated final class HAPMotionSensorAccessory: HAPAccessoryProtocol, @unchecked Sendable {

  let aid: Int
  let name: String
  let model: String
  let manufacturer: String
  let serialNumber: String
  let firmwareRevision: String

  private let _onStateChange = OSAllocatedUnfairLock<
    ((_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  var onStateChange: ((_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  /// Shared battery state — nil means no battery, omit battery service.
  private let _batteryState = OSAllocatedUnfairLock<BatteryState?>(initialState: nil)
  var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  private let _isMotionDetected = OSAllocatedUnfairLock(initialState: false)
  var isMotionDetected: Bool {
    _isMotionDetected.withLock { $0 }
  }

  static let iidMotionSensorService = 8
  static let iidMotionDetected = 9

  private static let uuidMotionSensor = "85"
  private static let uuidMotionDetected = "22"

  init(
    aid: Int,
    name: String = "Pylo Motion Sensor",
    model: String = "HAP-PoC",
    manufacturer: String = "DIY",
    serialNumber: String = "000001",
    firmwareRevision: String = "0.1.0"
  ) {
    self.aid = aid
    self.name = name
    self.model = model
    self.manufacturer = manufacturer
    self.serialNumber = serialNumber
    self.firmwareRevision = firmwareRevision
  }

  func updateMotionDetected(_ detected: Bool) {
    _isMotionDetected.withLock { $0 = detected }
    onStateChange?(aid, Self.iidMotionDetected, .bool(detected))
  }

  func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case Self.iidMotionDetected: return .bool(isMotionDetected)
    case BatteryIID.batteryLevel: return batteryState.map { .int($0.level) }
    case BatteryIID.chargingState: return batteryState.map { .int($0.chargingState) }
    case BatteryIID.statusLowBattery: return batteryState.map { .int($0.statusLowBattery) }
    default: return nil
    }
  }

  @discardableResult
  func writeCharacteristic(iid: Int, value: HAPValue) -> Bool {
    if iid == AccessoryInfoIID.identify {
      identify()
      return true
    }
    return false
  }

  func identify() {}

  func toJSON() -> [String: Any] {
    var services: [[String: Any]] = [
      accessoryInformationServiceJSON(),
      [
        "iid": Self.iidMotionSensorService,
        "type": Self.uuidMotionSensor,
        "characteristics": [
          [
            "iid": Self.iidMotionDetected,
            "type": Self.uuidMotionDetected, "format": "bool",
            "perms": ["pr", "ev"], "value": isMotionDetected,
          ]
        ],
      ],
    ]
    if let battery = batteryServiceJSON(state: batteryState) {
      services.append(battery)
    }
    return ["aid": aid, "services": services]
  }
}
