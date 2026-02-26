import AVFoundation
import Foundation
import os

// MARK: - Accessory Category (Table 12-3 in HAP R2 spec)

enum HAPAccessoryCategory: Int {
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

// MARK: - HAP Accessory Protocol

/// Common interface for all accessories served by the HAP server.
protocol HAPAccessoryProtocol: AnyObject {
  var aid: Int { get }
  var name: String { get }
  var model: String { get }
  var manufacturer: String { get }
  var serialNumber: String { get }
  var firmwareRevision: String { get }
  var onStateChange: ((_ aid: Int, _ iid: Int, _ value: Any) -> Void)? { get set }
  func readCharacteristic(iid: Int) -> Any?
  @discardableResult func writeCharacteristic(iid: Int, value: Any) -> Bool
  func identify()
  func toJSON() -> [String: Any]
}

// MARK: - Shared Accessory Information IIDs

/// Instance IDs for the Accessory Information service, shared by all accessories.
enum AccessoryInfoIID {
  static let service = 1
  static let identify = 2
  static let manufacturer = 3
  static let model = 4
  static let name = 5
  static let serialNumber = 6
  static let firmwareRevision = 7
}

extension HAPAccessoryProtocol {
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
}

// MARK: - HAP Accessory

final class HAPAccessory: HAPAccessoryProtocol {

  let name: String
  let model: String
  let manufacturer: String
  let serialNumber: String
  let firmwareRevision: String
  let category: HAPAccessoryCategory
  let aid: Int

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Accessory")

  // MARK: - Lightbulb State

  private(set) var isOn: Bool = false {
    didSet { applyTorchState() }
  }

  private(set) var brightness: Int = 100 {
    didSet { applyTorchState() }
  }

  /// Callback for notifying the server of state changes (for EVENT notifications).
  var onStateChange: ((_ aid: Int, _ iid: Int, _ value: Any) -> Void)?

  init(
    aid: Int,
    name: String = "Pylo Flashlight",
    model: String = "iPhone Light",
    manufacturer: String = "HAP PoC",
    serialNumber: String = "000001",
    firmwareRevision: String = "1.0.0",
    category: HAPAccessoryCategory = .lightbulb
  ) {
    self.aid = aid
    self.name = name
    self.model = model
    self.manufacturer = manufacturer
    self.serialNumber = serialNumber
    self.firmwareRevision = firmwareRevision
    self.category = category
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

  func readCharacteristic(iid: Int) -> Any? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return manufacturer
    case AccessoryInfoIID.model: return model
    case AccessoryInfoIID.name: return name
    case AccessoryInfoIID.serialNumber: return serialNumber
    case AccessoryInfoIID.firmwareRevision: return firmwareRevision
    case Self.iidOn: return isOn
    case Self.iidBrightness: return brightness
    default: return nil
    }
  }

  // MARK: - Write Characteristic

