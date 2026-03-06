import CommonCrypto
import CryptoKit
import Foundation
import Testing

@testable import HAP

// MARK: - Connection Buffer Limit Tests

@Suite("Connection Buffer Limits")
struct ConnectionBufferLimitTests {

  @Test("Max buffer size is 1 MB")
  func maxBufferSize() {
    #expect(HAPConnection.maxBufferSize == 1_048_576)
  }
}

// MARK: - HTTP Request Parser Tests

@Suite("HTTP Request Parser")
struct HTTPRequestTests {

  @Test("Parse simple GET request")
  func parseGet() {
    let raw = "GET /accessories HTTP/1.1\r\nHost: 10.0.0.1\r\n\r\n"
    let request = HTTPRequest.parse(Data(raw.utf8))
    #expect(request != nil)
    #expect(request?.method == "GET")
    #expect(request?.path == "/accessories")
    #expect(request?.headers["host"] == "10.0.0.1")
    #expect(request?.body == nil)
  }

  @Test("Parse GET with query string")
  func parseGetWithQuery() {
    let raw = "GET /characteristics?id=2.9,2.10 HTTP/1.1\r\nHost: local\r\n\r\n"
    let request = HTTPRequest.parse(Data(raw.utf8))
    #expect(request?.path == "/characteristics?id=2.9,2.10")
  }

  @Test("Parse PUT with JSON body")
  func parsePutWithBody() {
    let body = """
      {"characteristics":[{"aid":2,"iid":9,"value":true}]}
      """
    let raw =
      "PUT /characteristics HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    let request = HTTPRequest.parse(Data(raw.utf8))
    #expect(request?.method == "PUT")
    #expect(request?.path == "/characteristics")
    #expect(request?.headers["content-type"] == "application/json")
    #expect(request?.body != nil)
    #expect(request?.body?.count == body.utf8.count)
  }

  @Test("Parse POST with binary body")
  func parsePostWithBinaryBody() {
    let bodyBytes: [UInt8] = [0x06, 0x01, 0x01]
    var rawData = Data(
      "POST /pair-setup HTTP/1.1\r\nContent-Type: application/pairing+tlv8\r\nContent-Length: 3\r\n\r\n"
        .utf8)
    rawData.append(contentsOf: bodyBytes)
    let request = HTTPRequest.parse(rawData)
    #expect(request?.method == "POST")
    #expect(request?.body == Data(bodyBytes))
  }

  @Test("Headers are lowercased")
  func headersLowercased() {
    let raw = "GET / HTTP/1.1\r\nContent-Type: text/plain\r\nX-Custom-Header: foobar\r\n\r\n"
    let request = HTTPRequest.parse(Data(raw.utf8))
    #expect(request?.headers["content-type"] == "text/plain")
    #expect(request?.headers["x-custom-header"] == "foobar")
  }

  @Test("Returns nil for incomplete data (no header terminator)")
  func incompleteReturnsNil() {
    let raw = "GET /accessories HTTP/1.1\r\nHost: local\r\n"
    let request = HTTPRequest.parse(Data(raw.utf8))
    #expect(request == nil)
  }

  @Test("Returns nil for empty data")
  func emptyReturnsNil() {
    let request = HTTPRequest.parse(Data())
    #expect(request == nil)
  }

  @Test("parseAndConsume extracts request and removes from buffer")
  func parseAndConsume() {
    let raw = "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: y\r\n\r\n"
    var buffer = Data(raw.utf8)

    if case .request(let first) = HTTPRequest.parseAndConsume(&buffer) {
      #expect(first.path == "/a")
    } else {
      Issue.record("Expected .request for first parse")
    }
    #expect(!buffer.isEmpty)

    if case .request(let second) = HTTPRequest.parseAndConsume(&buffer) {
      #expect(second.path == "/b")
    } else {
      Issue.record("Expected .request for second parse")
    }
    #expect(buffer.isEmpty)
  }

  @Test("parseAndConsume returns needsMoreData when body incomplete")
  func parseAndConsumeIncompleteBody() {
    let raw = "POST /data HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort"
    var buffer = Data(raw.utf8)
    if case .needsMoreData = HTTPRequest.parseAndConsume(&buffer) {
      // Buffer should be preserved since request is incomplete
      #expect(!buffer.isEmpty)
    } else {
      Issue.record("Expected .needsMoreData for incomplete body")
    }
  }

  @Test("parseAndConsume handles zero content-length")
  func parseAndConsumeNoBody() {
    let raw = "GET /test HTTP/1.1\r\n\r\n"
    var buffer = Data(raw.utf8)
    if case .request(let request) = HTTPRequest.parseAndConsume(&buffer) {
      #expect(request.method == "GET")
      #expect(request.body == nil)
      #expect(buffer.isEmpty)
    } else {
      Issue.record("Expected .request for no-body parse")
    }
  }

  @Test("parseAndConsume returns malformed for oversized content-length")
  func rejectsOversizedContentLength() {
    let raw = "POST /pair-setup HTTP/1.1\r\nContent-Length: 100000\r\n\r\n"
    var buffer = Data(raw.utf8)
    if case .malformed = HTTPRequest.parseAndConsume(&buffer) {
      #expect(buffer.isEmpty)  // buffer cleared on rejection
    } else {
      Issue.record("Expected .malformed for oversized content-length")
    }
  }

  @Test("parseAndConsume returns malformed for invalid UTF-8 headers")
  func rejectsInvalidUTF8Headers() {
    // Construct a request with invalid UTF-8 in the header area
    var buffer = Data([0x47, 0x45, 0x54, 0x20])  // "GET "
    buffer.append(Data([0xFF, 0xFE]))  // Invalid UTF-8
    buffer.append(Data(" HTTP/1.1\r\n\r\n".utf8))
    if case .malformed = HTTPRequest.parseAndConsume(&buffer) {
      #expect(buffer.isEmpty)
    } else {
      Issue.record("Expected .malformed for invalid UTF-8 headers")
    }
  }

  @Test("parseAndConsume returns malformed for negative content-length")
  func rejectsNegativeContentLength() {
    let raw = "POST /pair-setup HTTP/1.1\r\nContent-Length: -1\r\n\r\n"
    var buffer = Data(raw.utf8)
    if case .malformed = HTTPRequest.parseAndConsume(&buffer) {
      #expect(buffer.isEmpty)
    } else {
      Issue.record("Expected .malformed for negative content-length")
    }
  }

  @Test("parseAndConsume returns malformed for duplicate differing Content-Length")
  func rejectsDuplicateContentLength() {
    let raw =
      "POST /pair-setup HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 10\r\n\r\nhello"
    var buffer = Data(raw.utf8)
    if case .malformed = HTTPRequest.parseAndConsume(&buffer) {
      #expect(buffer.isEmpty)
    } else {
      Issue.record("Expected .malformed for duplicate differing Content-Length")
    }
  }

  @Test("parseAndConsume rejects obsolete line folding (RFC 7230 \u{00A7}3.2.4)")
  func rejectsLineFolding() {
    let raw =
      "POST /pair-setup HTTP/1.1\r\nContent-Length:\r\n 5\r\n\r\nhello"
    var buffer = Data(raw.utf8)
    if case .malformed = HTTPRequest.parseAndConsume(&buffer) {
      #expect(buffer.isEmpty)
    } else {
      Issue.record("Expected .malformed for obsolete line folding")
    }
  }

  @Test("parseAndConsume rejects tab-folded header lines")
  func rejectsTabFolding() {
    let raw =
      "GET /accessories HTTP/1.1\r\nHost: example\r\n\tfolded-value\r\n\r\n"
    var buffer = Data(raw.utf8)
    if case .malformed = HTTPRequest.parseAndConsume(&buffer) {
      #expect(buffer.isEmpty)
    } else {
      Issue.record("Expected .malformed for tab-folded header")
    }
  }

