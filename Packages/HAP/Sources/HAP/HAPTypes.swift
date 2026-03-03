import CryptoKit
import Foundation
import SRP
import os

// MARK: - Encryption Context
// After pair-verify succeeds, this handles encrypting/decrypting HAP frames
// using ChaCha20-Poly1305 with incrementing nonce counters.

public nonisolated final class EncryptionContext {

  private let readKey: SymmetricKey  // Controller-to-Accessory
  private let writeKey: SymmetricKey  // Accessory-to-Controller
  private let counters = OSAllocatedUnfairLock(initialState: (read: UInt64(0), write: UInt64(0)))
  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Crypto")

  public init(readKey: SymmetricKey, writeKey: SymmetricKey) {
    self.readKey = readKey
    self.writeKey = writeKey
  }

  /// Decrypt an incoming HAP encrypted frame.
  /// - Parameters:
  ///   - lengthBytes: The 2-byte little-endian length prefix (used as AAD).
  ///   - ciphertext: The encrypted payload + 16-byte Poly1305 tag.
  public func decrypt(lengthBytes: Data, ciphertext: Data) -> Data? {
    // Always advance the read counter (HAP spec §6.5.2). The nonce must never
    // be reused, and on failure the connection is terminated anyway.
    let counterValue = counters.withLock { state -> UInt64 in
      let n = state.read
      state.read += 1
      return n
    }
    let nonce = Self.makeNonce(counter: counterValue)

    // Split ciphertext from tag
    guard ciphertext.count >= 16 else { return nil }
    let encrypted = ciphertext[ciphertext.startIndex..<ciphertext.endIndex - 16]
    let tag = ciphertext[ciphertext.endIndex - 16..<ciphertext.endIndex]

    do {
      let sealedBox = try ChaChaPoly.SealedBox(
        nonce: nonce,
        ciphertext: encrypted,
        tag: tag
      )
      return try ChaChaPoly.open(sealedBox, using: readKey, authenticating: lengthBytes)
    } catch {
      logger.error("Decrypt failed: \(error)")
      return nil
    }
  }

  /// Encrypt an outgoing HAP message, splitting into frames of max 1024 bytes.
  /// Each frame: [2-byte LE length][encrypted data][16-byte tag]
  /// Returns nil on failure — the caller should close the connection since
  /// the write counter has been consumed and the session is desynced.
  public func encrypt(plaintext: Data) -> Data? {
    // Pre-allocate: each 1024-byte chunk adds 2 (length) + chunk + 16 (tag) = 18 overhead.
    let chunkCount = (plaintext.count + 1023) / 1024
    var result = Data()
    result.reserveCapacity(plaintext.count + chunkCount * 18)
    var offset = plaintext.startIndex

    while offset < plaintext.endIndex {
      let chunkEnd = min(offset + 1024, plaintext.endIndex)
      let chunk = plaintext[offset..<chunkEnd]

      let counterValue = counters.withLock { state -> UInt64 in
        let n = state.write
        state.write += 1
        return n
      }
      let nonce = Self.makeNonce(counter: counterValue)

      let lengthBytes: [UInt8] = [UInt8(chunk.count & 0xFF), UInt8((chunk.count >> 8) & 0xFF)]

      do {
        let sealed = try ChaChaPoly.seal(
          chunk,
          using: writeKey,
          nonce: nonce,
          authenticating: lengthBytes
        )
        result.append(contentsOf: lengthBytes)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
      } catch {
        logger.error("Encrypt failed: \(error)")
        return nil
      }

      offset = chunkEnd
    }

    return result
  }

  /// HAP nonces are 12 bytes: 4 zero bytes + 8-byte little-endian counter.
  /// The 12-byte construction is always valid; this cannot fail in practice.
  private nonisolated static func makeNonce(counter: UInt64) -> ChaChaPoly.Nonce {
    var nonceData = Data(repeating: 0, count: 4)  // 4 zero bytes
    var le = counter.littleEndian
    nonceData.append(Data(bytes: &le, count: 8))
    // The construction is statically 12 bytes; if ChaChaPoly ever rejects it,
    // crash with a clear message rather than silently corrupting data.
    guard let nonce = try? ChaChaPoly.Nonce(data: nonceData) else {
      preconditionFailure("HAP nonce construction failed — 12-byte invariant violated")
    }
    return nonce
  }
}

// MARK: - Pair Setup Session State

/// Tracks in-progress pair-setup state for a connection.
///
/// All mutable properties are accessed exclusively on the HAP server queue
/// (via `HAPConnection.pairSetupState`). The class is `@unchecked Sendable`
/// because queue affinity provides the concurrency guarantee.
public nonisolated final class PairSetupSession: @unchecked Sendable {
  /// Explicit state machine phase to prevent out-of-order messages.
  public enum Phase {
    case awaitingM3  // M1 processed, waiting for client proof
    case awaitingM5  // M3 processed, waiting for key exchange
  }

  public var phase: Phase = .awaitingM3

  // SRP session values — filled in progressively during the M1→M6 exchange.
  public var salt: Data?
  public var serverPublicKey: Data?  // B
  public var sessionKey: SymmetricKey?  // K (derived from shared secret)
  public var srpSession: SRPServer?

  public init() {}
}

// MARK: - Pair Verify Session State

/// Tracks in-progress pair-verify state for a connection.
///
/// All mutable properties are accessed exclusively on the HAP server queue
/// (via `HAPConnection.pairVerifyState`). The class is `@unchecked Sendable`
/// because queue affinity provides the concurrency guarantee.
public nonisolated final class PairVerifySession: @unchecked Sendable {
  public var sharedSecret: SharedSecret?
  /// Raw bytes of the accessory's ephemeral public key (sent in M2).
  /// Only the public key is retained — the private key is discarded after
  /// deriving the shared secret in M1 to minimize key material exposure.
  public var accessoryEphemeralPublicKeyBytes: Data?
  public var controllerEphemeralPublicKey: Curve25519.KeyAgreement.PublicKey?
  public var sessionKey: SymmetricKey?  // Derived encryption key for verifying signatures

  public init() {}
}

// MARK: - HKDF Convenience

extension HKDF<SHA512> {
  /// Derive raw bytes using HKDF-SHA512 — use for non-key material (e.g. signature payloads).
  public static func deriveKey(
    inputKeyMaterial: Data,
    salt: Data,
    info: Data,
    outputByteCount: Int = 32
  ) -> Data {
    let ikm = SymmetricKey(data: inputKeyMaterial)
    let derived = Self.deriveKey(
      inputKeyMaterial: ikm,
      salt: salt,
      info: info,
      outputByteCount: outputByteCount
    )
    return derived.withUnsafeBytes { Data($0) }
  }

  /// Derive a SymmetricKey directly — avoids exposing key material through Data.
  public static func deriveSymmetricKey(
    inputKeyMaterial: Data,
    salt: Data,
    info: Data,
    outputByteCount: Int = 32
  ) -> SymmetricKey {
    let ikm = SymmetricKey(data: inputKeyMaterial)
    return Self.deriveKey(
      inputKeyMaterial: ikm,
      salt: salt,
      info: info,
      outputByteCount: outputByteCount
    )
  }

  /// Derive a SymmetricKey from a SymmetricKey input — keeps key material in SecureBytes.
  public static func deriveSymmetricKey(
    inputKeyMaterial: SymmetricKey,
    salt: Data,
    info: Data,
    outputByteCount: Int = 32
  ) -> SymmetricKey {
    Self.deriveKey(
      inputKeyMaterial: inputKeyMaterial,
      salt: salt,
      info: info,
      outputByteCount: outputByteCount
    )
  }
}
