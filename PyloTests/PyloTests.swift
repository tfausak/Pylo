import AudioToolbox
import CoreImage
import CryptoKit
import Foundation
import HAP
import Locked
import Sensors
import Streaming
import TLV8
import Testing

@testable import Pylo

// MARK: - HAP Lightbulb Accessory Tests

@Suite("HAP Lightbulb Accessory")
struct HAPAccessoryTests {

  @Test("Initial state is off with full brightness")
  func initialState() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.isOn == false)
    #expect(accessory.brightness == 100)
  }

  @Test("Read accessory information characteristics")
  func readInfoCharacteristics() {
    let accessory = HAPAccessory(
      aid: 2,
      name: "Test Light",
      model: "Test Model",
      manufacturer: "Test Maker",
      serialNumber: "SN-123",
      firmwareRevision: "2.0.0"
    )
    #expect(accessory.readCharacteristic(iid: AccessoryInfoIID.manufacturer) == .string("Test Maker"))
    #expect(accessory.readCharacteristic(iid: AccessoryInfoIID.model) == .string("Test Model"))
    #expect(accessory.readCharacteristic(iid: AccessoryInfoIID.name) == .string("Test Light"))
    #expect(accessory.readCharacteristic(iid: AccessoryInfoIID.serialNumber) == .string("SN-123"))
    #expect(accessory.readCharacteristic(iid: AccessoryInfoIID.firmwareRevision) == .string("2.0.0"))
  }

  @Test("Read lightbulb state characteristics")
  func readLightbulbState() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.readCharacteristic(iid: HAPAccessory.iidOn) == .bool(false))
    #expect(accessory.readCharacteristic(iid: HAPAccessory.iidBrightness) == .int(100))
  }

  @Test("Read unknown iid returns nil")
  func readUnknownIID() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.readCharacteristic(iid: 99) == nil)
  }

  @Test("Write on/off as bool")
  func writeOnBool() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: HAPAccessory.iidOn, value: .bool(true)))
    #expect(accessory.isOn == true)
    #expect(accessory.writeCharacteristic(iid: HAPAccessory.iidOn, value: .bool(false)))
    #expect(accessory.isOn == false)
  }

  @Test("Write on/off coerces int to bool")
  func writeOnInt() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: HAPAccessory.iidOn, value: .int(1)))
    #expect(accessory.isOn == true)
    #expect(accessory.writeCharacteristic(iid: HAPAccessory.iidOn, value: .int(0)))
    #expect(accessory.isOn == false)
  }

  @Test("Write on/off rejects invalid type")
  func writeOnInvalidType() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: HAPAccessory.iidOn, value: .string("yes")) == false)
  }

  @Test("Write brightness clamps to 0-100")
  func writeBrightnessClamped() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: HAPAccessory.iidBrightness, value: .int(50)))
    #expect(accessory.brightness == 50)

    #expect(accessory.writeCharacteristic(iid: HAPAccessory.iidBrightness, value: .int(150)))
    #expect(accessory.brightness == 100)

    #expect(accessory.writeCharacteristic(iid: HAPAccessory.iidBrightness, value: .int(-10)))
    #expect(accessory.brightness == 0)
  }

  @Test("Write brightness rejects non-int")
  func writeBrightnessInvalidType() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: HAPAccessory.iidBrightness, value: .string("50")) == false)
  }

  @Test("Write to unknown iid returns false")
  func writeUnknownIID() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 99, value: .bool(true)) == false)
  }

  @Test("Write identify succeeds")
  func writeIdentify() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: AccessoryInfoIID.identify, value: .bool(true)))
  }

  @Test("State change callback fires on write")
  func stateChangeCallback() {
    let accessory = HAPAccessory(aid: 2)
    struct CallbackState { var called = false; var aid = 0; var iid = 0 }
    let state = Locked(initialState: CallbackState())
    accessory.onStateChange = { aid, iid, _ in
      state.withLock { $0 = CallbackState(called: true, aid: aid, iid: iid) }
    }
    accessory.writeCharacteristic(iid: HAPAccessory.iidOn, value: .bool(true))
    let captured = state.withLock { $0 }
    #expect(captured.called)
    #expect(captured.aid == 2)
    #expect(captured.iid == HAPAccessory.iidOn)
  }

  @Test("toJSON has correct structure")
  func toJSONStructure() {
    let accessory = HAPAccessory(aid: 7, name: "Lamp")
    let json = accessory.toJSON()

    #expect(json["aid"] as? Int == 7)

    let services = json["services"] as! [[String: Any]]
    // Accessory Info + Protocol Info + Lightbulb = 3 services (no battery when batteryState is nil)
    #expect(services.count == 3)

    // Accessory Information service
    #expect(services[0]["type"] as? String == HKServiceUUID.accessoryInformation)
    let infoChars = services[0]["characteristics"] as! [[String: Any]]
    #expect(infoChars.count == 6)

    // Protocol Information service
    #expect(services[1]["type"] as? String == ProtocolInfoUUID.service)

    // Lightbulb service
    #expect(services[2]["type"] as? String == HKServiceUUID.lightbulb)
    let lightChars = services[2]["characteristics"] as! [[String: Any]]
    #expect(lightChars.count == 2)

    // On characteristic
    let onChar = lightChars[0]
    #expect(onChar["iid"] as? Int == HAPAccessory.iidOn)
    #expect(onChar["format"] as? String == "bool")

    // Brightness characteristic
    let brightChar = lightChars[1]
    #expect(brightChar["iid"] as? Int == HAPAccessory.iidBrightness)
    #expect(brightChar["format"] as? String == "int")
    #expect(brightChar["minValue"] as? Int == 0)
    #expect(brightChar["maxValue"] as? Int == 100)
    #expect(brightChar["unit"] as? String == "percentage")
  }
}

// MARK: - Accessory Information Service Tests

@Suite("Accessory Information Service JSON")
struct AccessoryInfoServiceTests {

