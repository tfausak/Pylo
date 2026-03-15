import BigInt
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

  @Test("Server public key B is not a multiple of N")
  func serverPublicKeyNotMultipleOfN() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    let b = BigUInt(server.publicKey)
    #expect(b % SRPTestClient.prime != 0)
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

  @Test("Rejects client public key equal to N (non-zero multiple of prime)")
  func rejectsKeyEqualToN() {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!
    // A = N serializes to exactly 384 bytes, is non-zero, but A % N == 0
    let keyEqualToN = SRPTestClient.pad(SRPTestClient.prime)
    #expect(keyEqualToN.count == 384)
    #expect(server.setClientPublicKey(keyEqualToN) == false)
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

// MARK: - SRP End-to-End Test

/// Minimal SRP-6a client implementation for testing the full handshake.
/// Intentionally duplicates prime/g/pad from SRPServer rather than sharing them —
/// an independent reimplementation ensures the test validates the protocol math
/// rather than just round-tripping through the same code.
private enum SRPTestClient {
  static let prime = BigUInt(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1"
      + "29024E088A67CC74020BBEA63B139B22514A08798E3404DD"
      + "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
      + "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
      + "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3D"
      + "C2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
      + "83655D23DCA3AD961C62F356208552BB9ED529077096966D"
      + "670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
      + "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9"
      + "DE2BCBF6955817183995497CEA956AE515D2261898FA0510"
      + "15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64"
      + "ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"
      + "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6B"
      + "F12FFA06D98A0864D87602733EC86A64521F2B18177B200C"
      + "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB31"
      + "43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF",
    radix: 16
  )!
  static let g = BigUInt(5)
  static let nLength = 384

  static func pad(_ value: BigUInt) -> Data {
    let data = value.serialize()
    if data.count >= nLength { return data }
    var padded = Data(repeating: 0, count: nLength - data.count)
    padded.append(data)
    return padded
  }

  /// Run the client side of SRP-6a, returning (clientPublicKey, clientProof, expectedSessionKey).
  static func handshake(
    username: String, password: String, salt: Data, serverPublicKey: Data,
    fixedPrivateKey: Data? = nil
  ) -> (clientPublicKey: Data, clientProof: Data, sessionKey: Data)? {
    let serverB = BigUInt(serverPublicKey)
    guard serverB % prime != 0 else { return nil }

    // Client private key a
    let a: BigUInt
    if let fixed = fixedPrivateKey {
      a = BigUInt(fixed)
    } else {
      var aBytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, aBytes.count, &aBytes) == errSecSuccess else {
        return nil
      }
      a = BigUInt(Data(aBytes))
    }
    let clientA = g.power(a, modulus: prime)

    // x = H(s | H(I | ":" | P))
    let identityHash = SHA512.hash(data: Data("\(username):\(password)".utf8))
    var xData = Data()
    xData.append(salt)
    xData.append(contentsOf: identityHash)
    let x = BigUInt(Data(SHA512.hash(data: xData)))

    // u = H(PAD(A) | PAD(B))
    var uData = Data()
    uData.append(pad(clientA))
    uData.append(serverPublicKey)
    let u = BigUInt(Data(SHA512.hash(data: uData)))
    guard u != 0 else { return nil }

    // k = H(PAD(N) | PAD(g))
    var kData = Data()
    kData.append(pad(prime))
    kData.append(pad(g))
    let k = BigUInt(Data(SHA512.hash(data: kData)))

    // S = (B - k * g^x mod N)^(a + u*x) mod N
    let gx = g.power(x, modulus: prime)
    let kgx = (k * gx) % prime
    // B - kgx mod N: add prime to prevent underflow
    let base = (serverB + prime - kgx) % prime
    let exp = (a + u * x)
    let premaster = base.power(exp, modulus: prime)

    // K = H(S)
    let derivedKey = Data(SHA512.hash(data: pad(premaster)))

    // M1 = H(H(N) XOR H(g) | H(I) | s | PAD(A) | B | K)
    let hashN = Data(SHA512.hash(data: prime.serialize()))
    let hashG = Data(SHA512.hash(data: g.serialize()))
    let xorResult = Data(zip(hashN, hashG).map { $0 ^ $1 })
    let hashI = Data(SHA512.hash(data: Data(username.utf8)))

    var m1Data = Data()
    m1Data.append(xorResult)
    m1Data.append(hashI)
    m1Data.append(salt)
    m1Data.append(pad(clientA))
    m1Data.append(serverPublicKey)
    m1Data.append(derivedKey)
    let m1Hash = Data(SHA512.hash(data: m1Data))

    return (clientPublicKey: pad(clientA), clientProof: m1Hash, sessionKey: derivedKey)
  }
}

