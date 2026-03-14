#if os(iOS)
  import HomeKit
#endif

// MARK: - HomeKit UUID Mapping
//
// HAP uses short-form UUIDs (e.g., "110") derived from Apple's full-form UUIDs
// (e.g., "00000110-0000-1000-8000-0026BB765291"). The values below are hardcoded
// for concurrency compatibility (HomeKit constants are @MainActor-isolated), but
// verified against the public HomeKit framework constants in debug builds.
//
// UUIDs that don't have public HomeKit constants (HKSV, DataStream) remain as
// literals in HAPCameraAccessory.swift with explicit documentation.

/// Extract the HAP short-form UUID from a full HomeKit UUID string.
/// "00000110-0000-1000-8000-0026BB765291" → "110"
private func hapShortUUID(_ fullUUID: String) -> String {
  let hex = fullUUID.prefix(8)  // "00000110"
  let value = UInt32(hex, radix: 16) ?? 0
  return String(value, radix: 16, uppercase: true)
}

// MARK: - Service UUIDs

nonisolated enum HKServiceUUID {
  // HMServiceTypeAccessoryInformation
  static let accessoryInformation = "3E"
  // HMServiceTypeLightbulb
  static let lightbulb = "43"
  // HMServiceTypeCameraRTPStreamManagement
  static let cameraRTPStreamManagement = "110"
  // HMServiceTypeMicrophone
  static let microphone = "112"
  // HMServiceTypeSpeaker
  static let speaker = "113"
  // HMServiceTypeMotionSensor
  static let motionSensor = "85"
  // HMServiceTypeLightSensor
  static let lightSensor = "84"
  // HMServiceTypeBattery
  static let battery = "96"
  // HMServiceTypeContactSensor
  static let contactSensor = "80"
  // HMServiceTypeOccupancySensor
  static let occupancySensor = "86"
  // HMServiceTypeSwitch
  static let `switch` = "49"
  // HMServiceTypeStatelessProgrammableSwitch
  static let statelessProgrammableSwitch = "89"
  // HMServiceTypeLabel
  static let serviceLabel = "CC"
}

// MARK: - Characteristic UUIDs

nonisolated enum HKCharacteristicUUID {
  // Accessory Information

  // HMCharacteristicTypeIdentify
  static let identify = "14"
  // HMCharacteristicTypeManufacturer
  static let manufacturer = "20"
  // HMCharacteristicTypeModel
  static let model = "21"
  // HMCharacteristicTypeName
  static let name = "23"
  // HMCharacteristicTypeSerialNumber
  static let serialNumber = "30"
  // HMCharacteristicTypeFirmwareVersion
  static let firmwareRevision = "52"
  // HMCharacteristicTypeVersion
  static let version = "37"

  // Lightbulb

  // HMCharacteristicTypePowerState
  static let on = "25"
  // HMCharacteristicTypeBrightness
  static let brightness = "8"

  // Camera RTP Stream

  // HMCharacteristicTypeSupportedVideoStreamConfiguration
  static let supportedVideoStreamConfig = "114"
  // HMCharacteristicTypeSupportedAudioStreamConfiguration
  static let supportedAudioStreamConfig = "115"
  // HMCharacteristicTypeSupportedRTPConfiguration
  static let supportedRTPConfig = "116"
  // HMCharacteristicTypeSelectedStreamConfiguration
  static let selectedRTPStreamConfig = "117"
  // HMCharacteristicTypeSetupStreamEndpoint
  static let setupEndpoints = "118"
  // HMCharacteristicTypeStreamingStatus
  static let streamingStatus = "120"

  // Audio

  // HMCharacteristicTypeMute
  static let mute = "11A"
  // HMCharacteristicTypeVolume
  static let volume = "119"
  // HMCharacteristicTypeActive
  static let active = "B0"

  // Motion Sensor

  // HMCharacteristicTypeMotionDetected
  static let motionDetected = "22"

  // Light Sensor

  // HMCharacteristicTypeCurrentLightLevel
  static let currentAmbientLightLevel = "6B"

  // Contact Sensor

  // HMCharacteristicTypeContactState
  static let contactSensorState = "6A"

  // Occupancy Sensor

  // HMCharacteristicTypeOccupancyDetected
  static let occupancyDetected = "71"

  // Programmable Switch

  // HMCharacteristicTypeInputEvent (event-only)
  static let programmableSwitchEvent = "73"

  // Battery

  // HMCharacteristicTypeBatteryLevel
  static let batteryLevel = "68"
  // HMCharacteristicTypeChargingState
  static let chargingState = "8F"
  // HMCharacteristicTypeStatusLowBattery
  static let statusLowBattery = "79"
}

// MARK: - Debug Verification

