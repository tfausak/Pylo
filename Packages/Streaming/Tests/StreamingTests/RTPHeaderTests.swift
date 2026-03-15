import Foundation
import Testing

@testable import Streaming

@Suite struct RTPHeaderTests {

  @Test func headerIs12Bytes() {
    var buf = Data()
    CameraStreamSession.writeRTPHeader(
      into: &buf, marker: false, payloadType: 99,
      sequenceNumber: 0, timestamp: 0, ssrc: 0, payloadSize: 0)
    #expect(buf.count == 12)
  }

  @Test func versionBits() {
    var buf = Data()
    CameraStreamSession.writeRTPHeader(
      into: &buf, marker: false, payloadType: 99,
      sequenceNumber: 0, timestamp: 0, ssrc: 0, payloadSize: 0)
    // V=2, P=0, X=0, CC=0 → 0x80
    #expect(buf[0] == 0x80)
  }

  @Test func markerBitSet() {
    var buf = Data()
    CameraStreamSession.writeRTPHeader(
      into: &buf, marker: true, payloadType: 99,
      sequenceNumber: 0, timestamp: 0, ssrc: 0, payloadSize: 0)
    #expect(buf[1] & 0x80 == 0x80)  // M=1
    #expect(buf[1] & 0x7F == 99)  // PT=99
  }

  @Test func markerBitClear() {
    var buf = Data()
    CameraStreamSession.writeRTPHeader(
      into: &buf, marker: false, payloadType: 110,
      sequenceNumber: 0, timestamp: 0, ssrc: 0, payloadSize: 0)
    #expect(buf[1] & 0x80 == 0x00)  // M=0
    #expect(buf[1] & 0x7F == 110)  // PT=110
  }

  @Test func sequenceNumberBigEndian() {
    var buf = Data()
    CameraStreamSession.writeRTPHeader(
      into: &buf, marker: false, payloadType: 99,
      sequenceNumber: 0x0102, timestamp: 0, ssrc: 0, payloadSize: 0)
    #expect(buf[2] == 0x01)
    #expect(buf[3] == 0x02)
  }

  @Test func timestampBigEndian() {
    var buf = Data()
    CameraStreamSession.writeRTPHeader(
      into: &buf, marker: false, payloadType: 99,
      sequenceNumber: 0, timestamp: 0xAABB_CCDD, ssrc: 0, payloadSize: 0)
    #expect(buf[4] == 0xAA)
    #expect(buf[5] == 0xBB)
    #expect(buf[6] == 0xCC)
    #expect(buf[7] == 0xDD)
  }

  @Test func ssrcBigEndian() {
    var buf = Data()
    CameraStreamSession.writeRTPHeader(
      into: &buf, marker: false, payloadType: 99,
      sequenceNumber: 0, timestamp: 0, ssrc: 0x1234_5678, payloadSize: 0)
    #expect(buf[8] == 0x12)
    #expect(buf[9] == 0x34)
    #expect(buf[10] == 0x56)
    #expect(buf[11] == 0x78)
  }

  @Test func bufferResetsOnEachCall() {
    var buf = Data([0xFF, 0xFF, 0xFF])
    CameraStreamSession.writeRTPHeader(
      into: &buf, marker: false, payloadType: 99,
      sequenceNumber: 0, timestamp: 0, ssrc: 0, payloadSize: 0)
    // Buffer should be exactly 12 bytes (old contents cleared)
    #expect(buf.count == 12)
    #expect(buf[0] == 0x80)
  }
}
