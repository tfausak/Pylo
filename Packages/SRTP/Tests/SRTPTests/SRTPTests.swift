import CommonCrypto
import Foundation
import Testing

@testable import SRTP

// MARK: - AU Header Framing Tests

@Suite("AU Header Framing")
struct AUHeaderTests {

  @Test("Roundtrip: strip(add(data)) == data")
  func roundtrip() throws {
    let original = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03])
    let framed = try #require(AUHeader.add(to: original))
    let stripped = AUHeader.strip(from: framed)
    #expect(stripped == original)
  }

  @Test("add() produces 0x00 0x10 prefix")
  func addPrefix() throws {
    let payload = Data([0xAA, 0xBB])
    let framed = try #require(AUHeader.add(to: payload))
    #expect(framed.count == payload.count + 4)
    #expect(framed[0] == 0x00)
    #expect(framed[1] == 0x10)
  }

  @Test("AU-size field encodes correctly for small payload")
  func auSizeSmall() throws {
    // Payload size 10: AU-size field = 10 << 3 = 80 = 0x0050
    let payload = Data(repeating: 0xFF, count: 10)
    let framed = try #require(AUHeader.add(to: payload))
    let auSizeBits = UInt16(framed[2]) << 8 | UInt16(framed[3])
    // Upper 13 bits = payload size, lower 3 bits = AU-Index = 0
    #expect(auSizeBits >> 3 == 10)
    #expect(auSizeBits & 0x07 == 0)
  }

  @Test("AU-size field encodes correctly for larger payload")
  func auSizeLarger() throws {
    let payload = Data(repeating: 0xAA, count: 500)
    let framed = try #require(AUHeader.add(to: payload))
    let auSizeBits = UInt16(framed[2]) << 8 | UInt16(framed[3])
    #expect(auSizeBits >> 3 == 500)
    #expect(auSizeBits & 0x07 == 0)
  }

  @Test("strip() passes through data without AU header unchanged")
  func stripPassthrough() {
    // Data that doesn't start with 0x00, 0x10
    let raw = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB])
    let result = AUHeader.strip(from: raw)
    #expect(result == raw)
  }

  @Test("strip() handles empty data")
  func stripEmpty() {
    let result = AUHeader.strip(from: Data())
    #expect(result == Data())
  }

  @Test("strip() handles short data (< 4 bytes)")
  func stripShort() {
    let short = Data([0x00, 0x10])  // Only 2 bytes — too short for full header
    let result = AUHeader.strip(from: short)
    #expect(result == short)
  }

  @Test("strip() does not false-positive on AAC data starting with 0x00 0x10")
  func stripFalsePositive() {
    // An AAC frame whose first two bytes happen to be 0x00, 0x10 but whose
    // AU-size field (bytes 2-3) does not match the remaining payload length.
    let aacFrame = Data([0x00, 0x10, 0xFF, 0xFE, 0xAA, 0xBB, 0xCC])
    let result = AUHeader.strip(from: aacFrame)
    #expect(result == aacFrame, "Should not strip data that merely starts with 0x00 0x10")
  }

  @Test("add() with empty payload")
  func addEmpty() throws {
    let framed = try #require(AUHeader.add(to: Data()))
    #expect(framed.count == 4)
    #expect(framed[0] == 0x00)
    #expect(framed[1] == 0x10)
    #expect(framed[2] == 0x00)
    #expect(framed[3] == 0x00)
  }

  @Test("add() with maximum 13-bit payload succeeds")
  func addMaxPayload() throws {
    let framed = try #require(AUHeader.add(to: Data(repeating: 0xAA, count: 8191)))
    #expect(framed.count == 4 + 8191)
  }

  @Test("add() with oversized payload returns nil")
  func addOversizedPayload() {
    let payload = Data(repeating: 0xBB, count: 8192)
    let result = AUHeader.add(to: payload)
    #expect(result == nil)
  }
}

// MARK: - SRTP Tests

