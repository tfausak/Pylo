import CryptoKit
import Foundation
import Network
import os

// MARK: - HAP Server
// Listens on TCP, advertises via Bonjour as _hap._tcp, and dispatches
// incoming HTTP requests to the appropriate handler.
//
// NOTE: This is an unauthorized implementation of the HomeKit Accessory
// Protocol (HAP). Apple's MFi Program requires licensing for HAP accessories.
// This app may be rejected from the App Store under Guidelines 5.2.1
// (proprietary protocols) and 2.5.1 (public APIs). Sideloading is the
// fallback distribution method.

public nonisolated final class HAPServer: @unchecked Sendable {

  private let listener: NWListener
  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Server")
  private let queue = DispatchQueue(label: "me.fausak.taylor.Pylo.server")
  private static let queueKey = DispatchSpecificKey<Bool>()

  /// Active connections keyed by a unique ID.
  private var connections: [String: HAPConnection] = [:]

  /// The bridge info accessory (aid=1).
  public let bridge: HAPBridgeInfo

  /// All accessories served by this bridge, keyed by aid.
  public private(set) var accessories: [Int: HAPAccessoryProtocol] = [:]

  /// Pairing state (persisted across app launches in a real implementation).
  public let pairingStore: PairingStore

  /// Device identity (long-term Ed25519 key pair).
  public let deviceIdentity: DeviceIdentity

  /// HDS (HomeKit Data Stream) handler for HKSV video transfer.
  /// Access is synchronized through the server queue.
  private var _dataStream: HAPDataStream?
  public var dataStream: HAPDataStream? {
    get {
      if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
        return _dataStream
      } else {
        return queue.sync { _dataStream }
      }
    }
    set {
      if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
        _dataStream = newValue
      } else {
        queue.sync { _dataStream = newValue }
      }
    }
  }

  /// Configuration number — derived from a hash of the accessory database structure
  /// so it updates automatically whenever services or characteristics change.
  public private(set) var configurationNumber: Int = 1

  public init(
    bridge: HAPBridgeInfo, accessories: [HAPAccessoryProtocol], pairingStore: PairingStore,
    deviceIdentity: DeviceIdentity
  ) throws {
    self.bridge = bridge
    self.pairingStore = pairingStore
    self.deviceIdentity = deviceIdentity

    queue.setSpecific(key: Self.queueKey, value: true)

    // Register bridge and all sub-accessories
    self.accessories[bridge.aid] = bridge
    for accessory in accessories {
      self.accessories[accessory.aid] = accessory
    }

    // Create TCP listener on a random available port.
    let params = NWParameters.tcp
    params.includePeerToPeer = true
    self.listener = try NWListener(using: params)

    // Compute c# from the accessory database structure so it auto-updates
    // when services/characteristics change (HAP spec §6.6.1, range 1...4294967295).
    let allJSON = self.accessories.keys.sorted().compactMap { self.accessories[$0]?.toJSON() }
    if let data = try? JSONSerialization.data(withJSONObject: allJSON),
      let str = String(data: data, encoding: .utf8)
    {
      var hash: UInt32 = 5381
      for byte in str.utf8 { hash = hash &* 33 &+ UInt32(byte) }
      let n = Int(hash & 0x7FFF_FFFF)
      self.configurationNumber = n == 0 ? 1 : n  // ensure ≥ 1 (HAP spec §6.6.1)
    }
  }

  public func start() {
    // Configure Bonjour advertisement.
    let txtItems = bonjourTXTRecord()
    let txtRecord = createTXTRecord(from: txtItems)
    listener.service = NWListener.Service(
      name: bridge.name,
      type: "_hap._tcp",
      txtRecord: txtRecord
    )

    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        if let port = self.listener.port {
          self.logger.info("HAP server listening on port \(port.rawValue)")
        }
      case .failed(let error):
        self.logger.error("Listener failed: \(error)")
        self.listener.cancel()
      default:
        break
      }
    }

    listener.newConnectionHandler = { [weak self] connection in
      self?.handleNewConnection(connection)
    }

    listener.start(queue: queue)
  }

  /// Look up the pair-verify shared secret from any active verified connection.
  /// Used by HDS to derive its encryption keys.
  public func sharedSecretForVerifiedConnection() -> SharedSecret? {
    let block = { [self] () -> SharedSecret? in
      for conn in connections.values {
        if let secret = conn.pairVerifySharedSecret {
          return secret
        }
      }
      return nil
    }
    if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
      return block()
    } else {
      return queue.sync(execute: block)
    }
  }

  /// Clear the pair-verify shared secret from all connections.
  /// Called after HDS keys have been derived so the raw DH secret
  /// does not remain in memory for the session's lifetime.
  public func clearVerifiedSharedSecrets() {
    if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
      for conn in connections.values {
        conn.setPairVerifySharedSecret(nil)
      }
    } else {
      queue.async { [self] in
        for conn in connections.values {
          conn.setPairVerifySharedSecret(nil)
        }
      }
    }
  }

  public func stop() {
    dataStream?.stop()
    dataStream = nil
    // Remove connections from the dictionary first, then cancel them.
    // This avoids a deadlock: NWConnection.cancel() fires
    // stateUpdateHandler(.cancelled) on this same serial queue, which
    // calls removeConnection() — a re-entrant dispatch that deadlocks
    // if we're inside queue.sync.
    let snapshotBlock = { [self] () -> [HAPConnection] in
      let conns = Array(connections.values)
      connections.removeAll()
      return conns
    }
    let snapshot: [HAPConnection]
    if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
      snapshot = snapshotBlock()
    } else {
      snapshot = queue.sync(execute: snapshotBlock)
    }
    listener.cancel()
    for conn in snapshot {
      conn.cancel()
    }
  }

  /// Update the Bonjour TXT record (e.g., after pairing state changes).
  public func updateAdvertisement() {
    queue.async { [self] in
      let txtItems = bonjourTXTRecord()
      let txtRecord = createTXTRecord(from: txtItems)
      listener.service = NWListener.Service(
        name: bridge.name,
        type: "_hap._tcp",
        txtRecord: txtRecord
      )
    }
  }

  /// Look up an accessory by its aid.
  public func accessory(aid: Int) -> HAPAccessoryProtocol? {
    accessories[aid]
  }

  // MARK: - Bonjour TXT Record

  private func bonjourTXTRecord() -> [String: String] {
    [
      "c#": "\(configurationNumber)",  // Configuration number
      "ff": "0",  // Feature flags (0 = supports HAP pairing)
      "id": deviceIdentity.deviceID,  // Device ID (AA:BB:CC:DD:EE:FF format)
      "md": bridge.model,  // Model name
      "pv": "1.1",  // Protocol version
      "s#": "1",  // State number
      "sf": pairingStore.isPaired ? "0" : "1",  // Status flags: 1=discoverable
      "ci": "\(HAPAccessoryCategory.bridge.rawValue)",  // Bridge category
      // Setup hash for QR pairing
      "sh": PairSetupHandler.setupHash(deviceID: deviceIdentity.deviceID),
    ]
  }

  /// Creates an NWTXTRecord from a dictionary of key-value pairs.
  private func createTXTRecord(from items: [String: String]) -> NWTXTRecord {
    var txtRecord = NWTXTRecord()
    for (key, value) in items {
      txtRecord[key] = value
    }
    return txtRecord
  }

  // MARK: - Connection Handling

  private func handleNewConnection(_ nwConnection: NWConnection) {
    let id = UUID().uuidString
    let connection = HAPConnection(
      id: id,
      connection: nwConnection,
      server: self,
      queue: queue
    )
    connections[id] = connection
    connection.start()
    logger.info("New connection: \(id)")
  }

  /// Remove a connection from the active set. Safe to call from any thread.
  public func removeConnection(_ id: String) {
    queue.async { [weak self] in
      guard let self else { return }
      self.connections.removeValue(forKey: id)
      self.logger.info("Connection removed: \(id)")
    }
  }

  /// Terminate all sessions belonging to a specific controller (HAP spec §5.11).
  public func terminateSessions(forController controllerID: String) {
    queue.async { [weak self] in
      guard let self else { return }
      let toRemove = self.connections.filter { $0.value.verifiedControllerID == controllerID }
      for (id, conn) in toRemove {
        conn.cancel()
        self.connections.removeValue(forKey: id)
      }
    }
  }

  /// Terminate sessions after a short delay to let the current response flush.
  /// Used by pairing removal (HAP §5.11) to ensure M2 is delivered before teardown.
  public func terminateSessionsAfterResponse(forController controllerID: String) {
    queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self else { return }
      let toRemove = self.connections.filter { $0.value.verifiedControllerID == controllerID }
      for (id, conn) in toRemove {
        conn.cancel()
        self.connections.removeValue(forKey: id)
      }
    }
  }

  /// Notify all subscribed connections of a characteristic change.
  /// Dispatches to the server queue so `connections` is accessed thread-safely.
  public func notifySubscribers(aid: Int, iid: Int, value: HAPValue) {
    queue.async { [weak self] in
      guard let self else { return }
      let charID = CharacteristicID(aid: aid, iid: iid)
      for conn in self.connections.values {
        guard conn.eventSubscriptions.contains(charID) else { continue }
        conn.sendEvent(aid: aid, iid: iid, value: value)
      }
    }
  }
}