/// Verify that hardcoded UUID strings match the public HomeKit framework constants.
/// Called once at startup in debug builds to catch any drift.
@MainActor
func verifyHomeKitUUIDs() {
  #if DEBUG && os(iOS)
    func check(_ hardcoded: String, _ hmConstant: String, _ label: String) {
      let derived = hapShortUUID(hmConstant)
      assert(hardcoded == derived, "\(label): expected \(derived), got \(hardcoded)")
    }

    // Services
    check(
      HKServiceUUID.accessoryInformation, HMServiceTypeAccessoryInformation, "accessoryInformation")
    check(HKServiceUUID.lightbulb, HMServiceTypeLightbulb, "lightbulb")
    check(
      HKServiceUUID.cameraRTPStreamManagement, HMServiceTypeCameraRTPStreamManagement,
      "cameraRTPStreamManagement")
    check(HKServiceUUID.microphone, HMServiceTypeMicrophone, "microphone")
    check(HKServiceUUID.speaker, HMServiceTypeSpeaker, "speaker")
    check(HKServiceUUID.motionSensor, HMServiceTypeMotionSensor, "motionSensor")
    check(HKServiceUUID.lightSensor, HMServiceTypeLightSensor, "lightSensor")
    check(HKServiceUUID.battery, HMServiceTypeBattery, "battery")
    check(HKServiceUUID.contactSensor, HMServiceTypeContactSensor, "contactSensor")
    check(HKServiceUUID.occupancySensor, HMServiceTypeOccupancySensor, "occupancySensor")
    check(HKServiceUUID.switch, HMServiceTypeSwitch, "switch")
    check(
      HKServiceUUID.statelessProgrammableSwitch, HMServiceTypeStatelessProgrammableSwitch,
      "statelessProgrammableSwitch")
    check(HKServiceUUID.serviceLabel, HMServiceTypeLabel, "serviceLabel")

    // Characteristics
    check(HKCharacteristicUUID.identify, HMCharacteristicTypeIdentify, "identify")
    check(HKCharacteristicUUID.name, HMCharacteristicTypeName, "name")
    check(HKCharacteristicUUID.version, HMCharacteristicTypeVersion, "version")
    // Manufacturer, Model, SerialNumber, FirmwareVersion omitted — deprecated in iOS 11,
    // no way to suppress the warning in Swift, and their UUIDs haven't changed since iOS 8.
    check(HKCharacteristicUUID.on, HMCharacteristicTypePowerState, "on")
    check(HKCharacteristicUUID.brightness, HMCharacteristicTypeBrightness, "brightness")
    check(
      HKCharacteristicUUID.supportedVideoStreamConfig,
      HMCharacteristicTypeSupportedVideoStreamConfiguration, "supportedVideoStreamConfig")
    check(
      HKCharacteristicUUID.supportedAudioStreamConfig,
      HMCharacteristicTypeSupportedAudioStreamConfiguration, "supportedAudioStreamConfig")
    check(
      HKCharacteristicUUID.supportedRTPConfig, HMCharacteristicTypeSupportedRTPConfiguration,
      "supportedRTPConfig")
    check(
      HKCharacteristicUUID.selectedRTPStreamConfig, HMCharacteristicTypeSelectedStreamConfiguration,
      "selectedRTPStreamConfig")
    check(
      HKCharacteristicUUID.setupEndpoints, HMCharacteristicTypeSetupStreamEndpoint, "setupEndpoints"
    )
    check(
      HKCharacteristicUUID.streamingStatus, HMCharacteristicTypeStreamingStatus, "streamingStatus")
    check(HKCharacteristicUUID.mute, HMCharacteristicTypeMute, "mute")
    check(HKCharacteristicUUID.volume, HMCharacteristicTypeVolume, "volume")
    check(HKCharacteristicUUID.active, HMCharacteristicTypeActive, "active")
    check(HKCharacteristicUUID.motionDetected, HMCharacteristicTypeMotionDetected, "motionDetected")
    check(
      HKCharacteristicUUID.currentAmbientLightLevel, HMCharacteristicTypeCurrentLightLevel,
      "currentAmbientLightLevel")
    check(HKCharacteristicUUID.batteryLevel, HMCharacteristicTypeBatteryLevel, "batteryLevel")
    check(HKCharacteristicUUID.chargingState, HMCharacteristicTypeChargingState, "chargingState")
    check(
      HKCharacteristicUUID.statusLowBattery, HMCharacteristicTypeStatusLowBattery,
      "statusLowBattery")
    check(
      HKCharacteristicUUID.contactSensorState, HMCharacteristicTypeContactState,
      "contactSensorState")
    check(
      HKCharacteristicUUID.occupancyDetected, HMCharacteristicTypeOccupancyDetected,
      "occupancyDetected")
    check(
      HKCharacteristicUUID.programmableSwitchEvent,
      HMCharacteristicTypeInputEvent,
      "programmableSwitchEvent")
  #endif
}
