import CryptoKit
import Foundation
import os

// MARK: - Keychain Helper

nonisolated enum KeychainHelper {

  private static let service = "me.fausak.taylor.Pylo"
  private static let signingKeyAccount = "device-signing-key"
  private static let deviceIDAccount = "device-id"
  private static let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Keychain")

  @discardableResult
  static func save(
    key: String, data: Data, accessible: CFString = kSecAttrAccessibleAfterFirstUnlock
  ) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    let attributes: [String: Any] = [
      kSecAttrAccessible as String: accessible,
      kSecValueData as String: data,
    ]
    let addQuery = query.merging(attributes) { _, new in new }
    let status = SecItemAdd(addQuery as CFDictionary, nil)
    if status == errSecDuplicateItem {
      let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      if updateStatus != errSecSuccess {
        logger.error("Keychain update failed for '\(key)': OSStatus \(updateStatus)")
        return false
      }
      return true
    }
    if status != errSecSuccess {
      logger.error("Keychain save failed for '\(key)': OSStatus \(status)")
      return false
    }
    return true
  }

  static func load(key: String) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { return nil }
    return result as? Data
  }

  static func saveSigningKey(_ rawKey: Data) {
    save(
      key: signingKeyAccount, data: rawKey, accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    )
  }

  static func loadSigningKey() -> Data? {
    load(key: signingKeyAccount)
  }

  static func saveDeviceID(_ id: String) {
    save(key: deviceIDAccount, data: Data(id.utf8))
  }

  static func loadDeviceID() -> String? {
    guard let data = load(key: deviceIDAccount) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

// MARK: - Keychain-backed KeyStore (app-side)

/// Concrete `KeyStore` implementation backed by the iOS Keychain.
/// Set this on `PairSetupHandler.keyStore` before starting the server.
nonisolated struct KeychainKeyStore: KeyStore {
  @discardableResult
  func save(key: String, data: Data) -> Bool {
    KeychainHelper.save(key: key, data: data)
  }

  func load(key: String) -> Data? {
    KeychainHelper.load(key: key)
  }
}

// MARK: - Encryption Context
// After pair-verify succeeds, this handles encrypting/decrypting HAP frames
// using ChaCha20-Poly1305 with incrementing nonce counters.

nonisolated final class EncryptionContext {

  private let readKey: SymmetricKey  // Controller-to-Accessory
  private let writeKey: SymmetricKey  // Accessory-to-Controller
  private let counters = OSAllocatedUnfairLock(initialState: (read: UInt64(0), write: UInt64(0)))
  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Crypto")

  init(readKey: SymmetricKey, writeKey: SymmetricKey) {
    self.readKey = readKey
    self.writeKey = writeKey
  }

  /// Decrypt an incoming HAP encrypted frame.
  /// - Parameters:
  ///   - lengthBytes: The 2-byte little-endian length prefix (used as AAD).
  ///   - ciphertext: The encrypted payload + 16-byte Poly1305 tag.
  func decrypt(lengthBytes: Data, ciphertext: Data) -> Data? {
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
  func encrypt(plaintext: Data) -> Data? {
    var result = Data()
    var offset = plaintext.startIndex

    while offset < plaintext.endIndex {
      let chunkEnd = min(offset + 1024, plaintext.endIndex)
      let chunk = plaintext[offset..<chunkEnd]

      let nonce = counters.withLock { state -> ChaChaPoly.Nonce in
        let n = Self.makeNonce(counter: state.write)
        state.write += 1
        return n
      }

      var lengthBytes = Data(count: 2)
      lengthBytes[0] = UInt8(chunk.count & 0xFF)
      lengthBytes[1] = UInt8((chunk.count >> 8) & 0xFF)

      do {
        let sealed = try ChaChaPoly.seal(
          chunk,
          using: writeKey,
          nonce: nonce,
          authenticating: lengthBytes
        )
        result.append(lengthBytes)
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
nonisolated final class PairSetupSession: @unchecked Sendable {
  // SRP session values — filled in progressively during the M1→M6 exchange.
  var salt: Data?
  var serverPublicKey: Data?  // B
  var sessionKey: SymmetricKey?  // K (derived from shared secret)
  var srpSession: SRPServer?
}

// MARK: - Pair Verify Session State

/// Tracks in-progress pair-verify state for a connection.
nonisolated final class PairVerifySession: @unchecked Sendable {
  var sharedSecret: SharedSecret?
  /// Raw bytes of the accessory's ephemeral public key (sent in M2).
  /// Only the public key is retained — the private key is discarded after
  /// deriving the shared secret in M1 to minimize key material exposure.
  var accessoryEphemeralPublicKeyBytes: Data?
  var controllerEphemeralPublicKey: Curve25519.KeyAgreement.PublicKey?
  var sessionKey: SymmetricKey?  // Derived encryption key for verifying signatures
}

// MARK: - HKDF Convenience

nonisolated extension HKDF<SHA512> {
  /// Derive raw bytes using HKDF-SHA512 — use for non-key material (e.g. signature payloads).
  static func deriveKey(
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
  static func deriveSymmetricKey(
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
  static func deriveSymmetricKey(
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