  @Test("All accessory types produce identical info service structure")
  func identicalStructure() {
    let light = HAPAccessory(
      aid: 2, name: "L", model: "M", manufacturer: "MF",
      serialNumber: "SN", firmwareRevision: "1.0")
    let bridge = HAPBridgeInfo(
      name: "L", model: "M", manufacturer: "MF",
      serialNumber: "SN", firmwareRevision: "1.0")
    let motion = HAPMotionSensorAccessory(
      aid: 5, name: "L", model: "M", manufacturer: "MF",
      serialNumber: "SN", firmwareRevision: "1.0")

    let accessories: [any HAPAccessoryProtocol] = [light, bridge, motion]
    let jsons = accessories.map { $0.accessoryInformationServiceJSON() }

    // All should have same structure
    for json in jsons {
      #expect(json["iid"] as? Int == AccessoryInfoIID.service)
      #expect(json["type"] as? String == HKServiceUUID.accessoryInformation)
      let chars = json["characteristics"] as! [[String: Any]]
      #expect(chars.count == 6)
      #expect(chars[0]["iid"] as? Int == AccessoryInfoIID.identify)
      #expect(chars[1]["value"] as? String == "MF")
      #expect(chars[2]["value"] as? String == "M")
      #expect(chars[3]["value"] as? String == "L")
      #expect(chars[4]["value"] as? String == "SN")
      #expect(chars[5]["value"] as? String == "1.0")
    }
  }
}

// MARK: - Accessory IID Constants Tests (App-level)

@Suite("Accessory IID Constants (App)")
struct AccessoryIIDConstantsAppTests {

  @Test("Lightbulb IIDs match toJSON output")
  func lightbulbIIDs() {
    let light = HAPAccessory(aid: 2)
    let json = light.toJSON()
    let services = json["services"] as! [[String: Any]]
    let lightService = services[2]
    #expect(lightService["iid"] as? Int == HAPAccessory.iidLightbulbService)
    let chars = lightService["characteristics"] as! [[String: Any]]
    #expect(chars[0]["iid"] as? Int == HAPAccessory.iidOn)
    #expect(chars[1]["iid"] as? Int == HAPAccessory.iidBrightness)
  }

  @Test("Camera IIDs match toJSON output")
  func cameraIIDs() {
    let camera = HAPCameraAccessory(aid: 3)
    let json = camera.toJSON()
    let services = json["services"] as! [[String: Any]]

    let cameraService = services[2]
    #expect(
      cameraService["iid"] as? Int
        == HAPCameraAccessory.iidCameraService)
    let cameraChars =
      cameraService["characteristics"] as! [[String: Any]]
    #expect(
      cameraChars[0]["iid"] as? Int
        == HAPCameraAccessory.iidSupportedVideoConfig)
    #expect(
      cameraChars[5]["iid"] as? Int
        == HAPCameraAccessory.iidStreamingStatus)

    let micService = services[3]
    #expect(
      micService["iid"] as? Int
        == HAPCameraAccessory.iidMicrophoneService)

    let speakerService = services[4]
    #expect(
      speakerService["iid"] as? Int
        == HAPCameraAccessory.iidSpeakerService)
  }
}

// MARK: - Thread Safety Tests

@Suite("Thread Safety")
struct ThreadSafetyTests {

  @Test("EncryptionContext concurrent encrypt does not crash")
  func concurrentEncrypt() async {
    let key = SymmetricKey(size: .bits256)
    let ctx = EncryptionContext(readKey: key, writeKey: key)
    let plaintext = Data(repeating: 0x42, count: 100)

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask {
          _ = ctx.encrypt(plaintext: plaintext)
        }
      }
    }
  }

  @Test("EncryptionContext concurrent encrypt produces unique ciphertexts")
  func concurrentEncryptUnique() async {
    let key = SymmetricKey(size: .bits256)
    let ctx = EncryptionContext(readKey: key, writeKey: key)
    let plaintext = Data("same message".utf8)

    let results = await withTaskGroup(of: Data?.self, returning: [Data].self) { group in
      for _ in 0..<50 {
        group.addTask {
          ctx.encrypt(plaintext: plaintext)
        }
      }
      var collected: [Data] = []
      for await result in group {
        if let result { collected.append(result) }
      }
      return collected
    }

    // Each encryption uses a different nonce -> all ciphertexts must be unique
    #expect(results.count == 50)
    let uniqueCount = Set(results).count
    #expect(uniqueCount == results.count)
  }

  @Test("PairingStore concurrent add/get does not crash")
  func concurrentPairingStore() async {
    let store = PairingStore(testPairings: [:])

    await withTaskGroup(of: Void.self) { group in
      // Concurrent writers
      for i in 0..<50 {
        group.addTask {
          let pairing = PairingStore.Pairing(
            identifier: "controller-\(i)",
            publicKey: Data(repeating: UInt8(i), count: 32),
            isAdmin: i % 2 == 0
          )
          store.addPairing(pairing)
        }
      }
      // Concurrent readers
      for i in 0..<50 {
        group.addTask {
          _ = store.getPairing(identifier: "controller-\(i)")
          _ = store.isPaired
        }
      }
    }

    // All 50 pairings should be present
    #expect(store.pairings.count == 50)
    #expect(store.isPaired == true)
  }

  @Test("PairingStore concurrent remove does not crash")
  func concurrentPairingStoreRemove() async {
    let store = PairingStore(testPairings: [:])

    // Add pairings first
    for i in 0..<50 {
      store.addPairing(
        PairingStore.Pairing(
          identifier: "rm-\(i)",
          publicKey: Data(repeating: UInt8(i), count: 32),
          isAdmin: false
        ))
    }
    #expect(store.pairings.count == 50)

    // Concurrently remove them all
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<50 {
        group.addTask {
          store.removePairing(identifier: "rm-\(i)")
        }
      }
    }

    #expect(store.pairings.isEmpty)
    #expect(store.isPaired == false)
  }
}

// MARK: - Battery Service Tests

@Suite("Battery Service")
struct BatteryServiceTests {

  @Test("Lightbulb toJSON includes battery service when batteryState is set")
  func lightbulbWithBattery() {
    let light = HAPAccessory(aid: 2)
    let state = BatteryState()
    state.level = 75
    state.chargingState = 1
    state.statusLowBattery = 0
    light.batteryState = state

    let json = light.toJSON()
    let services = json["services"] as! [[String: Any]]
    // Accessory Info + Protocol Info + Lightbulb + Battery = 4 services
    #expect(services.count == 4)
    #expect(services[3]["type"] as? String == BatteryUUID.service)
    #expect(services[3]["iid"] as? Int == BatteryIID.service)

    let chars = services[3]["characteristics"] as! [[String: Any]]
    #expect(chars.count == 3)
    #expect(chars[0]["iid"] as? Int == BatteryIID.batteryLevel)
    #expect(chars[0]["value"] as? Int == 75)
    #expect(chars[1]["iid"] as? Int == BatteryIID.chargingState)
    #expect(chars[1]["value"] as? Int == 1)
    #expect(chars[2]["iid"] as? Int == BatteryIID.statusLowBattery)
    #expect(chars[2]["value"] as? Int == 0)
  }

