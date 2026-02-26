import CommonCrypto
import CryptoKit
import Foundation
import Testing

@testable import Pylo

// MARK: - TLV8 Tests

@Suite("TLV8 Codec")
struct TLV8Tests {

  @Test("Encode single byte value")
  func encodeSingleByte() {
    let data = TLV8.encode(.state, 0x01)
    #expect(data == Data([0x06, 0x01, 0x01]))
  }

  @Test("Encode single data value")
  func encodeSingleData() {
    let payload = Data([0xAA, 0xBB, 0xCC])
    let data = TLV8.encode(.salt, payload)
    #expect(data == Data([0x02, 0x03, 0xAA, 0xBB, 0xCC]))
  }

  @Test("Encode empty value (separator)")
  func encodeEmptyValue() {
    let data = TLV8.encode([(TLV8.Tag.separator, Data())])
    #expect(data == Data([0xFF, 0x00]))
  }

  @Test("Encode multiple items")
  func encodeMultipleItems() {
    let data = TLV8.encode([
      (.state, Data([0x02])),
      (.error, Data([0x01])),
    ])
    #expect(data == Data([0x06, 0x01, 0x02, 0x07, 0x01, 0x01]))
  }

  @Test("Encode fragments values over 255 bytes")
  func encodeFragmentation() {
    let bigPayload = Data(repeating: 0x42, count: 300)
    let encoded = TLV8.encode(.publicKey, bigPayload)

    // First fragment: tag + 0xFF + 255 bytes
    #expect(encoded[0] == 0x03)
    #expect(encoded[1] == 0xFF)

    // Second fragment: tag + 45 + 45 bytes
    let secondStart = 2 + 255
    #expect(encoded[secondStart] == 0x03)
    #expect(encoded[secondStart + 1] == 45)

    #expect(encoded.count == 2 + 255 + 2 + 45)
  }

  @Test("Decode simple TLV pairs")
  func decodeSimple() {
    let raw = Data([0x06, 0x01, 0x02, 0x07, 0x01, 0x01])
    let pairs: [(UInt8, Data)] = TLV8.decode(raw)
    #expect(pairs.count == 2)
    #expect(pairs[0].0 == 0x06)
    #expect(pairs[0].1 == Data([0x02]))
    #expect(pairs[1].0 == 0x07)
    #expect(pairs[1].1 == Data([0x01]))
  }

  @Test("Decode coalesces fragmented values")
  func decodeCoalescing() {
    // Two consecutive items with same tag should be coalesced
    let fragment1 = Data(repeating: 0xAA, count: 255)
    let fragment2 = Data(repeating: 0xBB, count: 45)
    var raw = Data()
    raw.append(0x03)  // publicKey tag
    raw.append(0xFF)  // 255 length
    raw.append(fragment1)
    raw.append(0x03)  // same tag
    raw.append(45)  // 45 length
    raw.append(fragment2)

    let pairs: [(UInt8, Data)] = TLV8.decode(raw)
    #expect(pairs.count == 1)
    #expect(pairs[0].0 == 0x03)
    #expect(pairs[0].1.count == 300)
    #expect(pairs[0].1.prefix(255) == fragment1)
    #expect(pairs[0].1.suffix(45) == fragment2)
  }

  @Test("Decode to dictionary by tag")
  func decodeToDictionary() {
    let raw = Data([0x06, 0x01, 0x03, 0x02, 0x02, 0xAA, 0xBB])
    let dict: [TLV8.Tag: Data] = TLV8.decode(raw)
    #expect(dict[.state] == Data([0x03]))
    #expect(dict[.salt] == Data([0xAA, 0xBB]))
    #expect(dict[.error] == nil)
  }

  @Test("Encode-decode roundtrip preserves data")
  func roundtrip() {
    let original: [(TLV8.Tag, Data)] = [
      (.state, Data([0x01])),
      (.publicKey, Data(repeating: 0xDE, count: 32)),
      (.proof, Data(repeating: 0xAB, count: 64)),
    ]
    let encoded = TLV8.encode(original)
    let decoded: [(UInt8, Data)] = TLV8.decode(encoded)
    #expect(decoded.count == 3)
    #expect(decoded[0].1 == Data([0x01]))
    #expect(decoded[1].1 == Data(repeating: 0xDE, count: 32))
    #expect(decoded[2].1 == Data(repeating: 0xAB, count: 64))
  }

