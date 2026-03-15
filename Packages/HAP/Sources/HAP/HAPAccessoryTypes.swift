import CryptoKit
import Foundation
import Locked
import os

// MARK: - Accessory IDs

/// Central registry of accessory IDs (aids) used by the Pylo bridge.
/// HAP requires aid=1 for the bridge; accessories use 2+.
/// Add new entries here to avoid ID collisions across branches.
public enum AccessoryID {
  public static let bridge = 1
  public static let lightbulb = 2
  public static let camera = 3
  public static let lightSensor = 4
  public static let motionSensor = 5
  public static let contactSensor = 6
  public static let occupancySensor = 7
  public static let siren = 8
  public static let button = 9
}

// MARK: - Accessory Category (Table 12-3 in HAP R2 spec)

public enum HAPAccessoryCategory: Int, Sendable {
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
  case doorbell = 16
  case ipCamera = 17
}

// MARK: - Type-safe Characteristic Value

/// Type-safe wrapper for HAP characteristic values, replacing untyped `Any`.
public enum HAPValue: Equatable, Sendable {
  case bool(Bool)
  case int(Int)
  case float(Double)
  case string(String)
  case null

  /// Convert to a JSON-serializable value for `JSONSerialization`.
  public var jsonValue: Any {
    switch self {
    case .bool(let v): return v
    case .int(let v): return v
    case .float(let v): return v
    case .string(let v): return v
    case .null: return NSNull()
    }
  }