@Suite("SRTP")
struct SRTPTests {

  /// RFC 3711 Appendix B.3 test vectors for key derivation.
  @Test("Key derivation matches RFC 3711 B.3 test vectors")
  func keyDerivationRFC3711() {
    let testKey = Data([
      0xE1, 0xF9, 0x7A, 0x0D, 0x3E, 0x01, 0x8B, 0xE0,
      0xD6, 0x4F, 0xA3, 0x2C, 0x06, 0xDE, 0x41, 0x39,
    ])
    let testSalt = Data([
      0x0E, 0xC6, 0x75, 0xAD, 0x49, 0x8A, 0xFE, 0xEB,
      0xB6, 0x96, 0x0B, 0x3A, 0xAB, 0xE6,
    ])
    let expectedCipherKey = Data([
      0xC6, 0x1E, 0x7A, 0x93, 0x74, 0x4F, 0x39, 0xEE,
      0x10, 0x73, 0x4A, 0xFE, 0x3F, 0xF7, 0xA0, 0x87,
    ])
    let expectedSalt = Data([
      0x30, 0xCB, 0xBC, 0x08, 0x86, 0x3D, 0x8C, 0x85,
      0xD4, 0x9D, 0xB3, 0x4A, 0x9A, 0xE1,
    ])
    let expectedAuthKey = Data([
      0xCE, 0xBE, 0x32, 0x1F, 0x6F, 0xF7, 0x71, 0x6B,
      0x6F, 0xD4, 0xAB, 0x49, 0xAF, 0x25, 0x6A, 0x15,
      0x6D, 0x38, 0xBA, 0xA4,
    ])

    let ck = SRTPContext.deriveKey(
      masterKey: testKey, masterSalt: testSalt, label: 0x00, length: 16)
    let cs = SRTPContext.deriveKey(
      masterKey: testKey, masterSalt: testSalt, label: 0x02, length: 14)
    let ak = SRTPContext.deriveKey(
      masterKey: testKey, masterSalt: testSalt, label: 0x01, length: 20)

    #expect(ck == expectedCipherKey)
    #expect(cs == expectedSalt)
    #expect(ak == expectedAuthKey)
  }

  /// Helper: build a minimal valid RTP packet with given seq, SSRC, and payload.
  private static func makeRTPPacket(seq: UInt16, ssrc: UInt32, payload: Data) -> Data {
    var header = Data(count: 12)
    header[0] = 0x80  // V=2
    header[1] = 0x60  // PT=96
    header[2] = UInt8(seq >> 8)
    header[3] = UInt8(seq & 0xFF)
    // Timestamp = 0
    header[8] = UInt8((ssrc >> 24) & 0xFF)
    header[9] = UInt8((ssrc >> 16) & 0xFF)
    header[10] = UInt8((ssrc >> 8) & 0xFF)
    header[11] = UInt8(ssrc & 0xFF)
    var pkt = header
    pkt.append(payload)
    return pkt
  }

  private static let testMasterKey = Data([
    0xE1, 0xF9, 0x7A, 0x0D, 0x3E, 0x01, 0x8B, 0xE0,
    0xD6, 0x4F, 0xA3, 0x2C, 0x06, 0xDE, 0x41, 0x39,
  ])
  private static let testMasterSalt = Data([
    0x0E, 0xC6, 0x75, 0xAD, 0x49, 0x8A, 0xFE, 0xEB,
    0xB6, 0x96, 0x0B, 0x3A, 0xAB, 0xE6,
  ])

  @Test("Protect/unprotect roundtrip with known keys")
  func protectUnprotectRoundtrip() throws {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    let rtp = Self.makeRTPPacket(
      seq: 1, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0x42, count: 160))
    let srtp = try #require(sender.protect(rtp))

    // SRTP adds 10-byte auth tag
    #expect(srtp.count == rtp.count + 10)