  @Test("Roundtrip with large fragmented value")
  func roundtripLargeValue() {
    let bigValue = Data(repeating: 0x77, count: 600)
    let encoded = TLV8.encode(.encryptedData, bigValue)
    let decoded: [(UInt8, Data)] = TLV8.decode(encoded)
    #expect(decoded.count == 1)
    #expect(decoded[0].1 == bigValue)
  }

  @Test("Decode empty data returns empty")
  func decodeEmpty() {
    let pairs: [(UInt8, Data)] = TLV8.decode(Data())
    #expect(pairs.isEmpty)
  }

  @Test("Builder adds byte values")
  func builderByte() {
    var builder = TLV8.Builder()
    builder.add(0x06, byte: 0x01)
    let data = builder.build()
    #expect(data == Data([0x06, 0x01, 0x01]))
  }

  @Test("Builder adds uint16 as little-endian")
  func builderUInt16() {
    var builder = TLV8.Builder()
    builder.add(0x01, uint16: 0x0102)
    let data = builder.build()
    #expect(data == Data([0x01, 0x02, 0x02, 0x01]))
  }

  @Test("Builder adds uint32 as little-endian")
  func builderUInt32() {
    var builder = TLV8.Builder()
    builder.add(0x01, uint32: 0x0102_0304)
    let data = builder.build()
    #expect(data == Data([0x01, 0x04, 0x04, 0x03, 0x02, 0x01]))
  }

  @Test("Builder adds nested TLV")
  func builderNestedTLV() {
    var inner = TLV8.Builder()
    inner.add(0x01, byte: 0xFF)
    var outer = TLV8.Builder()
    outer.add(0x02, tlv: inner)
    let data = outer.build()
    // outer: tag=0x02, len=3, value=[0x01, 0x01, 0xFF]
    #expect(data == Data([0x02, 0x03, 0x01, 0x01, 0xFF]))
  }

  @Test("Builder base64 encoding")
  func builderBase64() {
    var builder = TLV8.Builder()
    builder.add(0x00, byte: 0x01)
    let b64 = builder.base64()
    #expect(b64 == Data([0x00, 0x01, 0x01]).base64EncodedString())
  }

  @Test("Builder fragments large values")
  func builderFragmentation() {
    var builder = TLV8.Builder()
    let bigValue = Data(repeating: 0xAA, count: 300)
    builder.add(0x05, bigValue)
    let data = builder.build()
    // Should produce two chunks
    #expect(data[0] == 0x05)
    #expect(data[1] == 0xFF)
    let secondStart = 2 + 255
    #expect(data[secondStart] == 0x05)
    #expect(data[secondStart + 1] == 45)
  }

