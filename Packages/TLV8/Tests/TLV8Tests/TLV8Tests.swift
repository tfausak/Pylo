import Foundation
import Testing

@testable import TLV8

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

  @Test("Dictionary decode rejects blobs containing separators")
  func decodeDictionaryRejectsSeparators() {
    // A multi-record blob with a separator should return empty from the
    // dictionary overload to prevent tag shadowing attacks.
    let encoded = TLV8.encode([
      (.identifier, Data("A".utf8)),
      (.publicKey, Data([0xAA])),
      (.separator, Data()),
      (.identifier, Data("B".utf8)),
      (.publicKey, Data([0xBB])),
    ])
    let dict: [TLV8.Tag: Data] = TLV8.decode(encoded)
    #expect(dict.isEmpty)
  }

  @Test("Decode multi-record TLV8 with separators")
  func decodeRecords() {
    // Two records separated by 0xFF:
    // Record 1: identifier="A", publicKey=0xAA
    // Record 2: identifier="B", publicKey=0xBB
    let encoded = TLV8.encode([
      (.identifier, Data("A".utf8)),
      (.publicKey, Data([0xAA])),
      (.separator, Data()),
      (.identifier, Data("B".utf8)),
      (.publicKey, Data([0xBB])),
    ])
    let records = TLV8.decodeRecords(encoded)
    #expect(records.count == 2)
    #expect(records[0][.identifier] == Data("A".utf8))
    #expect(records[0][.publicKey] == Data([0xAA]))
    #expect(records[1][.identifier] == Data("B".utf8))
    #expect(records[1][.publicKey] == Data([0xBB]))
  }

  @Test("Decode multi-record TLV8 strips leading separator")
  func decodeRecordsLeadingSeparator() {
    // Blob that starts with a separator should not produce a leading empty record
    var raw = Data([0xFF, 0x00])  // leading separator
    raw.append(TLV8.encode([
      (.identifier, Data("A".utf8)),
      (.publicKey, Data([0xAA])),
    ]))
    let records = TLV8.decodeRecords(raw)
    #expect(records.count == 1)
    #expect(records[0][.identifier] == Data("A".utf8))
  }

  @Test("Decode single-record TLV8 with decodeRecords returns one record")
  func decodeRecordsSingle() {
    let encoded = TLV8.encode([
      (.state, Data([0x01])),
      (.publicKey, Data([0xCC])),
    ])
    let records = TLV8.decodeRecords(encoded)
    #expect(records.count == 1)
    #expect(records[0][.state] == Data([0x01]))
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
  @Test("Builder addDelimiter inserts 00 00")
  func builderDelimiter() {
    var builder = TLV8.Builder()
    builder.add(0x01, byte: 0xAA)
    builder.addDelimiter()
    builder.add(0x01, byte: 0xBB)
    let data = builder.build()
    // [tag=0x01 len=1 val=0xAA] [tag=0x00 len=0x00] [tag=0x01 len=1 val=0xBB]
    #expect(data == Data([0x01, 0x01, 0xAA, 0x00, 0x00, 0x01, 0x01, 0xBB]))
  }

  @Test("Builder addList with bytes inserts delimiters between entries")
  func builderAddListBytes() {
    var builder = TLV8.Builder()
    builder.addList(0x02, bytes: [0x01, 0x02, 0x03])
    let data = builder.build()
    // 3 entries with 00 00 delimiters between:
    // [02 01 01] [00 00] [02 01 02] [00 00] [02 01 03]
    #expect(
      data == Data([
        0x02, 0x01, 0x01,
        0x00, 0x00,
        0x02, 0x01, 0x02,
        0x00, 0x00,
        0x02, 0x01, 0x03,
      ]))
  }

  @Test("Builder addList with single byte has no delimiter")
  func builderAddListSingleByte() {
    var builder = TLV8.Builder()
    builder.addList(0x05, bytes: [0xFF])
    let data = builder.build()
    #expect(data == Data([0x05, 0x01, 0xFF]))
  }

  @Test("Builder addList with empty array produces no output")
  func builderAddListEmpty() {
    var builder = TLV8.Builder()
    builder.addList(0x01, bytes: [])
    #expect(builder.build().isEmpty)
  }

  @Test("Builder addList with nested TLVs inserts delimiters between entries")
  func builderAddListTLVs() {
    var inner1 = TLV8.Builder()
    inner1.add(0x01, byte: 0xAA)
    var inner2 = TLV8.Builder()
    inner2.add(0x01, byte: 0xBB)
    var builder = TLV8.Builder()
    builder.addList(0x10, tlvs: [inner1, inner2])
    let data = builder.build()
    // [10 03 01-01-AA] [00 00] [10 03 01-01-BB]
    #expect(
      data == Data([
        0x10, 0x03, 0x01, 0x01, 0xAA,
        0x00, 0x00,
        0x10, 0x03, 0x01, 0x01, 0xBB,
      ]))
  }
}

// MARK: - TLV8 Truncation Tests

@Suite("TLV8 Truncation")
struct TLV8TruncationTests {

  @Test("Truncated at header (1 byte remaining) returns empty")
  func truncatedAtHeader() {
    // Valid TLV followed by a single orphan byte
    let data = Data([0x06, 0x01, 0x02, 0x03])  // tag 0x06 len 1 val 0x02, then orphan 0x03
    let pairs: [(UInt8, Data)] = TLV8.decode(data)
    #expect(pairs.isEmpty)
  }

  @Test("Truncated at value (declared length exceeds buffer) returns empty")
  func truncatedAtValue() {
    // Tag + length says 5 bytes but only 3 remain
    let data = Data([0x06, 0x05, 0x01, 0x02, 0x03])
    let pairs: [(UInt8, Data)] = TLV8.decode(data)
    #expect(pairs.isEmpty)
  }

  @Test("Valid TLV still decodes correctly")
  func validTLVStillWorks() {
    let data = Data([0x06, 0x01, 0x02, 0x07, 0x01, 0x01])
    let pairs: [(UInt8, Data)] = TLV8.decode(data)
    #expect(pairs.count == 2)
  }

  @Test("Empty data decodes to empty array")
  func emptyData() {
    let pairs: [(UInt8, Data)] = TLV8.decode(Data())
    #expect(pairs.isEmpty)
  }

  @Test("Entry with length exactly at boundary decodes correctly")
  func exactBoundary() {
    let data = Data([0x06, 0x01, 0x02, 0x07, 0x02, 0xAA, 0xBB])
    let pairs: [(UInt8, Data)] = TLV8.decode(data)
    #expect(pairs.count == 2)
    #expect(pairs[1].1 == Data([0xAA, 0xBB]))
  }

  @Test("Zero-length entry decodes correctly")
  func zeroLengthEntry() {
    let data = Data([0xFF, 0x00, 0x06, 0x01, 0x03])
    let pairs: [(UInt8, Data)] = TLV8.decode(data)
    #expect(pairs.count == 2)
    #expect(pairs[0].0 == 0xFF)
    #expect(pairs[0].1.isEmpty)
    #expect(pairs[1].1 == Data([0x03]))
  }
}