  @Test("Lightbulb toJSON omits battery service when batteryState is nil")
  func lightbulbWithoutBattery() {
    let light = HAPAccessory(aid: 2)
    let json = light.toJSON()
    let services = json["services"] as! [[String: Any]]
    // Accessory Info + Protocol Info + Lightbulb = 3 services (no battery)
    #expect(services.count == 3)
  }

  @Test("Motion sensor toJSON includes battery service when batteryState is set")
  func motionSensorWithBattery() {
    let sensor = HAPMotionSensorAccessory(aid: 5)
    let state = BatteryState()
    state.level = 50
    state.chargingState = 0
    state.statusLowBattery = 0
    sensor.batteryState = state

    let json = sensor.toJSON()
    let services = json["services"] as! [[String: Any]]
    #expect(services.count == 4)
    #expect(services[3]["type"] as? String == BatteryUUID.service)
  }

  @Test("Motion sensor toJSON omits battery service when batteryState is nil")
  func motionSensorWithoutBattery() {
    let sensor = HAPMotionSensorAccessory(aid: 5)
    let json = sensor.toJSON()
    let services = json["services"] as! [[String: Any]]
    // Accessory Info + Protocol Info + Motion Sensor = 3 services (no battery)
    #expect(services.count == 3)
  }

  @Test("Camera toJSON includes battery service when batteryState is set")
  func cameraWithBattery() {
    let camera = HAPCameraAccessory(aid: 3)
    let state = BatteryState()
    state.level = 90
    state.chargingState = 1
    state.statusLowBattery = 0
    camera.batteryState = state

    let json = camera.toJSON()
    let services = json["services"] as! [[String: Any]]
    // Accessory Info + Protocol Info + Camera RTP + Microphone + Speaker + Battery = 6 services
    #expect(services.count == 6)
    #expect(services[5]["type"] as? String == BatteryUUID.service)
  }

  @Test("Camera toJSON omits battery service when batteryState is nil")
  func cameraWithoutBattery() {
    let camera = HAPCameraAccessory(aid: 3)
    let json = camera.toJSON()
    let services = json["services"] as! [[String: Any]]
    // Accessory Info + Protocol Info + Camera RTP + Microphone + Speaker = 5 services (no battery)
    #expect(services.count == 5)
  }

  @Test("readCharacteristic returns battery values when state is set")
  func readBatteryCharacteristics() {
    let light = HAPAccessory(aid: 2)
    let state = BatteryState()
    state.level = 42
    state.chargingState = 1
    state.statusLowBattery = 0
    light.batteryState = state

    #expect(light.readCharacteristic(iid: BatteryIID.batteryLevel) == .int(42))
    #expect(light.readCharacteristic(iid: BatteryIID.chargingState) == .int(1))
    #expect(light.readCharacteristic(iid: BatteryIID.statusLowBattery) == .int(0))
  }

  @Test("readCharacteristic returns nil for battery IIDs when state is nil")
  func readBatteryNilState() {
    let light = HAPAccessory(aid: 2)
    #expect(light.readCharacteristic(iid: BatteryIID.batteryLevel) == nil)
    #expect(light.readCharacteristic(iid: BatteryIID.chargingState) == nil)
    #expect(light.readCharacteristic(iid: BatteryIID.statusLowBattery) == nil)
  }

  @Test("Shared BatteryState reflects updates across all accessories")
  func sharedBatteryState() {
    let state = BatteryState()
    state.level = 80

    let light = HAPAccessory(aid: 2)
    let motion = HAPMotionSensorAccessory(aid: 5)
    light.batteryState = state
    motion.batteryState = state

    // Both read the same level
    #expect(light.readCharacteristic(iid: BatteryIID.batteryLevel) == .int(80))
    #expect(motion.readCharacteristic(iid: BatteryIID.batteryLevel) == .int(80))

    // Update the shared state
    state.level = 30
    state.statusLowBattery = 1

    // Both see the new values
    #expect(light.readCharacteristic(iid: BatteryIID.batteryLevel) == .int(30))
    #expect(motion.readCharacteristic(iid: BatteryIID.batteryLevel) == .int(30))
    #expect(light.readCharacteristic(iid: BatteryIID.statusLowBattery) == .int(1))
    #expect(motion.readCharacteristic(iid: BatteryIID.statusLowBattery) == .int(1))
  }

  @Test("Battery IIDs do not collide with existing accessory IIDs")
  func batteryIIDsNoCollision() {
    // Highest existing IID is 19 (camera speaker volume)
    #expect(BatteryIID.service == 100)
    #expect(BatteryIID.batteryLevel == 101)
    #expect(BatteryIID.chargingState == 102)
    #expect(BatteryIID.statusLowBattery == 103)
  }
}

// MARK: - HAP Setup URI Tests

@Suite("HAP Setup URI")
struct SetupURITests {

  @Test("Bit layout matches HAP spec \u{00A7}8.6.1")
  func bitLayout() {
    // Setup code "111-22-333" = 11122333, category = bridge (2), flags = 2 (IP)
    // Expected layout:
    //   bits  0-26: 11122333 (0xA9C29D)
    //   bits 27-30: category (2)
    //   bits 31-34: flags (2)
    let uri = hapSetupURI(setupCode: "111-22-333", category: 2, setupID: "T3ST")
    #expect(uri.hasPrefix("X-HM://"))

    // Extract base-36 payload (drop "X-HM://" prefix and 4-char setupID suffix)
    let body = String(uri.dropFirst(7))
    let encoded = String(body.prefix(9))
    let payload = UInt64(encoded, radix: 36)!

    // Verify bit fields
    let code = payload & 0x7FF_FFFF  // bits 0-26 (27 bits)
    let category = (payload >> 27) & 0xF  // bits 27-30 (4 bits)
    let flags = (payload >> 31) & 0xF  // bits 31-34 (4 bits)

    #expect(code == 11_122_333)
    #expect(category == 2)
    #expect(flags == 2)
  }

  @Test("Returns empty string for invalid setup code")
  func invalidCode() {
    let uri = hapSetupURI(setupCode: "not-a-number", setupID: "T3ST")
    #expect(uri.isEmpty)
  }

  @Test("Returns empty string for invalid setup ID")
  func invalidSetupID() {
    #expect(hapSetupURI(setupCode: "111-22-333", setupID: "").isEmpty)
    #expect(hapSetupURI(setupCode: "111-22-333", setupID: "AB").isEmpty)
    #expect(hapSetupURI(setupCode: "111-22-333", setupID: "ABCDE").isEmpty)
  }
}

// MARK: - Preview Factory Tests

@Suite("Preview Factory")
@MainActor
struct PreviewFactoryTests {