  @Test("Builder empty value produces zero-length TLV")
  func builderEmptyValue() {
    var builder = TLV8.Builder()
    builder.add(0xFF, Data())
    let data = builder.build()
    #expect(data == Data([0xFF, 0x00]))
  }
}

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

    let first = HTTPRequest.parseAndConsume(&buffer)
    #expect(first?.path == "/a")
    #expect(!buffer.isEmpty)

    let second = HTTPRequest.parseAndConsume(&buffer)
    #expect(second?.path == "/b")
    #expect(buffer.isEmpty)
  }

  @Test("parseAndConsume returns nil when body incomplete")
  func parseAndConsumeIncompleteBody() {
    let raw = "POST /data HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort"
    var buffer = Data(raw.utf8)
    let request = HTTPRequest.parseAndConsume(&buffer)
    #expect(request == nil)
    // Buffer should be preserved since request is incomplete
    #expect(!buffer.isEmpty)
  }

  @Test("parseAndConsume handles zero content-length")
  func parseAndConsumeNoBody() {
    let raw = "GET /test HTTP/1.1\r\n\r\n"
    var buffer = Data(raw.utf8)
    let request = HTTPRequest.parseAndConsume(&buffer)
    #expect(request?.method == "GET")
    #expect(request?.body == nil)
    #expect(buffer.isEmpty)
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

// MARK: - HAP Accessory (Lightbulb) Tests

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
    #expect(accessory.readCharacteristic(iid: 3) as? String == "Test Maker")
    #expect(accessory.readCharacteristic(iid: 4) as? String == "Test Model")
    #expect(accessory.readCharacteristic(iid: 5) as? String == "Test Light")
    #expect(accessory.readCharacteristic(iid: 6) as? String == "SN-123")
    #expect(accessory.readCharacteristic(iid: 7) as? String == "2.0.0")
  }

  @Test("Read lightbulb state characteristics")
  func readLightbulbState() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.readCharacteristic(iid: 9) as? Bool == false)
    #expect(accessory.readCharacteristic(iid: 10) as? Int == 100)
  }

  @Test("Read unknown iid returns nil")
  func readUnknownIID() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.readCharacteristic(iid: 99) == nil)
  }

  @Test("Write on/off as bool")
  func writeOnBool() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 9, value: true))
    #expect(accessory.isOn == true)
    #expect(accessory.writeCharacteristic(iid: 9, value: false))
    #expect(accessory.isOn == false)
  }

  @Test("Write on/off coerces int to bool")
  func writeOnInt() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 9, value: 1))
    #expect(accessory.isOn == true)
    #expect(accessory.writeCharacteristic(iid: 9, value: 0))
    #expect(accessory.isOn == false)
  }

  @Test("Write on/off rejects invalid type")
  func writeOnInvalidType() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 9, value: "yes") == false)
  }

  @Test("Write brightness clamps to 0-100")
  func writeBrightnessClamped() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 10, value: 50))
    #expect(accessory.brightness == 50)

    #expect(accessory.writeCharacteristic(iid: 10, value: 150))
    #expect(accessory.brightness == 100)

    #expect(accessory.writeCharacteristic(iid: 10, value: -10))
    #expect(accessory.brightness == 0)
  }

  @Test("Write brightness rejects non-int")
  func writeBrightnessInvalidType() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 10, value: "50") == false)
  }

  @Test("Write to unknown iid returns false")
  func writeUnknownIID() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 99, value: true) == false)
  }

  @Test("Write identify (iid 2) succeeds")
  func writeIdentify() {
    let accessory = HAPAccessory(aid: 2)
    #expect(accessory.writeCharacteristic(iid: 2, value: true))
  }

  @Test("State change callback fires on write")
  func stateChangeCallback() {
    let accessory = HAPAccessory(aid: 2)
    var callbackCalled = false
    var receivedAid = 0
    var receivedIid = 0
    accessory.onStateChange = { aid, iid, _ in
      callbackCalled = true
      receivedAid = aid
      receivedIid = iid
    }
    accessory.writeCharacteristic(iid: 9, value: true)
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
    #expect(services.count == 2)

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
    #expect(bridge.readCharacteristic(iid: 3) as? String == "Acme")
    #expect(bridge.readCharacteristic(iid: 4) as? String == "Test")
    #expect(bridge.readCharacteristic(iid: 5) as? String == "My Bridge")
    #expect(bridge.readCharacteristic(iid: 6) as? String == "BR-001")
    #expect(bridge.readCharacteristic(iid: 7) as? String == "1.0")
  }

  @Test("Bridge identify write succeeds")
  func identifyWrite() {
    let bridge = HAPBridgeInfo()
    #expect(bridge.writeCharacteristic(iid: 2, value: true))
  }

  @Test("Bridge rejects writes to non-identify characteristics")
  func rejectNonIdentifyWrite() {
    let bridge = HAPBridgeInfo()
    #expect(bridge.writeCharacteristic(iid: 3, value: "foo") == false)
    #expect(bridge.writeCharacteristic(iid: 99, value: true) == false)
  }

  @Test("Bridge toJSON has single service")
  func toJSONSingleService() {
    let bridge = HAPBridgeInfo()
    let json = bridge.toJSON()
    let services = json["services"] as! [[String: Any]]
    #expect(services.count == 1)
    #expect(services[0]["type"] as? String == "3E")
  }
}

