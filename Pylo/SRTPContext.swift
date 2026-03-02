import CommonCrypto
import Foundation
import os

// MARK: - SRTP Context

/// Minimal SRTP implementation using AES-128-ICM + HMAC-SHA1-80.
/// Handles key derivation and per-packet encryption/authentication per RFC 3711.
nonisolated final class SRTPContext {

  private let masterKey: Data  // 16 bytes
  private let masterSalt: Data  // 14 bytes

  // Derived SRTP session keys
  private let sessionKey: Data  // 16 bytes — AES encryption key
  private let sessionSalt: Data  // 14 bytes — IV/counter salt
  private let sessionAuthKey: Data  // 20 bytes — HMAC-SHA1 key

  // Derived SRTCP session keys (labels 0x03, 0x04, 0x05)
  private let srtcpKey: Data
  private let srtcpSalt: Data
  private let srtcpAuthKey: Data

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "SRTP")

  // Mutable state protected by a lock to prevent data races when
  // protect/unprotect are called from concurrent threads.
  private struct State {
    var rolloverCounter: UInt32 = 0
    var lastSequenceNumber: UInt16 = 0
    var packetCount: Int = 0
    var srtcpIndex: UInt32 = 0
    // Incoming (receive) direction ROC tracking — separate from outgoing
    var incomingROC: UInt32 = 0
    var incomingLastSeq: UInt16 = 0
    var incomingInitialized: Bool = false
  }
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(masterKey: Data, masterSalt: Data) {
    self.masterKey = masterKey
    self.masterSalt = masterSalt

    // Derive SRTP session keys via AES-CM PRF (RFC 3711 §4.3.1)
    self.sessionKey = Self.deriveKey(
      masterKey: masterKey, masterSalt: masterSalt, label: 0x00, length: 16)
    self.sessionSalt = Self.deriveKey(
      masterKey: masterKey, masterSalt: masterSalt, label: 0x02, length: 14)
    self.sessionAuthKey = Self.deriveKey(
      masterKey: masterKey, masterSalt: masterSalt, label: 0x01, length: 20)

    // Derive SRTCP session keys (RFC 3711 §4.3.1, labels 0x03-0x05)
    self.srtcpKey = Self.deriveKey(
      masterKey: masterKey, masterSalt: masterSalt, label: 0x03, length: 16)
    self.srtcpSalt = Self.deriveKey(
      masterKey: masterKey, masterSalt: masterSalt, label: 0x05, length: 14)
    self.srtcpAuthKey = Self.deriveKey(
      masterKey: masterKey, masterSalt: masterSalt, label: 0x04, length: 20)

    logger.debug(
      "SRTP keys derived (master=\(masterKey.count)B, session=\(self.sessionKey.count)B)")

    // Self-test key derivation against RFC 3711 Appendix B.3 (once)
    _ = Self.selfTestResult
  }

  /// Run the self-test exactly once across all SRTPContext instances.
  private static let selfTestResult: Void = { runSelfTest() }()

  /// Verify key derivation against RFC 3711 Appendix B.3 test vectors.
  private static func runSelfTest() {
    let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "SRTP")
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

    let ck = deriveKey(masterKey: testKey, masterSalt: testSalt, label: 0x00, length: 16)
    let cs = deriveKey(masterKey: testKey, masterSalt: testSalt, label: 0x02, length: 14)
    let ak = deriveKey(masterKey: testKey, masterSalt: testSalt, label: 0x01, length: 20)

    let pass = (ck == expectedCipherKey && cs == expectedSalt && ak == expectedAuthKey)
    logger.info("SRTP self-test: \(pass ? "PASS" : "FAIL")")
    if !pass {
      logger.error(
        "SRTP self-test FAILED! cipher=\(ck == expectedCipherKey) salt=\(cs == expectedSalt) auth=\(ak == expectedAuthKey)"
      )
      logger.error("  Got cipher: \(ck.map { String(format: "%02x", $0) }.joined())")
      logger.error("  Expected:   \(expectedCipherKey.map { String(format: "%02x", $0) }.joined())")
    }
  }

  /// Encrypt and authenticate an RTP packet in place, returning the SRTP packet.
  /// Returns nil if encryption fails (caller should skip sending).
  func protect(_ rtpPacket: Data) -> Data? {
    guard rtpPacket.count >= 12 else { return nil }

    let header = Data(rtpPacket[rtpPacket.startIndex..<rtpPacket.startIndex + 12])
    let payload = Data(rtpPacket[rtpPacket.startIndex + 12..<rtpPacket.endIndex])

    // Extract SSRC and sequence number from header
    let ssrc =
      UInt32(header[header.startIndex + 8]) << 24 | UInt32(header[header.startIndex + 9]) << 16
      | UInt32(header[header.startIndex + 10]) << 8 | UInt32(header[header.startIndex + 11])
    let seq = UInt16(header[header.startIndex + 2]) << 8 | UInt16(header[header.startIndex + 3])

    // Track rollover counter (under lock for thread safety)
    let (currentROC, packetIndex) = state.withLock { s -> (UInt32, UInt64) in
      // Sender-side ROC: increment when the sequence number wraps.
      // A decrease > half the sequence space indicates a forward rollover
      // (RFC 3711 §3.3.1, Appendix A: s_l - SEQ > 2^15).
      if seq < s.lastSequenceNumber && (s.lastSequenceNumber &- seq) > 0x8000 {
        s.rolloverCounter += 1
      }
      s.lastSequenceNumber = seq
      s.packetCount += 1
      return (s.rolloverCounter, UInt64(s.rolloverCounter) << 16 | UInt64(seq))
    }

    // Build the IV for AES-ICM (RFC 3711 §4.1.1)
    // IV = (k_s * 2^16) XOR (SSRC * 2^64) XOR (i * 2^16)
    // k_s (14 bytes) at bytes 0-13, SSRC (4 bytes) at bytes 4-7,
    // packet index (6 bytes) at bytes 8-13, block counter at bytes 14-15
    var iv = Data(count: 16)
    iv[4] = UInt8((ssrc >> 24) & 0xFF)
    iv[5] = UInt8((ssrc >> 16) & 0xFF)
    iv[6] = UInt8((ssrc >> 8) & 0xFF)
    iv[7] = UInt8(ssrc & 0xFF)
    iv[8] = UInt8((packetIndex >> 40) & 0xFF)
    iv[9] = UInt8((packetIndex >> 32) & 0xFF)
    iv[10] = UInt8((packetIndex >> 24) & 0xFF)
    iv[11] = UInt8((packetIndex >> 16) & 0xFF)
    iv[12] = UInt8((packetIndex >> 8) & 0xFF)
    iv[13] = UInt8(packetIndex & 0xFF)

    // XOR with session salt (14 bytes at bytes 0-13)
    for i in 0..<min(14, sessionSalt.count) {
      iv[i] ^= sessionSalt[sessionSalt.startIndex + i]
    }

    // Encrypt payload with AES-128-CTR
    guard let encryptedPayload = aesCTREncrypt(key: sessionKey, iv: iv, data: Data(payload)) else {
      return nil
    }

    // Assemble: original header + encrypted payload
    var srtpPacket = Data(header)
    srtpPacket.append(encryptedPayload)

    // Compute HMAC-SHA1 authentication tag over (header + encrypted payload + ROC)
    var authInput = srtpPacket
    var roc = currentROC.bigEndian
    authInput.append(Data(bytes: &roc, count: 4))

    let tag = hmacSHA1(key: sessionAuthKey, data: authInput)
    srtpPacket.append(tag.prefix(10))  // Truncate to 80 bits

    return srtpPacket
  }

  /// Decrypt and verify an incoming SRTP packet, returning the plain RTP packet.
  /// Returns nil if authentication fails.
  func unprotect(_ srtpPacket: Data) -> Data? {
    // SRTP = RTP header (12+) || encrypted payload || auth tag (10 bytes)
    guard srtpPacket.count >= 22 else { return nil }  // 12 header + 0 payload + 10 tag

    let tagStart = srtpPacket.count - 10
    let receivedTag = Data(srtpPacket[srtpPacket.startIndex + tagStart..<srtpPacket.endIndex])
    let authenticated = Data(srtpPacket[srtpPacket.startIndex..<srtpPacket.startIndex + tagStart])

    // Extract sequence number from header
    let seq =
      UInt16(authenticated[authenticated.startIndex + 2]) << 8
      | UInt16(authenticated[authenticated.startIndex + 3])

    // Compute candidate ROC without mutating state (RFC 3711 §3.3:
    // state must only be updated after authentication succeeds).
    let (candidateROC, candidateSeq, wasInitialized) = state.withLock {
      s -> (UInt32, UInt16, Bool) in
      if !s.incomingInitialized {
        return (s.incomingROC, seq, false)
      }
      var roc = s.incomingROC
      if s.incomingLastSeq < 0x8000 && seq > (s.incomingLastSeq &+ 0x8000) {
        // Late packet from previous ROC period (RFC 3711 §3.3.1 v = ROC-1)
        roc &-= 1
      } else if seq < s.incomingLastSeq && (s.incomingLastSeq &- seq) > 0x8000 {
        // Forward rollover (RFC 3711 §3.3.1 v = ROC+1)
        roc &+= 1
      }
      return (roc, seq, true)
    }

    // Verify HMAC-SHA1-80 before committing any state changes
    var authInput = authenticated
    var roc = candidateROC.bigEndian
    authInput.append(Data(bytes: &roc, count: 4))
    let expectedTag = Data(hmacSHA1(key: sessionAuthKey, data: authInput).prefix(10))
    guard constantTimeCompare(receivedTag, expectedTag) else {
      logger.debug("SRTP unprotect: auth tag mismatch")
      return nil
    }

    // Authentication passed — commit state only if this packet advances
    // the highest-seen sequence (RFC 3711 §3.3.1: update s_l only when
    // the packet index is higher than the previously stored one).
    state.withLock { s in
      let candidateIndex = UInt64(candidateROC) << 16 | UInt64(candidateSeq)
      let currentIndex = UInt64(s.incomingROC) << 16 | UInt64(s.incomingLastSeq)
      if !wasInitialized || candidateIndex > currentIndex {
        s.incomingROC = candidateROC
        s.incomingLastSeq = candidateSeq
      }
      if !wasInitialized { s.incomingInitialized = true }
    }

    // Extract SSRC and build IV (same as protect)
    let header = Data(authenticated[authenticated.startIndex..<authenticated.startIndex + 12])
    let encryptedPayload = Data(
      authenticated[authenticated.startIndex + 12..<authenticated.endIndex])

    let ssrc =
      UInt32(header[header.startIndex + 8]) << 24 | UInt32(header[header.startIndex + 9]) << 16
      | UInt32(header[header.startIndex + 10]) << 8 | UInt32(header[header.startIndex + 11])

    let packetIndex = UInt64(candidateROC) << 16 | UInt64(seq)

    var iv = Data(count: 16)
    iv[4] = UInt8((ssrc >> 24) & 0xFF)
    iv[5] = UInt8((ssrc >> 16) & 0xFF)
    iv[6] = UInt8((ssrc >> 8) & 0xFF)
    iv[7] = UInt8(ssrc & 0xFF)
    iv[8] = UInt8((packetIndex >> 40) & 0xFF)
    iv[9] = UInt8((packetIndex >> 32) & 0xFF)
    iv[10] = UInt8((packetIndex >> 24) & 0xFF)
    iv[11] = UInt8((packetIndex >> 16) & 0xFF)
    iv[12] = UInt8((packetIndex >> 8) & 0xFF)
    iv[13] = UInt8(packetIndex & 0xFF)

    for i in 0..<min(14, sessionSalt.count) {
      iv[i] ^= sessionSalt[sessionSalt.startIndex + i]
    }

    // AES-CTR decrypt (symmetric — same as encrypt)
    guard let decryptedPayload = aesCTREncrypt(key: sessionKey, iv: iv, data: encryptedPayload)
    else {
      return nil
    }

    var rtpPacket = Data(header)
    rtpPacket.append(decryptedPayload)
    return rtpPacket
  }

  /// Encrypt and authenticate an RTCP packet, returning the SRTCP packet.
  /// Returns nil if encryption fails (caller should skip sending).
  /// Format: RTCP_header(8B) || encrypted_payload || E_flag+SRTCP_index(4B) || auth_tag(10B)
  func protectRTCP(_ rtcpPacket: Data) -> Data? {
    guard rtcpPacket.count >= 8 else { return nil }

    let header = Data(rtcpPacket[rtcpPacket.startIndex..<rtcpPacket.startIndex + 8])
    let payload = Data(rtcpPacket[rtcpPacket.startIndex + 8..<rtcpPacket.endIndex])

    // Extract SSRC from header (bytes 4-7)
    let ssrc =
      UInt32(header[header.startIndex + 4]) << 24 | UInt32(header[header.startIndex + 5]) << 16
      | UInt32(header[header.startIndex + 6]) << 8 | UInt32(header[header.startIndex + 7])

    let index = state.withLock { s -> UInt32 in
      let idx = s.srtcpIndex
      s.srtcpIndex = (s.srtcpIndex &+ 1) & 0x7FFF_FFFF
      return idx
    }

    // Build IV: (srtcp_salt * 2^16) XOR (SSRC * 2^64) XOR (index * 2^16)
    var iv = Data(count: 16)
    iv[4] = UInt8((ssrc >> 24) & 0xFF)
    iv[5] = UInt8((ssrc >> 16) & 0xFF)
    iv[6] = UInt8((ssrc >> 8) & 0xFF)
    iv[7] = UInt8(ssrc & 0xFF)
    // SRTCP index is 32-bit (not 48-bit like SRTP packet index), placed at bytes 10-13
    iv[10] = UInt8((index >> 24) & 0xFF)
    iv[11] = UInt8((index >> 16) & 0xFF)
    iv[12] = UInt8((index >> 8) & 0xFF)
    iv[13] = UInt8(index & 0xFF)

    for i in 0..<min(14, srtcpSalt.count) {
      iv[i] ^= srtcpSalt[srtcpSalt.startIndex + i]
    }

    guard let encryptedPayload = aesCTREncrypt(key: srtcpKey, iv: iv, data: payload) else {
      return nil
    }

    // Assemble: header + encrypted payload + E||index + auth tag
    var srtcpPacket = Data(header)
    srtcpPacket.append(encryptedPayload)

    // E flag (bit 31) = 1 (encrypted) + 31-bit SRTCP index
    let eIndex = (UInt32(1) << 31) | (index & 0x7FFF_FFFF)
    var eIndexBE = eIndex.bigEndian
    srtcpPacket.append(Data(bytes: &eIndexBE, count: 4))

    // Auth tag covers: header + encrypted payload + E||index
    let tag = hmacSHA1(key: srtcpAuthKey, data: srtcpPacket)
    srtcpPacket.append(tag.prefix(10))

    return srtcpPacket
  }

  // MARK: - Key Derivation (AES-CM PRF)

  /// RFC 3711 §4.3.1 — derive a session key using AES-CM as a PRF.
  static func deriveKey(masterKey: Data, masterSalt: Data, label: UInt8, length: Int)
    -> Data
  {
    // x = label || 0x000000000000 (7 bytes) — then r = salt XOR (x left-padded to 14 bytes)
    var r = Data(count: 14)
    // Copy salt
    for i in 0..<min(14, masterSalt.count) {
      r[i] = masterSalt[masterSalt.startIndex + i]
    }
    // XOR label at byte index 7 (within the 14-byte block)
    r[7] ^= label

    // Build IV: r || 0x0000 (pad to 16 bytes)
    var iv = Data(count: 16)
    for i in 0..<14 { iv[i] = r[i] }
    // iv[14] = 0, iv[15] = 0 (block counter = 0)

    // Generate keystream by encrypting the IV with AES-ECB (counter mode with counter = 0,1,...)
    var result = Data()
    var counter: UInt16 = 0
    while result.count < length {
      iv[14] = UInt8(counter >> 8)
      iv[15] = UInt8(counter & 0xFF)

      // Buffer must be >= inputLength + blockSize for CCCrypt
      var block = Data(count: 32)
      var outLength = 0
      let status = block.withUnsafeMutableBytes { outPtr in
        iv.withUnsafeBytes { ivPtr in
          masterKey.withUnsafeBytes { keyPtr in
            CCCrypt(
              CCOperation(kCCEncrypt),
              CCAlgorithm(kCCAlgorithmAES),
              CCOptions(kCCOptionECBMode),
              keyPtr.baseAddress, masterKey.count,
              nil,
              ivPtr.baseAddress, 16,
              outPtr.baseAddress, 32,
              &outLength
            )
          }
        }
      }
      if status != kCCSuccess || outLength == 0 {
        // Fallback: should never happen
        break
      }
      result.append(block.prefix(min(outLength, 16)))
      counter += 1
    }
    return Data(result.prefix(length))
  }

  // MARK: - AES-128-CTR Encryption

  private func aesCTREncrypt(key: Data, iv: Data, data: Data) -> Data? {
    guard !data.isEmpty else { return data }

    var cryptorRef: CCCryptorRef?
    let createStatus = key.withUnsafeBytes { keyPtr in
      iv.withUnsafeBytes { ivPtr in
        CCCryptorCreateWithMode(
          CCOperation(kCCEncrypt),
          CCMode(kCCModeCTR),
          CCAlgorithm(kCCAlgorithmAES),
          CCPadding(ccNoPadding),
          ivPtr.baseAddress,
          keyPtr.baseAddress, key.count,
          nil, 0, 0,
          CCModeOptions(kCCModeOptionCTR_BE),
          &cryptorRef
        )
      }
    }

    guard createStatus == kCCSuccess, let cryptor = cryptorRef else {
      return nil
    }

    let resultCount = data.count
    var result = Data(count: resultCount)
    var outLength = 0
    let updateStatus = result.withUnsafeMutableBytes { outPtr in
      data.withUnsafeBytes { inPtr in
        CCCryptorUpdate(
          cryptor,
          inPtr.baseAddress, data.count,
          outPtr.baseAddress, resultCount,
          &outLength
        )
      }
    }

    CCCryptorRelease(cryptor)

    if updateStatus != kCCSuccess {
      return nil
    }

    return result
  }

  // MARK: - Constant-Time Comparison

  private func constantTimeCompare(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return lhs.withUnsafeBytes { lhsPtr in
      rhs.withUnsafeBytes { rhsPtr in
        timingsafe_bcmp(lhsPtr.baseAddress, rhsPtr.baseAddress, lhs.count) == 0
      }
    }
  }

  // MARK: - HMAC-SHA1

  private func hmacSHA1(key: Data, data: Data) -> Data {
    var result = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
    result.withUnsafeMutableBytes { resultPtr in
      data.withUnsafeBytes { dataPtr in
        key.withUnsafeBytes { keyPtr in
          CCHmac(
            CCHmacAlgorithm(kCCHmacAlgSHA1),
            keyPtr.baseAddress, key.count,
            dataPtr.baseAddress, data.count,
            resultPtr.baseAddress
          )
        }
      }
    }
    return result
  }
}
