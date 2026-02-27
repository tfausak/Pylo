import BigInt
import CryptoKit
import Foundation

// MARK: - SRP-6a Server Implementation
// This is the core crypto piece that CryptoKit doesn't provide.
// HAP uses SRP-6a with:
//   - 3072-bit group (RFC 5054)
//   - SHA-512
//   - Username: "Pair-Setup"
//   - Password: the setup code (e.g. "111-22-333")

/// SRP-6a server session for HAP pair-setup.
nonisolated final class SRPServer {

  // MARK: - 3072-bit SRP Group (RFC 5054, Appendix A)

  /// N: A large safe prime (N = 2q+1, where q is prime)
  /// All arithmetic is done modulo N.
  private static let prime = BigUInt(
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

  /// g: A generator modulo N
  private static let g = BigUInt(5)

  /// Length of N in bytes (3072 bits = 384 bytes)
  private static let nLength = 384

  // MARK: - Session State

  let salt: Data  // Random 16-byte salt (s)
  let publicKey: Data  // Server public key (B)

  private let username: String
  private let password: String

  // Private SRP values
  private let verifier: BigUInt  // v = g^x mod N
  private let privateKey: BigUInt  // b (random private key)
  private let k: BigUInt  // k = H(N | PAD(g))

  // Client's public key and derived values
  private var clientPublicKey: BigUInt?
  private var u: BigUInt?
  private var sharedSecret: BigUInt?

  /// The derived session key (K = H(S)), available after verifyClientProof succeeds.
  /// Stored as SymmetricKey for memory protection (SecureBytes, locked pages).
  private(set) var sessionKey: SymmetricKey?

  // MARK: - Initialization

  /// Creates a new SRP server session.
  /// Generates salt and computes the server's public key B.
  init?(username: String, password: String) {
    self.username = username
    self.password = password

    // 1. Generate random 16-byte salt (s)
    var saltBytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else {
      return nil
    }
    self.salt = Data(saltBytes)

    // 2. Compute x = H(s | H(I | ":" | P))
    // where I = username, P = password, H = SHA-512
    let identityHash = SHA512.hash(data: Data("\(username):\(password)".utf8))
    var xData = Data()
    xData.append(self.salt)
    xData.append(contentsOf: identityHash)
    let x = BigUInt(Data(SHA512.hash(data: xData)))

    // 3. Compute verifier v = g^x mod N
    self.verifier = Self.g.power(x, modulus: Self.prime)

    // 4. Generate random private key b (256 bits = 32 bytes)
    var bBytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bBytes.count, &bBytes) == errSecSuccess else {
      return nil
    }
    self.privateKey = BigUInt(Data(bBytes))

    // 5. Compute k = H(N | PAD(g)) per SRP-6a (required by HAP)
    var kData = Data()
    kData.append(Self.pad(Self.prime))
    kData.append(Self.pad(Self.g))
    self.k = BigUInt(Data(SHA512.hash(data: kData)))

    // 6. Compute B = (k*v + g^b mod N) mod N
    let gb = Self.g.power(self.privateKey, modulus: Self.prime)
    let kv = (self.k * self.verifier) % Self.prime
    let serverPublicKey = (kv + gb) % Self.prime

    // 7. Store B as public key
    self.publicKey = Self.pad(serverPublicKey)
  }

  // MARK: - Step 2: Receive Client Public Key

  /// Sets the client's public key A. Returns false if A is invalid.
  /// HAP spec requires A to be exactly 384 bytes (3072-bit group).
  func setClientPublicKey(_ clientPublicKey: Data) -> Bool {
    // 1. Validate length — must match the SRP group size
    guard clientPublicKey.count == Self.nLength else {
      return false
    }

    // 2. Convert A from Data to BigUInt
    let clientA = BigUInt(clientPublicKey)

    // 3. Verify A % N != 0 (security check to prevent invalid keys)
    guard clientA % Self.prime != 0 else {
      return false
    }

    self.clientPublicKey = clientA

    // 4. Compute u = H(PAD(A) | PAD(B))
    // RFC 5054 §2.5.4: abort if u == 0
    var uData = Data()
    uData.append(Self.pad(clientA))
    uData.append(self.publicKey)
    let computedU = BigUInt(Data(SHA512.hash(data: uData)))
    guard computedU != 0 else { return false }
    self.u = computedU

    // 5. Compute S = (A * v^u)^b mod N
    let u = computedU
    let vu = self.verifier.power(u, modulus: Self.prime)
    let avu = (clientA * vu) % Self.prime
    let s = avu.power(self.privateKey, modulus: Self.prime)
    self.sharedSecret = s

    return true
  }

  // MARK: - Step 3: Verify Client Proof

  /// Verifies the client's proof M1 and returns the server's proof M2.
  /// Returns nil if verification fails (wrong password).
  func verifyClientProof(_ clientProof: Data) -> Data? {
    guard let clientA = self.clientPublicKey,
      let s = self.sharedSecret
    else {
      return nil
    }

    // Derive K = H(S) — only exposed as sessionKey after proof succeeds
    let derivedKey = Data(SHA512.hash(data: Self.pad(s)))

    // Compute M1 = H(H(N) XOR H(g) | H(I) | s | A | B | K)

    // H(N) XOR H(g) — hash the raw (unpadded) serializations per RFC 2945.
    // Note: PAD() is used for k = H(PAD(N) | PAD(g)), but NOT for M1's H(N)/H(g).
    // For N, serialize() == pad() since it's already 384 bytes; for g=5, serialize()
    // is [0x05] (1 byte), which is what Apple Home.app expects.
    let hashN = Data(SHA512.hash(data: Self.prime.serialize()))
    let hashG = Data(SHA512.hash(data: Self.g.serialize()))
    let xorResult = Self.xor(hashN, hashG)

    // H(I) where I is the username
    let hashI = Data(SHA512.hash(data: Data(username.utf8)))

    // Build M1
    var m1Data = Data()
    m1Data.append(xorResult)
    m1Data.append(hashI)
    m1Data.append(self.salt)
    m1Data.append(Self.pad(clientA))
    m1Data.append(self.publicKey)
    m1Data.append(derivedKey)

    let expectedM1 = Data(SHA512.hash(data: m1Data))

    // 2. Compare with received clientProof (constant-time comparison)
    guard Self.constantTimeCompare(expectedM1, clientProof) else {
      // Proof verification failed — wrong password
      return nil
    }

    // 3. Compute M2 = H(A | M1 | K)
    var m2Data = Data()
    m2Data.append(Self.pad(clientA))
    m2Data.append(expectedM1)
    m2Data.append(derivedKey)

    let serverProof = Data(SHA512.hash(data: m2Data))

    // Proof verified — now expose the session key
    self.sessionKey = SymmetricKey(data: derivedKey)

    return serverProof
  }

  // MARK: - Helper Functions

  /// Pads a BigUInt to the length of N (384 bytes for 3072-bit group)
  private static func pad(_ value: BigUInt) -> Data {
    let data = value.serialize()
    if data.count >= nLength {
      return data
    }
    // Pad with leading zeros
    var padded = Data(repeating: 0, count: nLength - data.count)
    padded.append(data)
    return padded
  }

  /// XORs two Data objects of equal length
  private static func xor(_ lhs: Data, _ rhs: Data) -> Data {
    precondition(lhs.count == rhs.count, "XOR requires equal length data")
    return Data(zip(lhs, rhs).map { $0 ^ $1 })
  }

  /// Constant-time comparison to prevent timing attacks.
  /// Uses the platform's timingsafe_bcmp which is immune to compiler optimizations.
  /// Hashes both inputs to a fixed length before comparing so that a length
  /// mismatch does not leak timing information via an early return.
  private static func constantTimeCompare(_ lhs: Data, _ rhs: Data) -> Bool {
    let lhsHash = Data(SHA512.hash(data: lhs))
    let rhsHash = Data(SHA512.hash(data: rhs))
    return lhsHash.withUnsafeBytes { lhsPtr in
      rhsHash.withUnsafeBytes { rhsPtr in
        timingsafe_bcmp(lhsPtr.baseAddress, rhsPtr.baseAddress, lhsHash.count) == 0
      }
    }
  }
}

// MARK: - SRP Helper: PAD
// PAD(x) pads a BigUInt to the byte length of N (384 bytes for 3072-bit).

// MARK: - SRP Helper: H
// H is SHA-512 throughout HAP's SRP usage.
// Use: SHA512.hash(data: ...) from CryptoKit.

// MARK: - Implementation Guide
//
// Here's what the complete SRP-6a looks like once you add BigInt.
// This is about 150 lines of actual code:
//
// import BigInt
//
// // RFC 5054, 3072-bit group
// private static let prime = BigUInt(
//     "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1" +
//     ...
//     "DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF",
//     radix: 16
// )!
//
// private static let g = BigUInt(5)
//
// Then implement:
//
// init: salt, x, v, b, k, B
// setClientPublicKey: A, u, S, K
// verifyClientProof: M1 verification, M2 computation
//
// All using BigUInt.power(_:modulus:) for modular exponentiation
// and SHA512.hash(data:) for hashing.