// MARK: - HAP Light Sensor Tests

@Suite("HAP Light Sensor Accessory")
struct HAPLightSensorTests {

  @Test("Initial light level is 1.0 lux")
  func initialLevel() {
    let sensor = HAPLightSensorAccessory(aid: 4)
    #expect(sensor.ambientLightLevel == 1.0)
  }

  @Test("Update ambient light level")
  func updateLevel() {
    let sensor = HAPLightSensorAccessory(aid: 4)
    sensor.updateAmbientLight(500.0)
    #expect(sensor.ambientLightLevel == 500.0)
    #expect(sensor.readCharacteristic(iid: 9) as? Float == 500.0)
  }

  @Test("Update fires state change callback")
  func updateCallback() {
    let sensor = HAPLightSensorAccessory(aid: 4)
    var receivedValue: Float?
    sensor.onStateChange = { _, iid, value in
      if iid == 9 { receivedValue = value as? Float }
    }
    sensor.updateAmbientLight(42.5)
    #expect(receivedValue == 42.5)
  }

  @Test("toJSON includes lux range constraints")
  func toJSONConstraints() {
    let sensor = HAPLightSensorAccessory(aid: 4)
    let json = sensor.toJSON()
    let services = json["services"] as! [[String: Any]]
    let lightService = services[1]
    let chars = lightService["characteristics"] as! [[String: Any]]
    let luxChar = chars[0]
    #expect(luxChar["format"] as? String == "float")
    #expect(luxChar["unit"] as? String == "lux")
    #expect(luxChar["minValue"] as? Float == Float(0.0001))
    #expect(luxChar["maxValue"] as? Float == Float(100000))
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
    #expect(sensor.readCharacteristic(iid: 9) as? Bool == true)

    sensor.updateMotionDetected(false)
    #expect(sensor.isMotionDetected == false)
  }

  @Test("Update fires state change callback")
  func updateCallback() {
    let sensor = HAPMotionSensorAccessory(aid: 5)
    var receivedValue: Bool?
    sensor.onStateChange = { _, iid, value in
      if iid == 9 { receivedValue = value as? Bool }
    }
    sensor.updateMotionDetected(true)
    #expect(receivedValue == true)
  }

  @Test("toJSON has motion sensor service")
  func toJSONService() {
    let sensor = HAPMotionSensorAccessory(aid: 5)
    let json = sensor.toJSON()
    let services = json["services"] as! [[String: Any]]
    #expect(services.count == 2)
    #expect(services[1]["type"] as? String == "85")
    let chars = services[1]["characteristics"] as! [[String: Any]]
    #expect(chars[0]["format"] as? String == "bool")
  }
}

// MARK: - Encryption Context Tests

@Suite("Encryption Context")
struct EncryptionContextTests {

  @Test("Encrypt-decrypt roundtrip")
  func encryptDecryptRoundtrip() {
    let key = SymmetricKey(size: .bits256)
    let ctx = EncryptionContext(readKey: key, writeKey: key)

    let plaintext = Data("Hello, HomeKit!".utf8)
    let encrypted = ctx.encrypt(plaintext: plaintext)

    // Encrypted format: [2-byte length][ciphertext][16-byte tag]
    #expect(encrypted.count == 2 + plaintext.count + 16)

    let lengthBytes = encrypted.prefix(2)
    let cipherAndTag = encrypted.dropFirst(2)
    let decrypted = ctx.decrypt(lengthBytes: Data(lengthBytes), ciphertext: Data(cipherAndTag))

    #expect(decrypted == plaintext)
  }