  @Test("parseAndConsume accepts duplicate identical Content-Length")
  func acceptsIdenticalContentLength() {
    let raw =
      "POST /pair-setup HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello"
    var buffer = Data(raw.utf8)
    if case .request(let req) = HTTPRequest.parseAndConsume(&buffer) {
      #expect(req.body == Data("hello".utf8))
    } else {
      Issue.record("Expected .request for duplicate identical Content-Length")
    }
  }

  @Test("parse works correctly with Data slices (non-zero startIndex)")
  func parseDataSlice() {
    let prefix = Data(repeating: 0xAA, count: 10)
    let raw = Data("GET /test HTTP/1.1\r\nHost: local\r\n\r\n".utf8)
    var combined = prefix
    combined.append(raw)
    // Create a slice with non-zero startIndex
    let slice = combined[10...]
    let request = HTTPRequest.parse(slice)
    #expect(request != nil)
    #expect(request?.method == "GET")
    #expect(request?.path == "/test")
  }
}

// MARK: - HTTP Response Tests

@Suite("HTTP Response Serializer")
struct HTTPResponseTests {

  @Test("Status text mapping")
  func statusTexts() {
    #expect(HTTPResponse(status: 200, body: nil, contentType: "").statusText == "OK")
    #expect(HTTPResponse(status: 204, body: nil, contentType: "").statusText == "No Content")
    #expect(HTTPResponse(status: 207, body: nil, contentType: "").statusText == "Multi-Status")
    #expect(HTTPResponse(status: 400, body: nil, contentType: "").statusText == "Bad Request")
    #expect(HTTPResponse(status: 404, body: nil, contentType: "").statusText == "Not Found")
    #expect(
      HTTPResponse(status: 422, body: nil, contentType: "").statusText == "Unprocessable Entity")
    #expect(
      HTTPResponse(status: 470, body: nil, contentType: "").statusText
        == "Connection Authorization Required")
    #expect(
      HTTPResponse(status: 500, body: nil, contentType: "").statusText == "Internal Server Error")
    #expect(HTTPResponse(status: 999, body: nil, contentType: "").statusText == "Unknown")
  }

  @Test("Serialize response without body")
  func serializeNoBody() {
    let response = HTTPResponse(status: 204, body: nil, contentType: "application/hap+json")
    let serialized = String(data: response.serialize(), encoding: .utf8)!
    #expect(serialized.contains("HTTP/1.1 204 No Content\r\n"))
    #expect(serialized.contains("Content-Type: application/hap+json\r\n"))
    #expect(serialized.contains("Content-Length: 0\r\n"))
  }

  @Test("Serialize response with body includes correct content-length")
  func serializeWithBody() {
    let body = Data("{\"status\":0}".utf8)
    let response = HTTPResponse(status: 200, body: body, contentType: "application/hap+json")
    let serialized = response.serialize()

    let headerEnd = serialized.range(of: Data("\r\n\r\n".utf8))!
    let responseBody = serialized[headerEnd.upperBound...]

    #expect(responseBody == body)

    let headerStr = String(data: serialized[..<headerEnd.lowerBound], encoding: .utf8)!
    #expect(headerStr.contains("Content-Length: \(body.count)"))
  }

  @Test("Serialized response is parseable as HTTP request")
  func serializeRoundtrip() {
    let body = Data("hello".utf8)
    let response = HTTPResponse(status: 200, body: body, contentType: "text/plain")
    let serialized = response.serialize()

    // Verify basic structure: starts with HTTP/1.1, has headers, then body
    let str = String(data: serialized, encoding: .utf8)!
    #expect(str.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(str.hasSuffix("hello"))
  }
}

// MARK: - HAPValue Tests

@Suite("HAPValue Type-safe Values")
struct HAPValueTests {

  @Test("fromJSON converts bool correctly")
  func fromJSONBool() throws {
    let jsonTrue =
      try JSONSerialization.jsonObject(
        with: Data("{\"v\":true}".utf8)) as! [String: Any]
    let jsonFalse =
      try JSONSerialization.jsonObject(
        with: Data("{\"v\":false}".utf8)) as! [String: Any]
    #expect(HAPValue(fromJSON: jsonTrue["v"]!) == .bool(true))
    #expect(HAPValue(fromJSON: jsonFalse["v"]!) == .bool(false))
  }

  @Test("fromJSON converts int correctly")
  func fromJSONInt() {
    let json =
      try! JSONSerialization.jsonObject(
        with: Data("{\"v\":42}".utf8)) as! [String: Any]
    #expect(HAPValue(fromJSON: json["v"]!) == .int(42))
  }

  @Test("fromJSON converts string correctly")
  func fromJSONString() {
    let json =
      try! JSONSerialization.jsonObject(
        with: Data("{\"v\":\"hello\"}".utf8)) as! [String: Any]
    #expect(HAPValue(fromJSON: json["v"]!) == .string("hello"))
  }

  @Test("fromJSON converts float correctly")
  func fromJSONFloat() {
    let json =
      try! JSONSerialization.jsonObject(
        with: Data("{\"v\":3.14}".utf8)) as! [String: Any]
    let value = HAPValue(fromJSON: json["v"]!)
    #expect(value == .float(Float(3.14)))
  }

  @Test("fromJSON distinguishes bool from int")
  func fromJSONBoolVsInt() {
    let json =
      try! JSONSerialization.jsonObject(
        with: Data("{\"b\":true,\"i\":1}".utf8)) as! [String: Any]
    #expect(HAPValue(fromJSON: json["b"]!) == .bool(true))
    #expect(HAPValue(fromJSON: json["i"]!) == .int(1))
  }

  @Test("fromJSON distinguishes float from int")
  func fromJSONFloatVsInt() {
    let json =
      try! JSONSerialization.jsonObject(
        with: Data("{\"f\":1.5,\"i\":1}".utf8)) as! [String: Any]
    #expect(HAPValue(fromJSON: json["f"]!) == .float(1.5))
    #expect(HAPValue(fromJSON: json["i"]!) == .int(1))
  }

  @Test("jsonValue round-trips through JSONSerialization")
  func jsonValueRoundTrip() {
    let values: [HAPValue] = [.bool(true), .int(42), .float(3.14), .string("test")]
    for value in values {
      let dict: [String: Any] = ["v": value.jsonValue]
      let data = try! JSONSerialization.data(withJSONObject: dict)
      #expect(data.count > 0)
    }
  }
}

// MARK: - Accessory Information Service Tests

@Suite("Accessory Information Service JSON")
struct AccessoryInfoServiceTests {

  @Test("Bridge and motion sensor produce identical info service structure")
  func identicalStructure() {
    let bridge = HAPBridgeInfo(
      name: "L", model: "M", manufacturer: "MF",
      serialNumber: "SN", firmwareRevision: "1.0")
    let motion = HAPMotionSensorAccessory(
      aid: 5, name: "L", model: "M", manufacturer: "MF",
      serialNumber: "SN", firmwareRevision: "1.0")

    let accessories: [any HAPAccessoryProtocol] = [bridge, motion]
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

// MARK: - Accessory IID Constants Tests

@Suite("Accessory IID Constants")
struct AccessoryIIDConstantsTests {

  @Test("Motion sensor IIDs match toJSON output")
  func motionSensorIIDs() {
    let motion = HAPMotionSensorAccessory(aid: 5)
    let json = motion.toJSON()
    let services = json["services"] as! [[String: Any]]
    let sensorService = services[2]
    #expect(
      sensorService["iid"] as? Int
        == HAPMotionSensorAccessory.iidMotionSensorService)
    let chars = sensorService["characteristics"] as! [[String: Any]]
    #expect(
      chars[0]["iid"] as? Int
        == HAPMotionSensorAccessory.iidMotionDetected)
  }