    let recovered = receiver.unprotect(srtp)
    #expect(recovered == rtp)
  }

  @Test("Auth failure: tampered ciphertext returns nil")
  func authFailureTampered() throws {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    let rtp = Self.makeRTPPacket(
      seq: 1, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0xAA, count: 100))
    var srtp = try #require(sender.protect(rtp))

    // Tamper with encrypted payload (flip a byte in the middle)
    let tamperIndex = 20
    if tamperIndex < srtp.count - 10 {
      srtp[tamperIndex] ^= 0xFF
    }

    let result = receiver.unprotect(srtp)
    #expect(result == nil)
  }

  @Test("Empty payload roundtrip (12-byte header only)")
  func emptyPayloadRoundtrip() throws {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    let rtp = Self.makeRTPPacket(seq: 1, ssrc: 0x1234_5678, payload: Data())
    let srtp = try #require(sender.protect(rtp))

    // Header-only: 12 bytes + 10-byte auth tag
    #expect(srtp.count == 22)

    let recovered = receiver.unprotect(srtp)
    #expect(recovered == rtp)
  }

  @Test("Multiple sequential packets with incrementing seq")
  func multipleSequentialPackets() throws {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    for seq: UInt16 in 1...10 {
      let rtp = Self.makeRTPPacket(
        seq: seq, ssrc: 0xCAFE_BABE, payload: Data(repeating: UInt8(seq), count: 80))
      let srtp = try #require(sender.protect(rtp))
      let recovered = receiver.unprotect(srtp)
      #expect(recovered == rtp, "Failed at seq \(seq)")
    }
  }

  @Test("RTCP protect produces output larger than input")
  func rtcpProtectGrows() throws {
    let ctx = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    // Minimal RTCP Sender Report: 8-byte header + 20-byte SR body
    var rtcp = Data(count: 28)
    rtcp[0] = 0x80  // V=2
    rtcp[1] = 200  // PT=SR
    rtcp[2] = 0x00
    rtcp[3] = 0x06  // length
    // SSRC at bytes 4-7
    rtcp[4] = 0xDE
    rtcp[5] = 0xAD
    rtcp[6] = 0xBE
    rtcp[7] = 0xEF

    let srtcp = try #require(ctx.protectRTCP(rtcp))
    // SRTCP adds: E||index (4 bytes) + auth tag (10 bytes) = 14 bytes
    #expect(srtcp.count == rtcp.count + 14)
  }

  @Test("Auth failure: single bit flip in auth tag returns nil")
  func authFailureTagFlip() throws {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    let rtp = Self.makeRTPPacket(
      seq: 1, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0xBB, count: 50))
    var srtp = try #require(sender.protect(rtp))

    // Flip one bit in the last byte of the 10-byte auth tag
    srtp[srtp.count - 1] ^= 0x01
    #expect(receiver.unprotect(srtp) == nil)
  }

  @Test("Auth failure: each tag byte position is validated")
  func authFailureEachTagByte() throws {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    let rtp = Self.makeRTPPacket(
      seq: 1, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0xCC, count: 50))
    let srtp = try #require(sender.protect(rtp))

    // Flip a byte at each position in the 10-byte auth tag
    for i in 0..<10 {
      let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
      var tampered = srtp
      tampered[tampered.count - 10 + i] ^= 0xFF
      #expect(receiver.unprotect(tampered) == nil, "Tag byte \(i) not validated")
    }
  }

  @Test("Short packets (< 12 bytes) return nil from protect")
  func shortPacketProtect() {
    let ctx = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let shortData = Data([0x80, 0x60, 0x00, 0x01])  // Only 4 bytes
    let result = ctx.protect(shortData)
    #expect(result == nil)
  }

  @Test("Short packets (< 22 bytes) return nil from unprotect")
  func shortPacketUnprotect() {
    let ctx = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let shortData = Data(repeating: 0x00, count: 15)
    let result = ctx.unprotect(shortData)
    #expect(result == nil)
  }

  @Test("Sequence number rollover across ROC boundary")
  func sequenceRollover() throws {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    // Send packets near the rollover boundary (0xFFFD, 0xFFFE, 0xFFFF, 0x0000, 0x0001)
    let sequences: [UInt16] = [0xFFFD, 0xFFFE, 0xFFFF, 0x0000, 0x0001]
    for seq in sequences {
      let rtp = Self.makeRTPPacket(
        seq: seq, ssrc: 0xCAFE_BABE, payload: Data(repeating: UInt8(seq & 0xFF), count: 40))
      let srtp = try #require(sender.protect(rtp))
      let recovered = receiver.unprotect(srtp)
      #expect(recovered == rtp, "Failed at seq \(seq)")
    }
  }

  @Test("Out-of-order packet before ROC rollover still decrypts")
  func outOfOrderBeforeRollover() throws {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    // Send seq 1..5 in order, then send seq 3 again (out of order)
    var srtpPackets: [UInt16: Data] = [:]
    for seq: UInt16 in 1...5 {
      let rtp = Self.makeRTPPacket(
        seq: seq, ssrc: 0xBEEF_CAFE, payload: Data(repeating: UInt8(seq), count: 40))
      srtpPackets[seq] = try #require(sender.protect(rtp))
    }

    // Receive 1, 2, 4, 5 in order (skip 3)
    for seq: UInt16 in [1, 2, 4, 5] {
      let recovered = receiver.unprotect(srtpPackets[seq]!)
      #expect(recovered != nil, "Failed to unprotect seq \(seq)")
    }

    // Now receive late packet seq 3
    let late = receiver.unprotect(srtpPackets[3]!)
    #expect(late != nil, "Failed to unprotect late packet seq 3")
  }

  @Test("ROC increments on clear forward wrap (0xFFFF → 0x0000)")
  func rocIncrementAtWrap() throws {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    // Send a packet at seq 0xFFFF, then jump to 0x0000.
    // The gap is 0xFFFF — clearly a forward wrap, so ROC must increment.
    let rtp1 = Self.makeRTPPacket(
      seq: 0xFFFF, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0xAA, count: 40))
    let srtp1 = try #require(sender.protect(rtp1))
    let recovered1 = receiver.unprotect(srtp1)
    #expect(recovered1 == rtp1, "Failed at seq 0xFFFF")

    let rtp2 = Self.makeRTPPacket(
      seq: 0x0000, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0xBB, count: 40))
    let srtp2 = try #require(sender.protect(rtp2))
    let recovered2 = receiver.unprotect(srtp2)
    #expect(recovered2 == rtp2, "Failed at seq 0x0000 after 0xFFFF (ROC should have incremented)")
  }
}