  @Test("Encrypt-decrypt large message splits into frames")
  func largeMessageFrames() {
    let writeKey = SymmetricKey(size: .bits256)
    let readKey = SymmetricKey(size: .bits256)
    let encryptor = EncryptionContext(readKey: readKey, writeKey: writeKey)
    let decryptor = EncryptionContext(readKey: writeKey, writeKey: readKey)

    let plaintext = Data(repeating: 0x42, count: 2500)
    let encrypted = encryptor.encrypt(plaintext: plaintext)

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
  func decryptWrongKey() {
    let key1 = SymmetricKey(size: .bits256)
    let key2 = SymmetricKey(size: .bits256)
    let encryptor = EncryptionContext(readKey: key1, writeKey: key1)
    let decryptor = EncryptionContext(readKey: key2, writeKey: key2)

    let encrypted = encryptor.encrypt(plaintext: Data("secret".utf8))
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
  func nonceIncrements() {
    let key = SymmetricKey(size: .bits256)
    let encryptor = EncryptionContext(readKey: key, writeKey: key)

    let msg1 = encryptor.encrypt(plaintext: Data("msg1".utf8))
    let msg2 = encryptor.encrypt(plaintext: Data("msg1".utf8))

    // Same plaintext, different nonces → different ciphertext
    #expect(msg1 != msg2)
  }
}

// MARK: - SRP Server Tests

@Suite("SRP Server")
struct SRPServerTests {

  @Test("Initialization succeeds and produces salt and public key")
  func initSucceeds() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")
    #expect(server != nil)
    #expect(server!.salt.count == 16)
    #expect(server!.publicKey.count == 384)
  }

  @Test("Reject client public key of zero")
  func rejectZeroPublicKey() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    let zeroKey = Data(repeating: 0, count: 384)
    #expect(server.setClientPublicKey(zeroKey) == false)
  }

  @Test("Session key is nil before client public key is set")
  func sessionKeyNilBeforePublicKey() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    #expect(server.sessionKey == nil)
  }

  @Test("Verify client proof returns nil without client public key")
  func verifyWithoutPublicKey() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    let result = server.verifyClientProof(Data(repeating: 0, count: 64))
    #expect(result == nil)
  }

  @Test("Wrong proof is rejected")
  func wrongProofRejected() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    // Set a valid (non-zero) client public key
    var fakeKey = Data(repeating: 0, count: 384)
    fakeKey[383] = 0x05  // Non-zero so it passes the A%N!=0 check
    _ = server.setClientPublicKey(fakeKey)
    let result = server.verifyClientProof(Data(repeating: 0xAB, count: 64))
    #expect(result == nil)
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
    let store = PairingStore()
    // Note: may have pairings from disk, but isPaired reflects current state
    // For a clean test, we remove all first
    store.removeAll()
    #expect(store.isPaired == false)
  }

  @Test("Add and retrieve pairing")
  func addAndGet() {
    let store = PairingStore()
    store.removeAll()

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

    store.removeAll()
  }

  @Test("Remove pairing")
  func removePairing() {
    let store = PairingStore()
    store.removeAll()

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
    let store = PairingStore()
    #expect(store.getPairing(identifier: "does-not-exist") == nil)
  }

  @Test("onChange callback fires on add and remove")
  func onChangeCallback() {
    let store = PairingStore()
    store.removeAll()

    var callCount = 0
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
}

// MARK: - Setup Hash Tests

@Suite("Setup Hash")
struct SetupHashTests {

  @Test("Deterministic — same input produces same output")
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

// MARK: - AU Header Framing Tests

@Suite("AU Header Framing")
struct AUHeaderTests {