  @Test("AccessoryInfoIID constants match shared JSON")
  func accessoryInfoIIDs() {
    let bridge = HAPBridgeInfo()
    let json = bridge.accessoryInformationServiceJSON()
    #expect(json["iid"] as? Int == AccessoryInfoIID.service)
    let chars = json["characteristics"] as! [[String: Any]]
    #expect(chars[0]["iid"] as? Int == AccessoryInfoIID.identify)
    #expect(
      chars[1]["iid"] as? Int == AccessoryInfoIID.manufacturer)
    #expect(chars[2]["iid"] as? Int == AccessoryInfoIID.model)
    #expect(chars[3]["iid"] as? Int == AccessoryInfoIID.name)
    #expect(
      chars[4]["iid"] as? Int == AccessoryInfoIID.serialNumber)
    #expect(
      chars[5]["iid"] as? Int
        == AccessoryInfoIID.firmwareRevision)
  }
}

// MARK: - HAP Bridge Info Tests

@Suite("HAP Bridge Info")
struct HAPBridgeInfoTests {

  @Test("Bridge always has aid 1")
  func bridgeAid() {
    let bridge = HAPBridgeInfo()
    #expect(bridge.aid == 1)
  }

  @Test("Read bridge characteristics")
  func readCharacteristics() {
    let bridge = HAPBridgeInfo(
      name: "My Bridge",
      model: "Test",
      manufacturer: "Acme",
      serialNumber: "BR-001",
      firmwareRevision: "1.0"
    )
    #expect(bridge.readCharacteristic(iid: 3) == .string("Acme"))
    #expect(bridge.readCharacteristic(iid: 4) == .string("Test"))
    #expect(bridge.readCharacteristic(iid: 5) == .string("My Bridge"))
    #expect(bridge.readCharacteristic(iid: 6) == .string("BR-001"))
    #expect(bridge.readCharacteristic(iid: 7) == .string("1.0"))
  }

  @Test("Bridge identify write succeeds")
  func identifyWrite() {
    let bridge = HAPBridgeInfo()
    #expect(bridge.writeCharacteristic(iid: 2, value: .bool(true)))
  }

  @Test("Bridge rejects writes to non-identify characteristics")
  func rejectNonIdentifyWrite() {
    let bridge = HAPBridgeInfo()
    #expect(bridge.writeCharacteristic(iid: 3, value: .string("foo")) == false)
    #expect(bridge.writeCharacteristic(iid: 99, value: .bool(true)) == false)
  }

  @Test("Bridge toJSON has accessory info and protocol info services")
  func toJSONServices() {
    let bridge = HAPBridgeInfo()
    let json = bridge.toJSON()
    let services = json["services"] as! [[String: Any]]
    #expect(services.count == 2)
    #expect(services[0]["type"] as? String == "3E")  // Accessory Information
    #expect(services[1]["type"] as? String == "A2")  // Protocol Information
  }
}

// MARK: - HAP Motion Sensor Tests

@Suite("HAP Motion Sensor Accessory")
struct HAPMotionSensorTests {

  @Test("Initial state is no motion")
  func initialState() {
    let sensor = HAPMotionSensorAccessory(aid: 5)
    #expect(sensor.isMotionDetected == false)
  }

  @Test("Update motion detected")
  func updateMotion() {
    let sensor = HAPMotionSensorAccessory(aid: 5)
    sensor.updateMotionDetected(true)
    #expect(sensor.isMotionDetected == true)
    #expect(sensor.readCharacteristic(iid: 9) == .bool(true))

    sensor.updateMotionDetected(false)
    #expect(sensor.isMotionDetected == false)
  }

  @Test("Update fires state change callback")
  func updateCallback() {
    let sensor = HAPMotionSensorAccessory(aid: 5)
    nonisolated(unsafe) var receivedValue: HAPValue?
    sensor.onStateChange = { _, iid, value in
      if iid == 9 { receivedValue = value }
    }
    sensor.updateMotionDetected(true)
    #expect(receivedValue == .bool(true))
  }

  @Test("toJSON has motion sensor and battery services")
  func toJSONService() {
    let sensor = HAPMotionSensorAccessory(aid: 5)
    let json = sensor.toJSON()
    let services = json["services"] as! [[String: Any]]
    #expect(services.count == 4)  // accessory info + protocol info + motion sensor + battery
    #expect(services[1]["type"] as? String == "A2")  // protocol info
    #expect(services[2]["type"] as? String == "85")  // motion sensor
    let chars = services[2]["characteristics"] as! [[String: Any]]
    #expect(chars[0]["format"] as? String == "bool")
    #expect(services[3]["type"] as? String == BatteryUUID.service)  // battery
  }
}

// MARK: - Encryption Context Tests

@Suite("Encryption Context")
struct EncryptionContextTests {

  @Test("Encrypt-decrypt roundtrip")
  func encryptDecryptRoundtrip() throws {
    let key = SymmetricKey(size: .bits256)
    let ctx = EncryptionContext(readKey: key, writeKey: key)

    let plaintext = Data("Hello, HomeKit!".utf8)
    let encrypted = try #require(ctx.encrypt(plaintext: plaintext))

    // Encrypted format: [2-byte length][ciphertext][16-byte tag]
    #expect(encrypted.count == 2 + plaintext.count + 16)

    let lengthBytes = encrypted.prefix(2)
    let cipherAndTag = encrypted.dropFirst(2)
    let decrypted = ctx.decrypt(lengthBytes: Data(lengthBytes), ciphertext: Data(cipherAndTag))

    #expect(decrypted == plaintext)
  }

  @Test("Encrypt-decrypt large message splits into frames")
  func largeMessageFrames() throws {
    let writeKey = SymmetricKey(size: .bits256)
    let readKey = SymmetricKey(size: .bits256)
    let encryptor = EncryptionContext(readKey: readKey, writeKey: writeKey)
    let decryptor = EncryptionContext(readKey: writeKey, writeKey: readKey)

    let plaintext = Data(repeating: 0x42, count: 2500)
    let encrypted = try #require(encryptor.encrypt(plaintext: plaintext))

    // 2500 bytes = 1024 + 1024 + 452 = 3 frames
    // Each frame: 2 + chunk + 16
    let expectedSize = (2 + 1024 + 16) + (2 + 1024 + 16) + (2 + 452 + 16)
    #expect(encrypted.count == expectedSize)

    // Decrypt each frame
    var decrypted = Data()
    var offset = encrypted.startIndex
    while offset < encrypted.endIndex {
      let lengthBytes = encrypted[offset..<offset + 2]
      let length = Int(lengthBytes[offset]) | (Int(lengthBytes[offset + 1]) << 8)
      offset += 2
      let cipherAndTag = encrypted[offset..<offset + length + 16]
      offset += length + 16
      guard
        let frame = decryptor.decrypt(
          lengthBytes: Data(lengthBytes), ciphertext: Data(cipherAndTag))
      else {
        Issue.record("Failed to decrypt frame")
        return
      }
      decrypted.append(frame)
    }
    #expect(decrypted == plaintext)
  }

  @Test("Decrypt with wrong key fails")
  func decryptWrongKey() throws {
    let key1 = SymmetricKey(size: .bits256)
    let key2 = SymmetricKey(size: .bits256)
    let encryptor = EncryptionContext(readKey: key1, writeKey: key1)
    let decryptor = EncryptionContext(readKey: key2, writeKey: key2)

    let encrypted = try #require(encryptor.encrypt(plaintext: Data("secret".utf8)))
    let lengthBytes = encrypted.prefix(2)
    let cipherAndTag = encrypted.dropFirst(2)
    let decrypted = decryptor.decrypt(
      lengthBytes: Data(lengthBytes), ciphertext: Data(cipherAndTag))
    #expect(decrypted == nil)
  }

  @Test("Decrypt too-short ciphertext returns nil")
  func decryptTooShort() {
    let key = SymmetricKey(size: .bits256)
    let ctx = EncryptionContext(readKey: key, writeKey: key)
    let result = ctx.decrypt(
      lengthBytes: Data([0x05, 0x00]), ciphertext: Data(repeating: 0, count: 10))
    #expect(result == nil)
  }

  @Test("Nonce increments prevent replay")
  func nonceIncrements() throws {
    let key = SymmetricKey(size: .bits256)
    let encryptor = EncryptionContext(readKey: key, writeKey: key)

    let msg1 = try #require(encryptor.encrypt(plaintext: Data("msg1".utf8)))
    let msg2 = try #require(encryptor.encrypt(plaintext: Data("msg1".utf8)))

    // Same plaintext, different nonces -> different ciphertext
    #expect(msg1 != msg2)
  }

