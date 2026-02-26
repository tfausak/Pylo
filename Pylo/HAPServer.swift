import Foundation
import Network
import os

// MARK: - HAP Server
// Listens on TCP, advertises via Bonjour as _hap._tcp, and dispatches
// incoming HTTP requests to the appropriate handler.

final class HAPServer {

  private let listener: NWListener
  private let logger = Logger(subsystem: "com.example.hap", category: "Server")
  private let queue = DispatchQueue(label: "com.example.hap.server")

  /// Active connections keyed by a unique ID.
  private var connections: [String: HAPConnection] = [:]

  /// The bridge info accessory (aid=1).
  let bridge: HAPBridgeInfo

  /// All accessories served by this bridge, keyed by aid.
  private(set) var accessories: [Int: HAPAccessoryProtocol] = [:]

  /// Pairing state (persisted across app launches in a real implementation).
  let pairingStore: PairingStore

  /// Device identity (long-term Ed25519 key pair).
  let deviceIdentity: DeviceIdentity

  /// Configuration number — derived from a hash of the accessory database structure
  /// so it updates automatically whenever services or characteristics change.
  private(set) var configurationNumber: Int = 1

  init(
    bridge: HAPBridgeInfo, accessories: [HAPAccessoryProtocol], pairingStore: PairingStore,
    deviceIdentity: DeviceIdentity
  ) throws {
    self.bridge = bridge
    self.pairingStore = pairingStore
    self.deviceIdentity = deviceIdentity

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
      self.configurationNumber = Int(hash & 0x7FFF_FFFF) | 1  // ensure ≥ 1
    }
  }

  func start() {
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

  func stop() {
    listener.cancel()
    for conn in connections.values {
      conn.cancel()
    }
    connections.removeAll()
  }

  /// Update the Bonjour TXT record (e.g., after pairing state changes).
  func updateAdvertisement() {
    let txtItems = bonjourTXTRecord()
    let txtRecord = createTXTRecord(from: txtItems)
    listener.service = NWListener.Service(
      name: bridge.name,
      type: "_hap._tcp",
      txtRecord: txtRecord
    )
  }

  /// Look up an accessory by its aid.
  func accessory(aid: Int) -> HAPAccessoryProtocol? {
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

  func removeConnection(_ id: String) {
    connections.removeValue(forKey: id)
    logger.info("Connection removed: \(id)")
  }

  /// Notify all subscribed connections of a characteristic change.
  func notifySubscribers(aid: Int, iid: Int, value: Any) {
    let charID = CharacteristicID(aid: aid, iid: iid)
    for conn in connections.values {
      guard conn.eventSubscriptions.contains(charID) else { continue }
      conn.sendEvent(aid: aid, iid: iid, value: value)
    }
  }
}