  /// Returns true if the write was accepted.
  @discardableResult
  func writeCharacteristic(iid: Int, value: Any) -> Bool {
    switch iid {
    case AccessoryInfoIID.identify:
      identify()
      return true
    case Self.iidOn:
      if let v = value as? Bool {
        isOn = v
        onStateChange?(aid, iid, v)
        logger.info("Light \(v ? "ON" : "OFF")")
        return true
      } else if let v = value as? Int {
        isOn = (v != 0)
        onStateChange?(aid, iid, isOn)
        return true
      }
      return false
    case Self.iidBrightness:
      if let v = value as? Int {
        brightness = max(0, min(100, v))
        onStateChange?(aid, iid, brightness)
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
    [
      "aid": aid,
      "services": [
        accessoryInformationServiceJSON(),
        // Lightbulb Service
        [
          "iid": Self.iidLightbulbService,
          "type": Self.uuidLightbulb,
          "characteristics": [
            characteristicJSON(
              iid: Self.iidOn, type: Self.uuidOn, format: "bool",
              perms: ["pr", "pw", "ev"], value: isOn),
            characteristicJSON(
              iid: Self.iidBrightness, type: Self.uuidBrightness,
              format: "int", perms: ["pr", "pw", "ev"], value: brightness,
              minValue: 0, maxValue: 100, unit: "percentage"),
          ],
        ],
      ],
    ]
  }

  private func characteristicJSON(
    iid: Int,
    type: String,
    format: String,
    perms: [String],
    value: Any?,
    minValue: Any? = nil,
    maxValue: Any? = nil,
    unit: String? = nil
  ) -> [String: Any] {
    var json: [String: Any] = [
      "iid": iid,
      "type": type,
      "format": format,
      "perms": perms,
    ]
    if let value { json["value"] = value }
    if let minValue { json["minValue"] = minValue }
    if let maxValue { json["maxValue"] = maxValue }
    if let unit { json["unit"] = unit }
    return json
  }
}

// MARK: - Bridge Info Accessory

/// Lightweight accessory representing the bridge itself (aid=1).
/// Only exposes the Accessory Information service.
final class HAPBridgeInfo: HAPAccessoryProtocol {

  let aid: Int = 1
  let name: String
  let model: String
  let manufacturer: String
  let serialNumber: String
  let firmwareRevision: String
  var onStateChange: ((_ aid: Int, _ iid: Int, _ value: Any) -> Void)?

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

  func readCharacteristic(iid: Int) -> Any? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return manufacturer
    case AccessoryInfoIID.model: return model
    case AccessoryInfoIID.name: return name
    case AccessoryInfoIID.serialNumber: return serialNumber
    case AccessoryInfoIID.firmwareRevision: return firmwareRevision
    default: return nil
    }
  }

  @discardableResult
  func writeCharacteristic(iid: Int, value: Any) -> Bool {
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
final class HAPLightSensorAccessory: HAPAccessoryProtocol {

  let aid: Int
  let name: String
  let model: String
  let manufacturer: String
  let serialNumber: String
  let firmwareRevision: String
  var onStateChange: ((_ aid: Int, _ iid: Int, _ value: Any) -> Void)?

  private(set) var ambientLightLevel: Float = 1.0

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
    ambientLightLevel = lux
    onStateChange?(aid, Self.iidAmbientLightLevel, lux)
  }

  func readCharacteristic(iid: Int) -> Any? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return manufacturer
    case AccessoryInfoIID.model: return model
    case AccessoryInfoIID.name: return name
    case AccessoryInfoIID.serialNumber: return serialNumber
    case AccessoryInfoIID.firmwareRevision: return firmwareRevision
    case Self.iidAmbientLightLevel: return ambientLightLevel
    default: return nil
    }
  }

  @discardableResult
  func writeCharacteristic(iid: Int, value: Any) -> Bool {
    if iid == AccessoryInfoIID.identify {
      identify()
      return true
    }
    return false
  }

  func identify() {}

  func toJSON() -> [String: Any] {
    [
      "aid": aid,
      "services": [
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
      ],
    ]
  }
}

// MARK: - Motion Sensor Accessory

/// Standalone motion sensor accessory for the bridge.
final class HAPMotionSensorAccessory: HAPAccessoryProtocol {

  let aid: Int
  let name: String
  let model: String
  let manufacturer: String
  let serialNumber: String
  let firmwareRevision: String
  var onStateChange: ((_ aid: Int, _ iid: Int, _ value: Any) -> Void)?

  private(set) var isMotionDetected: Bool = false

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
    isMotionDetected = detected
    onStateChange?(aid, Self.iidMotionDetected, detected)
  }

  func readCharacteristic(iid: Int) -> Any? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return manufacturer
    case AccessoryInfoIID.model: return model
    case AccessoryInfoIID.name: return name
    case AccessoryInfoIID.serialNumber: return serialNumber
    case AccessoryInfoIID.firmwareRevision: return firmwareRevision
    case Self.iidMotionDetected: return isMotionDetected
    default: return nil
    }
  }

  @discardableResult
  func writeCharacteristic(iid: Int, value: Any) -> Bool {
    if iid == AccessoryInfoIID.identify {
      identify()
      return true
    }
    return false
  }

  func identify() {}

  func toJSON() -> [String: Any] {
    [
      "aid": aid,
      "services": [
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
      ],
    ]
  }
}