  @Test("Preview view model initializes without crash")
  func previewFactory() {
    let vm = HAPViewModel.preview(running: true)
    #expect(vm.setupCode == "123-45-678")
  }

  @Test("Preview view model generates QR URI without crash")
  func previewQRCode() {
    let vm = HAPViewModel.preview(running: true)
    let uri = hapSetupURI(setupCode: vm.setupCode, setupID: vm.setupID)
    #expect(vm.setupID.count == 4)
    #expect(uri.hasPrefix("X-HM://"))
  }
}

// MARK: - VideoMotionDetector Thread Safety Tests

@Suite("VideoMotionDetector Thread Safety")
struct VideoMotionDetectorThreadSafetyTests {

  @Test("Concurrent reset does not crash")
  func concurrentReset() async {
    let detector = VideoMotionDetector()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask { detector.reset() }
      }
    }
  }

  // MARK: - Cached Snapshot Freshness Tests

  @Test("cachedSnapshot(maxAgeSeconds:) returns snapshot within age limit")
  func cachedSnapshotFresh() {
    let camera = HAPCameraAccessory(aid: 3)
    let data = Data([0xFF, 0xD8, 0xFF, 0xD9])
    camera.cachedSnapshot = data
    #expect(camera.cachedSnapshot(maxAgeSeconds: 10) == data)
  }

  @Test("cachedSnapshot(maxAgeSeconds:) returns nil for zero maxAge")
  func cachedSnapshotExpired() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.cachedSnapshot = Data([0xFF, 0xD8, 0xFF, 0xD9])
    #expect(camera.cachedSnapshot(maxAgeSeconds: 0) == nil)
  }

  @Test("cachedSnapshot(maxAgeSeconds:) returns nil when no snapshot is cached")
  func cachedSnapshotNil() {
    let camera = HAPCameraAccessory(aid: 3)
    #expect(camera.cachedSnapshot(maxAgeSeconds: 10) == nil)
  }
}

// MARK: - Camera Write Characteristic Tests

@Suite("Camera Write Characteristics")
struct CameraWriteCharacteristicTests {

  @Test("Recording active triggers monitoring when no stream session exists")
  func recordingActiveStartsMonitoring() {
    let camera = HAPCameraAccessory(aid: 3)
    let monitoringNeeded = Locked<Bool?>(initialState: nil)
    camera.onMonitoringCaptureNeeded = { needed, _ in
      monitoringNeeded.withLock { $0 = needed }
    }
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidRecordingActive, value: .int(1))
    #expect(monitoringNeeded.withLock { $0 } == true)
  }

  @Test("Recording active does not trigger monitoring when stream session exists")
  func recordingActiveSkipsMonitoringWithStream() {
    let camera = HAPCameraAccessory(aid: 3)
    // Install a dummy stream session so hasActiveStreamSession returns true
    let dummySession = CameraStreamSession(
      sessionID: Data(repeating: 0, count: 16),
      controllerAddress: "127.0.0.1", controllerVideoPort: 5000, controllerAudioPort: 5001,
      videoSRTPKey: Data(repeating: 0, count: 16), videoSRTPSalt: Data(repeating: 0, count: 14),
      audioSRTPKey: Data(repeating: 0, count: 16), audioSRTPSalt: Data(repeating: 0, count: 14),
      localAddress: "127.0.0.1", localVideoPort: 6000, localAudioPort: 6001,
      videoSSRC: 1, audioSSRC: 2,
      ciContext: CIContext()
    )
    camera.streamSession = dummySession
    let monitoringCalled = Locked(initialState: false)
    camera.onMonitoringCaptureNeeded = { _, _ in
      monitoringCalled.withLock { $0 = true }
    }
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidRecordingActive, value: .int(1))
    #expect(monitoringCalled.withLock { $0 } == false)
  }

  @Test("Recording deactivate triggers monitoring stop")
  func recordingDeactivateStopsMonitoring() {
    let camera = HAPCameraAccessory(aid: 3)
    // First activate
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidRecordingActive, value: .int(1))
    let monitoringNeeded = Locked<Bool?>(initialState: nil)
    camera.onMonitoringCaptureNeeded = { needed, _ in
      monitoringNeeded.withLock { $0 = needed }
    }
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidRecordingActive, value: .int(0))
    #expect(monitoringNeeded.withLock { $0 } == false)
  }

  @Test("Recording active fires onStateChange")
  func recordingActiveFiresStateChange() {
    let camera = HAPCameraAccessory(aid: 3)
    let receivedValue = Locked<HAPValue?>(initialState: nil)
    camera.onStateChange = { _, _, value in
      receivedValue.withLock { $0 = value }
    }
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidRecordingActive, value: .int(1))
    #expect(receivedValue.withLock { $0 } == .int(1))
  }

  @Test("HomeKitCameraActive write updates state and fires callback")
  func homeKitCameraActiveWrite() {
    let camera = HAPCameraAccessory(aid: 3)
    struct Change: Sendable { let iid: Int; let value: HAPValue }
    let stateChanges = Locked<[Change]>(initialState: [])
    camera.onStateChange = { _, iid, value in
      stateChanges.withLock { $0.append(Change(iid: iid, value: value)) }
    }
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidHomeKitCameraActive, value: .bool(false))
    #expect(camera.homeKitCameraActive == false)
    // Should also mirror to motion sensor StatusActive
    let changes = stateChanges.withLock { $0 }
    #expect(changes.count == 2)
    #expect(changes[0].iid == HAPCameraAccessory.iidHomeKitCameraActive)
    #expect(changes[1].iid == HAPCameraAccessory.iidMotionSensorStatusActive)
  }

  @Test("Microphone mute write updates audio settings")
  func microphoneMuteWrite() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidMicrophoneMute, value: .bool(true))
    #expect(camera.readCharacteristic(iid: HAPCameraAccessory.iidMicrophoneMute) == .bool(true))
  }

  @Test("Speaker volume write clamps to 0-100")
  func speakerVolumeClamp() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidSpeakerVolume, value: .int(150))
    #expect(camera.readCharacteristic(iid: HAPCameraAccessory.iidSpeakerVolume) == .int(100))
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidSpeakerVolume, value: .int(-10))
    #expect(camera.readCharacteristic(iid: HAPCameraAccessory.iidSpeakerVolume) == .int(0))
  }

  @Test("Write to unknown iid returns false")
  func writeUnknownIID() {
    let camera = HAPCameraAccessory(aid: 3)
    #expect(camera.writeCharacteristic(iid: 999, value: .bool(true)) == false)
  }
}

// MARK: - Button Accessory Tests

@Suite("Button Accessory")
struct ButtonTests {

