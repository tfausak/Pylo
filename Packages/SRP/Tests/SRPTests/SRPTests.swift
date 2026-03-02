import CryptoKit
import Foundation
import Testing

@testable import SRP

// MARK: - SRP Server Tests

@Suite("SRP Server")
struct SRPServerTests {

  @Test("Initialization succeeds and produces salt and public key")
  func initSucceeds() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")
    #expect(server != nil)
    #expect(server!.salt.count == 16)
    #expect(server!.publicKey.count == 384)
  }

  @Test("Reject client public key of zero")
  func rejectZeroPublicKey() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    let zeroKey = Data(repeating: 0, count: 384)
    #expect(server.setClientPublicKey(zeroKey) == false)
  }

  @Test("Session key is nil before client public key is set")
  func sessionKeyNilBeforePublicKey() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    #expect(server.sessionKey == nil)
  }

  @Test("Verify client proof returns nil without client public key")
  func verifyWithoutPublicKey() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    let result = server.verifyClientProof(Data(repeating: 0, count: 64))
    #expect(result == nil)
  }

  @Test("Wrong proof is rejected")
  func wrongProofRejected() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    // Set a valid (non-zero) client public key
    var fakeKey = Data(repeating: 0, count: 384)
    fakeKey[383] = 0x05  // Non-zero so it passes the A%N!=0 check
    _ = server.setClientPublicKey(fakeKey)
    let result = server.verifyClientProof(Data(repeating: 0xAB, count: 64))
    #expect(result == nil)
  }

  @Test("Wrong-length proof is rejected early")
  func wrongLengthProofRejected() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    var fakeKey = Data(repeating: 0, count: 384)
    fakeKey[383] = 0x05
    _ = server.setClientPublicKey(fakeKey)
    // SHA-512 digest is 64 bytes; shorter and longer should both fail
    #expect(server.verifyClientProof(Data(repeating: 0xAB, count: 32)) == nil)
    #expect(server.verifyClientProof(Data(repeating: 0xAB, count: 0)) == nil)
    #expect(server.verifyClientProof(Data(repeating: 0xAB, count: 128)) == nil)
  }
}

// MARK: - SRP Session Key Deferral Tests

@Suite("SRP Session Key Deferral")
struct SRPSessionKeyDeferralTests {

  @Test("Session key is nil after setClientPublicKey but before verifyClientProof")
  func sessionKeyNilAfterSetClientPublicKey() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!

    // Use a valid (non-zero) client public key
    var fakeKey = Data(repeating: 0, count: 384)
    fakeKey[383] = 0x05
    let result = server.setClientPublicKey(fakeKey)
    #expect(result == true)

    // sessionKey should still be nil — not exposed until proof succeeds
    #expect(server.sessionKey == nil)
  }

  @Test("Session key is nil after failed verifyClientProof")
  func sessionKeyNilAfterFailedProof() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!

    var fakeKey = Data(repeating: 0, count: 384)
    fakeKey[383] = 0x05
    _ = server.setClientPublicKey(fakeKey)

    // Wrong proof should fail
    let result = server.verifyClientProof(Data(repeating: 0xAB, count: 64))
    #expect(result == nil)

    // sessionKey should still be nil
    #expect(server.sessionKey == nil)
  }
}

// MARK: - SRP Client Public Key Validation Tests

@Suite("SRP Client Public Key Validation")
struct SRPClientPublicKeyTests {

  @Test("Rejects client public key shorter than 384 bytes")
  func rejectsShortKey() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    let shortKey = Data(repeating: 0x05, count: 1)
    #expect(server.setClientPublicKey(shortKey) == false)
  }

  @Test("Rejects client public key longer than 384 bytes")
  func rejectsLongKey() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    let longKey = Data(repeating: 0x05, count: 385)
    #expect(server.setClientPublicKey(longKey) == false)
  }

  @Test("Accepts valid 384-byte client public key")
  func acceptsCorrectLength() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    var validKey = Data(repeating: 0, count: 384)
    validKey[383] = 0x05  // non-zero so A % N != 0
    #expect(server.setClientPublicKey(validKey) == true)
  }

  @Test("Rejects empty client public key")
  func rejectsEmpty() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    #expect(server.setClientPublicKey(Data()) == false)
  }

  @Test("Rejects second call to setClientPublicKey")
  func rejectsDoubleSet() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    var key1 = Data(repeating: 0, count: 384)
    key1[383] = 0x05
    #expect(server.setClientPublicKey(key1) == true)

    var key2 = Data(repeating: 0, count: 384)
    key2[383] = 0x07
    #expect(server.setClientPublicKey(key2) == false)
  }
}
