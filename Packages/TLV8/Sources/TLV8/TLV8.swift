import Foundation
import os

private let logSubsystem = "me.fausak.taylor.Pylo"

// MARK: - TLV8 Codec
// HomeKit Accessory Protocol uses TLV8 (Type-Length-Value, 8-bit) encoding
// for pairing data exchange. Values longer than 255 bytes are split across
// consecutive TLV items with the same type.

public enum TLV8 {

  // MARK: - HAP TLV Types (Table 5-6 in HAP R2 spec)

  public enum Tag: UInt8 {
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

  public enum ErrorCode: UInt8 {
    case unknown = 0x01
    case authentication = 0x02
    case backoff = 0x03
    case maxPeers = 0x04
    case maxTries = 0x05
    case unavailable = 0x06
    case busy = 0x07
  }

  // MARK: - Decode

  private static let logger = Logger(subsystem: logSubsystem, category: "TLV8")

  /// Decodes a TLV8-encoded Data blob into an ordered list of (tag, value) pairs.
  /// Consecutive items with the same tag are coalesced (fragmented values).
  ///
  /// Uses fail-closed semantics: returns `[]` if any part of the blob is
  /// truncated, even if earlier TLVs parsed successfully. This prevents
  /// partial parses from being mistaken for complete messages in a security
  /// protocol. Truncation is logged as a warning to aid debugging.
  ///
  /// Returns tuples rather than a named struct because call sites
  /// universally destructure as `for (tag, value) in pairs`, which
  /// is more ergonomic with tuples than with a struct.
  public static func decode(_ data: Data) -> [(UInt8, Data)] {
    var results: [(UInt8, Data)] = []
    var offset = data.startIndex

    while offset < data.endIndex {
      guard offset + 2 <= data.endIndex else {
        logger.warning(
          "TLV8 decode: truncated header at offset \(data.startIndex.distance(to: offset)) of \(data.count) bytes"
        )
        return []
      }
      let type = data[offset]
      let length = Int(data[offset + 1])
      offset += 2

      guard offset + length <= data.endIndex else {
        logger.warning(
          "TLV8 decode: truncated value for tag 0x\(String(type, radix: 16)) at offset \(data.startIndex.distance(to: offset) - 2), declared \(length) bytes but only \(data.endIndex - offset) remain"
        )
        return []
      }
      let value = data[offset..<offset + length]
      offset += length

      // Coalesce consecutive fragments with the same type (but never separators).
      // Append in place to avoid O(n²) copies across fragments.
      if !results.isEmpty, results[results.count - 1].0 == type,
        type != Tag.separator.rawValue
      {
        results[results.count - 1].1.append(contentsOf: value)
      } else {
        results.append((type, Data(value)))
      }
    }

    return results
  }

  /// Convenience: decode a single-record TLV8 blob as a dictionary keyed by Tag.
  /// Only suitable for messages that contain a single logical record (no separators).
  /// Returns an empty dictionary if the blob contains separator tags (use
  /// `decodeRecords(_:)` for multi-record TLV8).
  ///
  /// Tags not in the ``Tag`` enum are silently dropped. This is intentional:
  /// the dictionary decode is used exclusively for pairing exchanges where
  /// the tag set is fixed by the HAP spec. Unknown tags in that context
  /// indicate either a newer spec revision (which we can't handle anyway)
  /// or malformed data. Use the raw `[(UInt8, Data)]` overload if you need
  /// to preserve all tags.
  public static func decode(_ data: Data) -> [Tag: Data] {
    let pairs: [(UInt8, Data)] = decode(data)
    var dict: [Tag: Data] = [:]
    for (rawTag, value) in pairs {
      if rawTag == Tag.separator.rawValue {
        // Separator in a single-record decode — reject to prevent tag shadowing.
        return [:]
      }
      if let tag = Tag(rawValue: rawTag) {
        dict[tag] = value
      }
    }
    return dict
  }

  /// Decode a multi-record TLV8 blob into an array of dictionaries.
  /// Records are delimited by separator TLVs (0xFF). Each dictionary
  /// represents one logical record.
  public static func decodeRecords(_ data: Data) -> [[Tag: Data]] {
    let pairs: [(UInt8, Data)] = decode(data)
    var records: [[Tag: Data]] = [[:]]
    for (rawTag, value) in pairs {
      if rawTag == Tag.separator.rawValue {
        records.append([:])
      } else if let tag = Tag(rawValue: rawTag) {
        records[records.count - 1][tag] = value
      }
    }
    // Strip empty records caused by leading/trailing separators.
    // Interior empty records (from consecutive separators) are preserved,
    // as they may carry semantic meaning in some HAP contexts.
    while records.first?.isEmpty == true {
      records.removeFirst()
    }
    while records.last?.isEmpty == true {
      records.removeLast()
    }
    return records
  }