  private func makeButton() -> HAPButtonAccessory {
    HAPButtonAccessory(
      aid: AccessoryID.button, name: "Test Button", model: "Test",
      manufacturer: "Test", serialNumber: "SN-BTN", firmwareRevision: "1.0.0"
    )
  }

  @Test("ProgrammableSwitchEvent reads as null (event-only)")
  func eventReadNull() {
    let btn = makeButton()
    #expect(btn.readCharacteristic(iid: HAPButtonAccessory.iidProgrammableSwitchEvent) == .null)
  }

  @Test("ProgrammableSwitchEvent is not writable")
  func eventNotWritable() {
    let btn = makeButton()
    #expect(
      btn.writeCharacteristic(iid: HAPButtonAccessory.iidProgrammableSwitchEvent, value: .int(0))
        == false)
  }

  @Test("trigger fires onStateChange with single press event")
  func triggerFiresEvent() {
    let btn = makeButton()
    struct Event: Sendable { let aid: Int; let iid: Int; let value: HAPValue }
    let received = Locked<Event?>(initialState: nil)
    btn.onStateChange = { aid, iid, value in
      received.withLock { $0 = Event(aid: aid, iid: iid, value: value) }
    }
    btn.trigger()
    let event = received.withLock { $0 }
    #expect(event?.aid == AccessoryID.button)
    #expect(event?.iid == HAPButtonAccessory.iidProgrammableSwitchEvent)
    #expect(event?.value == .int(0))
  }

  @Test("toJSON includes programmable switch service with service label")
  func toJSONStructure() {
    let btn = makeButton()
    let json = btn.toJSON()
    let services = json["services"] as! [[String: Any]]

    // Stateless Programmable Switch service (0x89)
    let switchService = services.first { ($0["type"] as? String) == "89" }
    #expect(switchService != nil)
    #expect(switchService!["primary"] as? Bool == true)
    let chars = switchService!["characteristics"] as! [[String: Any]]
    let eventChar = chars.first { ($0["type"] as? String) == "73" }
    #expect(eventChar != nil)
    let perms = eventChar!["perms"] as! [String]
    #expect(perms.contains("pr"))
    #expect(perms.contains("ev"))
    #expect(!perms.contains("pw"))
    // Service Label Index
    let labelIndex = chars.first { ($0["type"] as? String) == "CB" }
    #expect(labelIndex != nil)
    #expect(labelIndex!["value"] as? Int == 1)

    // Service Label service (0xCC)
    let labelService = services.first { ($0["type"] as? String) == "CC" }
    #expect(labelService != nil)
  }
}

// MARK: - RTCP Sender Report Tests

@Suite("RTCP Sender Report")
struct RTCPSenderReportTests {

  @Test("Report is 28 bytes with correct header")
  func headerFormat() {
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0x1234_5678, rtpTimestamp: 0,
      packetsSent: 0, octetsSent: 0)
    #expect(sr.count == 28)
    #expect(sr[0] == 0x80)  // V=2, P=0, RC=0
    #expect(sr[1] == 200)  // PT = Sender Report
    #expect(sr[2] == 0x00)  // Length MSB
    #expect(sr[3] == 0x06)  // Length = 6
  }

  @Test("SSRC is encoded big-endian at bytes 4-7")
  func ssrcEncoding() {
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0xDEAD_BEEF, rtpTimestamp: 0,
      packetsSent: 0, octetsSent: 0)
    #expect(sr[4] == 0xDE)
    #expect(sr[5] == 0xAD)
    #expect(sr[6] == 0xBE)
    #expect(sr[7] == 0xEF)
  }

  @Test("RTP timestamp is encoded big-endian at bytes 16-19")
  func rtpTimestampEncoding() {
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0, rtpTimestamp: 0x00AB_CDEF,
      packetsSent: 0, octetsSent: 0)
    #expect(sr[16] == 0x00)
    #expect(sr[17] == 0xAB)
    #expect(sr[18] == 0xCD)
    #expect(sr[19] == 0xEF)
  }

  @Test("Packet and octet counts at bytes 20-27")
  func countsEncoding() {
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0, rtpTimestamp: 0,
      packetsSent: 256, octetsSent: 65536)
    // packetsSent = 256 = 0x00000100
    #expect(sr[20] == 0x00)
    #expect(sr[21] == 0x00)
    #expect(sr[22] == 0x01)
    #expect(sr[23] == 0x00)
    // octetsSent = 65536 = 0x00010000
    #expect(sr[24] == 0x00)
    #expect(sr[25] == 0x01)
    #expect(sr[26] == 0x00)
    #expect(sr[27] == 0x00)
  }

  @Test("NTP timestamp is non-zero for a known date")
  func ntpTimestamp() {
    // 2024-01-01 00:00:00 UTC
    let date = Date(timeIntervalSince1970: 1_704_067_200)
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0, rtpTimestamp: 0,
      packetsSent: 0, octetsSent: 0, now: date)
    // NTP seconds at bytes 8-11 should be non-zero
    let ntpSec =
      UInt32(sr[8]) << 24 | UInt32(sr[9]) << 16
      | UInt32(sr[10]) << 8 | UInt32(sr[11])
    // 1704067200 + 2208988800 = 3913056000
    #expect(ntpSec == 3_913_056_000)
  }
}

// MARK: - Audio Resampling Tests

@Suite("Audio Resampling")
struct AudioResamplingTests {

  @Test("Resample 44.1kHz mono to 16kHz")
  func resample44100to16000() {
    // 1024 frames of 16-bit mono at 44.1kHz
    let frameCount = 1024
    let samples = (0..<frameCount).map { i in Int16(sin(Double(i) / 10.0) * 10000) }
    let data = samples.withUnsafeBytes { Data($0) }
    let asbd = AudioStreamBasicDescription(
      mSampleRate: 44100,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2,
      mFramesPerPacket: 1,
      mBytesPerFrame: 2,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0
    )
    let result = convertToFloat32At16kHz(data, sourceASBD: asbd)
    let outputFrames = result.count / MemoryLayout<Float>.size
    #expect(outputFrames > 0)
    #expect(outputFrames < frameCount)
  }

  @Test("Resample 48kHz stereo to 16kHz")
  func resample48000stereoTo16000() {
    // 960 frames of 16-bit stereo at 48kHz
    let frameCount = 960
    let sampleCount = frameCount * 2
    let samples = (0..<sampleCount).map { _ in Int16.random(in: -1000...1000) }
    let data = samples.withUnsafeBytes { Data($0) }
    let asbd = AudioStreamBasicDescription(
      mSampleRate: 48000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 16,
      mReserved: 0
    )
    let result = convertToFloat32At16kHz(data, sourceASBD: asbd)
    let outputFrames = result.count / MemoryLayout<Float>.size
    #expect(outputFrames > 0)
    #expect(outputFrames < frameCount)
  }