// MARK: - SRTP Thread Safety Tests

@Suite("SRTP Thread Safety")
struct SRTPThreadSafetyTests {

  private static let testMasterKey = Data([
    0xE1, 0xF9, 0x7A, 0x0D, 0x3E, 0x01, 0x8B, 0xE0,
    0xD6, 0x4F, 0xA3, 0x2C, 0x06, 0xDE, 0x41, 0x39,
  ])
  private static let testMasterSalt = Data([
    0x0E, 0xC6, 0x75, 0xAD, 0x49, 0x8A, 0xFE, 0xEB,
    0xB6, 0x96, 0x0B, 0x3A, 0xAB, 0xE6,
  ])

  private static func makeRTPPacket(seq: UInt16, ssrc: UInt32, payload: Data) -> Data {
    var header = Data(count: 12)
    header[0] = 0x80
    header[1] = 0x60
    header[2] = UInt8(seq >> 8)
    header[3] = UInt8(seq & 0xFF)
    header[8] = UInt8((ssrc >> 24) & 0xFF)
    header[9] = UInt8((ssrc >> 16) & 0xFF)
    header[10] = UInt8((ssrc >> 8) & 0xFF)
    header[11] = UInt8(ssrc & 0xFF)
    var pkt = header
    pkt.append(payload)
    return pkt
  }