  @Test("Failed decrypt advances counter per HAP spec")
  func failedDecryptAdvancesCounter() throws {
    let readKey = SymmetricKey(size: .bits256)
    let writeKey = SymmetricKey(size: .bits256)

    let encryptor = EncryptionContext(readKey: readKey, writeKey: writeKey)
    let decryptor = EncryptionContext(readKey: writeKey, writeKey: readKey)

    // Encrypt two messages (nonces 0 and 1)
    let frame1 = try #require(encryptor.encrypt(plaintext: Data("hello".utf8)))
    let frame2 = try #require(encryptor.encrypt(plaintext: Data("world".utf8)))

    // Feed garbage -- fails but advances the read counter to 1
    let garbage = Data(repeating: 0xAA, count: 32)
    let garbageLen = Data([UInt8(16), 0x00])
    let badResult = decryptor.decrypt(lengthBytes: garbageLen, ciphertext: garbage)
    #expect(badResult == nil)

    // frame1 was encrypted with nonce 0 but the decryptor is now at nonce 1,
    // so it must fail (nonce mismatch).
    let len1 = frame1[0..<2]
    let ct1 = frame1[2...]
    let result1 = decryptor.decrypt(lengthBytes: len1, ciphertext: ct1)
    #expect(result1 == nil)

    // frame2 was encrypted with nonce 1, decryptor is now at nonce 2 -- also fails.
    // The connection is irrecoverably desynced after a corrupted frame, which is
    // the correct behavior: the caller should close the connection.
    let len2 = frame2[0..<2]
    let ct2 = frame2[2...]
    let result2 = decryptor.decrypt(lengthBytes: len2, ciphertext: ct2)
    #expect(result2 == nil)
  }
}

// MARK: - HKDF Convenience Tests

@Suite("HKDF Key Derivation")
struct HKDFTests {

  @Test("Derives key of requested length")
  func derivesCorrectLength() {
    let key = HKDF<SHA512>.deriveKey(
      inputKeyMaterial: Data(repeating: 0x0B, count: 32),
      salt: Data("salt".utf8),
      info: Data("info".utf8),
      outputByteCount: 64
    )
    #expect(key.count == 64)
  }

  @Test("Default output is 32 bytes")
  func defaultLength() {
    let key = HKDF<SHA512>.deriveKey(
      inputKeyMaterial: Data(repeating: 0x0B, count: 32),
      salt: Data("salt".utf8),
      info: Data("info".utf8)
    )
    #expect(key.count == 32)
  }

  @Test("Same inputs produce same output (deterministic)")
  func deterministic() {
    let ikm = Data(repeating: 0x42, count: 32)
    let salt = Data("hap-salt".utf8)
    let info = Data("hap-info".utf8)

    let key1 = HKDF<SHA512>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info)
    let key2 = HKDF<SHA512>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info)
    #expect(key1 == key2)
  }

  @Test("Different inputs produce different output")
  func differentInputs() {
    let salt = Data("salt".utf8)
    let info = Data("info".utf8)

    let key1 = HKDF<SHA512>.deriveKey(
      inputKeyMaterial: Data(repeating: 0x01, count: 32), salt: salt, info: info)
    let key2 = HKDF<SHA512>.deriveKey(
      inputKeyMaterial: Data(repeating: 0x02, count: 32), salt: salt, info: info)
    #expect(key1 != key2)
  }
}

// MARK: - PairingStore Tests

@Suite("Pairing Store")
struct PairingStoreTests {

  @Test("New store is not paired")
  func newStoreEmpty() {
    let store = PairingStore(testPairings: [:])
    #expect(store.isPaired == false)
  }

  @Test("Add and retrieve pairing")
  func addAndGet() {
    let store = PairingStore(testPairings: [:])

    let pairing = PairingStore.Pairing(
      identifier: "test-controller",
      publicKey: Data(repeating: 0xAA, count: 32),
      isAdmin: true
    )
    store.addPairing(pairing)

    #expect(store.isPaired == true)
    let retrieved = store.getPairing(identifier: "test-controller")
    #expect(retrieved != nil)
    #expect(retrieved?.publicKey == Data(repeating: 0xAA, count: 32))
    #expect(retrieved?.isAdmin == true)
  }

  @Test("Remove pairing")
  func removePairing() {
    let store = PairingStore(testPairings: [:])

    let pairing = PairingStore.Pairing(
      identifier: "to-remove",
      publicKey: Data(repeating: 0xBB, count: 32),
      isAdmin: false
    )
    store.addPairing(pairing)
    #expect(store.isPaired == true)

    store.removePairing(identifier: "to-remove")
    #expect(store.getPairing(identifier: "to-remove") == nil)
    #expect(store.isPaired == false)
  }

  @Test("Get nonexistent pairing returns nil")
  func getNonexistent() {
    let store = PairingStore(testPairings: [:])
    #expect(store.getPairing(identifier: "does-not-exist") == nil)
  }

  @Test("onChange callback fires on add and remove")
  func onChangeCallback() {
    let store = PairingStore(testPairings: [:])

    nonisolated(unsafe) var callCount = 0
    store.onChange = { callCount += 1 }

    let pairing = PairingStore.Pairing(
      identifier: "cb-test",
      publicKey: Data(repeating: 0xCC, count: 32),
      isAdmin: true
    )
    store.addPairing(pairing)
    #expect(callCount == 1)

    store.removePairing(identifier: "cb-test")
    #expect(callCount == 2)

    store.removeAll()
    #expect(callCount == 3)
  }

  @Test("Pairing is Codable")
  func pairingCodable() throws {
    let original = PairingStore.Pairing(
      identifier: "codable-test",
      publicKey: Data([0x01, 0x02, 0x03]),
      isAdmin: true
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PairingStore.Pairing.self, from: encoded)
    #expect(decoded.identifier == original.identifier)
    #expect(decoded.publicKey == original.publicKey)
    #expect(decoded.isAdmin == original.isAdmin)
  }