  @Test("16kHz mono input passes through without resampling")
  func noResampleNeeded() {
    let frameCount = 480
    let floats = (0..<frameCount).map { Float($0) / Float(frameCount) }
    let data = floats.withUnsafeBytes { Data($0) }
    let asbd = AudioStreamBasicDescription(
      mSampleRate: 16000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 32,
      mReserved: 0
    )
    let result = convertToFloat32At16kHz(data, sourceASBD: asbd)
    #expect(result.count == data.count)
  }

  @Test("Empty input returns empty output")
  func emptyInput() {
    let asbd = AudioStreamBasicDescription(
      mSampleRate: 44100,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2,
      mFramesPerPacket: 1,
      mBytesPerFrame: 2,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0
    )
    let result = convertToFloat32At16kHz(Data(), sourceASBD: asbd)
    #expect(result.isEmpty)
  }

  @Test("Zero bytesPerFrame returns empty output")
  func zeroBytesPerFrame() {
    let asbd = AudioStreamBasicDescription(
      mSampleRate: 44100,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 0,
      mFramesPerPacket: 1,
      mBytesPerFrame: 0,
      mChannelsPerFrame: 1,
      mBitsPerChannel: 16,
      mReserved: 0
    )
    let result = convertToFloat32At16kHz(Data([0x00, 0x01]), sourceASBD: asbd)
    #expect(result.isEmpty)
  }

  @Test("Float32 stereo downmixes to mono")
  func float32StereoDownmix() {
    // 100 frames of Float32 stereo: left=1.0, right=-1.0 → mono should be 0.0
    let frameCount = 100
    var data = Data()
    for _ in 0..<frameCount {
      var left: Float = 1.0
      var right: Float = -1.0
      withUnsafeBytes(of: &left) { data.append(contentsOf: $0) }
      withUnsafeBytes(of: &right) { data.append(contentsOf: $0) }
    }
    let asbd = AudioStreamBasicDescription(
      mSampleRate: 16000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 8,
      mFramesPerPacket: 1,
      mBytesPerFrame: 8,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0
    )
    let result = convertToFloat32At16kHz(data, sourceASBD: asbd)
    let outputFrames = result.count / MemoryLayout<Float>.size
    #expect(outputFrames == frameCount)
    result.withUnsafeBytes { buf in
      for i in 0..<outputFrames {
        let value = buf.load(fromByteOffset: i * MemoryLayout<Float>.size, as: Float.self)
        #expect(abs(value) < 0.001)
      }
    }
  }
}

// MARK: - AccessoryConfig Tests

@Suite("AccessoryConfig")
@MainActor
struct AccessoryConfigTests {

  private func makeConfig(
    flashlight: Bool = false, camera: String? = nil,
    motion: Bool = false, microphone: Bool = false,
    contact: Bool = false, lightSensor: Bool = false,
    occupancy: Bool = false,
    siren: Bool = false, button: Bool = false
  ) -> AccessoryConfig {
    AccessoryConfig(
      flashlightEnabled: flashlight, selectedCameraID: camera,
      motionEnabled: motion, microphoneEnabled: microphone,
      contactEnabled: contact, lightSensorEnabled: lightSensor,
      occupancyEnabled: occupancy,
      sirenEnabled: siren, buttonEnabled: button
    )
  }

  @Test("Identical configs are equal")
  func identicalEqual() {
    let a = makeConfig(flashlight: true, motion: true, siren: true)
    let b = makeConfig(flashlight: true, motion: true, siren: true)
    #expect(a == b)
  }

  @Test("Different flashlight setting is not equal")
  func flashlightDiffers() {
    let a = makeConfig(flashlight: true)
    let b = makeConfig(flashlight: false)
    #expect(a != b)
  }

  @Test("Different camera ID is not equal")
  func cameraDiffers() {
    let a = makeConfig(camera: "cam-1")
    let b = makeConfig(camera: "cam-2")
    #expect(a != b)
  }

  @Test("Nil vs non-nil camera is not equal")
  func cameraNilVsNonNil() {
    let a = makeConfig(camera: nil)
    let b = makeConfig(camera: "cam-1")
    #expect(a != b)
  }

  @Test("Toggle and toggle back produces equal config")
  func toggleRoundTrip() {
    let original = makeConfig(motion: true, contact: true)
    var modified = original
    modified.motionEnabled = false
    modified.motionEnabled = true
    #expect(original == modified)
  }

  @Test("Each field independently affects equality")
  func eachFieldMatters() {
    let base = makeConfig()
    #expect(base != makeConfig(flashlight: true))
    #expect(base != makeConfig(motion: true))
    #expect(base != makeConfig(microphone: true))
    #expect(base != makeConfig(contact: true))
    #expect(base != makeConfig(lightSensor: true))
    #expect(base != makeConfig(occupancy: true))
    #expect(base != makeConfig(siren: true))
    #expect(base != makeConfig(button: true))
  }
}

// MARK: - HAPViewModel Tests

@Suite("HAPViewModel")
@MainActor
struct HAPViewModelTests {

  @Test("needsRestart is false when startedConfig is nil")
  func needsRestartNilConfig() {
    let vm = HAPViewModel(skipRestore: true)
    #expect(vm.needsRestart == false)
  }

  @Test("needsRestart is false when config matches")
  func needsRestartMatches() {
    let vm = HAPViewModel(skipRestore: true)
    vm.withRestoring {
      vm.flashlightEnabled = true
      vm.motionEnabled = false
    }
    vm.startedConfig = AccessoryConfig(from: vm)
    #expect(vm.needsRestart == false)
  }

  @Test("needsRestart is true when flashlight changes")
  func needsRestartFlashlightChanged() {
    let vm = HAPViewModel(skipRestore: true)
    vm.withRestoring {
      vm.flashlightEnabled = false
    }
    vm.startedConfig = AccessoryConfig(from: vm)
    vm.withRestoring { vm.flashlightEnabled = true }
    #expect(vm.needsRestart == true)
  }

  @Test("needsRestart is true when camera selection changes")
  func needsRestartCameraChanged() {
    let vm = HAPViewModel(skipRestore: true)
    vm.withRestoring {
      vm.selectedStreamCamera = nil
      vm.availableCameras = [
        CameraOption(id: "cam-1", name: "Back", fNumber: 1.8)
      ]
    }
    vm.startedConfig = AccessoryConfig(from: vm)
    vm.withRestoring {
      vm.selectedStreamCamera = CameraOption(id: "cam-1", name: "Back", fNumber: 1.8)
    }
    #expect(vm.needsRestart == true)
  }