  /// Create from a JSON-deserialized value (from `JSONSerialization`).
  public init?(fromJSON value: Any) {
    if let s = value as? String {
      self = .string(s)
      return
    }
    if value is NSNull {
      self = .null
      return
    }
    if let n = value as? NSNumber {
      if CFGetTypeID(n) == CFBooleanGetTypeID() {
        self = .bool(n.boolValue)
      } else if CFNumberIsFloatType(n) {
        self = .float(n.doubleValue)
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
///
/// The mutable `onStateChange` property requires conformers to be `@unchecked Sendable`
/// with manual lock protection. This is intentional — Swift protocols cannot have stored
/// properties, and a base class would force a class hierarchy that's worse than the 4-line
/// boilerplate each conformer duplicates (Locked + computed get/set).
public protocol HAPAccessoryProtocol: AnyObject {
  var aid: Int { get }
  var name: String { get }
  var model: String { get }
  var manufacturer: String { get }
  var serialNumber: String { get }
  var firmwareRevision: String { get }
  var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? { get set }
  func readCharacteristic(iid: Int) -> HAPValue?
  @discardableResult func writeCharacteristic(
    iid: Int, value: HAPValue, sharedSecret: SharedSecret?
  ) -> Bool
  func identify()
  func toJSON() -> [String: Any]
}

// MARK: - Shared HAP Service/Characteristic UUIDs (shortened form)

/// HAP uses Apple-defined UUIDs of the form 000000XX-0000-1000-8000-0026BB765291.
/// The JSON representation uses just the short hex string.
///
/// These values match the HomeKit framework constants (HMServiceTypeAccessoryInformation,
/// HMCharacteristicTypeIdentify, etc.) but are hardcoded here because the HAP package
/// cannot import HomeKit. The app target verifies them via HomeKitUUIDs.swift.
public enum HAPUUID {
  public static let accessoryInformation = "3E"  // HMServiceTypeAccessoryInformation
  public static let identify = "14"  // HMCharacteristicTypeIdentify
  public static let manufacturer = "20"  // HMCharacteristicTypeManufacturer
  public static let model = "21"  // HMCharacteristicTypeModel
  public static let name = "23"  // HMCharacteristicTypeName
  public static let serialNumber = "30"  // HMCharacteristicTypeSerialNumber
  public static let firmwareRevision = "52"  // HMCharacteristicTypeFirmwareVersion
}

// MARK: - Shared Accessory Information IIDs

/// Instance IDs for the Accessory Information service, shared by all accessories.
public enum AccessoryInfoIID {
  public static let service = 1
  public static let identify = 2
  public static let manufacturer = 3
  public static let model = 4
  public static let name = 5
  public static let serialNumber = 6
  public static let firmwareRevision = 7
}

// MARK: - HAP Protocol Information Service (required by HAP spec §6.6.1)

/// IIDs for the HAP Protocol Information service, shared by all accessories.
/// Uses IIDs 110-111 to avoid conflicts with other shared services (Battery is 100-103).
public enum ProtocolInfoIID {
  public static let service = 110
  public static let version = 111
}

/// HAP short-form UUIDs for the Protocol Information service.
public enum ProtocolInfoUUID {
  public static let service = "A2"  // HAP Protocol Information
  public static let version = "37"  // Version characteristic
  /// The HAP protocol version reported in the Protocol Information service.
  /// Also relates to "pv" in the Bonjour TXT record ("1.1"), which uses a shorter format.
  public static let protocolVersion = "1.1.0"
}

/// Backwards-compatible alias — prefer `ProtocolInfoUUID.protocolVersion`.
public let hapProtocolVersion = ProtocolInfoUUID.protocolVersion

// MARK: - Shared Battery Service IIDs & UUIDs

/// Instance IDs for the Battery Service, shared by all accessories.
/// IIDs 100-103 are safely above all current accessory IIDs.
public enum BatteryIID {
  public static let service = 100
  public static let batteryLevel = 101
  public static let chargingState = 102
  public static let statusLowBattery = 103
}

/// HAP short-form UUIDs for the Battery Service and its characteristics.
/// Values match HomeKit constants (HMServiceTypeBattery, HMCharacteristicTypeBatteryLevel, etc.).
public enum BatteryUUID {
  public static let service = "96"  // HMServiceTypeBattery
  public static let level = "68"  // HMCharacteristicTypeBatteryLevel
  public static let chargingState = "8F"  // HMCharacteristicTypeChargingState
  public static let lowBattery = "79"  // HMCharacteristicTypeStatusLowBattery
}

extension HAPAccessoryProtocol {
  /// Builds the Accessory Information service JSON (iid 1, characteristics 2-7).
  /// Shared by all accessories to avoid duplicating this boilerplate.
  public func accessoryInformationServiceJSON() -> [String: Any] {
    [
      "iid": AccessoryInfoIID.service,
      "type": HAPUUID.accessoryInformation,
      "characteristics": [
        [
          "iid": AccessoryInfoIID.identify,
          "type": HAPUUID.identify, "format": "bool",
          "perms": ["pw"],
        ],
        [
          "iid": AccessoryInfoIID.manufacturer,
          "type": HAPUUID.manufacturer, "format": "string",
          "perms": ["pr"], "value": manufacturer,
        ],
        [
          "iid": AccessoryInfoIID.model,
          "type": HAPUUID.model, "format": "string",
          "perms": ["pr"], "value": model,
        ],
        [
          "iid": AccessoryInfoIID.name,
          "type": HAPUUID.name, "format": "string",
          "perms": ["pr"], "value": name,
        ],
        [
          "iid": AccessoryInfoIID.serialNumber,
          "type": HAPUUID.serialNumber, "format": "string",
          "perms": ["pr"], "value": serialNumber,
        ],
        [
          "iid": AccessoryInfoIID.firmwareRevision,
          "type": HAPUUID.firmwareRevision, "format": "string",
          "perms": ["pr"], "value": firmwareRevision,
        ],
      ],
    ]
  }

  /// Builds the HAP Protocol Information service JSON (iid 110, characteristic 111).
  /// Required by HAP spec §6.6.1 on every accessory.
  public func protocolInformationServiceJSON() -> [String: Any] {
    [
      "iid": ProtocolInfoIID.service,
      "type": ProtocolInfoUUID.service,
      "characteristics": [
        [
          "iid": ProtocolInfoIID.version,
          "type": ProtocolInfoUUID.version, "format": "string",
          "perms": ["pr"], "value": hapProtocolVersion,
        ]
      ],
    ]
  }

  /// Builds the Battery Service JSON (iid 100, characteristics 101-103).
  /// Only included when `batteryState` is non-nil (device has a battery).
  public func batteryServiceJSON(state: BatteryState?) -> [String: Any]? {
    guard let state else { return nil }
    let level = state.level
    let chargingState = state.chargingState
    let statusLowBattery = state.statusLowBattery
    return [
      "iid": BatteryIID.service,
      "type": BatteryUUID.service,
      "characteristics": [
        [
          "iid": BatteryIID.batteryLevel,
          "type": BatteryUUID.level, "format": "uint8",
          "perms": ["pr", "ev"], "value": level,
          "minValue": 0, "maxValue": 100, "minStep": 1,
          "unit": "percentage",
        ],
        [
          "iid": BatteryIID.chargingState,
          "type": BatteryUUID.chargingState, "format": "uint8",
          "perms": ["pr", "ev"], "value": chargingState,
          "minValue": 0, "maxValue": 2,
        ],
        [
          "iid": BatteryIID.statusLowBattery,
          "type": BatteryUUID.lowBattery, "format": "uint8",
          "perms": ["pr", "ev"], "value": statusLowBattery,
          "minValue": 0, "maxValue": 1,
        ],
      ],
    ]
  }
}

// MARK: - Bridge Info Accessory

/// Lightweight accessory representing the bridge itself (aid=1).
/// Exposes the Accessory Information and Protocol Information services.
public final class HAPBridgeInfo: HAPAccessoryProtocol, @unchecked Sendable {

  public let aid: Int = 1
  public let name: String
  public let model: String
  public let manufacturer: String
  public let serialNumber: String
  public let firmwareRevision: String

  private let _onStateChange = Locked<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  public var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  public init(
    name: String = "Pylo Bridge",
    model: String = "iPhone Bridge",
    manufacturer: String = "Pylo",
    serialNumber: String = "000000",
    firmwareRevision: String = "0.1.0"
  ) {
    self.name = name
    self.model = model
    self.manufacturer = manufacturer
    self.serialNumber = serialNumber
    self.firmwareRevision = firmwareRevision
  }

  public func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case ProtocolInfoIID.version: return .string(hapProtocolVersion)
    default: return nil
    }
  }

  @discardableResult
  public func writeCharacteristic(iid: Int, value: HAPValue, sharedSecret: SharedSecret? = nil)
    -> Bool
  {
    if iid == AccessoryInfoIID.identify {
      identify()
      return true
    }
    return false
  }

  public func identify() {
    // Bridge identify — no-op (sub-accessories handle their own)
  }

  public func toJSON() -> [String: Any] {
    [
      "aid": aid,
      "services": [
        accessoryInformationServiceJSON(),
        protocolInformationServiceJSON(),
      ],
    ]
  }
}

// MARK: - Siren Accessory

/// Standalone siren accessory for the bridge.
/// Uses the HAP Switch service — when turned on, the siren plays; when off, it stops.
public final class HAPSirenAccessory: HAPAccessoryProtocol, @unchecked Sendable {

  public let aid: Int
  public let name: String
  public let model: String
  public let manufacturer: String
  public let serialNumber: String
  public let firmwareRevision: String

  private let _onStateChange = Locked<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  public var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  /// Shared battery state — nil uses safe defaults (0/0/0) since the battery
  /// service is always present in `toJSON()` for stable accessory database hashing.
  private let _batteryState = Locked<BatteryState?>(initialState: nil)
  public var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  /// Called when HomeKit writes to the On characteristic.
  /// The app wires this to start/stop the siren player.
  private let _onSirenActivate = Locked<(@Sendable (Bool) -> Void)?>(initialState: nil)
  public var onSirenActivate: (@Sendable (Bool) -> Void)? {
    get { _onSirenActivate.withLock { $0 } }
    set { _onSirenActivate.withLock { $0 = newValue } }
  }

  private let _isOn = Locked(initialState: false)
  public var isOn: Bool {
    _isOn.withLock { $0 }
  }

  public static let iidSwitchService = 8
  public static let iidOn = 9

  private static let uuidSwitch = "49"  // Switch service
  private static let uuidOn = "25"  // On characteristic (same as lightbulb)

  public init(
    aid: Int,
    name: String = "Pylo Siren",
    model: String = "iPhone Siren",
    manufacturer: String = "Pylo",
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

  /// Update the siren state programmatically (e.g. when stopped externally).
  public func updateOn(_ on: Bool) {
    _isOn.withLock { $0 = on }
    onStateChange?(aid, Self.iidOn, .bool(on))
  }

  public func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case ProtocolInfoIID.version: return .string(hapProtocolVersion)
    case Self.iidOn: return .bool(isOn)
    case BatteryIID.batteryLevel: return batteryState.map { .int($0.level) }
    case BatteryIID.chargingState: return batteryState.map { .int($0.chargingState) }
    case BatteryIID.statusLowBattery: return batteryState.map { .int($0.statusLowBattery) }
    default: return nil
    }
  }

  @discardableResult
  public func writeCharacteristic(iid: Int, value: HAPValue, sharedSecret: SharedSecret? = nil)
    -> Bool
  {
    switch iid {
    case AccessoryInfoIID.identify:
      identify()
      return true
    case Self.iidOn:
      if case .bool(let on) = value {
        _isOn.withLock { $0 = on }
        onSirenActivate?(on)
        onStateChange?(aid, Self.iidOn, .bool(on))
        return true
      }
      // HomeKit sometimes sends 0/1 as int
      if case .int(let v) = value {
        let on = v != 0
        _isOn.withLock { $0 = on }
        onSirenActivate?(on)
        onStateChange?(aid, Self.iidOn, .bool(on))
        return true
      }
      return false
    default:
      return false
    }
  }

  public func identify() {}

  public func toJSON() -> [String: Any] {
    var services: [[String: Any]] = [
      accessoryInformationServiceJSON(),
      protocolInformationServiceJSON(),
      [
        "iid": Self.iidSwitchService,
        "type": Self.uuidSwitch,
        "characteristics": [
          [
            "iid": Self.iidOn,
            "type": Self.uuidOn, "format": "bool",
            "perms": ["pr", "pw", "ev"], "value": isOn,
          ]
        ],
      ],
    ]
    if let battery = batteryServiceJSON(state: batteryState) { services.append(battery) }
    return ["aid": aid, "services": services]
  }
}

// MARK: - Motion Sensor Accessory

/// Standalone motion sensor accessory for the bridge.
public final class HAPMotionSensorAccessory: HAPAccessoryProtocol, @unchecked Sendable {