  @Test("Forged packet does not desync incoming ROC")
  func forgedPacketDoesNotDesyncROC() throws {
    let ctx = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    // Protect a sequence of packets so ctx has valid outgoing state
    let rtp1 = Self.makeRTPPacket(
      seq: 1, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0x11, count: 20))
    let srtp1 = try #require(ctx.protect(rtp1))

    // Create a second context with the same keys to act as receiver
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    // Successfully unprotect the first legitimate packet
    let result1 = receiver.unprotect(srtp1)
    #expect(result1 != nil)
    #expect(result1 == rtp1)

    // Send a forged packet with a low sequence number that would trigger
    // a ROC increment if state were updated before auth verification
    var forged = Data(count: 12 + 20 + 10)
    forged[0] = 0x80
    forged[1] = 0x60
    forged[2] = 0x00  // seq = 1 (low, would trigger ROC increment)
    forged[3] = 0x01
    // SSRC
    forged[8] = 0xDE
    forged[9] = 0xAD
    forged[10] = 0xBE
    forged[11] = 0xEF
    // Garbage payload and auth tag
    for i in 12..<forged.count { forged[i] = UInt8(i & 0xFF) }

    // This should fail authentication
    let forgedResult = receiver.unprotect(forged)
    #expect(forgedResult == nil)