  @Test("restoreConfig reverts to saved state")
  func restoreConfigReverts() {
    let vm = HAPViewModel(skipRestore: true)
    vm.withRestoring {
      vm.flashlightEnabled = true
      vm.motionEnabled = false
      vm.sirenEnabled = true
    }
    let saved = AccessoryConfig(from: vm)
    // Change settings
    vm.withRestoring {
      vm.flashlightEnabled = false
      vm.motionEnabled = true
      vm.sirenEnabled = false
    }
    // Restore
    vm.restoreConfig(saved)
    #expect(vm.flashlightEnabled == true)
    #expect(vm.motionEnabled == false)
    #expect(vm.sirenEnabled == true)
  }

  @Test("withRestoring suppresses didSet side effects")
  func withRestoringSuppress() {
    let vm = HAPViewModel(skipRestore: true)
    // Set a known value first
    vm.flashlightEnabled = false
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: "flashlightEnabled")
    // withRestoring should NOT write to UserDefaults
    vm.withRestoring {
      vm.flashlightEnabled = true
    }
    // The key should not have been written (isRestoring suppressed didSet)
    #expect(defaults.object(forKey: "flashlightEnabled") == nil)
  }

  @Test("resetPairings clears hasPairings state")
  func resetPairingsClears() {
    let vm = HAPViewModel(skipRestore: true)
    vm.withRestoring { vm.hasPairings = true }
    vm.resetPairings()
    #expect(vm.hasPairings == false)
  }
}

// MARK: - Setup URI Edge Case Tests

@Suite("HAP Setup URI Edge Cases")
struct SetupURIEdgeCaseTests {

  @Test("Setup code with leading zeros")
  func leadingZeros() {
    let uri = hapSetupURI(setupCode: "000-00-001", setupID: "T3ST")
    #expect(!uri.isEmpty)

    let body = String(uri.dropFirst(7))
    let encoded = String(body.prefix(9))
    let payload = UInt64(encoded, radix: 36)!
    let code = payload & 0x7FF_FFFF
    #expect(code == 1)
  }

  @Test("Maximum valid setup code")
  func maxCode() {
    let uri = hapSetupURI(setupCode: "999-99-999", setupID: "T3ST")
    #expect(!uri.isEmpty)

    let body = String(uri.dropFirst(7))
    let encoded = String(body.prefix(9))
    let payload = UInt64(encoded, radix: 36)!
    let code = payload & 0x7FF_FFFF
    #expect(code == 99_999_999)
  }

  @Test("Non-bridge category encodes correctly")
  func nonBridgeCategory() {
    // Category 17 = IP Camera
    let uri = hapSetupURI(setupCode: "111-22-333", category: 17, setupID: "T3ST")
    #expect(!uri.isEmpty)

    let body = String(uri.dropFirst(7))
    let encoded = String(body.prefix(9))
    let payload = UInt64(encoded, radix: 36)!
    let category = (payload >> 27) & 0xF
    #expect(category == 17 & 0xF)
  }

  @Test("Setup ID is appended as suffix")
  func setupIDSuffix() {
    let uri = hapSetupURI(setupCode: "111-22-333", setupID: "ABCD")
    #expect(uri.hasSuffix("ABCD"))
  }
}

// MARK: - TLV8 Config Builder Tests

@Suite("TLV8 Config Builders")
struct TLV8ConfigBuilderTests {

  @Test("Supported video config produces valid TLV8")
  func supportedVideoConfig() {
    let builder = HAPCameraAccessory.supportedVideoConfig()
    let data = builder.build()
    #expect(!data.isEmpty)
    let tlvs = TLV8.decode(data) as [(UInt8, Data)]
    // Should have a video codec configuration (tag 0x01)
    let codecConfig = tlvs.first { $0.0 == 0x01 }
    #expect(codecConfig != nil)
    // Decode the codec config
    let sub = TLV8.decode(codecConfig!.1) as [(UInt8, Data)]
    // Tag 0x01 = codec type (H.264 = 0x00)
    let codecType = sub.first { $0.0 == 0x01 }
    #expect(codecType != nil)
    #expect(codecType!.1 == Data([0x00]))
    // Should have resolution attributes (tag 0x03) — TLV8 coalesces consecutive
    // same-tag entries, so multiple resolutions may appear as one coalesced blob
    let resolutions = sub.filter { $0.0 == 0x03 }
    #expect(!resolutions.isEmpty)
  }

  @Test("Supported audio config produces valid TLV8")
  func supportedAudioConfig() {
    let builder = HAPCameraAccessory.supportedAudioConfig()
    let data = builder.build()
    #expect(!data.isEmpty)
    let tlvs = TLV8.decode(data) as [(UInt8, Data)]
    // Tag 0x01 = audio codec config
    let codecConfig = tlvs.first { $0.0 == 0x01 }
    #expect(codecConfig != nil)
    let sub = TLV8.decode(codecConfig!.1) as [(UInt8, Data)]
    // Tag 0x01 = codec type (AAC-ELD = 2)
    let codecType = sub.first { $0.0 == 0x01 }
    #expect(codecType != nil)
    #expect(codecType!.1 == Data([2]))
    // Tag 0x02 = comfort noise support (No = 0)
    let comfortNoise = tlvs.first { $0.0 == 0x02 }
    #expect(comfortNoise != nil)
    #expect(comfortNoise!.1 == Data([0x00]))
  }

  @Test("Supported RTP config specifies SRTP AES_CM_128")
  func supportedRTPConfig() {
    let builder = HAPCameraAccessory.supportedRTPConfig()
    let data = builder.build()
    #expect(!data.isEmpty)
    let tlvs = TLV8.decode(data) as [(UInt8, Data)]
    // Tag 0x02 = SRTP crypto suite (AES_CM_128_HMAC_SHA1_80 = 0x00)
    let crypto = tlvs.first { $0.0 == 0x02 }
    #expect(crypto != nil)
    #expect(crypto!.1 == Data([0x00]))
  }

  @Test("Supported data stream config specifies TCP")
  func supportedDataStreamConfig() {
    let camera = HAPCameraAccessory(aid: 3)
    let builder = camera.supportedDataStreamConfig()
    let data = builder.build()
    let tlvs = TLV8.decode(data) as [(UInt8, Data)]
    // Tag 0x01 = transfer transport config
    let transport = tlvs.first { $0.0 == 0x01 }
    #expect(transport != nil)
    let sub = TLV8.decode(transport!.1) as [(UInt8, Data)]
    // Tag 0x01 = transport type (TCP = 0x00)
    let transportType = sub.first { $0.0 == 0x01 }
    #expect(transportType != nil)
    #expect(transportType!.1 == Data([0x00]))
  }
}