@Suite("SRP End-to-End")
struct SRPEndToEndTests {

  @Test("Full SRP-6a handshake succeeds with correct password")
  func happyPath() {
    let username = "Pair-Setup"
    let password = "111-22-333"

    let server = SRPServer(username: username, password: password)!

    // Client receives salt and B from server
    guard
      let client = SRPTestClient.handshake(
        username: username, password: password,
        salt: server.salt, serverPublicKey: server.publicKey
      )
    else {
      Issue.record("Client handshake computation failed")
      return
    }

    // Server receives A from client
    #expect(server.setClientPublicKey(client.clientPublicKey) == true)

    // Server verifies M1 and returns M2
    let serverProof = server.verifyClientProof(client.clientProof)
    #expect(serverProof != nil, "Server should accept correct client proof")

    // Session key should now be available and match
    #expect(server.sessionKey != nil)

    // Verify M2: M2 = H(PAD(A) | M1 | K)
    var m2Data = Data()
    m2Data.append(client.clientPublicKey)
    m2Data.append(client.clientProof)
    m2Data.append(client.sessionKey)
    let expectedM2 = Data(SHA512.hash(data: m2Data))
    #expect(serverProof == expectedM2, "Server proof M2 should match client expectation")
  }

  @Test("SRP handshake fails with wrong password")
  func wrongPassword() {
    let username = "Pair-Setup"

    let server = SRPServer(username: username, password: "111-22-333")!

    // Client uses wrong password
    guard
      let client = SRPTestClient.handshake(
        username: username, password: "999-99-999",
        salt: server.salt, serverPublicKey: server.publicKey
      )
    else {
      Issue.record("Client handshake computation failed")
      return
    }

    #expect(server.setClientPublicKey(client.clientPublicKey) == true)
    let serverProof = server.verifyClientProof(client.clientProof)
    #expect(serverProof == nil, "Server should reject wrong password")
    #expect(server.sessionKey == nil, "Session key should not be set after failed proof")
  }
}

// MARK: - SRP Idempotency Guard Tests

@Suite("SRP Proof Idempotency")
struct SRPProofIdempotencyTests {

  @Test("Second call to verifyClientProof returns nil after successful verification")
  func secondVerifyReturnsNil() {
    let username = "Pair-Setup"
    let password = "111-22-333"

    let server = SRPServer(username: username, password: password)!

    guard
      let client = SRPTestClient.handshake(
        username: username, password: password,
        salt: server.salt, serverPublicKey: server.publicKey
      )
    else {
      Issue.record("Client handshake computation failed")
      return
    }

    #expect(server.setClientPublicKey(client.clientPublicKey) == true)

    // First call should succeed
    let firstResult = server.verifyClientProof(client.clientProof)
    #expect(firstResult != nil, "First verification should succeed")
    #expect(server.sessionKey != nil)

    // Second call with the same valid proof should return nil (idempotency guard)
    let secondResult = server.verifyClientProof(client.clientProof)
    #expect(secondResult == nil, "Second verification should return nil")

    // Session key should still be available from the first successful call
    #expect(server.sessionKey != nil)
  }
}

// MARK: - SRP Concurrency Tests

@Suite("SRP Concurrency")
struct SRPConcurrencyTests {

  @Test("Concurrent setClientPublicKey calls — exactly one succeeds")
  func concurrentSetClientPublicKey() async {
    let server = SRPServer(username: "Pair-Setup", password: "111-22-333")!

    // Generate distinct valid (non-zero) client public keys
    let keys: [Data] = (1...10).map { i in
      var key = Data(repeating: 0, count: 384)
      key[383] = UInt8(i)
      return key
    }

    let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for key in keys {
        group.addTask {
          server.setClientPublicKey(key)
        }
      }
      var collected: [Bool] = []
      for await result in group {
        collected.append(result)
      }
      return collected
    }

    let successes = results.filter { $0 }.count
    let failures = results.filter { !$0 }.count
    #expect(successes == 1, "Exactly one concurrent setClientPublicKey should succeed")
    #expect(failures == 9, "All other concurrent calls should fail")
  }
}

// MARK: - SRP Deterministic Test Vectors

