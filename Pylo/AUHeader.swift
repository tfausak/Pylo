import Foundation

// MARK: - AU Header (RFC 3640)

/// RFC 3640 AU header helpers for AAC-ELD framing used by HomeKit.
nonisolated enum AUHeader {

  /// Prepend a 4-byte RFC 3640 AU header section to raw AAC data.
  /// Layout: 2-byte AU-headers-length (0x0010 = one 16-bit AU header)
  ///       + 2-byte AU header (13-bit AU-size << 3 | AU-Index=0).
  static func add(to aacData: Data) -> Data {
    precondition(aacData.count <= 8191, "AU-size field is 13 bits; payload exceeds maximum")
    let auSize = UInt16(aacData.count)
    var header = Data(count: 4)
    header[0] = 0x00  // AU-headers-length MSB
    header[1] = 0x10  // AU-headers-length LSB = 16 bits
    header[2] = UInt8((auSize << 3) >> 8)  // AU-size upper bits
    header[3] = UInt8((auSize << 3) & 0xFF)  // AU-size lower bits + AU-Index=0
    var result = header
    result.append(aacData)
    return result
  }

  /// Strip the 4-byte RFC 3640 AU header if present, otherwise return data unchanged.
  static func strip(from payload: Data) -> Data {
    guard payload.count >= 4,
      payload[payload.startIndex] == 0x00,
      payload[payload.startIndex + 1] == 0x10
    else {
      return payload
    }
    return Data(payload[payload.startIndex + 4..<payload.endIndex])
  }
}
