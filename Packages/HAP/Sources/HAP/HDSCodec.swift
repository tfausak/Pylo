import Foundation

// MARK: - HDS DataStream Codec

/// Binary codec for HDS (HomeKit Data Stream) messages.
/// This implements the DataStream serialization format used by HomeKit hubs
/// for the HDS protocol. It uses different tag values from Apple's OPack format.
public nonisolated enum HDSCodec {

  // MARK: - Encode

  /// Encode a dictionary to HDS binary format.
  public static func encode(_ dict: [String: Any]) -> Data {
    var data = Data()
    encodeDict(dict, into: &data)
    return data
  }

  private static func encodeDict(_ dict: [String: Any], into data: inout Data) {
    let count = dict.count
    if count <= 14 {
      data.append(UInt8(0xE0 + count))  // Length-prefixed dictionary
    } else {
      data.append(0xEF)  // Terminated dictionary
    }
    // Sorted keys ensure deterministic binary output.  HDS control messages
    // have small dictionaries so the O(n log n) cost is negligible.
    for key in dict.keys.sorted() {
      encodeString(key, into: &data)
      encodeValue(dict[key]!, into: &data)
    }
    if count > 14 {
      data.append(0x03)  // Terminator
    }
  }

  private static func encodeValue(_ value: Any, into data: inout Data) {
    switch value {
    case let v as Bool:
      data.append(v ? 0x01 : 0x02)  // TRUE=0x01, FALSE=0x02

    case let v as Int:
      encodeInt(v, into: &data)

    case let v as String:
      encodeString(v, into: &data)

    case let v as Data:
      encodeBinary(v, into: &data)

    case let v as [String: Any]:
      encodeDict(v, into: &data)

    case let v as [[String: Any]]:
      encodeArray(v.map { $0 as Any }, into: &data)

    case let v as [Any]:
      encodeArray(v, into: &data)

    default:
      data.append(0x04)  // NULL
    }
  }

  private static func encodeArray(_ arr: [Any], into data: inout Data) {
    let count = arr.count
    if count <= 14 {
      data.append(UInt8(0xD0 + count))  // Length-prefixed array
    } else {
      data.append(0xDF)  // Terminated array
    }
    for item in arr {
      encodeValue(item, into: &data)
    }
    if count > 14 {
      data.append(0x03)  // Terminator
    }
  }

  private static func encodeInt(_ value: Int, into data: inout Data) {
    if value == -1 {
      data.append(0x07)  // INTEGER_MINUS_ONE
    } else if value >= 0 && value <= 39 {
      data.append(UInt8(0x08 + value))  // Inline 0-39
    } else if value >= -128 && value <= 127 {
      data.append(0x30)
      data.append(UInt8(bitPattern: Int8(value)))
    } else if value >= -32768 && value <= 32767 {
      data.append(0x31)
      var le = Int16(value).littleEndian
      data.append(Data(bytes: &le, count: 2))
    } else if value >= -2_147_483_648 && value <= 2_147_483_647 {
      data.append(0x32)
      var le = Int32(value).littleEndian
      data.append(Data(bytes: &le, count: 4))
    } else {
      data.append(0x33)
      var le = Int64(value).littleEndian
      data.append(Data(bytes: &le, count: 8))
    }
  }

  private static func encodeString(_ string: String, into data: inout Data) {
    let utf8 = Data(string.utf8)
    let len = utf8.count
    if len <= 32 {
      data.append(UInt8(0x40 + len))  // Short string (0x40-0x60)
    } else if len <= 0xFF {
      data.append(0x61)
      data.append(UInt8(len))
    } else if len <= 0xFFFF {
      data.append(0x62)
      var le = UInt16(len).littleEndian
      data.append(Data(bytes: &le, count: 2))
    } else {
      data.append(0x63)
      var le = UInt32(len).littleEndian
      data.append(Data(bytes: &le, count: 4))
    }
    data.append(utf8)
  }

  private static func encodeBinary(_ binary: Data, into data: inout Data) {
    let len = binary.count
    if len <= 32 {
      data.append(UInt8(0x70 + len))  // Short data (0x70-0x90)
    } else if len <= 0xFF {
      data.append(0x91)
      data.append(UInt8(len))
    } else if len <= 0xFFFF {
      data.append(0x92)
      var le = UInt16(len).littleEndian
      data.append(Data(bytes: &le, count: 2))
    } else {
      data.append(0x93)
      var le = UInt32(len).littleEndian
      data.append(Data(bytes: &le, count: 4))
    }
    data.append(binary)
  }

  // MARK: - Decode

  /// Decode an HDS binary blob into a Swift value (typically a dictionary).
  public static func decode(_ data: Data) -> Any? {
    var tracked: [Any] = []
    var offset = 0
    return decodeValue(data, offset: &offset, tracked: &tracked)
  }

  private static func decodeValue(
    _ data: Data, offset: inout Int, tracked: inout [Any]
  ) -> Any? {
    guard offset < data.count else { return nil }

    let tag = data[offset]
    offset += 1

    switch tag {
    case 0x00:  // INVALID
      return nil

    case 0x01:  // TRUE
      tracked.append(true)
      return true

    case 0x02:  // FALSE
      tracked.append(false)
      return false

    case 0x04:  // NULL
      return NSNull()

    case 0x05:  // UUID (16 bytes big-endian)
      guard offset + 16 <= data.count else { return nil }
      let bytes = [UInt8](data[offset..<offset + 16])
      offset += 16
      let str = NSUUID(uuidBytes: bytes).uuidString
      tracked.append(str)
      return str

    case 0x06:  // DATE (float64 seconds since 2001-01-01)
      guard offset + 8 <= data.count else { return nil }
      let bits =
        UInt64(data[offset])
        | UInt64(data[offset + 1]) << 8
        | UInt64(data[offset + 2]) << 16
        | UInt64(data[offset + 3]) << 24
        | UInt64(data[offset + 4]) << 32
        | UInt64(data[offset + 5]) << 40
        | UInt64(data[offset + 6]) << 48
        | UInt64(data[offset + 7]) << 56
      offset += 8
      let v = Double(bitPattern: bits)
      tracked.append(v)
      return v

    case 0x07:  // INTEGER -1
      tracked.append(-1)
      return -1

    case 0x08...0x2F:  // Small integer 0-39
      let v = Int(tag - 0x08)
      tracked.append(v)
      return v

    case 0x30:  // Int8
      guard offset < data.count else { return nil }
      let v = Int(Int8(bitPattern: data[offset]))
      offset += 1
      tracked.append(v)
      return v

    case 0x31:  // Int16 LE
      guard offset + 2 <= data.count else { return nil }
      let v = Int(Int16(littleEndian: Int16(data[offset]) | Int16(data[offset + 1]) << 8))
      offset += 2
      tracked.append(v)
      return v

    case 0x32:  // Int32 LE
      guard offset + 4 <= data.count else { return nil }
      let raw =
        UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
      let v = Int(Int32(bitPattern: raw))
      offset += 4
      tracked.append(v)
      return v

    case 0x33:  // Int64 LE
      guard offset + 8 <= data.count else { return nil }
      let raw =
        UInt64(data[offset])
        | UInt64(data[offset + 1]) << 8
        | UInt64(data[offset + 2]) << 16
        | UInt64(data[offset + 3]) << 24
        | UInt64(data[offset + 4]) << 32
        | UInt64(data[offset + 5]) << 40
        | UInt64(data[offset + 6]) << 48
        | UInt64(data[offset + 7]) << 56
      let v = Int(Int64(bitPattern: raw))
      offset += 8
      tracked.append(v)
      return v

    case 0x35:  // Float32 LE
      guard offset + 4 <= data.count else { return nil }
      let raw =
        UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
      offset += 4
      let v = Double(Float(bitPattern: raw))
      tracked.append(v)
      return v

    case 0x36:  // Float64 LE
      guard offset + 8 <= data.count else { return nil }
      let bits =
        UInt64(data[offset])
        | UInt64(data[offset + 1]) << 8
        | UInt64(data[offset + 2]) << 16
        | UInt64(data[offset + 3]) << 24
        | UInt64(data[offset + 4]) << 32
        | UInt64(data[offset + 5]) << 40
        | UInt64(data[offset + 6]) << 48
        | UInt64(data[offset + 7]) << 56
      offset += 8
      let v = Double(bitPattern: bits)
      tracked.append(v)
      return v

    case 0x40...0x60:  // Short UTF-8 string (len 0-32)
      let len = Int(tag - 0x40)
      guard offset + len <= data.count else { return nil }
      guard let str = String(data: data[offset..<offset + len], encoding: .utf8) else { return nil }
      offset += len
      tracked.append(str)
      return str

    case 0x61:  // String with 1-byte length
      guard offset < data.count else { return nil }
      let len = Int(data[offset])
      offset += 1
      guard offset + len <= data.count else { return nil }
      guard let str = String(data: data[offset..<offset + len], encoding: .utf8) else { return nil }
      offset += len
      tracked.append(str)
      return str

    case 0x62:  // String with 2-byte LE length
      guard offset + 2 <= data.count else { return nil }
      let len = Int(UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
      offset += 2
      guard offset + len <= data.count else { return nil }
      guard let str = String(data: data[offset..<offset + len], encoding: .utf8) else { return nil }
      offset += len
      tracked.append(str)
      return str

    case 0x63:  // String with 4-byte LE length
      guard offset + 4 <= data.count else { return nil }
      let len = Int(
        UInt32(data[offset])
          | UInt32(data[offset + 1]) << 8
          | UInt32(data[offset + 2]) << 16
          | UInt32(data[offset + 3]) << 24)
      offset += 4
      guard offset + len <= data.count else { return nil }
      guard let str = String(data: data[offset..<offset + len], encoding: .utf8) else { return nil }
      offset += len
      tracked.append(str)
      return str

    case 0x6F:  // Null-terminated string
      var end = offset
      while end < data.count && data[end] != 0 { end += 1 }
      guard let str = String(data: data[offset..<end], encoding: .utf8) else { return nil }
      offset = min(end + 1, data.count)
      tracked.append(str)
      return str

    case 0x70...0x90:  // Short binary data (len 0-32)
      let len = Int(tag - 0x70)
      guard offset + len <= data.count else { return nil }
      let d = Data(data[offset..<offset + len])
      offset += len
      tracked.append(d)
      return d

    case 0x91:  // Data with 1-byte length
      guard offset < data.count else { return nil }
      let len = Int(data[offset])
      offset += 1
      guard offset + len <= data.count else { return nil }
      let d = Data(data[offset..<offset + len])
      offset += len
      tracked.append(d)
      return d

    case 0x92:  // Data with 2-byte LE length
      guard offset + 2 <= data.count else { return nil }
      let len = Int(UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
      offset += 2
      guard offset + len <= data.count else { return nil }
      let d = Data(data[offset..<offset + len])
      offset += len
      tracked.append(d)
      return d

    case 0x93:  // Data with 4-byte LE length
      guard offset + 4 <= data.count else { return nil }
      let len = Int(
        UInt32(data[offset])
          | UInt32(data[offset + 1]) << 8
          | UInt32(data[offset + 2]) << 16
          | UInt32(data[offset + 3]) << 24)
      offset += 4
      guard offset + len <= data.count else { return nil }
      let d = Data(data[offset..<offset + len])
      offset += len
      tracked.append(d)
      return d

    case 0xA0...0xCF:  // Compression back-reference
      let index = Int(tag - 0xA0)
      guard index < tracked.count else { return nil }
      return tracked[index]

    case 0xD0...0xDE:  // Array with length (0-14 elements)
      let count = Int(tag - 0xD0)
      var arr: [Any] = []
      for _ in 0..<count {
        guard let v = decodeValue(data, offset: &offset, tracked: &tracked) else { return nil }
        arr.append(v)
      }
      tracked.append(arr)
      return arr

    case 0xDF:  // Terminated array
      var arr: [Any] = []
      while offset < data.count {
        if data[offset] == 0x03 {
          offset += 1
          break
        }
        guard let v = decodeValue(data, offset: &offset, tracked: &tracked) else { return nil }
        arr.append(v)
      }
      tracked.append(arr)
      return arr

    case 0xE0...0xEE:  // Dictionary with length (0-14 entries)
      let count = Int(tag - 0xE0)
      var dict: [String: Any] = [:]
      for _ in 0..<count {
        guard let key = decodeValue(data, offset: &offset, tracked: &tracked) as? String
        else { return nil }
        guard let value = decodeValue(data, offset: &offset, tracked: &tracked) else { return nil }
        dict[key] = value
      }
      tracked.append(dict)
      return dict

    case 0xEF:  // Terminated dictionary
      var dict: [String: Any] = [:]
      while offset < data.count {
        if data[offset] == 0x03 {
          offset += 1
          break
        }
        guard let key = decodeValue(data, offset: &offset, tracked: &tracked) as? String
        else { return nil }
        guard let value = decodeValue(data, offset: &offset, tracked: &tracked) else { return nil }
        dict[key] = value
      }
      tracked.append(dict)
      return dict

    default:
      return nil
    }
  }
}