// MARK: - Camera Bool/Int Coercion Tests

@Suite("Camera Bool/Int Coercion")
struct CameraCoercionTests {

  @Test("HomeKitCameraActive accepts int 0 and 1")
  func homeKitCameraActiveInt() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidHomeKitCameraActive, value: .int(0))
    #expect(camera.homeKitCameraActive == false)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidHomeKitCameraActive, value: .int(1))
    #expect(camera.homeKitCameraActive == true)
  }

  @Test("EventSnapshotsActive accepts both bool and int")
  func eventSnapshotsActiveCoercion() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidEventSnapshotsActive, value: .bool(false))
    #expect(camera.eventSnapshotsActive == false)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidEventSnapshotsActive, value: .int(1))
    #expect(camera.eventSnapshotsActive == true)
  }

  @Test("PeriodicSnapshotsActive accepts both bool and int")
  func periodicSnapshotsActiveCoercion() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.writeCharacteristic(
      iid: HAPCameraAccessory.iidPeriodicSnapshotsActive, value: .int(0))
    #expect(camera.periodicSnapshotsActive == false)
    camera.writeCharacteristic(
      iid: HAPCameraAccessory.iidPeriodicSnapshotsActive, value: .bool(true))
    #expect(camera.periodicSnapshotsActive == true)
  }

  @Test("RecordingActive clamps out-of-range int values")
  func recordingActiveClamping() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidRecordingActive, value: .int(999))
    #expect(camera.recordingActive == 255)  // UInt8(clamping: 999)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidRecordingActive, value: .int(-1))
    #expect(camera.recordingActive == 0)  // UInt8(clamping: -1)
  }

  @Test("RecordingAudioActive clamps out-of-range values")
  func recordingAudioActiveClamping() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidRecordingAudioActive, value: .int(500))
    #expect(camera.recordingAudioActive == 255)
  }

  @Test("RTPStreamActive clamps out-of-range values")
  func rtpStreamActiveClamping() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidRTPStreamActive, value: .int(300))
    #expect(camera.rtpStreamActive == 255)
  }

  @Test("MicrophoneMute accepts int coercion")
  func microphoneMuteIntCoercion() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidMicrophoneMute, value: .int(1))
    #expect(camera.readCharacteristic(iid: HAPCameraAccessory.iidMicrophoneMute) == .bool(true))
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidMicrophoneMute, value: .int(0))
    #expect(camera.readCharacteristic(iid: HAPCameraAccessory.iidMicrophoneMute) == .bool(false))
  }

  @Test("SpeakerMute accepts int coercion")
  func speakerMuteIntCoercion() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidSpeakerMute, value: .int(1))
    #expect(camera.readCharacteristic(iid: HAPCameraAccessory.iidSpeakerMute) == .bool(true))
  }

  @Test("Write with invalid type returns false")
  func invalidTypeRejected() {
    let camera = HAPCameraAccessory(aid: 3)
    #expect(
      camera.writeCharacteristic(
        iid: HAPCameraAccessory.iidHomeKitCameraActive, value: .string("yes")) == false)
    #expect(
      camera.writeCharacteristic(
        iid: HAPCameraAccessory.iidRecordingActive, value: .string("1")) == false)
    #expect(
      camera.writeCharacteristic(
        iid: HAPCameraAccessory.iidMicrophoneMute, value: .string("mute")) == false)
    #expect(
      camera.writeCharacteristic(
        iid: HAPCameraAccessory.iidSpeakerVolume, value: .string("50")) == false)
  }

  @Test("RecordingActive accepts bool coercion from HomeKit hub")
  func recordingActiveBoolCoercion() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidRecordingActive, value: .bool(true))
    #expect(camera.recordingActive == 1)
    camera.writeCharacteristic(iid: HAPCameraAccessory.iidRecordingActive, value: .bool(false))
    #expect(camera.recordingActive == 0)
  }
}

// MARK: - Camera Thread Safety Tests

@Suite("Camera Thread Safety")
struct CameraThreadSafetyTests {

  @Test("Concurrent read/write characteristics does not crash")
  func concurrentReadWrite() async {
    let camera = HAPCameraAccessory(aid: 3)

    await withTaskGroup(of: Void.self) { group in
      // Concurrent writers
      for i in 0..<50 {
        group.addTask {
          camera.writeCharacteristic(
            iid: HAPCameraAccessory.iidSpeakerVolume, value: .int(i % 100))
        }
      }
      // Concurrent readers
      for _ in 0..<50 {
        group.addTask {
          _ = camera.readCharacteristic(iid: HAPCameraAccessory.iidSpeakerVolume)
          _ = camera.readCharacteristic(iid: HAPCameraAccessory.iidMicrophoneMute)
          _ = camera.readCharacteristic(iid: HAPCameraAccessory.iidStreamingStatus)
        }
      }
    }
  }

  @Test("Concurrent detachStreamSession is safe")
  func concurrentDetach() async {
    let camera = HAPCameraAccessory(aid: 3)

    // Only one caller should get a non-nil session
    let session = CameraStreamSession(
      sessionID: Data(repeating: 0, count: 16),
      controllerAddress: "127.0.0.1", controllerVideoPort: 5000, controllerAudioPort: 5001,
      videoSRTPKey: Data(repeating: 0, count: 16), videoSRTPSalt: Data(repeating: 0, count: 14),
      audioSRTPKey: Data(repeating: 0, count: 16), audioSRTPSalt: Data(repeating: 0, count: 14),
      localAddress: "127.0.0.1", localVideoPort: 6000, localAudioPort: 6001,
      videoSSRC: 1, audioSSRC: 2,
      ciContext: CIContext()
    )
    camera.streamSession = session

    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for _ in 0..<10 {
        group.addTask {
          camera.detachStreamSession() != nil
        }
      }
      var collected: [Bool] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }

    // Exactly one caller should have gotten the session
    let gotSession = results.filter { $0 }.count
    #expect(gotSession == 1)
  }

  @Test("Concurrent HKSV state access does not crash")
  func concurrentHKSVState() async {
    let camera = HAPCameraAccessory(aid: 3)

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask {
          camera.writeCharacteristic(
            iid: HAPCameraAccessory.iidRecordingActive, value: .int(1))
        }
        group.addTask {
          _ = camera.recordingActive
          _ = camera.homeKitCameraActive
          _ = camera.eventSnapshotsActive
        }
      }
    }
  }
}
