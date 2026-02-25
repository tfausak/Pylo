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

    /// The accessory this server exposes.
    let accessory: HAPAccessory

    /// Pairing state (persisted across app launches in a real implementation).
    let pairingStore: PairingStore

    /// Device identity (long-term Ed25519 key pair).
    let deviceIdentity: DeviceIdentity

    /// Current configuration number. Increment when accessory DB changes.
    var configurationNumber: Int = 1

    init(accessory: HAPAccessory, pairingStore: PairingStore, deviceIdentity: DeviceIdentity) throws {
        self.accessory = accessory
        self.pairingStore = pairingStore
        self.deviceIdentity = deviceIdentity

        // Create TCP listener on a random available port.
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        self.listener = try NWListener(using: params)
    }

    func start() {
        // Configure Bonjour advertisement.
        let txtItems = bonjourTXTRecord()
        let txtRecord = createTXTRecord(from: txtItems)
        listener.service = NWListener.Service(
            name: accessory.name,
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
            name: accessory.name,
            type: "_hap._tcp",
            txtRecord: txtRecord
        )
    }

    // MARK: - Bonjour TXT Record

    private func bonjourTXTRecord() -> [String: String] {
        [
            "c#": "\(configurationNumber)",  // Configuration number
            "ff": "0",                        // Feature flags (0 = supports HAP pairing)
            "id": deviceIdentity.deviceID,    // Device ID (AA:BB:CC:DD:EE:FF format)
            "md": accessory.model,            // Model name
            "pv": "1.1",                      // Protocol version
            "s#": "1",                        // State number
            "sf": pairingStore.isPaired ? "0" : "1",  // Status flags: 1=discoverable
            "ci": "\(accessory.category.rawValue)",    // Accessory category
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
        // EVENT/1.0 200 OK notifications go here.
        // For the PoC, we can implement this later.
    }
}
