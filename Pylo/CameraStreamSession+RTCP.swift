import Foundation

// MARK: - RTCP Sender Report Builder

extension CameraStreamSession {

  /// Builds a 28-byte RTCP Sender Report (RFC 3550 §6.4.1).
  nonisolated static func buildRTCPSenderReport(
    ssrc: UInt32,
    rtpTimestamp: UInt32,
    packetsSent: Int,
    octetsSent: Int,
    now: Date = Date()
  ) -> Data {
    var sr = Data(count: 28)
    // Header: V=2, P=0, RC=0, PT=200 (SR), length=6
    sr[0] = 0x80
    sr[1] = 200
    sr[2] = 0x00
    sr[3] = 0x06
    // SSRC
    sr[4] = UInt8((ssrc >> 24) & 0xFF)
    sr[5] = UInt8((ssrc >> 16) & 0xFF)
    sr[6] = UInt8((ssrc >> 8) & 0xFF)
    sr[7] = UInt8(ssrc & 0xFF)
    // NTP timestamp (seconds since 1900-01-01)
    let ntpEpochOffset: TimeInterval = 2_208_988_800
    let ntpTime = now.timeIntervalSince1970 + ntpEpochOffset
    let ntpSec = UInt32(ntpTime)
    let ntpFrac = UInt32((ntpTime - Double(ntpSec)) * 4_294_967_296.0)
    sr[8] = UInt8((ntpSec >> 24) & 0xFF)
    sr[9] = UInt8((ntpSec >> 16) & 0xFF)
    sr[10] = UInt8((ntpSec >> 8) & 0xFF)
    sr[11] = UInt8(ntpSec & 0xFF)
    sr[12] = UInt8((ntpFrac >> 24) & 0xFF)
    sr[13] = UInt8((ntpFrac >> 16) & 0xFF)
    sr[14] = UInt8((ntpFrac >> 8) & 0xFF)
    sr[15] = UInt8(ntpFrac & 0xFF)
    // RTP timestamp
    sr[16] = UInt8((rtpTimestamp >> 24) & 0xFF)
    sr[17] = UInt8((rtpTimestamp >> 16) & 0xFF)
    sr[18] = UInt8((rtpTimestamp >> 8) & 0xFF)
    sr[19] = UInt8(rtpTimestamp & 0xFF)
    // Sender's packet count
    let pc = UInt32(truncatingIfNeeded: packetsSent)
    sr[20] = UInt8((pc >> 24) & 0xFF)
    sr[21] = UInt8((pc >> 16) & 0xFF)
    sr[22] = UInt8((pc >> 8) & 0xFF)
    sr[23] = UInt8(pc & 0xFF)
    // Sender's octet count
    let oc = UInt32(truncatingIfNeeded: octetsSent)
    sr[24] = UInt8((oc >> 24) & 0xFF)
    sr[25] = UInt8((oc >> 16) & 0xFF)
    sr[26] = UInt8((oc >> 8) & 0xFF)
    sr[27] = UInt8(oc & 0xFF)
    return sr
  }
}