  @Test("Non-32-byte public key is rejected by CryptoKit")
  func invalidPublicKeyRejectedByCryptoKit() {
    // Validates why PairingsHandler.handleAdd must check publicKey.count == 32:
    // a stored key with the wrong length permanently breaks pair-verify for that identifier.
    let shortKey = Data(repeating: 0xAA, count: 16)
    #expect(throws: CryptoKitError.self) {
      _ = try Curve25519.Signing.PublicKey(rawRepresentation: shortKey)
    }
    let longKey = Data(repeating: 0xBB, count: 64)
    #expect(throws: CryptoKitError.self) {
      _ = try Curve25519.Signing.PublicKey(rawRepresentation: longKey)
    }
    // 32 bytes is accepted
    let validKey = Data(repeating: 0xCC, count: 32)
    #expect(throws: Never.self) {
      _ = try Curve25519.Signing.PublicKey(rawRepresentation: validKey)
    }
  }

  @Test("Pairing identifier is normalized to uppercase on storage")
  func identifierNormalized() {
    let store = PairingStore(testPairings: [:])
    let pairing = PairingStore.Pairing(
      identifier: "abc-def-123",
      publicKey: Data(repeating: 0xAA, count: 32),
      isAdmin: true
    )
    store.addPairing(pairing)
    let retrieved = store.getPairing(identifier: "ABC-DEF-123")
    #expect(retrieved != nil)
    // The stored identifier itself should be normalized
    #expect(retrieved?.identifier == "ABC-DEF-123")
  }

  @Test("removePairing for nonexistent identifier does not fire onChange")
  func removeNonexistentNoCallback() {
    let store = PairingStore(testPairings: [:])
    nonisolated(unsafe) var callCount = 0
    store.onChange = { callCount += 1 }

    store.removePairing(identifier: "does-not-exist")
    #expect(callCount == 0)
  }

  @Test("addPairingIfUnpaired normalizes identifier")
  func addIfUnpairedNormalizesID() {
    let store = PairingStore(testPairings: [:])
    let pairing = PairingStore.Pairing(
      identifier: "lower-case-id",
      publicKey: Data(repeating: 0xBB, count: 32),
      isAdmin: true
    )
    store.addPairingIfUnpaired(pairing)
    let retrieved = store.getPairing(identifier: "LOWER-CASE-ID")
    #expect(retrieved?.identifier == "LOWER-CASE-ID")
  }

  @Test("addPairingIfUnpaired succeeds when store is empty")
  func addIfUnpairedSucceeds() {
    let store = PairingStore(testPairings: [:])
    let pairing = PairingStore.Pairing(
      identifier: "first",
      publicKey: Data(repeating: 0xAA, count: 32),
      isAdmin: true
    )
    #expect(store.addPairingIfUnpaired(pairing) == true)
    #expect(store.isPaired == true)
    #expect(store.getPairing(identifier: "first") != nil)
  }

  @Test("removeAll clears all pairings")
  func removeAllClearsPairings() {
    let store = PairingStore(testPairings: [:])
    store.addPairing(
      PairingStore.Pairing(
        identifier: "a", publicKey: Data(repeating: 0xAA, count: 32), isAdmin: true))
    store.addPairing(
      PairingStore.Pairing(
        identifier: "b", publicKey: Data(repeating: 0xBB, count: 32), isAdmin: false))
    #expect(store.isPaired == true)
    store.removeAll()
    // Test store save always succeeds (no-op), so pairings should be cleared
    #expect(store.isPaired == false)
    #expect(store.getPairing(identifier: "a") == nil)
    #expect(store.getPairing(identifier: "b") == nil)
  }

  @Test("addPairingIfUnpaired fails when store already has a pairing")
  func addIfUnpairedRejectsSecond() {
    let store = PairingStore(testPairings: [:])
    let first = PairingStore.Pairing(
      identifier: "first",
      publicKey: Data(repeating: 0xAA, count: 32),
      isAdmin: true
    )
    store.addPairing(first)

    let second = PairingStore.Pairing(
      identifier: "second",
      publicKey: Data(repeating: 0xBB, count: 32),
      isAdmin: true
    )
    #expect(store.addPairingIfUnpaired(second) == false)
    #expect(store.getPairing(identifier: "second") == nil)
    // First pairing is untouched
    #expect(store.getPairing(identifier: "first")?.publicKey == Data(repeating: 0xAA, count: 32))
  }
}

// MARK: - Setup Hash Tests

@Suite("Setup Hash")
struct SetupHashTests {

  @Test("Deterministic -- same input produces same output")
  func deterministic() {
    let h1 = PairSetupHandler.setupHash(setupID: "ABCD", deviceID: "AA:BB:CC:DD:EE:FF")
    let h2 = PairSetupHandler.setupHash(setupID: "ABCD", deviceID: "AA:BB:CC:DD:EE:FF")
    #expect(h1 == h2)
  }

  @Test("Output is valid base64 that decodes to exactly 4 bytes")
  func validBase64FourBytes() {
    let hash = PairSetupHandler.setupHash(setupID: "ABCD", deviceID: "11:22:33:44:55:66")
    let decoded = Data(base64Encoded: hash)
    #expect(decoded != nil)
    #expect(decoded?.count == 4)
  }

  @Test("Different deviceIDs produce different hashes")
  func differentDeviceIDs() {
    let h1 = PairSetupHandler.setupHash(setupID: "ABCD", deviceID: "AA:BB:CC:DD:EE:F1")
    let h2 = PairSetupHandler.setupHash(setupID: "ABCD", deviceID: "AA:BB:CC:DD:EE:F2")
    #expect(h1 != h2)
  }

  @Test("Different setupIDs produce different hashes")
  func differentSetupIDs() {
    let h1 = PairSetupHandler.setupHash(setupID: "AAAA", deviceID: "11:22:33:44:55:66")
    let h2 = PairSetupHandler.setupHash(setupID: "BBBB", deviceID: "11:22:33:44:55:66")
    #expect(h1 != h2)
  }

  @Test("Matches manual SHA512 computation")
  func matchesManualSHA512() {
    let setupID = "T3ST"
    let deviceID = "DE:AD:BE:EF:00:01"
    let input = Data((setupID + deviceID).utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
    input.withUnsafeBytes { ptr in
      _ = CC_SHA512(ptr.baseAddress, CC_LONG(input.count), &digest)
    }
    let expected = Data(digest[0..<4]).base64EncodedString()

    let actual = PairSetupHandler.setupHash(setupID: setupID, deviceID: deviceID)
    #expect(actual == expected)
  }
}

// MARK: - Setup Code Validation Tests

@Suite("Setup Code Validation")
struct SetupCodeValidationTests {

  @Test("Rejects all-zeros code")
  func rejectsAllZeros() {
    #expect(PairSetupHandler.isValidSetupCode("000-00-000") == false)
  }

  @Test("Rejects all-same-digit codes (111 through 999)")
  func rejectsAllSameDigit() {
    for d in 1...9 {
      let code = "\(d)\(d)\(d)-\(d)\(d)-\(d)\(d)\(d)"
      #expect(PairSetupHandler.isValidSetupCode(code) == false, "Should reject \(code)")
    }
  }

  @Test("Rejects ascending sequence 123-45-678")
  func rejectsAscending() {
    #expect(PairSetupHandler.isValidSetupCode("123-45-678") == false)
  }

  @Test("Rejects descending sequence 876-54-321")
  func rejectsDescending() {
    #expect(PairSetupHandler.isValidSetupCode("876-54-321") == false)
  }

  @Test("Accepts a typical valid code")
  func acceptsValidCode() {
    #expect(PairSetupHandler.isValidSetupCode("031-45-154") == true)
  }

  @Test("Invalid set contains exactly 12 codes")
  func invalidSetSize() {
    // 000-00-000, 111-11-111 ... 999-99-999 (10), 123-45-678, 876-54-321 = 12
    #expect(PairSetupHandler.invalidSetupCodes.count == 12)
  }

  @Test("generateSetupCode never produces an invalid code")
  func generateNeverInvalid() {
    for _ in 0..<1000 {
      let code = PairSetupHandler.generateSetupCode()
      #expect(PairSetupHandler.isValidSetupCode(code), "Generated invalid code: \(code)")
    }
  }

  @Test("generateSetupCode produces XXX-XX-XXX format")
  func generateFormat() {
    let code = PairSetupHandler.generateSetupCode()
    let parts = code.split(separator: "-")
    #expect(parts.count == 3)
    #expect(parts[0].count == 3)
    #expect(parts[1].count == 2)
    #expect(parts[2].count == 3)
    #expect(code.allSatisfy { $0.isNumber || $0 == "-" })
  }
}

// MARK: - Pair Setup Throttle Tests

@Suite("PairSetupThrottle")
struct PairSetupThrottleTests {

  @Test("Not throttled initially")
  func notThrottledInitially() {
    let throttle = PairSetupThrottle()
    #expect(!throttle.isThrottled())
    #expect(throttle.failedAttempts == 0)
  }

  @Test("Not throttled below max attempts")
  func notThrottledBelowMax() {
    let throttle = PairSetupThrottle()
    let now = Date()
    for _ in 0..<(PairSetupThrottle.maxAttempts - 1) {
      throttle.recordFailure(now: now)
    }
    #expect(throttle.failedAttempts == PairSetupThrottle.maxAttempts - 1)
    #expect(!throttle.isThrottled(now: now))
  }

  @Test("Throttled after max attempts")
  func throttledAfterMax() {
    let throttle = PairSetupThrottle()
    let now = Date()
    for _ in 0..<PairSetupThrottle.maxAttempts {
      throttle.recordFailure(now: now)
    }
    #expect(throttle.failedAttempts == PairSetupThrottle.maxAttempts)
    #expect(throttle.isThrottled(now: now))
  }