  @Test("Roundtrip: strip(add(data)) == data")
  func roundtrip() {
    let original = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03])
    let framed = AUHeader.add(to: original)
    let stripped = AUHeader.strip(from: framed)
    #expect(stripped == original)
  }

  @Test("add() produces 0x00 0x10 prefix")
  func addPrefix() {
    let payload = Data([0xAA, 0xBB])
    let framed = AUHeader.add(to: payload)
    #expect(framed.count == payload.count + 4)
    #expect(framed[0] == 0x00)
    #expect(framed[1] == 0x10)
  }

  @Test("AU-size field encodes correctly for small payload")
  func auSizeSmall() {
    // Payload size 10: AU-size field = 10 << 3 = 80 = 0x0050
    let payload = Data(repeating: 0xFF, count: 10)
    let framed = AUHeader.add(to: payload)
    let auSizeBits = UInt16(framed[2]) << 8 | UInt16(framed[3])
    // Upper 13 bits = payload size, lower 3 bits = AU-Index = 0
    #expect(auSizeBits >> 3 == 10)
    #expect(auSizeBits & 0x07 == 0)
  }

  @Test("AU-size field encodes correctly for larger payload")
  func auSizeLarger() {
    let payload = Data(repeating: 0xAA, count: 500)
    let framed = AUHeader.add(to: payload)
    let auSizeBits = UInt16(framed[2]) << 8 | UInt16(framed[3])
    #expect(auSizeBits >> 3 == 500)
    #expect(auSizeBits & 0x07 == 0)
  }

  @Test("strip() passes through data without AU header unchanged")
  func stripPassthrough() {
    // Data that doesn't start with 0x00, 0x10
    let raw = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB])
    let result = AUHeader.strip(from: raw)
    #expect(result == raw)
  }

  @Test("strip() handles empty data")
  func stripEmpty() {
    let result = AUHeader.strip(from: Data())
    #expect(result == Data())
  }

  @Test("strip() handles short data (< 4 bytes)")
  func stripShort() {
    let short = Data([0x00, 0x10])  // Only 2 bytes — too short for full header
    let result = AUHeader.strip(from: short)
    #expect(result == short)
  }

  @Test("add() with empty payload")
  func addEmpty() {
    let framed = AUHeader.add(to: Data())
    #expect(framed.count == 4)
    #expect(framed[0] == 0x00)
    #expect(framed[1] == 0x10)
    #expect(framed[2] == 0x00)
    #expect(framed[3] == 0x00)
  }
}

// MARK: - SRTP Tests

@Suite("SRTP")
struct SRTPTests {

  /// RFC 3711 Appendix B.3 test vectors for key derivation.
  @Test("Key derivation matches RFC 3711 B.3 test vectors")
  func keyDerivationRFC3711() {
    let testKey = Data([
      0xE1, 0xF9, 0x7A, 0x0D, 0x3E, 0x01, 0x8B, 0xE0,
      0xD6, 0x4F, 0xA3, 0x2C, 0x06, 0xDE, 0x41, 0x39,
    ])
    let testSalt = Data([
      0x0E, 0xC6, 0x75, 0xAD, 0x49, 0x8A, 0xFE, 0xEB,
      0xB6, 0x96, 0x0B, 0x3A, 0xAB, 0xE6,
    ])
    let expectedCipherKey = Data([
      0xC6, 0x1E, 0x7A, 0x93, 0x74, 0x4F, 0x39, 0xEE,
      0x10, 0x73, 0x4A, 0xFE, 0x3F, 0xF7, 0xA0, 0x87,
    ])
    let expectedSalt = Data([
      0x30, 0xCB, 0xBC, 0x08, 0x86, 0x3D, 0x8C, 0x85,
      0xD4, 0x9D, 0xB3, 0x4A, 0x9A, 0xE1,
    ])
    let expectedAuthKey = Data([
      0xCE, 0xBE, 0x32, 0x1F, 0x6F, 0xF7, 0x71, 0x6B,
      0x6F, 0xD4, 0xAB, 0x49, 0xAF, 0x25, 0x6A, 0x15,
      0x6D, 0x38, 0xBA, 0xA4,
    ])

    let ck = SRTPContext.deriveKey(
      masterKey: testKey, masterSalt: testSalt, label: 0x00, length: 16)
    let cs = SRTPContext.deriveKey(
      masterKey: testKey, masterSalt: testSalt, label: 0x02, length: 14)
    let ak = SRTPContext.deriveKey(
      masterKey: testKey, masterSalt: testSalt, label: 0x01, length: 20)

    #expect(ck == expectedCipherKey)
    #expect(cs == expectedSalt)
    #expect(ak == expectedAuthKey)
  }

  /// Helper: build a minimal valid RTP packet with given seq, SSRC, and payload.
  private static func makeRTPPacket(seq: UInt16, ssrc: UInt32, payload: Data) -> Data {
    var header = Data(count: 12)
    header[0] = 0x80  // V=2
    header[1] = 0x60  // PT=96
    header[2] = UInt8(seq >> 8)
    header[3] = UInt8(seq & 0xFF)
    // Timestamp = 0
    header[8] = UInt8((ssrc >> 24) & 0xFF)
    header[9] = UInt8((ssrc >> 16) & 0xFF)
    header[10] = UInt8((ssrc >> 8) & 0xFF)
    header[11] = UInt8(ssrc & 0xFF)
    var pkt = header
    pkt.append(payload)
    return pkt
  }