  public let aid: Int
  public let name: String
  public let model: String
  public let manufacturer: String
  public let serialNumber: String
  public let firmwareRevision: String

  private let _onStateChange = Locked<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  public var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  /// Shared battery state — nil means no battery, omit battery service.
  private let _batteryState = Locked<BatteryState?>(initialState: nil)
  public var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  private let _isMotionDetected = Locked(initialState: false)
  public var isMotionDetected: Bool {
    _isMotionDetected.withLock { $0 }
  }

  public static let iidMotionSensorService = 8
  public static let iidMotionDetected = 9

  private static let uuidMotionSensor = "85"  // HMServiceTypeMotionSensor
  private static let uuidMotionDetected = "22"  // HMCharacteristicTypeMotionDetected

  public init(
    aid: Int,
    name: String = "Pylo Motion Sensor",
    model: String = "iPhone Motion Sensor",
    manufacturer: String = "Pylo",
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

  public func updateMotionDetected(_ detected: Bool) {
    _isMotionDetected.withLock { $0 = detected }
    onStateChange?(aid, Self.iidMotionDetected, .bool(detected))
  }

  public func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case ProtocolInfoIID.version: return .string(hapProtocolVersion)
    case Self.iidMotionDetected: return .bool(isMotionDetected)
    case BatteryIID.batteryLevel: return batteryState.map { .int($0.level) }
    case BatteryIID.chargingState: return batteryState.map { .int($0.chargingState) }
    case BatteryIID.statusLowBattery: return batteryState.map { .int($0.statusLowBattery) }
    default: return nil
    }
  }

