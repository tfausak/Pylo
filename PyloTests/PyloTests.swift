import CryptoKit
import Foundation
import HAP
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
    #expect(accessory.readCharacteristic(iid: 3) == .string("Test Maker"))
    #expect(accessory.readCharacteristic(iid: 4) == .string("Test Model"))
    #expect(accessory.readCharacteristic(iid: 5) == .string("Test Light"))
    #expect(accessory.readCharacteristic(iid: 6) == .string("SN-123"))
    #expect(accessory.readCharacteristic(iid: 7) == .string("2.0.0"))
  }

  @Test("Read lightbulb state characteristics")
  func readLightbulbState() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.readCharacteristic(iid: 9) == .bool(false))
    #expect(accessory.readCharacteristic(iid: 10) == .int(100))
  }

  @Test("Read unknown iid returns nil")
  func readUnknownIID() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.readCharacteristic(iid: 99) == nil)
  }

  @Test("Write on/off as bool")
  func writeOnBool() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 9, value: .bool(true)))
    #expect(accessory.isOn == true)
    #expect(accessory.writeCharacteristic(iid: 9, value: .bool(false)))
    #expect(accessory.isOn == false)
  }

  @Test("Write on/off coerces int to bool")
  func writeOnInt() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 9, value: .int(1)))
    #expect(accessory.isOn == true)
    #expect(accessory.writeCharacteristic(iid: 9, value: .int(0)))
    #expect(accessory.isOn == false)
  }

  @Test("Write on/off rejects invalid type")
  func writeOnInvalidType() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 9, value: .string("yes")) == false)
  }

  @Test("Write brightness clamps to 0-100")
  func writeBrightnessClamped() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 10, value: .int(50)))
    #expect(accessory.brightness == 50)

    #expect(accessory.writeCharacteristic(iid: 10, value: .int(150)))
    #expect(accessory.brightness == 100)

    #expect(accessory.writeCharacteristic(iid: 10, value: .int(-10)))
    #expect(accessory.brightness == 0)
  }

  @Test("Write brightness rejects non-int")
  func writeBrightnessInvalidType() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 10, value: .string("50")) == false)
  }

  @Test("Write to unknown iid returns false")
  func writeUnknownIID() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 99, value: .bool(true)) == false)
  }

  @Test("Write identify (iid 2) succeeds")
  func writeIdentify() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 2, value: .bool(true)))
  }

  @Test("State change callback fires on write")
  func stateChangeCallback() {
    let accessory = HAPAccessory(aid: 2)
    nonisolated(unsafe) var callbackCalled = false
    nonisolated(unsafe) var receivedAid = 0
    nonisolated(unsafe) var receivedIid = 0
    accessory.onStateChange = { aid, iid, _ in
      callbackCalled = true
      receivedAid = aid
      receivedIid = iid
    }
    accessory.writeCharacteristic(iid: 9, value: .bool(true))
    #expect(callbackCalled)
    #expect(receivedAid == 2)
    #expect(receivedIid == 9)
  }

  @Test("toJSON has correct structure")
  func toJSONStructure() {
    let accessory = HAPAccessory(aid: 7, name: "Lamp")
    let json = accessory.toJSON()

    #expect(json["aid"] as? Int == 7)

    let services = json["services"] as! [[String: Any]]
    // Accessory Info + Lightbulb + Battery = 3 services
    #expect(services.count == 3)

    // Accessory Information service
    #expect(services[0]["type"] as? String == "3E")
    let infoChars = services[0]["characteristics"] as! [[String: Any]]
    #expect(infoChars.count == 6)

    // Lightbulb service
    #expect(services[1]["type"] as? String == "43")
    let lightChars = services[1]["characteristics"] as! [[String: Any]]
    #expect(lightChars.count == 2)

    // On characteristic
    let onChar = lightChars[0]
    #expect(onChar["iid"] as? Int == 9)
    #expect(onChar["format"] as? String == "bool")

    // Brightness characteristic
    let brightChar = lightChars[1]
    #expect(brightChar["iid"] as? Int == 10)
    #expect(brightChar["format"] as? String == "int")
    #expect(brightChar["minValue"] as? Int == 0)
    #expect(brightChar["maxValue"] as? Int == 100)
    #expect(brightChar["unit"] as? String == "percentage")

    // Battery service (always included for stable c# hashing)
    #expect(services[2]["type"] as? String == BatteryUUID.service)
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
      #expect(json["iid"] as? Int == 1)
      #expect(json["type"] as? String == "3E")
      let chars = json["characteristics"] as! [[String: Any]]
      #expect(chars.count == 6)
      #expect(chars[0]["iid"] as? Int == 2)
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
    let lightService = services[1]
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

    let cameraService = services[1]
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

    let micService = services[2]
    #expect(
      micService["iid"] as? Int
        == HAPCameraAccessory.iidMicrophoneService)

    let speakerService = services[3]
    #expect(
      speakerService["iid"] as? Int
        == HAPCameraAccessory.iidSpeakerService)
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
    // Accessory Info + Lightbulb + Battery = 3 services
    #expect(services.count == 3)
    #expect(services[2]["type"] as? String == BatteryUUID.service)
    #expect(services[2]["iid"] as? Int == BatteryIID.service)

    let chars = services[2]["characteristics"] as! [[String: Any]]
    #expect(chars.count == 3)
    #expect(chars[0]["iid"] as? Int == BatteryIID.batteryLevel)
    #expect(chars[0]["value"] as? Int == 75)
    #expect(chars[1]["iid"] as? Int == BatteryIID.chargingState)
    #expect(chars[1]["value"] as? Int == 1)
    #expect(chars[2]["iid"] as? Int == BatteryIID.statusLowBattery)
    #expect(chars[2]["value"] as? Int == 0)
  }

  @Test("Lightbulb toJSON always includes battery service")
  func lightbulbWithoutBattery() {
    let light = HAPAccessory(aid: 2)
    let json = light.toJSON()
    let services = json["services"] as! [[String: Any]]
    // Accessory Info + Lightbulb + Battery = 3 services (battery always present for stable c#)
    #expect(services.count == 3)
    #expect(services[2]["type"] as? String == BatteryUUID.service)
    // Verify default values when batteryState is nil
    let chars = services[2]["characteristics"] as! [[String: Any]]
    #expect(chars[0]["value"] as? Int == 0)  // level defaults to 0
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
    #expect(services.count == 3)
    #expect(services[2]["type"] as? String == BatteryUUID.service)
  }

  @Test("Motion sensor toJSON always includes battery service")
  func motionSensorWithoutBattery() {
    let sensor = HAPMotionSensorAccessory(aid: 5)
    let json = sensor.toJSON()
    let services = json["services"] as! [[String: Any]]
    // Accessory Info + Motion Sensor + Battery = 3 services
    #expect(services.count == 3)
    #expect(services[2]["type"] as? String == BatteryUUID.service)
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
    // Accessory Info + Camera RTP + Microphone + Speaker + Battery = 5 services
    #expect(services.count == 5)
    #expect(services[4]["type"] as? String == BatteryUUID.service)
  }

  @Test("Camera toJSON always includes battery service")
  func cameraWithoutBattery() {
    let camera = HAPCameraAccessory(aid: 3)
    let json = camera.toJSON()
    let services = json["services"] as! [[String: Any]]
    // Accessory Info + Camera RTP + Microphone + Speaker + Battery = 5 services
    #expect(services.count == 5)
    #expect(services[4]["type"] as? String == BatteryUUID.service)
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

  @Test("cachedSnapshot(maxAge:) returns snapshot within age limit")
  func cachedSnapshotFresh() {
    let camera = HAPCameraAccessory(aid: 3)
    let data = Data([0xFF, 0xD8, 0xFF, 0xD9])
    camera.cachedSnapshot = data
    #expect(camera.cachedSnapshot(maxAge: .seconds(10)) == data)
  }

  @Test("cachedSnapshot(maxAge:) returns nil for zero maxAge")
  func cachedSnapshotExpired() {
    let camera = HAPCameraAccessory(aid: 3)
    camera.cachedSnapshot = Data([0xFF, 0xD8, 0xFF, 0xD9])
    #expect(camera.cachedSnapshot(maxAge: .zero) == nil)
  }

  @Test("cachedSnapshot(maxAge:) returns nil when no snapshot is cached")
  func cachedSnapshotNil() {
    let camera = HAPCameraAccessory(aid: 3)
    #expect(camera.cachedSnapshot(maxAge: .seconds(10)) == nil)
  }
}
