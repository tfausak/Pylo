import Foundation
import Testing

@testable import Streaming

@Suite struct RTCPTests {

  @Test func senderReportIs28Bytes() {
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0, rtpTimestamp: 0, packetsSent: 0, octetsSent: 0)
    #expect(sr.count == 28)
  }

  @Test func senderReportHeader() {
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0x1234_5678, rtpTimestamp: 0, packetsSent: 0, octetsSent: 0)
    // V=2, P=0, RC=0 → 0x80
    #expect(sr[0] == 0x80)
    // PT=200 (SR)
    #expect(sr[1] == 200)
    // Length=6 (big-endian)
    #expect(sr[2] == 0x00)
    #expect(sr[3] == 0x06)
  }

  @Test func senderReportSSRC() {
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0xDEAD_BEEF, rtpTimestamp: 0, packetsSent: 0, octetsSent: 0)
    #expect(sr[4] == 0xDE)
    #expect(sr[5] == 0xAD)
    #expect(sr[6] == 0xBE)
    #expect(sr[7] == 0xEF)
  }

  @Test func senderReportNTPTimestamp() {
    // Use a known date: 2024-01-01 00:00:00 UTC
    // Unix epoch: 1704067200
    // NTP epoch offset: 2208988800
    // NTP seconds: 1704067200 + 2208988800 = 3913056000
    let date = Date(timeIntervalSince1970: 1_704_067_200.0)
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0, rtpTimestamp: 0, packetsSent: 0, octetsSent: 0, now: date)
    let ntpSec = UInt32(3_913_056_000)
    #expect(sr[8] == UInt8((ntpSec >> 24) & 0xFF))
    #expect(sr[9] == UInt8((ntpSec >> 16) & 0xFF))
    #expect(sr[10] == UInt8((ntpSec >> 8) & 0xFF))
    #expect(sr[11] == UInt8(ntpSec & 0xFF))
    // Fractional part should be 0 for an integer timestamp
    #expect(sr[12] == 0)
    #expect(sr[13] == 0)
    #expect(sr[14] == 0)
    #expect(sr[15] == 0)
  }

  @Test func senderReportRTPTimestamp() {
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0, rtpTimestamp: 0xAABB_CCDD, packetsSent: 0, octetsSent: 0)
    #expect(sr[16] == 0xAA)
    #expect(sr[17] == 0xBB)
    #expect(sr[18] == 0xCC)
    #expect(sr[19] == 0xDD)
  }

  @Test func senderReportPacketAndOctetCounts() {
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0, rtpTimestamp: 0, packetsSent: 256, octetsSent: 0x0001_0002)
    // 256 = 0x00000100
    #expect(sr[20] == 0x00)
    #expect(sr[21] == 0x00)
    #expect(sr[22] == 0x01)
    #expect(sr[23] == 0x00)
    // 0x00010002
    #expect(sr[24] == 0x00)
    #expect(sr[25] == 0x01)
    #expect(sr[26] == 0x00)
    #expect(sr[27] == 0x02)
  }

  @Test func senderReportTruncatesLargeCounts() {
    // Int values > UInt32.max should truncate safely
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0, rtpTimestamp: 0,
      packetsSent: Int(UInt32.max) + 1, octetsSent: Int(UInt32.max) + 2)
    // UInt32.max + 1 truncates to 0
    #expect(sr[20] == 0 && sr[21] == 0 && sr[22] == 0 && sr[23] == 0)
    // UInt32.max + 2 truncates to 1
    #expect(sr[24] == 0 && sr[25] == 0 && sr[26] == 0 && sr[27] == 1)
  }

  @Test func senderReportNTPDoesNotTrapAfter2036() {
    // NTP era 1 rollover: Feb 7, 2036 06:28:16 UTC.
    // Unix timestamp = 2085978496, NTP seconds = 2085978496 + 2208988800 = 4294967296
    // This exceeds UInt32.max — must wrap to 0, not trap.
    let post2036 = Date(timeIntervalSince1970: 2_085_978_496.0 + 100)
    let sr = CameraStreamSession.buildRTCPSenderReport(
      ssrc: 0, rtpTimestamp: 0, packetsSent: 0, octetsSent: 0, now: post2036)
    // Should not crash, and NTP seconds should wrap (small value near 0)
    #expect(sr.count == 28)
    // NTP seconds field at bytes 8-11 — should be a small wrapped value, not crash
    let ntpSec = UInt32(sr[8]) << 24 | UInt32(sr[9]) << 16 | UInt32(sr[10]) << 8 | UInt32(sr[11])
    #expect(ntpSec < 1000)  // wrapped past 0, should be ~100
  }
}
