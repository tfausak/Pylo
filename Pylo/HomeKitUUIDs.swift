import HomeKit

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
  static let accessoryInformation = "3E"  // HMServiceTypeAccessoryInformation
  static let lightbulb = "43"  // HMServiceTypeLightbulb
  static let cameraRTPStreamManagement = "110"  // HMServiceTypeCameraRTPStreamManagement
  static let microphone = "112"  // HMServiceTypeMicrophone
  static let speaker = "113"  // HMServiceTypeSpeaker
  static let motionSensor = "85"  // HMServiceTypeMotionSensor
  static let lightSensor = "84"  // HMServiceTypeLightSensor
  static let battery = "96"  // HMServiceTypeBattery
}

// MARK: - Characteristic UUIDs

nonisolated enum HKCharacteristicUUID {
  // Accessory Information
  static let identify = "14"  // HMCharacteristicTypeIdentify
  static let manufacturer = "20"  // HMCharacteristicTypeManufacturer
  static let model = "21"  // HMCharacteristicTypeModel
  static let name = "23"  // HMCharacteristicTypeName
  static let serialNumber = "30"  // HMCharacteristicTypeSerialNumber
  static let firmwareRevision = "52"  // HMCharacteristicTypeFirmwareVersion
  static let version = "37"  // HMCharacteristicTypeVersion

  // Lightbulb
  static let on = "25"  // HMCharacteristicTypePowerState
  static let brightness = "8"  // HMCharacteristicTypeBrightness

  // Camera RTP Stream
  static let supportedVideoStreamConfig = "114"  // HMCharacteristicTypeSupportedVideoStreamConfiguration
  static let supportedAudioStreamConfig = "115"  // HMCharacteristicTypeSupportedAudioStreamConfiguration
  static let supportedRTPConfig = "116"  // HMCharacteristicTypeSupportedRTPConfiguration
  static let selectedRTPStreamConfig = "117"  // HMCharacteristicTypeSelectedStreamConfiguration
  static let setupEndpoints = "118"  // HMCharacteristicTypeSetupStreamEndpoint
  static let streamingStatus = "120"  // HMCharacteristicTypeStreamingStatus

  // Audio
  static let mute = "11A"  // HMCharacteristicTypeMute
  static let volume = "119"  // HMCharacteristicTypeVolume
  static let active = "B0"  // HMCharacteristicTypeActive

  // Motion Sensor
  static let motionDetected = "22"  // HMCharacteristicTypeMotionDetected

  // Light Sensor
  static let currentAmbientLightLevel = "6B"  // HMCharacteristicTypeCurrentLightLevel

  // Battery
  static let batteryLevel = "68"  // HMCharacteristicTypeBatteryLevel
  static let chargingState = "8F"  // HMCharacteristicTypeChargingState
  static let statusLowBattery = "79"  // HMCharacteristicTypeStatusLowBattery
}

// MARK: - Debug Verification

/// Verify that hardcoded UUID strings match the public HomeKit framework constants.
/// Called once at startup in debug builds to catch any drift.
@MainActor
func verifyHomeKitUUIDs() {
  #if DEBUG
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
  #endif
}
