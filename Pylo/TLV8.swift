import Foundation

// MARK: - TLV8 Codec
// HomeKit Accessory Protocol uses TLV8 (Type-Length-Value, 8-bit) encoding
// for pairing data exchange. Values longer than 255 bytes are split across
// consecutive TLV items with the same type.

enum TLV8 {

  // MARK: - HAP TLV Types (Table 5-6 in HAP R2 spec)

  enum Tag: UInt8 {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case retryDelay = 0x08
    case certificate = 0x09
    case signature = 0x0A
    case permissions = 0x0B
    case fragmentData = 0x0C
    case fragmentLast = 0x0D
    case flags = 0x13
    case separator = 0xFF
  }

  // MARK: - Error Codes (Table 5-5 in HAP R2 spec)

  enum ErrorCode: UInt8 {
    case unknown = 0x01
    case authentication = 0x02
    case backoff = 0x03
    case maxPeers = 0x04
    case maxTries = 0x05
    case unavailable = 0x06
    case busy = 0x07
  }

  // MARK: - Decode

  /// Decodes a TLV8-encoded Data blob into an ordered list of (tag, value) pairs.
  /// Consecutive items with the same tag are coalesced (fragmented values).
  static func decode(_ data: Data) -> [(UInt8, Data)] {
    var results: [(UInt8, Data)] = []
    var offset = data.startIndex

    while offset < data.endIndex {
      guard offset + 2 <= data.endIndex else { break }
      let type = data[offset]
      let length = Int(data[offset + 1])
      offset += 2

      guard offset + length <= data.endIndex else { break }
      let value = data[offset..<offset + length]
      offset += length

      // Coalesce consecutive fragments with the same type
      if let last = results.last, last.0 == type {
        var combined = last.1
        combined.append(contentsOf: value)
        results[results.count - 1] = (type, combined)
      } else {
        results.append((type, Data(value)))
      }
    }

    return results
  }

  /// Convenience: decode and return as a dictionary keyed by Tag.
  /// If duplicate tags exist (separated by a separator), only the last value is kept.
  static func decode(_ data: Data) -> [Tag: Data] {
    let pairs: [(UInt8, Data)] = decode(data)
    var dict: [Tag: Data] = [:]
    for (rawTag, value) in pairs {
      if let tag = Tag(rawValue: rawTag) {
        dict[tag] = value
      }
    }
    return dict
  }

  // MARK: - Encode

  /// Encodes a list of (tag, value) pairs into TLV8 Data.
  /// Values longer than 255 bytes are automatically fragmented.
  static func encode(_ items: [(Tag, Data)]) -> Data {
    var result = Data()

    for (tag, value) in items {
      if value.isEmpty {
        // Zero-length TLV (used for separators)
        result.append(tag.rawValue)
        result.append(0)
        continue
      }

      var offset = value.startIndex
      while offset < value.endIndex {
        let chunkSize = min(255, value.endIndex - offset)
        result.append(tag.rawValue)
        result.append(UInt8(chunkSize))
        result.append(contentsOf: value[offset..<offset + chunkSize])
        offset += chunkSize
      }
    }

    return result
  }

  /// Convenience: encode a single (tag, value) pair.
  static func encode(_ tag: Tag, _ value: Data) -> Data {
    encode([(tag, value)])
  }

  /// Convenience: encode a single (tag, byte) pair.
  static func encode(_ tag: Tag, _ byte: UInt8) -> Data {
    encode([(tag, Data([byte]))])
  }

  // MARK: - Raw-Tag Builder (for camera / non-pairing TLV8)

  /// Builder for constructing TLV8 blobs with raw UInt8 tags.
  struct Builder {
    private(set) var data = Data()

    mutating func add(_ tag: UInt8, _ value: Data) {
      var offset = value.startIndex
      if value.isEmpty {
        data.append(tag)
        data.append(0)
      } else {
        while offset < value.endIndex {
          let chunkSize = min(255, value.endIndex - offset)
          data.append(tag)
          data.append(UInt8(chunkSize))
          data.append(contentsOf: value[offset..<offset + chunkSize])
          offset += chunkSize
        }
      }
    }

    mutating func add(_ tag: UInt8, byte: UInt8) {
      add(tag, Data([byte]))
    }

    mutating func add(_ tag: UInt8, uint16: UInt16) {
      withUnsafeBytes(of: uint16.littleEndian) { add(tag, Data($0)) }
    }

    mutating func add(_ tag: UInt8, uint32: UInt32) {
      withUnsafeBytes(of: uint32.littleEndian) { add(tag, Data($0)) }
    }

    mutating func add(_ tag: UInt8, tlv: Builder) {
      add(tag, tlv.data)
    }

    func build() -> Data { data }
    func base64() -> String { data.base64EncodedString() }
  }
}