@Suite("SRP Deterministic Vectors")
struct SRPDeterministicTests {

  // Fixed inputs — arbitrary but stable values for reproducible tests
  private static let fixedSalt = Data(
    [
      0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
      0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    ])
  private static let fixedServerKey = Data(
    [
      0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22,
      0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00,
      0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22,
      0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00,
    ])
  private static let fixedClientKey = Data(
    [
      0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
      0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
      0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
      0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00,
    ])

  @Test("Deterministic handshake produces identical results across runs")
  func deterministicHandshake() {
    let username = "Pair-Setup"
    let password = "111-22-333"

    // Run the handshake twice with identical fixed inputs
    var sessionKeys: [Data] = []
    var serverProofs: [Data] = []
    var clientPublicKeys: [Data] = []
    var serverPublicKeys: [Data] = []

    for _ in 0..<2 {
      let server = SRPServer(
        username: username, password: password,
        fixedSalt: Self.fixedSalt, fixedPrivateKey: Self.fixedServerKey
      )

      serverPublicKeys.append(server.publicKey)

      guard
        let client = SRPTestClient.handshake(
          username: username, password: password,
          salt: server.salt, serverPublicKey: server.publicKey,
          fixedPrivateKey: Self.fixedClientKey
        )
      else {
        Issue.record("Client handshake computation failed")
        return
      }

      clientPublicKeys.append(client.clientPublicKey)

      #expect(server.setClientPublicKey(client.clientPublicKey) == true)

      let serverProof = server.verifyClientProof(client.clientProof)
      #expect(serverProof != nil, "Deterministic handshake should succeed")
      guard let serverProof else { return }

      serverProofs.append(serverProof)
      sessionKeys.append(client.sessionKey)
    }

    // Both runs must produce identical outputs
    #expect(
      serverPublicKeys[0] == serverPublicKeys[1], "Server public key B should be deterministic")
    #expect(
      clientPublicKeys[0] == clientPublicKeys[1], "Client public key A should be deterministic")
    #expect(serverProofs[0] == serverProofs[1], "Server proof M2 should be deterministic")
    #expect(sessionKeys[0] == sessionKeys[1], "Session key should be deterministic")
  }

  @Test("Deterministic handshake produces correct session key")
  func deterministicSessionKey() {
    let username = "Pair-Setup"
    let password = "111-22-333"

    let server = SRPServer(
      username: username, password: password,
      fixedSalt: Self.fixedSalt, fixedPrivateKey: Self.fixedServerKey
    )

    guard
      let client = SRPTestClient.handshake(
        username: username, password: password,
        salt: server.salt, serverPublicKey: server.publicKey,
        fixedPrivateKey: Self.fixedClientKey
      )
    else {
      Issue.record("Client handshake computation failed")
      return
    }

    #expect(server.setClientPublicKey(client.clientPublicKey) == true)
    let serverProof = server.verifyClientProof(client.clientProof)
    #expect(serverProof != nil, "Handshake should succeed")

    // Server and client must derive the same session key
    #expect(server.sessionKey != nil)
    let serverKeyData = server.sessionKey!.withUnsafeBytes { Data($0) }
    #expect(serverKeyData == client.sessionKey, "Server and client session keys must match")

    // Verify M2
    var m2Data = Data()
    m2Data.append(client.clientPublicKey)
    m2Data.append(client.clientProof)
    m2Data.append(client.sessionKey)
    let expectedM2 = Data(SHA512.hash(data: m2Data))
    #expect(serverProof == expectedM2, "Server proof M2 must match client computation")
  }

  @Test("Deterministic handshake rejects wrong password")
  func deterministicWrongPassword() {
    let username = "Pair-Setup"

    let server = SRPServer(
      username: username, password: "111-22-333",
      fixedSalt: Self.fixedSalt, fixedPrivateKey: Self.fixedServerKey
    )

    guard
      let client = SRPTestClient.handshake(
        username: username, password: "wrong-password",
        salt: server.salt, serverPublicKey: server.publicKey,
        fixedPrivateKey: Self.fixedClientKey
      )
    else {
      Issue.record("Client handshake computation failed")
      return
    }

    #expect(server.setClientPublicKey(client.clientPublicKey) == true)
    let serverProof = server.verifyClientProof(client.clientProof)
    #expect(serverProof == nil, "Wrong password should be rejected with fixed inputs")
    #expect(server.sessionKey == nil)
  }
}