  @Test("Not throttled after throttle duration passes")
  func notThrottledAfterDuration() {
    let throttle = PairSetupThrottle()
    let failTime = Date()
    for _ in 0..<PairSetupThrottle.maxAttempts {
      throttle.recordFailure(now: failTime)
    }
    #expect(throttle.isThrottled(now: failTime))

    let later = failTime.addingTimeInterval(
      PairSetupThrottle.throttleDuration + 1
    )
    #expect(!throttle.isThrottled(now: later))
  }

  @Test("Reset clears state")
  func resetClearsState() {
    let throttle = PairSetupThrottle()
    let now = Date()
    for _ in 0..<PairSetupThrottle.maxAttempts {
      throttle.recordFailure(now: now)
    }
    #expect(throttle.isThrottled(now: now))

    throttle.reset()
    #expect(throttle.failedAttempts == 0)
    #expect(!throttle.isThrottled(now: now))
  }

  @Test("M1 session starts do not count toward throttle")
  func sessionStartsDoNotThrottle() {
    // Only M3 proof failures (recordFailure) should count toward the
    // throttle threshold. M1 session initiations should not, preventing
    // self-DoS from network reconnects or crashes.
    let throttle = PairSetupThrottle()
    let now = Date()
    // Simulate many M3 proof failures minus one -- should not be throttled
    for _ in 0..<(PairSetupThrottle.maxAttempts - 1) {
      throttle.recordFailure(now: now)
    }
    #expect(!throttle.isThrottled(now: now))
    // One more failure tips it over
    throttle.recordFailure(now: now)
    #expect(throttle.isThrottled(now: now))
  }
}

// MARK: - PairSetupThrottle Thread Safety Tests

@Suite("PairSetupThrottle Thread Safety")
struct PairSetupThrottleThreadTests {

  @Test("Concurrent recordFailure calls do not crash or lose counts")
  func concurrentRecordFailure() async {
    let throttle = PairSetupThrottle()
    let iterations = 100

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<4 {
        group.addTask {
          for _ in 0..<iterations {
            throttle.recordFailure()
          }
        }
      }
    }

    #expect(throttle.failedAttempts == 4 * iterations)
  }
}

// MARK: - PairSetupThrottle Window Behavior Tests

@Suite("PairSetupThrottle Window Behavior")
struct PairSetupThrottleWindowTests {

  @Test("Failures beyond maxAttempts keep throttle engaged with latest timestamp")
  func windowSlidesWithNewFailures() {
    let throttle = PairSetupThrottle()
    let startTime = Date()

    // Record exactly maxAttempts failures at startTime
    for _ in 0..<PairSetupThrottle.maxAttempts {
      throttle.recordFailure(now: startTime)
    }
    #expect(throttle.isThrottled(now: startTime))

    // Record more failures 15 seconds later (within the 30s window)
    let midTime = startTime.addingTimeInterval(15)
    for _ in 0..<50 {
      throttle.recordFailure(now: midTime)
    }
    #expect(throttle.isThrottled(now: midTime))

    // The window now extends from midTime (the latest failure), so 30s after
    // startTime is still within the throttle window.
    let afterOriginalWindow = startTime.addingTimeInterval(
      PairSetupThrottle.throttleDuration + 1)
    #expect(throttle.isThrottled(now: afterOriginalWindow))

    // Throttle expires 30s after the last failure at midTime
    let afterMidWindow = midTime.addingTimeInterval(
      PairSetupThrottle.throttleDuration + 1)
    #expect(!throttle.isThrottled(now: afterMidWindow))
  }

  @Test("Single failure after expiry immediately re-throttles")
  func reThrottlesImmediately() {
    let throttle = PairSetupThrottle()
    let t0 = Date()

    // Trigger throttle
    for _ in 0..<PairSetupThrottle.maxAttempts {
      throttle.recordFailure(now: t0)
    }
    #expect(throttle.isThrottled(now: t0))

    // Wait for window to expire
    let t1 = t0.addingTimeInterval(PairSetupThrottle.throttleDuration + 1)
    #expect(!throttle.isThrottled(now: t1))

    // A single new failure should immediately re-throttle since the counter
    // is still >= maxAttempts (never resets without calling reset()).
    throttle.recordFailure(now: t1)
    #expect(throttle.isThrottled(now: t1))
  }
}

// MARK: - BatteryState Thread Safety Tests

@Suite("BatteryState Thread Safety")
struct BatteryStateTests {

  @Test("Concurrent reads and writes do not crash")
  func concurrentAccess() async {
    let state = BatteryState()

    await withTaskGroup(of: Void.self) { group in
      // Writer
      group.addTask {
        for i in 0..<1000 {
          state.level = i % 101
          state.chargingState = i % 3
          state.statusLowBattery = i % 2
        }
      }
      // Reader
      group.addTask {
        for _ in 0..<1000 {
          _ = state.level
          _ = state.chargingState
          _ = state.statusLowBattery
        }
      }
    }

    // If we get here without crashing, thread safety works
    #expect(state.level >= 0)
  }

  @Test("Bulk update is atomic -- all three fields change together")
  func bulkUpdate() {
    let state = BatteryState()
    state.update(level: 75, chargingState: 1, statusLowBattery: 0)
    #expect(state.level == 75)
    #expect(state.chargingState == 1)
    #expect(state.statusLowBattery == 0)
  }
}

// MARK: - HDSCodec Tests

@Suite("HDSCodec Round-Trip")
struct HDSCodecTests {

  @Test("Empty dictionary")
  func emptyDict() {
    let input: [String: Any] = [:]
    let encoded = HDSCodec.encode(input)
    let decoded = HDSCodec.decode(encoded) as? [String: Any]
    #expect(decoded != nil)
    #expect(decoded?.isEmpty == true)
  }

  @Test("String values")
  func stringValues() {
    let input: [String: Any] = ["hello": "world", "key": "value"]
    let encoded = HDSCodec.encode(input)
    let decoded = HDSCodec.decode(encoded) as? [String: Any]
    #expect(decoded?["hello"] as? String == "world")
    #expect(decoded?["key"] as? String == "value")
  }

  @Test("Integer values: inline, Int8, Int16, Int32, Int64, minus-one")
  func integerValues() {
    let input: [String: Any] = [
      "zero": 0,
      "small": 39,
      "minus1": -1,
      "byte": 100,
      "short": 1000,
      "int32": 100_000,
      "int64": 5_000_000_000,
    ]
    let encoded = HDSCodec.encode(input)
    let decoded = HDSCodec.decode(encoded) as? [String: Any]
    #expect(decoded?["zero"] as? Int == 0)
    #expect(decoded?["small"] as? Int == 39)
    #expect(decoded?["minus1"] as? Int == -1)
    #expect(decoded?["byte"] as? Int == 100)
    #expect(decoded?["short"] as? Int == 1000)
    #expect(decoded?["int32"] as? Int == 100_000)
    #expect(decoded?["int64"] as? Int == 5_000_000_000)
  }

  @Test("Boolean values")
  func boolValues() {
    let input: [String: Any] = ["t": true, "f": false]
    let encoded = HDSCodec.encode(input)
    let decoded = HDSCodec.decode(encoded) as? [String: Any]
    #expect(decoded?["t"] as? Bool == true)
    #expect(decoded?["f"] as? Bool == false)
  }

  @Test("Bool and Int 0/1 encode distinctly")
  func boolIntDistinct() {
    let input: [String: Any] = ["flag": true, "count": 1]
    let encoded = HDSCodec.encode(input)
    let decoded = HDSCodec.decode(encoded) as? [String: Any]
    // Bool true encodes as tag 0x01, Int 1 encodes as tag 0x09 (inline 0x08 + 1)
    #expect(decoded?["flag"] as? Bool == true)
    #expect(decoded?["count"] as? Int == 1)
  }

  @Test("Data values")
  func dataValues() {
    let blob = Data(repeating: 0xAB, count: 64)
    let input: [String: Any] = ["blob": blob]
    let encoded = HDSCodec.encode(input)
    let decoded = HDSCodec.decode(encoded) as? [String: Any]
    #expect(decoded?["blob"] as? Data == blob)
  }