  @discardableResult
  public func writeCharacteristic(iid: Int, value: HAPValue, sharedSecret: SharedSecret? = nil)
    -> Bool
  {
    if iid == AccessoryInfoIID.identify {
      identify()
      return true
    }
    return false
  }

  public func identify() {}

  public func toJSON() -> [String: Any] {
    var services: [[String: Any]] = [
      accessoryInformationServiceJSON(),
      protocolInformationServiceJSON(),
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
    if let battery = batteryServiceJSON(state: batteryState) { services.append(battery) }
    return ["aid": aid, "services": services]
  }
}

// MARK: - Contact Sensor Accessory

/// Standalone contact sensor accessory for the bridge.
/// Uses the iPhone's proximity sensor to detect open/close state.
public final class HAPContactSensorAccessory: HAPAccessoryProtocol,
  @unchecked Sendable
{

  public let aid: Int
  public let name: String
  public let model: String
  public let manufacturer: String
  public let serialNumber: String
  public let firmwareRevision: String

  private let _onStateChange = Locked<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  public var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  /// Shared battery state — nil means no battery, omit battery service.
  private let _batteryState = Locked<BatteryState?>(initialState: nil)
  public var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  /// HAP ContactSensorState: 0 = contact detected (closed), 1 = contact not detected (open).
  private let _contactState = Locked(initialState: 1)
  public var contactState: Int {
    _contactState.withLock { $0 }
  }

  public static let iidContactSensorService = 8
  public static let iidContactSensorState = 9

  private static let uuidContactSensor = "80"  // HMServiceTypeContactSensor
  private static let uuidContactSensorState = "6A"  // HMCharacteristicTypeContactState

  public init(
    aid: Int,
    name: String = "Pylo Contact Sensor",
    model: String = "iPhone Contact Sensor",
    manufacturer: String = "Pylo",
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

  /// Update contact state from proximity sensor.
  /// `near` = true means contact detected (state 0), false means no contact (state 1).
  public func updateContactState(near: Bool) {
    let state = near ? 0 : 1
    _contactState.withLock { $0 = state }
    onStateChange?(aid, Self.iidContactSensorState, .int(state))
  }

  public func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case ProtocolInfoIID.version: return .string(hapProtocolVersion)
    case Self.iidContactSensorState: return .int(contactState)
    case BatteryIID.batteryLevel: return batteryState.map { .int($0.level) }
    case BatteryIID.chargingState: return batteryState.map { .int($0.chargingState) }
    case BatteryIID.statusLowBattery: return batteryState.map { .int($0.statusLowBattery) }
    default: return nil
    }
  }

