import Foundation

// MARK: - RTCP Sender Report Builder

extension CameraStreamSession {

  /// Builds a 28-byte RTCP Sender Report (RFC 3550 §6.4.1).
  /// Note: RFC 3550 §6.1 requires compound RTCP (SR + SDES with CNAME), but
  /// HomeKit implementations tolerate SR-only packets, and SRTCP does not
  /// require CNAME. Omitting SDES keeps the packet minimal.
  public nonisolated static func buildRTCPSenderReport(
    ssrc: UInt32,
    rtpTimestamp: UInt32,
    packetsSent: Int,
    octetsSent: Int,
    now: Date = Date()
  ) -> Data {
    var sr = Data(capacity: 28)
    // Header: V=2, P=0, RC=0, PT=200 (SR), length=6 (in 32-bit words minus one)
    sr.appendBigEndian(UInt32(0x80C8_0006))
    sr.appendBigEndian(ssrc)
    // NTP timestamp (seconds since 1900-01-01)
    let ntpEpochOffset: TimeInterval = 2_208_988_800
    let ntpTime = now.timeIntervalSince1970 + ntpEpochOffset
    sr.appendBigEndian(UInt32(ntpTime))
    sr.appendBigEndian(UInt32((ntpTime - Double(UInt32(ntpTime))) * 4_294_967_296.0))
    sr.appendBigEndian(rtpTimestamp)
    sr.appendBigEndian(UInt32(truncatingIfNeeded: packetsSent))
    sr.appendBigEndian(UInt32(truncatingIfNeeded: octetsSent))
    return sr
  }
}

extension Data {
  mutating func appendBigEndian(_ value: UInt32) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}