  @Test("Array values")
  func arrayValues() {
    let input: [String: Any] = ["items": [1, 2, 3] as [Any]]
    let encoded = HDSCodec.encode(input)
    let decoded = HDSCodec.decode(encoded) as? [String: Any]
    let items = decoded?["items"] as? [Any]
    #expect(items?.count == 3)
    #expect(items?[0] as? Int == 1)
    #expect(items?[2] as? Int == 3)
  }

  @Test("Nested dictionaries")
  func nestedDicts() {
    let input: [String: Any] = [
      "outer": ["inner": "value"] as [String: Any]
    ]
    let encoded = HDSCodec.encode(input)
    let decoded = HDSCodec.decode(encoded) as? [String: Any]
    let outer = decoded?["outer"] as? [String: Any]
    #expect(outer?["inner"] as? String == "value")
  }

  @Test("Large dictionary (>14 entries) uses terminated encoding")
  func largeDictTerminated() {
    var input: [String: Any] = [:]
    for i in 0..<20 {
      input["key\(String(format: "%02d", i))"] = i
    }
    let encoded = HDSCodec.encode(input)
    let decoded = HDSCodec.decode(encoded) as? [String: Any]
    #expect(decoded?.count == 20)
    #expect(decoded?["key00"] as? Int == 0)
    #expect(decoded?["key19"] as? Int == 19)
  }
}

// MARK: - HDSMessage Tests

@Suite("HDSMessage Round-Trip")
struct HDSMessageTests {

  @Test("Event message round-trip")
  func eventRoundTrip() {
    let msg = HDSMessage(
      type: .event,
      protocol: "dataSend",
      topic: "data",
      identifier: 0,
      status: .success,
      body: ["streamId": 1]
    )
    let encoded = msg.encode()
    let decoded = HDSMessage.decode(encoded)
    #expect(decoded != nil)
    #expect(decoded?.type == .event)
    #expect(decoded?.protocol == "dataSend")
    #expect(decoded?.topic == "data")
    #expect(decoded?.body["streamId"] as? Int == 1)
  }

  @Test("Request message round-trip")
  func requestRoundTrip() {
    let msg = HDSMessage(
      type: .request,
      protocol: "control",
      topic: "hello",
      identifier: 42,
      status: .success,
      body: ["version": 1]
    )
    let encoded = msg.encode()
    let decoded = HDSMessage.decode(encoded)
    #expect(decoded != nil)
    #expect(decoded?.type == .request)
    #expect(decoded?.protocol == "control")
    #expect(decoded?.topic == "hello")
    #expect(decoded?.identifier == 42)
    #expect(decoded?.body["version"] as? Int == 1)
  }

  @Test("Response message round-trip")
  func responseRoundTrip() {
    let msg = HDSMessage(
      type: .response,
      protocol: "dataSend",
      topic: "open",
      identifier: 7,
      status: .protocolError,
      body: ["status": 1]
    )
    let encoded = msg.encode()
    let decoded = HDSMessage.decode(encoded)
    #expect(decoded != nil)
    #expect(decoded?.type == .response)
    #expect(decoded?.protocol == "dataSend")
    #expect(decoded?.topic == "open")
    #expect(decoded?.identifier == 7)
    #expect(decoded?.status == .protocolError)
    #expect(decoded?.body["status"] as? Int == 1)
  }

  @Test("Decode returns nil for empty data")
  func decodeEmpty() {
    #expect(HDSMessage.decode(Data()) == nil)
  }
}

// MARK: - PairSetupThrottle Bad Public Key Tests

@Suite("PairSetupThrottle Bad Public Key")
struct PairSetupThrottleBadPubKeyTests {

  @Test("Throttle activates after maxAttempts bad public key failures")
  func throttleActivatesAfterBadPubKey() {
    let throttle = PairSetupThrottle()
    let now = Date()

    // Simulate bad public key failures reaching the threshold
    for _ in 0..<PairSetupThrottle.maxAttempts {
      #expect(
        !throttle.isThrottled(now: now) || throttle.failedAttempts >= PairSetupThrottle.maxAttempts)
      throttle.recordFailure(now: now)
    }

    #expect(throttle.failedAttempts == PairSetupThrottle.maxAttempts)
    #expect(throttle.isThrottled(now: now))
  }
}

// MARK: - JSON PID Extraction Tests

@Suite("JSON PID Extraction")
struct JSONPIDExtractionTests {

  @Test("PID extracted from JSONSerialization via Int cast")
  func pidExtractedFromJSON() throws {
    // JSONSerialization deserializes numbers as NSNumber. The Int cast approach
    // is more reliable across platforms than as? UInt64.
    let jsonData = Data(#"{"pid": 12345678}"#.utf8)
    let json = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]

    let pid = (json["pid"] as? Int).map { UInt64($0) }
    #expect(pid == 12_345_678)
  }

  @Test("PID extraction works for large values")
  func pidLargeValue() throws {
    let large: UInt64 = 4_000_000_000
    let jsonData = Data(#"{"pid": \#(large)}"#.utf8)
    let json = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]

    let pid = (json["pid"] as? Int).map { UInt64($0) }
    #expect(pid == large)
  }
}

// MARK: - PairSetupInProgress Flag Tests

@Suite("PairSetupInProgress Flag")
struct PairSetupInProgressFlagTests {

  @Test("isPairSetupInProgress defaults to false and is clearable")
  func flagDefaultsToFalseAndIsSettable() {
    // Ensure the flag starts false (or reset it for test isolation)
    PairSetupHandler.isPairSetupInProgress = false
    #expect(!PairSetupHandler.isPairSetupInProgress)

    PairSetupHandler.isPairSetupInProgress = true
    #expect(PairSetupHandler.isPairSetupInProgress)

    PairSetupHandler.isPairSetupInProgress = false
    #expect(!PairSetupHandler.isPairSetupInProgress)
  }
}

// MARK: - HDSCodec Back-Reference Tests

@Suite("HDSCodec Back-References")
struct HDSCodecBackReferenceTests {

  @Test("Round-trip encode/decode preserves dict values")
  func roundTripDict() {
    let original: [String: Any] = ["key": "value", "num": 42]
    let encoded = HDSCodec.encode(original)
    let decoded = HDSCodec.decode(encoded) as? [String: Any]
    #expect(decoded?["key"] as? String == "value")
    #expect(decoded?["num"] as? Int == 42)
  }

  @Test("Decoded arrays are tracked for back-references")
  func arrayBackReference() {
    // Manually construct: a dict with two keys pointing to the same array.
    // The array [1, 2] is encoded once, then a back-reference (0xA0+index) is used.
    //
    // Layout:
    //   0xE2        - dict with 2 entries
    //   0x41 'a'    - key "a" (1-char string)
    //   0xD2        - array with 2 elements
    //     0x09      - int 1 (0x08 + 1)
    //     0x0A      - int 2 (0x08 + 2)
    //   0x41 'b'    - key "b" (1-char string)
    //   0xA?        - back-reference to the array
    //
    // tracked order: "a" (0), 1 (1), 2 (2), [1,2] (3), "b" (4)
    // So back-reference to array is 0xA0 + 3 = 0xA3

    let bytes: [UInt8] = [
      0xE2,  // dict with 2 entries
      0x41, 0x61,  // key "a"
      0xD2,  // array with 2 elements
      0x09,  // int 1
      0x0A,  // int 2
      0x41, 0x62,  // key "b"
      0xA3,  // back-ref to tracked[3] (the array)
    ]
    let data = Data(bytes)
    let decoded = HDSCodec.decode(data) as? [String: Any]

    let a = decoded?["a"] as? [Any]
    let b = decoded?["b"] as? [Any]
    #expect(a?.count == 2)
    #expect(a?[0] as? Int == 1)
    #expect(a?[1] as? Int == 2)
    #expect(b?.count == 2)
    #expect(b?[0] as? Int == 1)
    #expect(b?[1] as? Int == 2)
  }