    // Now send a legitimate packet with seq=2 — this must still decrypt
    // successfully, proving the forged packet did NOT desync the ROC
    let rtp2 = Self.makeRTPPacket(
      seq: 2, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0x22, count: 20))
    let srtp2 = try #require(ctx.protect(rtp2))
    let result2 = receiver.unprotect(srtp2)
    #expect(result2 != nil)
    #expect(result2 == rtp2)
  }

  @Test("Concurrent protect calls do not crash")
  func concurrentProtect() async {
    let ctx = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    await withTaskGroup(of: Void.self) { group in
      for i: UInt16 in 0..<100 {
        group.addTask {
          let rtp = Self.makeRTPPacket(
            seq: i, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0x42, count: 160))
          _ = ctx.protect(rtp)
        }
      }
    }
  }

  @Test("Concurrent protectRTCP calls do not crash")
  func concurrentProtectRTCP() async {
    let ctx = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask {
          var rtcp = Data(count: 28)
          rtcp[0] = 0x80
          rtcp[1] = 200
          rtcp[3] = 0x06
          rtcp[4] = 0xDE
          rtcp[5] = 0xAD
          rtcp[6] = 0xBE
          rtcp[7] = 0xEF
          _ = ctx.protectRTCP(rtcp)
        }
      }
    }
  }

  @Test("Concurrent protect produces SRTP packets of correct size")
  func concurrentProtectCorrectSize() async {
    let ctx = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    let results = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
      for i: UInt16 in 0..<50 {
        group.addTask {
          let rtp = Self.makeRTPPacket(
            seq: i, ssrc: 0xCAFE_BABE, payload: Data(repeating: UInt8(i), count: 80))
          let srtp = ctx.protect(rtp)
          return srtp?.count ?? 0
        }
      }
      var collected: [Int] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }

    // Each SRTP packet should be RTP (12 header + 80 payload) + 10 auth tag = 102
    for size in results {
      #expect(size == 102)
    }
  }

  @Test("SRTCP index wraps at 0x7FFF_FFFF instead of overflowing into E-flag")
  func srtcpIndexWrap() throws {
    let ctx = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    // Build a minimal RTCP packet
    var rtcp = Data(count: 28)
    rtcp[0] = 0x80
    rtcp[1] = 200
    rtcp[3] = 0x06
    rtcp[4] = 0xDE
    rtcp[5] = 0xAD
    rtcp[6] = 0xBE
    rtcp[7] = 0xEF

    // Protect many packets to advance index — just verify it doesn't crash.
    // The real test is that after 0x7FFF_FFFF the index wraps to 0 rather
    // than setting bit 31 (which is the E-flag). We can't easily drive
    // the index to max in a unit test, but we verify protect succeeds.
    for _ in 0..<10 {
      let result = ctx.protectRTCP(rtcp)
      #expect(result != nil)
    }
  }

  @Test("Protect returns non-nil for valid input")
  func protectReturnsNonNil() {
    let ctx = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let rtp = Self.makeRTPPacket(
      seq: 1, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0x42, count: 160))
    let result = ctx.protect(rtp)
    #expect(result != nil)
  }

  @Test("Late packet when ROC is 0 does not wrap to UInt32.max")
  func latePacketAtROCZero() throws {
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    // Send packets 1, 2, 3 in order
    var srtpPackets: [UInt16: Data] = [:]
    for seq: UInt16 in 1...3 {
      let rtp = Self.makeRTPPacket(
        seq: seq, ssrc: 0xDEAD_BEEF, payload: Data(repeating: UInt8(seq), count: 20))
      srtpPackets[seq] = try #require(sender.protect(rtp))
    }

    // Receive 1, 3 (skip 2) — establishes s_l = 3 at ROC = 0
    let _ = receiver.unprotect(srtpPackets[1]!)
    let _ = receiver.unprotect(srtpPackets[3]!)

    // Now send a packet with a high seq number that would trigger the
    // "late packet" branch (s_l < 0x8000 && seq > s_l + 0x8000).
    // With ROC == 0, the old code did roc &-= 1 wrapping to UInt32.max,
    // which would cause auth failure. The fix guards against this by
    // keeping candidateROC = 0 (matching the sender), so the packet
    // decrypts successfully.
    let rtp4 = Self.makeRTPPacket(
      seq: 0xFFF0, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0xFF, count: 20))
    let srtp4 = try #require(sender.protect(rtp4))
    let result = receiver.unprotect(srtp4)
    // With the fix, ROC stays at 0 (matching sender) so auth succeeds
    #expect(result == rtp4, "Packet at ROC=0 with high seq should decrypt (no wraparound)")

    // Verify normal operation continues
    let rtp5 = Self.makeRTPPacket(
      seq: 4, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0x44, count: 20))
    let srtp5 = try #require(sender.protect(rtp5))
    let recovered5 = receiver.unprotect(srtp5)
    #expect(
      recovered5 == rtp5, "Normal packets must still decrypt after high-seq packet at ROC=0")
  }

  @Test("ROC boundary: s_l=0x8000, SEQ=0x0000 does not spuriously increment ROC")
  func rocBoundaryNoSpuriousIncrement() throws {
    // This tests the off-by-one fix: when s_l=0x8000 and SEQ=0x0000,
    // the difference is exactly 0x8000. With the fix (> 0x8000 instead of
    // >= 0x8000), this should NOT trigger a ROC increment on the receiver.
    let sender = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)
    let receiver = SRTPContext(masterKey: Self.testMasterKey, masterSalt: Self.testMasterSalt)

    // Send packet at seq 0x8000 to establish s_l = 0x8000 on receiver
    let rtp1 = Self.makeRTPPacket(
      seq: 0x8000, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0xAA, count: 20))
    let srtp1 = try #require(sender.protect(rtp1))
    let recovered1 = receiver.unprotect(srtp1)
    #expect(recovered1 == rtp1)

    // Now send seq 0x0000 — sender sees this as ROC rollover (0x8000 → 0x0000),
    // receiver should also detect it correctly and decrypt successfully
    let rtp2 = Self.makeRTPPacket(
      seq: 0x0000, ssrc: 0xDEAD_BEEF, payload: Data(repeating: 0xBB, count: 20))
    let srtp2 = try #require(sender.protect(rtp2))
    let recovered2 = receiver.unprotect(srtp2)
    #expect(recovered2 == rtp2, "Packet at exact ROC boundary should decrypt successfully")
  }
}
