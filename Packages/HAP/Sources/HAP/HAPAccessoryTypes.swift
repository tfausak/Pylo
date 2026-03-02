import CryptoKit
import Foundation
import os

// MARK: - Accessory Category (Table 12-3 in HAP R2 spec)

public nonisolated enum HAPAccessoryCategory: Int, Sendable {
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
public nonisolated enum HAPValue: Equatable, Sendable {
  case bool(Bool)
  case int(Int)
  case float(Float)
  case string(String)

  /// Convert to a JSON-serializable value for `JSONSerialization`.
  public var jsonValue: Any {
    switch self {
    case .bool(let v): return v
    case .int(let v): return v
    case .float(let v): return v
    case .string(let v): return v
    }
  }

  /// Create from a JSON-deserialized value (from `JSONSerialization`).
  public init?(fromJSON value: Any) {
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
public nonisolated protocol HAPAccessoryProtocol: AnyObject {
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
public nonisolated enum HAPUUID {
  public static let accessoryInformation = "3E"
  public static let identify = "14"
  public static let manufacturer = "20"
  public static let model = "21"
  public static let name = "23"
  public static let serialNumber = "30"
  public static let firmwareRevision = "52"
}

// MARK: - Shared Accessory Information IIDs

/// Instance IDs for the Accessory Information service, shared by all accessories.
public nonisolated enum AccessoryInfoIID {
  public static let service = 1
  public static let identify = 2
  public static let manufacturer = 3
  public static let model = 4
  public static let name = 5
  public static let serialNumber = 6
  public static let firmwareRevision = 7
}

// MARK: - Shared Battery Service IIDs & UUIDs

/// Instance IDs for the Battery Service, shared by all accessories.
/// IIDs 100-103 are safely above all current accessory IIDs.
public nonisolated enum BatteryIID {
  public static let service = 100
  public static let batteryLevel = 101
  public static let chargingState = 102
  public static let statusLowBattery = 103
}

/// HAP short-form UUIDs for the Battery Service and its characteristics.
public nonisolated enum BatteryUUID {
  public static let service = "96"
  public static let level = "68"
  public static let chargingState = "8F"
  public static let lowBattery = "79"
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

  /// Builds the Battery Service JSON (iid 100, characteristics 101-103).
  /// Returns nil if the given `BatteryState` is nil (no battery on this device).
  public func batteryServiceJSON(state: BatteryState?) -> [String: Any]? {
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

// MARK: - Bridge Info Accessory

/// Lightweight accessory representing the bridge itself (aid=1).
/// Only exposes the Accessory Information service.
public nonisolated final class HAPBridgeInfo: HAPAccessoryProtocol, @unchecked Sendable {

  public let aid: Int = 1
  public let name: String
  public let model: String
  public let manufacturer: String
  public let serialNumber: String
  public let firmwareRevision: String

  private let _onStateChange = OSAllocatedUnfairLock<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  public var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  public init(
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

  public func readCharacteristic(iid: Int) -> HAPValue? {
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
        accessoryInformationServiceJSON()
      ],
    ]
  }
}

// MARK: - Motion Sensor Accessory

/// Standalone motion sensor accessory for the bridge.
public nonisolated final class HAPMotionSensorAccessory: HAPAccessoryProtocol, @unchecked Sendable {

  public let aid: Int
  public let name: String
  public let model: String
  public let manufacturer: String
  public let serialNumber: String
  public let firmwareRevision: String

  private let _onStateChange = OSAllocatedUnfairLock<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  public var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  /// Shared battery state — nil means no battery, omit battery service.
  private let _batteryState = OSAllocatedUnfairLock<BatteryState?>(initialState: nil)
  public var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  private let _isMotionDetected = OSAllocatedUnfairLock(initialState: false)
  public var isMotionDetected: Bool {
    _isMotionDetected.withLock { $0 }
  }

  public static let iidMotionSensorService = 8
  public static let iidMotionDetected = 9

  private static let uuidMotionSensor = "85"
  private static let uuidMotionDetected = "22"

  public init(
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

// MARK: - Light Sensor Accessory

/// Standalone ambient light sensor accessory for the bridge.
public nonisolated final class HAPLightSensorAccessory: HAPAccessoryProtocol, @unchecked Sendable {

  public let aid: Int
  public let name: String
  public let model: String
  public let manufacturer: String
  public let serialNumber: String
  public let firmwareRevision: String

  private let _onStateChange = OSAllocatedUnfairLock<
    (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)?
  >(initialState: nil)
  public var onStateChange: (@Sendable (_ aid: Int, _ iid: Int, _ value: HAPValue) -> Void)? {
    get { _onStateChange.withLock { $0 } }
    set { _onStateChange.withLock { $0 = newValue } }
  }

  /// Shared battery state — nil means no battery, omit battery service.
  private let _batteryState = OSAllocatedUnfairLock<BatteryState?>(initialState: nil)
  public var batteryState: BatteryState? {
    get { _batteryState.withLock { $0 } }
    set { _batteryState.withLock { $0 = newValue } }
  }

  private let _currentLux = OSAllocatedUnfairLock<Float>(initialState: 0.0001)
  public var currentLux: Float {
    _currentLux.withLock { $0 }
  }

  public static let iidLightSensorService = 8
  public static let iidCurrentAmbientLightLevel = 9

  private static let uuidLightSensor = "84"
  private static let uuidCurrentAmbientLightLevel = "6B"

  public init(
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

  public func updateLux(_ lux: Float) {
    _currentLux.withLock { $0 = lux }
    onStateChange?(aid, Self.iidCurrentAmbientLightLevel, .float(lux))
  }

  public func readCharacteristic(iid: Int) -> HAPValue? {
    switch iid {
    case AccessoryInfoIID.manufacturer: return .string(manufacturer)
    case AccessoryInfoIID.model: return .string(model)
    case AccessoryInfoIID.name: return .string(name)
    case AccessoryInfoIID.serialNumber: return .string(serialNumber)
    case AccessoryInfoIID.firmwareRevision: return .string(firmwareRevision)
    case Self.iidCurrentAmbientLightLevel: return .float(currentLux)
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
      [
        "iid": Self.iidLightSensorService,
        "type": Self.uuidLightSensor,
        "characteristics": [
          [
            "iid": Self.iidCurrentAmbientLightLevel,
            "type": Self.uuidCurrentAmbientLightLevel, "format": "float",
            "perms": ["pr", "ev"], "value": currentLux,
            "minValue": 0.0001, "maxValue": 100000, "unit": "lux",
          ] as [String: Any]
        ],
      ],
    ]
    if let battery = batteryServiceJSON(state: batteryState) {
      services.append(battery)
    }
    return ["aid": aid, "services": services]
  }
}