  @Test("Decoded dicts are tracked for back-references")
  func dictBackReference() {
    // Layout:
    //   0xD2        - array with 2 elements
    //   0xE1        - dict with 1 entry
    //     0x41 'x'  - key "x"
    //     0x09      - int 1
    //   0xA?        - back-reference to the dict
    //
    // tracked order: "x" (0), 1 (1), {"x":1} (2)
    // So back-reference to dict is 0xA0 + 2 = 0xA2

    let bytes: [UInt8] = [
      0xD2,  // array with 2 elements
      0xE1,  // dict with 1 entry
      0x41, 0x78,  // key "x"
      0x09,  // int 1
      0xA2,  // back-ref to tracked[2] (the dict)
    ]
    let data = Data(bytes)
    let decoded = HDSCodec.decode(data) as? [Any]

    #expect(decoded?.count == 2)
    let first = decoded?[0] as? [String: Any]
    let second = decoded?[1] as? [String: Any]
    #expect(first?["x"] as? Int == 1)
    #expect(second?["x"] as? Int == 1)
  }
}

// MARK: - HDSCodec Invalid UTF-8 Tests

@Suite("HDSCodec Invalid UTF-8")
struct HDSCodecInvalidUTF8Tests {

  @Test("Decode returns nil for short string with invalid UTF-8 bytes")
  func invalidUTF8ShortString() {
    // 0x42 = short string with length 2, followed by 2 invalid UTF-8 bytes
    let bytes: [UInt8] = [0x42, 0xFE, 0xFF]
    let result = HDSCodec.decode(Data(bytes))
    #expect(result == nil)
  }
}

// MARK: - HDSCodec Truncation Tests

@Suite("HDSCodec Truncation")
struct HDSCodecTruncationTests {

  @Test("Truncated length-prefixed array returns nil")
  func truncatedLengthArray() {
    // 0xD2 = array of 2, but only 1 valid element follows (0x09 = int 1)
    let data = Data([0xD2, 0x09])
    #expect(HDSCodec.decode(data) == nil)
  }

  @Test("Truncated length-prefixed dict returns nil")
  func truncatedLengthDict() {
    // 0xE1 = dict of 1, key "a" (0x41, 0x61) but no value follows
    let data = Data([0xE1, 0x41, 0x61])
    #expect(HDSCodec.decode(data) == nil)
  }

  @Test("Truncated terminated array returns nil")
  func truncatedTerminatedArray() {
    // 0xDF = terminated array, one valid element, then truncated (no 0x03 terminator)
    // and an invalid tag that decodeValue returns nil for
    let data = Data([0xDF, 0x09, 0x00])
    #expect(HDSCodec.decode(data) == nil)
  }

  @Test("Truncated terminated dict returns nil")
  func truncatedTerminatedDict() {
    // 0xEF = terminated dict, key "a", value 1, then key "b" with no value
    let data = Data([0xEF, 0x41, 0x61, 0x09, 0x41, 0x62])
    #expect(HDSCodec.decode(data) == nil)
  }

  @Test("Valid terminated array with terminator decodes correctly")
  func validTerminatedArray() {
    // 0xDF = terminated array, element 0x09 (int 1), terminator 0x03
    let data = Data([0xDF, 0x09, 0x03])
    let result = HDSCodec.decode(data) as? [Any]
    #expect(result?.count == 1)
    #expect(result?[0] as? Int == 1)
  }
}

// MARK: - Pair Setup Session Phase Tests

@Suite("PairSetupSession Phase")
struct PairSetupSessionPhaseTests {

  @Test("Initial phase is awaitingM3")
  func initialPhase() {
    let session = PairSetupSession()
    #expect(session.phase == .awaitingM3)
  }

  @Test("Phase transitions to awaitingM5")
  func phaseTransition() {
    let session = PairSetupSession()
    session.phase = .awaitingM5
    #expect(session.phase == .awaitingM5)
  }
}

// MARK: - Admin Pairing Management Tests

@Suite("Admin Pairing Management")
struct AdminPairingManagementTests {

  @Test("adminCount returns count of admin pairings")
  func adminCountReflectsAdminPairings() {
    let store = PairingStore(testPairings: [
      "A": PairingStore.Pairing(
        identifier: "A", publicKey: Data(repeating: 0xAA, count: 32), isAdmin: true),
      "B": PairingStore.Pairing(
        identifier: "B", publicKey: Data(repeating: 0xBB, count: 32), isAdmin: false),
    ])
    #expect(store.adminCount == 1)
  }

  @Test("Removing non-admin pairing succeeds even when one admin exists")
  func removeNonAdminSucceeds() {
    let store = PairingStore(testPairings: [
      "ADMIN": PairingStore.Pairing(
        identifier: "ADMIN", publicKey: Data(repeating: 0xAA, count: 32), isAdmin: true),
      "USER": PairingStore.Pairing(
        identifier: "USER", publicKey: Data(repeating: 0xBB, count: 32), isAdmin: false),
    ])
    store.removePairing(identifier: "USER")
    #expect(store.pairings.count == 1)
    #expect(store.getPairing(identifier: "ADMIN") != nil)
  }

  @Test("adminCount decreases when admin is removed")
  func adminCountDecreasesOnRemoval() {
    let store = PairingStore(testPairings: [
      "A1": PairingStore.Pairing(
        identifier: "A1", publicKey: Data(repeating: 0xAA, count: 32), isAdmin: true),
      "A2": PairingStore.Pairing(
        identifier: "A2", publicKey: Data(repeating: 0xBB, count: 32), isAdmin: true),
    ])
    #expect(store.adminCount == 2)
    store.removePairing(identifier: "A1")
    #expect(store.adminCount == 1)
  }

  // HAP spec §5.11: removing the last admin must clear all pairings.
  // PairingsHandler calls removeAll() when it detects last-admin removal;
  // these tests verify the PairingStore primitives that support that flow.

  @Test("removeAll clears all pairings including non-admin")
  func removeAllClearsEverything() {
    let store = PairingStore(testPairings: [
      "ADMIN": PairingStore.Pairing(
        identifier: "ADMIN", publicKey: Data(repeating: 0xAA, count: 32), isAdmin: true),
      "HUB-1": PairingStore.Pairing(
        identifier: "HUB-1", publicKey: Data(repeating: 0xBB, count: 32), isAdmin: false),
      "HUB-2": PairingStore.Pairing(
        identifier: "HUB-2", publicKey: Data(repeating: 0xCC, count: 32), isAdmin: false),
    ])
    #expect(store.isPaired)
    store.removeAll()
    #expect(!store.isPaired)
    #expect(store.pairings.isEmpty)
    #expect(store.adminCount == 0)
  }

  @Test("isPaired returns false after removeAll")
  func isPairedFalseAfterRemoveAll() {
    let store = PairingStore(testPairings: [
      "ADMIN": PairingStore.Pairing(
        identifier: "ADMIN", publicKey: Data(repeating: 0xAA, count: 32), isAdmin: true)
    ])
    #expect(store.isPaired)
    store.removeAll()
    #expect(!store.isPaired)
  }

  @Test("addPairingIfUnpaired succeeds after removeAll")
  func canRepairAfterRemoveAll() {
    let store = PairingStore(testPairings: [
      "OLD-ADMIN": PairingStore.Pairing(
        identifier: "OLD-ADMIN", publicKey: Data(repeating: 0xAA, count: 32), isAdmin: true),
      "HUB": PairingStore.Pairing(
        identifier: "HUB", publicKey: Data(repeating: 0xBB, count: 32), isAdmin: false),
    ])
    store.removeAll()

    let newPairing = PairingStore.Pairing(
      identifier: "NEW-ADMIN", publicKey: Data(repeating: 0xDD, count: 32), isAdmin: true)
    let added = store.addPairingIfUnpaired(newPairing)
    #expect(added)
    #expect(store.pairings.count == 1)
    #expect(store.getPairing(identifier: "NEW-ADMIN")?.isAdmin == true)
  }
}