  @discardableResult
  public func writeCharacteristic(iid: Int, value: HAPValue, sharedSecret: SharedSecret? = nil)
    -> Bool
  {
    if iid == AccessoryInfoIID.identify {
      identify()
      return true
    }
    return false
  }

  public func identify() {}

  public func toJSON() -> [String: Any] {
    var services: [[String: Any]] = [
      accessoryInformationServiceJSON(),
      protocolInformationServiceJSON(),
      [
        "iid": Self.iidContactSensorService,
        "type": Self.uuidContactSensor,
        "characteristics": [
          [
            "iid": Self.iidContactSensorState,
            "type": Self.uuidContactSensorState, "format": "uint8",
            "perms": ["pr", "ev"], "value": contactState,
            "minValue": 0, "maxValue": 1,
          ]
        ],
      ],
    ]
    if let battery = batteryServiceJSON(state: batteryState) { services.append(battery) }
    return ["aid": aid, "services": services]
  }
}

// MARK: - Occupancy Sensor Accessory

/// Standalone occupancy sensor accessory for the bridge.
/// Uses Vision framework person detection to expose persistent occupied/unoccupied state.
public final class HAPOccupancySensorAccessory: HAPAccessoryProtocol,
  @unchecked Sendable
{

  public let aid: Int
  public let name: String
  public let model: String
  public let manufacturer: String
  public let serialNumber: String
  public let firmwareRevision: String

  private let _onStateChange = Locked<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  public var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  /// Shared battery state — nil means no battery, omit battery service.
  private let _batteryState = Locked<BatteryState?>(initialState: nil)
  public var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  private let _isOccupancyDetected = Locked(initialState: false)
  public var isOccupancyDetected: Bool {
    _isOccupancyDetected.withLock { $0 }
  }

  public static let iidOccupancySensorService = 8
  public static let iidOccupancyDetected = 9

  private static let uuidOccupancySensor = "86"  // HMServiceTypeOccupancySensor
  private static let uuidOccupancyDetected = "71"  // HMCharacteristicTypeOccupancyDetected

  public init(
    aid: Int,
    name: String = "Pylo Occupancy Sensor",
    model: String = "iPhone Occupancy Sensor",
    manufacturer: String = "Pylo",
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

  public func updateOccupancyDetected(_ detected: Bool) {
    _isOccupancyDetected.withLock { $0 = detected }
    onStateChange?(aid, Self.iidOccupancyDetected, .int(detected ? 1 : 0))
  }

  public func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case ProtocolInfoIID.version: return .string(hapProtocolVersion)
    case Self.iidOccupancyDetected: return .int(isOccupancyDetected ? 1 : 0)
    case BatteryIID.batteryLevel: return batteryState.map { .int($0.level) }
    case BatteryIID.chargingState: return batteryState.map { .int($0.chargingState) }
    case BatteryIID.statusLowBattery: return batteryState.map { .int($0.statusLowBattery) }
    default: return nil
    }
  }

  @discardableResult
  public func writeCharacteristic(iid: Int, value: HAPValue, sharedSecret: SharedSecret? = nil)
    -> Bool
  {
    if iid == AccessoryInfoIID.identify {
      identify()
      return true
    }
    return false
  }

  public func identify() {}

  public func toJSON() -> [String: Any] {
    var services: [[String: Any]] = [
      accessoryInformationServiceJSON(),
      protocolInformationServiceJSON(),
      [
        "iid": Self.iidOccupancySensorService,
        "type": Self.uuidOccupancySensor,
        "characteristics": [
          [
            "iid": Self.iidOccupancyDetected,
            "type": Self.uuidOccupancyDetected, "format": "uint8",
            "perms": ["pr", "ev"], "value": isOccupancyDetected ? 1 : 0,
            "minValue": 0, "maxValue": 1,
          ]
        ],
      ],
    ]
    if let battery = batteryServiceJSON(state: batteryState) { services.append(battery) }
    return ["aid": aid, "services": services]
  }
}

