import CryptoKit
import Foundation
import Locked
import os

// MARK: - Device Identity
// The accessory's long-term Ed25519 key pair and device ID.

public final class DeviceIdentity: @unchecked Sendable {

  private static let logger = Logger(subsystem: logSubsystem, category: "Identity")

  /// Persistent Ed25519 signing key.
  public let signingKey: Curve25519.Signing.PrivateKey

  /// Device ID in AA:BB:CC:DD:EE:FF format (derived from key or randomly generated once).
  public let deviceID: String

  /// Initialize from a `KeyStore` (used by the HAP package without Keychain dependency).
  public init(keyStore: KeyStore) {
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
    (self.signingKey, self.deviceID, _) = Self.generate(keyStore: keyStore)
  }

  /// Generates a new signing key and device ID and persists them to `keyStore`.
  private static func generate(keyStore: KeyStore) -> (
    signingKey: Curve25519.Signing.PrivateKey, deviceID: String, persisted: Bool
  ) {
    let newKey = Curve25519.Signing.PrivateKey()

    var bytes = [UInt8](repeating: 0, count: 6)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      fatalError("SecRandomCopyBytes failed — cannot generate device ID")
    }
    let newID = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")

    var persisted = true
    if !keyStore.save(key: "device-signing-key", data: newKey.rawRepresentation) {
      logger.error(
        "Failed to persist device signing key — identity will change on next launch")
      persisted = false
    }
    if !keyStore.save(key: "device-id", data: Data(newID.utf8)) {
      logger.error("Failed to persist device ID — identity will change on next launch")
      persisted = false
    }
    logger.info("Generated new identity: \(newID)")
    return (newKey, newID, persisted)
  }

  // MARK: - Rotation

  /// Key store entry marking an identity that has never been given to a controller.
  /// Absent for identities created before this marker existed, which are treated
  /// as possibly paired.
  private static let neverPairedKey = "identity-never-paired"

  /// Serializes rotation, identity loads, and pairing marks. A cancelled server
  /// startup can still be running when its replacement starts, and without this
  /// it could rotate credentials after the replacement has loaded them.
  private static let rotationLock = Locked(initialState: ())

  /// Rotates the identity if needed (see `rotateIfNeeded`) and loads it.
  /// Use this instead of `init(keyStore:)` when starting a server.
  public static func load(keyStore: KeyStore, isPaired: Bool) -> DeviceIdentity {
    rotationLock.withLock { _ in
      _ = rotateIfNeededLocked(keyStore: keyStore, isPaired: isPaired)
      return DeviceIdentity(keyStore: keyStore)
    }
  }

  /// Replaces the device ID, signing key, setup code, and setup ID if the
  /// accessory is unpaired but its identity may still be known to a controller.
  ///
  /// HomeKit remembers accessories by device ID. If a pairing is lost on the
  /// accessory side (unpair, reinstall, or an interrupted add), Home keeps
  /// refusing the old ID with "Accessory Already in Another Home". HAP requires
  /// a new device ID after a reset, so a fresh identity makes Home treat the
  /// bridge as a new accessory. Keychain items survive app deletion, so this
  /// also covers reinstalls, where `pairings.json` is gone but the identity isn't.
  ///
  /// Returns true if the identity was replaced. If any new value fails to
  /// persist, returns false and leaves the rotation to be retried next time.
  @discardableResult
  public static func rotateIfNeeded(keyStore: KeyStore, isPaired: Bool) -> Bool {
    rotationLock.withLock { _ in rotateIfNeededLocked(keyStore: keyStore, isPaired: isPaired) }
  }

  private static func rotateIfNeededLocked(keyStore: KeyStore, isPaired: Bool) -> Bool {
    guard !isPaired, keyStore.load(key: neverPairedKey) != Data([1]) else { return false }
    let identityPersisted = generate(keyStore: keyStore).persisted
    let credentialsPersisted = PairSetupHandler.resetSetupCredentials(keyStore: keyStore)
    // Written last, and only if everything else was saved, so a partial
    // rotation is retried on the next start.
    guard identityPersisted, credentialsPersisted,
      keyStore.save(key: neverPairedKey, data: Data([1]))
    else {
      logger.error("Identity rotation incomplete — will retry on next start")
      return false
    }
    logger.info("Rotated identity for unpaired accessory")
    return true
  }

  /// Records that the current identity has been given to a controller, so it is
  /// rotated the next time the accessory is found unpaired.
  public static func markPaired(keyStore: KeyStore) {
    rotationLock.withLock { _ in
      if !keyStore.save(key: neverPairedKey, data: Data([0])) {
        logger.error("Failed to mark identity as paired")
      }
    }
  }

  public init(signingKey: Curve25519.Signing.PrivateKey, deviceID: String) {
    self.signingKey = signingKey
    self.deviceID = deviceID
  }

  public var publicKey: Curve25519.Signing.PublicKey {
    signingKey.publicKey
  }
}