  // MARK: - Encode

  /// Encodes a list of (tag, value) pairs into TLV8 Data.
  /// Values longer than 255 bytes are automatically fragmented.
  public static func encode(_ items: [(Tag, Data)]) -> Data {
    var result = Data()

    for (tag, value) in items {
      if tag == .separator {
        // Separators must always be empty (FF 00). Discard any data payload.
        if !value.isEmpty {
          logger.warning(
            "Non-empty separator value (\(value.count)B) discarded — encoding as FF 00")
        }
        result.append(Tag.separator.rawValue)
        result.append(0)
        continue
      }

      // Zero-length non-separator TLVs are valid in TLV8 encoding.
      // The chunking loop below would produce no iterations for empty data,
      // so we handle it explicitly here.
      if value.isEmpty {
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
  public static func encode(_ tag: Tag, _ value: Data) -> Data {
    encode([(tag, value)])
  }

  /// Convenience: encode a single (tag, byte) pair.
  public static func encode(_ tag: Tag, _ byte: UInt8) -> Data {
    encode([(tag, Data([byte]))])
  }

  // MARK: - Raw-Tag Builder (for camera / non-pairing TLV8)

  /// Builder for constructing TLV8 blobs with raw UInt8 tags.
  public struct Builder: Sendable {
    public private(set) var data = Data()

    public init() {}

    /// Closure-based initializer to reduce `var`/`build()` boilerplate.
    public init(_ configure: (inout Builder) -> Void) {
      self.init()
      configure(&self)
    }

    public mutating func add(_ tag: UInt8, _ value: Data) {
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

    public mutating func add(_ tag: UInt8, byte: UInt8) {
      add(tag, Data([byte]))
    }

    public mutating func add(_ tag: UInt8, uint16: UInt16) {
      withUnsafeBytes(of: uint16.littleEndian) { add(tag, Data($0)) }
    }

    public mutating func add(_ tag: UInt8, uint32: UInt32) {
      withUnsafeBytes(of: uint32.littleEndian) { add(tag, Data($0)) }
    }

    public mutating func add(_ tag: UInt8, uint64: UInt64) {
      withUnsafeBytes(of: uint64.littleEndian) { add(tag, Data($0)) }
    }

    public mutating func add(_ tag: UInt8, tlv: Builder) {
      add(tag, tlv.data)
    }

    /// Insert a camera configuration list-entry delimiter (`[0x00, 0x00]`).
    /// Used between entries in HAP camera TLV8 lists (video codec configs,
    /// audio codec configs, etc.) — NOT the same as the pairing record
    /// separator (`Tag.separator` / `0xFF`), which delimits multi-record
    /// TLV8 blobs in pairing exchanges.
    public mutating func addDelimiter() {
      data.append(0x00)
      data.append(0x00)
    }

    /// Add a list of single-byte values under the same tag, with `00 00` delimiters between entries.
    public mutating func addList(_ tag: UInt8, bytes: [UInt8]) {
      for (index, byte) in bytes.enumerated() {
        if index > 0 { addDelimiter() }
        add(tag, byte: byte)
      }
    }

    /// Add a list of nested TLV builders under the same tag, with `00 00` delimiters between entries.
    public mutating func addList(_ tag: UInt8, tlvs: [Builder]) {
      for (index, tlv) in tlvs.enumerated() {
        if index > 0 { addDelimiter() }
        add(tag, tlv: tlv)
      }
    }

    // MARK: Tag-typed overloads

    public mutating func add(_ tag: Tag, _ value: Data) { add(tag.rawValue, value) }
    public mutating func add(_ tag: Tag, byte: UInt8) { add(tag.rawValue, byte: byte) }
    public mutating func add(_ tag: Tag, uint16: UInt16) { add(tag.rawValue, uint16: uint16) }
    public mutating func add(_ tag: Tag, uint32: UInt32) { add(tag.rawValue, uint32: uint32) }
    public mutating func add(_ tag: Tag, uint64: UInt64) { add(tag.rawValue, uint64: uint64) }
    public mutating func add(_ tag: Tag, tlv: Builder) { add(tag.rawValue, tlv: tlv) }

    public func build() -> Data { data }
    public func base64() -> String { data.base64EncodedString() }
  }
}