// MARK: - Light Sensor Accessory

/// Standalone ambient light sensor accessory for the bridge.
public final class HAPLightSensorAccessory: HAPAccessoryProtocol, @unchecked Sendable {

  public let aid: Int
  public let name: String
  public let model: String
  public let manufacturer: String
  public let serialNumber: String
  public let firmwareRevision: String

  private let _onStateChange = Locked<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  public var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  /// Shared battery state — nil means no battery, omit battery service.
  private let _batteryState = Locked<BatteryState?>(initialState: nil)
  public var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  private let _currentLux = Locked<Float>(initialState: 1.0)
  public var currentLux: Float {
    _currentLux.withLock { $0 }
  }

  public static let iidLightSensorService = 8
  public static let iidCurrentAmbientLightLevel = 9

  private static let uuidLightSensor = "84"  // HMServiceTypeLightSensor
  private static let uuidCurrentAmbientLightLevel = "6B"  // HMCharacteristicTypeCurrentLightLevel

  public init(
    aid: Int,
    name: String = "Pylo Light Sensor",
    model: String = "iPhone Light Sensor",
    manufacturer: String = "Pylo",
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

  public func updateLux(_ lux: Float) {
    _currentLux.withLock { $0 = lux }
    onStateChange?(aid, Self.iidCurrentAmbientLightLevel, .float(Double(lux)))
  }

  public func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case ProtocolInfoIID.version: return .string(hapProtocolVersion)
    case Self.iidCurrentAmbientLightLevel: return .float(Double(currentLux))
    case BatteryIID.batteryLevel: return batteryState.map { .int($0.level) }
    case BatteryIID.chargingState: return batteryState.map { .int($0.chargingState) }
    case BatteryIID.statusLowBattery: return batteryState.map { .int($0.statusLowBattery) }
    default: return nil
    }
  }

  @discardableResult
  public func writeCharacteristic(iid: Int, value: HAPValue, sharedSecret: SharedSecret? = nil)
    -> Bool
  {
    if iid == AccessoryInfoIID.identify {
      identify()
      return true
    }
    return false
  }

  public func identify() {}

  public func toJSON() -> [String: Any] {
    var services: [[String: Any]] = [
      accessoryInformationServiceJSON(),
      protocolInformationServiceJSON(),
      [
        "iid": Self.iidLightSensorService,
        "type": Self.uuidLightSensor,
        "characteristics": [
          [
            "iid": Self.iidCurrentAmbientLightLevel,
            "type": Self.uuidCurrentAmbientLightLevel, "format": "float",
            "perms": ["pr", "ev"], "value": max(0.0001, Double(currentLux)),
            "minValue": 0.0001, "maxValue": 100000, "unit": "lux",
          ] as [String: Any]
        ],
      ],
    ]
    if let battery = batteryServiceJSON(state: batteryState) { services.append(battery) }
    return ["aid": aid, "services": services]
  }
}

