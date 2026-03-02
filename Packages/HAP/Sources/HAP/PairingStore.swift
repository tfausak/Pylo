import Foundation
import os

// MARK: - Pairing Store
// Stores paired controllers (their Ed25519 public keys and identifiers).

public nonisolated final class PairingStore: @unchecked Sendable {

  public struct Pairing: Codable, Sendable {
    public let identifier: String  // Controller's pairing ID (UUID string)
    public let publicKey: Data  // Controller's Ed25519 LTPK (32 bytes)
    public let isAdmin: Bool

    public init(identifier: String, publicKey: Data, isAdmin: Bool) {
      self.identifier = identifier
      self.publicKey = publicKey
      self.isAdmin = isAdmin
    }
  }

  private static let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "PairingStore")

  /// Called whenever pairings are added or removed.
  /// Protected by its own lock: set from @MainActor, called from the server queue.
  private let _onChange = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
  public var onChange: (@Sendable () -> Void)? {
    get { _onChange.withLock { $0 } }
    set { _onChange.withLock { $0 = newValue } }
  }

  /// Lock-protected pairings dictionary.
  private let lock = OSAllocatedUnfairLock(initialState: [String: Pairing]())

  /// Thread-safe snapshot of all pairings.
  public var pairings: [String: Pairing] {
    lock.withLock { $0 }
  }

  private static var storageURL: URL {
    get throws {
      let appSupport = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
      )
      return appSupport.appendingPathComponent("pairings.json")
    }
  }

  public var isPaired: Bool {
    lock.withLock { !$0.isEmpty }
  }

  public init() {
    if let url = try? Self.storageURL,
      let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode([String: Pairing].self, from: data)
    {
      // Re-key with normalized (uppercased) identifiers for case-insensitive matching.
      let normalized = decoded.reduce(into: [String: Pairing]()) { result, entry in
        let key = Self.normalizeID(entry.key)
        result[key] = entry.value
        Self.logger.info("  Pairing: \(key) admin=\(entry.value.isAdmin)")
      }
      lock.withLock { $0 = normalized }
      Self.logger.info("Loaded \(normalized.count) pairing(s) from disk")
    }
  }

  /// Initializer for testing — does not load from or persist to disk.
  public init(testPairings: [String: Pairing]) {
    lock.withLock { $0 = testPairings }
  }

  /// Normalize pairing identifiers for case- and format-insensitive matching.
  /// Apple devices may send UUID pairing identifiers in varying cases across
  /// different connections (e.g. iPhone vs Apple TV hub), and theoretically
  /// with or without hyphens.
  private static func normalizeID(_ id: String) -> String {
    id.uppercased()
  }

  public func addPairing(_ pairing: Pairing) {
    let key = Self.normalizeID(pairing.identifier)
    let normalized = Pairing(
      identifier: key, publicKey: pairing.publicKey, isAdmin: pairing.isAdmin)
    // Mutate atomically under lock, then persist outside the lock.
    let snapshot = lock.withLock { state -> [String: Pairing] in
      state[key] = normalized
      return state
    }
    save(snapshot)
    Self.logger.info("Added pairing: \(key) admin=\(pairing.isAdmin)")
    onChange?()
  }

  /// Atomically adds the first admin pairing only if no pairings exist yet.
  /// Returns true if the pairing was added, false if the store was already paired
  /// or if persisting to disk failed.
  @discardableResult
  public func addPairingIfUnpaired(_ pairing: Pairing) -> Bool {
    let key = Self.normalizeID(pairing.identifier)
    let normalized = Pairing(
      identifier: key, publicKey: pairing.publicKey, isAdmin: pairing.isAdmin)
    // Atomically check emptiness and add under lock.
    let snapshot: [String: Pairing]? = lock.withLock { state -> [String: Pairing]? in
      guard state.isEmpty else { return nil }
      state[key] = normalized
      return state
    }
    guard let snapshot else { return false }
    guard save(snapshot) else {
      // Rollback on disk failure.
      lock.withLock { _ = $0.removeValue(forKey: key) }
      return false
    }
    Self.logger.info("Added first pairing: \(key) admin=\(pairing.isAdmin)")
    onChange?()
    return true
  }

  public func removePairing(identifier: String) {
    let key = Self.normalizeID(identifier)
    let snapshot: [String: Pairing]? = lock.withLock { state -> [String: Pairing]? in
      guard state.removeValue(forKey: key) != nil else { return nil }
      return state
    }
    guard let snapshot else { return }
    save(snapshot)
    onChange?()
  }

  public func getPairing(identifier: String) -> Pairing? {
    let key = Self.normalizeID(identifier)
    return lock.withLock { $0[key] }
  }

  public func removeAll() {
    lock.withLock { $0.removeAll() }
    save([:])
    onChange?()
  }

  @discardableResult
  private func save(_ state: [String: Pairing]) -> Bool {
    do {
      let data = try JSONEncoder().encode(state)
      try data.write(
        to: Self.storageURL,
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
      )
      return true
    } catch {
      Self.logger.error("Failed to save pairings: \(error)")
      return false
    }
  }
}
