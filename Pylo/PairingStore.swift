import Foundation
import os

// MARK: - Pairing Store
// Stores paired controllers (their Ed25519 public keys and identifiers).

nonisolated final class PairingStore: @unchecked Sendable {

  struct Pairing: Codable {
    let identifier: String  // Controller's pairing ID (UUID string)
    let publicKey: Data  // Controller's Ed25519 LTPK (32 bytes)
    let isAdmin: Bool
  }

  private static let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "PairingStore")

  /// Called whenever pairings are added or removed.
  /// Protected by its own lock: set from @MainActor, called from the server queue.
  private let _onChange = OSAllocatedUnfairLock<(() -> Void)?>(initialState: nil)
  var onChange: (() -> Void)? {
    get { _onChange.withLock { $0 } }
    set { _onChange.withLock { $0 = newValue } }
  }

  /// Lock-protected pairings dictionary.
  private let lock = OSAllocatedUnfairLock(initialState: [String: Pairing]())

  /// Thread-safe snapshot of all pairings.
  var pairings: [String: Pairing] {
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

  var isPaired: Bool {
    lock.withLock { !$0.isEmpty }
  }

  init() {
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
  init(testPairings: [String: Pairing]) {
    lock.withLock { $0 = testPairings }
  }

  /// Normalize pairing identifiers for case- and format-insensitive matching.
  /// Apple devices may send UUID pairing identifiers in varying cases across
  /// different connections (e.g. iPhone vs Apple TV hub), and theoretically
  /// with or without hyphens.
  private static func normalizeID(_ id: String) -> String {
    id.uppercased()
  }

  func addPairing(_ pairing: Pairing) {
    let key = Self.normalizeID(pairing.identifier)
    lock.withLock { $0[key] = pairing }
    if !save() {
      // Roll back in-memory state so it stays consistent with disk.
      lock.withLock { _ = $0.removeValue(forKey: key) }
      return
    }
    Self.logger.info("Added pairing: \(key) admin=\(pairing.isAdmin)")
    onChange?()
  }

  /// Atomically adds the first admin pairing only if no pairings exist yet.
  /// Returns true if the pairing was added, false if the store was already paired
  /// or if persisting to disk failed.
  @discardableResult
  func addPairingIfUnpaired(_ pairing: Pairing) -> Bool {
    let key = Self.normalizeID(pairing.identifier)
    let added = lock.withLock { state -> Bool in
      guard state.isEmpty else { return false }
      state[key] = pairing
      return true
    }
    guard added else { return false }
    if !save() {
      // Roll back — the pairing must not exist only in memory.
      lock.withLock { _ = $0.removeValue(forKey: key) }
      return false
    }
    Self.logger.info("Added first pairing: \(key) admin=\(pairing.isAdmin)")
    onChange?()
    return true
  }

  func removePairing(identifier: String) {
    let key = Self.normalizeID(identifier)
    let old = lock.withLock { $0.removeValue(forKey: key) }
    if !save(), let old {
      lock.withLock { $0[Self.normalizeID(old.identifier)] = old }
      return
    }
    onChange?()
  }

  func getPairing(identifier: String) -> Pairing? {
    let key = Self.normalizeID(identifier)
    return lock.withLock { $0[key] }
  }

  func removeAll() {
    let snapshot = lock.withLock { state -> [String: Pairing] in
      let copy = state
      state.removeAll()
      return copy
    }
    if !save() {
      lock.withLock { $0 = snapshot }
      return
    }
    onChange?()
  }

  @discardableResult
  private func save() -> Bool {
    let snapshot = lock.withLock { $0 }
    do {
      let data = try JSONEncoder().encode(snapshot)
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
