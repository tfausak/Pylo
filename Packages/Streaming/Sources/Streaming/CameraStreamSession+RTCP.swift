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
    // NTP timestamp (seconds since 1900-01-01).
    // Uses truncating conversion so NTP era 1 rollover (Feb 2036) wraps
    // instead of trapping, matching RFC 4330 §3 behavior.
    let ntpEpochOffset: TimeInterval = 2_208_988_800
    let ntpTime = now.timeIntervalSince1970 + ntpEpochOffset
    let ntpSec = UInt32(truncatingIfNeeded: Int64(ntpTime))
    let ntpFrac = UInt32((ntpTime - ntpTime.rounded(.down)) * 4_294_967_296.0)
    sr.appendBigEndian(ntpSec)
    sr.appendBigEndian(ntpFrac)
    sr.appendBigEndian(rtpTimestamp)
    sr.appendBigEndian(UInt32(truncatingIfNeeded: packetsSent))
    sr.appendBigEndian(UInt32(truncatingIfNeeded: octetsSent))
    return sr
  }
}

extension Data {
  mutating func appendBigEndian(_ value: UInt16) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }

  mutating func appendBigEndian(_ value: UInt32) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}
