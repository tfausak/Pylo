import Foundation

/// Abstraction over Keychain for device identity and pair-setup persistence.
/// The app provides a concrete `KeychainKeyStore` implementation; the HAP
/// package uses this protocol to avoid a Security.framework dependency.
public nonisolated protocol KeyStore {
  @discardableResult
  func save(key: String, data: Data) -> Bool
  func load(key: String) -> Data?
}