  private static let testMasterKey = Data([
    0xE1, 0xF9, 0x7A, 0x0D, 0x3E, 0x01, 0x8B, 0xE0,
    0xD6, 0x4F, 0xA3, 0x2C, 0x06, 0xDE, 0x41, 0x39,
  ])
  private static let testMasterSalt = Data([
    0x0E, 0xC6, 0x75, 0xAD, 0x49, 0x8A, 0xFE, 0xEB,
    0xB6, 0x96, 0x0B, 0x3A, 0xAB, 0xE6,
  ])

  @Test("Protect/unprotect roundtrip with known keys")
  func protectUnprotectRoundtrip() {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    let rtp = Self.makeRTPPacket(
      seq: 1, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0x42, count: 160))
    let srtp = sender.protect(rtp)

    // SRTP adds 10-byte auth tag
    #expect(srtp.count == rtp.count + 10)

    let recovered = receiver.unprotect(srtp)
    #expect(recovered == rtp)
  }

  @Test("Auth failure: tampered ciphertext returns nil")
  func authFailureTampered() {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    let rtp = Self.makeRTPPacket(
      seq: 1, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0xAA, count: 100))
    var srtp = sender.protect(rtp)

    // Tamper with encrypted payload (flip a byte in the middle)
    let tamperIndex = 20
    if tamperIndex < srtp.count - 10 {
      srtp[tamperIndex] ^= 0xFF
    }

    let result = receiver.unprotect(srtp)
    #expect(result == nil)
  }

  @Test("Empty payload roundtrip (12-byte header only)")
  func emptyPayloadRoundtrip() {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    let rtp = Self.makeRTPPacket(seq: 1, ssrc: 0x1234_5678, payload: Data())
    let srtp = sender.protect(rtp)

    // Header-only: 12 bytes + 10-byte auth tag
    #expect(srtp.count == 22)

    let recovered = receiver.unprotect(srtp)
    #expect(recovered == rtp)
  }

  @Test("Multiple sequential packets with incrementing seq")
  func multipleSequentialPackets() {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    for seq: UInt16 in 1...10 {
      let rtp = Self.makeRTPPacket(
        seq: seq, ssrc: 0xCAFE_BABE, payload: Data(repeating: UInt8(seq), count: 80))
      let srtp = sender.protect(rtp)
      let recovered = receiver.unprotect(srtp)
      #expect(recovered == rtp, "Failed at seq \(seq)")
    }
  }

  @Test("RTCP protect produces output larger than input")
  func rtcpProtectGrows() {
    let ctx = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    // Minimal RTCP Sender Report: 8-byte header + 20-byte SR body
    var rtcp = Data(count: 28)
    rtcp[0] = 0x80  // V=2
    rtcp[1] = 200  // PT=SR
    rtcp[2] = 0x00
    rtcp[3] = 0x06  // length
    // SSRC at bytes 4-7
    rtcp[4] = 0xDE
    rtcp[5] = 0xAD
    rtcp[6] = 0xBE
    rtcp[7] = 0xEF

    let srtcp = ctx.protectRTCP(rtcp)
    // SRTCP adds: E||index (4 bytes) + auth tag (10 bytes) = 14 bytes
    #expect(srtcp.count == rtcp.count + 14)
  }

  @Test("Short packets (< 12 bytes) are returned unchanged by protect")
  func shortPacketProtect() {
    let ctx = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let shortData = Data([0x80, 0x60, 0x00, 0x01])  // Only 4 bytes
    let result = ctx.protect(shortData)
    #expect(result == shortData)
  }

  @Test("Short packets (< 22 bytes) return nil from unprotect")
  func shortPacketUnprotect() {
    let ctx = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let shortData = Data(repeating: 0x00, count: 15)
    let result = ctx.unprotect(shortData)
    #expect(result == nil)
  }
}
