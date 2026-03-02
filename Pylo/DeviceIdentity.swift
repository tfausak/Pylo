import CryptoKit
import Foundation
import os

// MARK: - Device Identity
// The accessory's long-term Ed25519 key pair and device ID.

nonisolated final class DeviceIdentity: @unchecked Sendable {

  private static let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Identity")

  /// Persistent Ed25519 signing key.
  let signingKey: Curve25519.Signing.PrivateKey

  /// Device ID in AA:BB:CC:DD:EE:FF format (derived from key or randomly generated once).
  let deviceID: String

  /// Initialize from a `KeyStore` (used by the HAP package without Keychain dependency).
  init(keyStore: KeyStore) {
    // Try loading from key store first
    if let keyData = keyStore.load(key: "device-signing-key"),
      let savedID = keyStore.load(key: "device-id"),
      let savedIDString = String(data: savedID, encoding: .utf8)
    {
      do {
        self.signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
        self.deviceID = savedIDString
        Self.logger.info("Loaded identity from key store: \(savedIDString)")
        return
      } catch {
        Self.logger.warning("Failed to restore signing key: \(error)")
      }
    }

    // Generate fresh identity and persist
    let newKey = Curve25519.Signing.PrivateKey()
    self.signingKey = newKey

    var bytes = [UInt8](repeating: 0, count: 6)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      fatalError("SecRandomCopyBytes failed — cannot generate device ID")
    }
    let newID = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    self.deviceID = newID

    keyStore.save(key: "device-signing-key", data: newKey.rawRepresentation)
    keyStore.save(key: "device-id", data: Data(newID.utf8))
    Self.logger.info("Generated new identity: \(newID)")
  }

  init(signingKey: Curve25519.Signing.PrivateKey, deviceID: String) {
    self.signingKey = signingKey
    self.deviceID = deviceID
  }

  var publicKey: Curve25519.Signing.PublicKey {
    signingKey.publicKey
  }
}