// MARK: - Button Accessory

/// Standalone button accessory using a Stateless Programmable Switch.
/// Shows up as a button tile in Home.app; can be configured with automations
/// to send notifications, play sounds, etc.
public final class HAPButtonAccessory: HAPAccessoryProtocol, @unchecked Sendable {

  public let aid: Int
  public let name: String
  public let model: String
  public let manufacturer: String
  public let serialNumber: String
  public let firmwareRevision: String

  private let _onStateChange = Locked<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  public var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  private let _batteryState = Locked<BatteryState?>(initialState: nil)
  public var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  // Stateless Programmable Switch service (iid 8-10)
  public static let iidSwitchService = 8
  public static let iidProgrammableSwitchEvent = 9
  public static let iidServiceLabelIndex = 10

  // Service Label service (iid 11-12)
  public static let iidServiceLabelService = 11
  public static let iidServiceLabelNamespace = 12

  // HMServiceTypeStatelessProgrammableSwitch
  private static let uuidStatelessProgrammableSwitch = "89"
  // HMCharacteristicTypeProgrammableSwitchEvent
  private static let uuidProgrammableSwitchEvent = "73"
  // HAP Service Label Index (no public HomeKit constant)
  private static let uuidServiceLabelIndex = "CB"
  // HMServiceTypeLabel
  private static let uuidServiceLabel = "CC"
  // HAP Service Label Namespace (no public HomeKit constant)
  private static let uuidServiceLabelNamespace = "CD"

  public init(
    aid: Int,
    name: String = "Pylo Button",
    model: String = "iPhone Button",
    manufacturer: String = "Pylo",
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

  /// Fire a single-press event.
  public func trigger() {
    onStateChange?(aid, Self.iidProgrammableSwitchEvent, .int(0))
  }

  public func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case ProtocolInfoIID.version: return .string(hapProtocolVersion)
    case Self.iidProgrammableSwitchEvent: return .null
    case Self.iidServiceLabelIndex: return .int(1)
    case Self.iidServiceLabelNamespace: return .int(1)  // Arabic numerals
    case BatteryIID.batteryLevel: return batteryState.map { .int($0.level) }
    case BatteryIID.chargingState: return batteryState.map { .int($0.chargingState) }
    case BatteryIID.statusLowBattery: return batteryState.map { .int($0.statusLowBattery) }
    default: return nil
    }
  }

  @discardableResult
  public func writeCharacteristic(iid: Int, value: HAPValue, sharedSecret: SharedSecret? = nil)
    -> Bool
  {
    if iid == AccessoryInfoIID.identify {
      identify()
      return true
    }
    return false
  }

  public func identify() {}

  public func toJSON() -> [String: Any] {
    var services: [[String: Any]] = [
      accessoryInformationServiceJSON(),
      protocolInformationServiceJSON(),
      // Stateless Programmable Switch service
      [
        "iid": Self.iidSwitchService,
        "type": Self.uuidStatelessProgrammableSwitch,
        "primary": true,
        "characteristics": [
          [
            "iid": Self.iidProgrammableSwitchEvent,
            "type": Self.uuidProgrammableSwitchEvent, "format": "uint8",
            "perms": ["pr", "ev"],
            "minValue": 0, "maxValue": 2,
            "value": NSNull(),
          ] as [String: Any],
          [
            "iid": Self.iidServiceLabelIndex,
            "type": Self.uuidServiceLabelIndex, "format": "uint8",
            "perms": ["pr"], "value": 1,
            "minValue": 1,
          ],
        ],
      ] as [String: Any],
      // Service Label service (required by HAP spec for programmable switches)
      [
        "iid": Self.iidServiceLabelService,
        "type": Self.uuidServiceLabel,
        "characteristics": [
          [
            "iid": Self.iidServiceLabelNamespace,
            "type": Self.uuidServiceLabelNamespace, "format": "uint8",
            "perms": ["pr"], "value": 1,  // 1 = Arabic numerals
            "minValue": 0, "maxValue": 1,
          ]
        ],
      ],
    ]
    if let battery = batteryServiceJSON(state: batteryState) { services.append(battery) }
    return ["aid": aid, "services": services]
  }
}
