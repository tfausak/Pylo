import Foundation
import HAP
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
