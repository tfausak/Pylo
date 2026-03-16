import CryptoKit
import Foundation
import FragmentedMP4
import Locked
import Network
import TLV8
import os

// MARK: - HomeKit Data Stream (HDS)

/// Implements the HomeKit Data Stream protocol for HKSV video transfer.
/// HDS runs on a separate TCP connection with its own ChaCha20-Poly1305 encryption,
/// derived from the HAP pair-verify shared secret.
public final class HAPDataStream: @unchecked Sendable {

  private let logger = Logger(subsystem: logSubsystem, category: "DataStream")

  /// All mutable state protected by stateLock, since setupTransport runs
  /// on the HAP queue and newConnectionHandler/listener callbacks run on
  /// the HDS queue.
  private struct State {
    var listener: NWListener?
    var connection: HDSConnection?
    var fragmentWriter: FragmentedMP4Writer?
    var pendingReadKey: SymmetricKey?
    var pendingWriteKey: SymmetricKey?
    /// The HDS serial dispatch queue. Set in startListener, used to dispatch
    /// connection setup from setupTransport (which runs on the HAP queue).
    var queue: DispatchQueue?
  }
  private let stateLock = Locked(initialState: State())

  /// Port the listener is bound to.
  public var port: UInt16? {
    stateLock.withLockUnchecked { $0.listener?.port?.rawValue }
  }

  /// Active HDS connection to the hub.
  public var connection: HDSConnection? {
    stateLock.withLockUnchecked { $0.connection }
  }

  /// The fragment writer to serve prebuffered and live video from.
  /// Strong reference — HAPDataStream owns the writer's lifetime while active.
  public var fragmentWriter: FragmentedMP4Writer? {
    get { stateLock.withLockUnchecked { $0.fragmentWriter } }
    set { stateLock.withLockUnchecked { $0.fragmentWriter = newValue } }
  }

  public init() {}

  /// Start the HDS TCP listener on a random port.
  /// Cancels any existing listener before creating a new one.
  public func startListener() throws {
    // Cancel any existing listener to avoid leaking TCP ports and queues
    let oldListener = stateLock.withLockUnchecked { s -> NWListener? in
      let old = s.listener
      s.listener = nil
      return old
    }
    oldListener?.cancel()

    let params = NWParameters.tcp
    let listener = try NWListener(using: params)

    let queue = DispatchQueue(label: "\(logSubsystem).datastream")

    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        if let port = self?.stateLock.withLockUnchecked({ $0.listener?.port }) {
          self?.logger.info("HDS listener ready on port \(port.rawValue)")
        }
      case .failed(let error):
        self?.logger.error("HDS listener failed: \(error)")
      default:
        break
      }
    }

    listener.newConnectionHandler = { [weak self] nwConnection in
      guard let self else { return }
      self.logger.info("HDS: new TCP connection from hub")

      let conn = HDSConnection(connection: nwConnection, queue: queue)

      // Snapshot state under lock, then perform side effects outside
      let (oldConn, writer, keys) = self.stateLock.withLockUnchecked {
        s -> (HDSConnection?, FragmentedMP4Writer?, (SymmetricKey, SymmetricKey)?) in
        let old = s.connection
        s.connection = conn
        let w = s.fragmentWriter
        var k: (SymmetricKey, SymmetricKey)? = nil
        if let rk = s.pendingReadKey, let wk = s.pendingWriteKey {
          k = (rk, wk)
          s.pendingReadKey = nil
          s.pendingWriteKey = nil
        }
        return (old, w, k)
      }

      oldConn?.cancel()
      conn.fragmentWriter = writer
      if let (readKey, writeKey) = keys {
        conn.setupEncryption(readKey: readKey, writeKey: writeKey)
        conn.start()
      } else {
        // Keys not yet available — setupTransport hasn't been called.
        // Set a watchdog to cancel this connection if keys never arrive.
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
          guard let self else { return }
          // Check isEncrypted (not pendingReadKey == nil) to distinguish
          // "keys never arrived" from "keys were applied and cleared".
          let orphaned = self.stateLock.withLockUnchecked { s -> Bool in
            guard s.connection === conn, !conn.isEncrypted else { return false }
            s.connection = nil
            return true
          }
          if orphaned {
            self.logger.warning("HDS: cancelling orphaned connection (no keys after 30s)")
            conn.cancel()
          }
        }
      }
    }

    listener.start(queue: queue)
    stateLock.withLockUnchecked { s in
      s.listener = listener
      s.queue = queue
    }
  }

  /// Handle the SetupDataStreamTransport write from the hub.
  /// Returns the response TLV with the accessory's key salt and TCP port.
  ///
  /// Request TLV (flat):
  ///   Tag 1: Session command type (1 byte, 0 = START_SESSION)
  ///   Tag 2: Transport type (1 byte, 0 = HDS over TCP)
  ///   Tag 3: Controller key salt (32 bytes)
  ///
  /// Response TLV (flat):
  ///   Tag 1: Status (1 byte, 0 = SUCCESS)
  ///   Tag 2: Transport session parameters (nested: Tag 1 = TCP port uint16)
  ///   Tag 3: Accessory key salt (32 bytes)
  public func setupTransport(requestTLV: Data, sharedSecret: SharedSecret) -> Data {
    let tlvs = TLV8.decode(requestTLV) as [(UInt8, Data)]

    // Parse flat TLV fields
    var sessionCommand: UInt8 = 0xFF
    var transportType: UInt8 = 0xFF
    var controllerKeySalt = Data()

    for (tag, val) in tlvs {
      switch tag {
      case 0x01: if let v = val.first { sessionCommand = v }
      case 0x02: if let v = val.first { transportType = v }
      case 0x03: controllerKeySalt = val
      default: break
      }
    }

    logger.debug(
      "SetupDataStreamTransport: cmd=\(sessionCommand) transport=\(transportType) salt=\(controllerKeySalt.count)B"
    )

    guard sessionCommand == 0x00, transportType == 0x00, controllerKeySalt.count == 32 else {
      logger.error("SetupDataStreamTransport: invalid request")
      var error = TLV8.Builder()
      error.add(0x01, byte: 0x01)  // Status: Generic Error
      return error.build()
    }

    // Generate accessory key salt (32 bytes random)
    let accessoryKeySalt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

    // Derive HDS encryption keys via HKDF-SHA512
    // Salt = controllerKeySalt || accessoryKeySalt
    // IKM = shared secret from pair-verify
    //
    // Key names are from the controller's perspective:
    //   "HDS-Read-Encryption-Key"  = what the controller reads (accessory->controller)
    //   "HDS-Write-Encryption-Key" = what the controller writes (controller->accessory)
    let hkdfSalt = controllerKeySalt + accessoryKeySalt

    // Derive keys directly from SharedSecret to avoid leaking key material
    // into unzeroed Data intermediaries.
    let readKey = sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA512.self,
      salt: hkdfSalt,
      sharedInfo: Data("HDS-Write-Encryption-Key".utf8),
      outputByteCount: 32
    )

    let writeKey = sharedSecret.hkdfDerivedSymmetricKey(
      using: SHA512.self,
      salt: hkdfSalt,
      sharedInfo: Data("HDS-Read-Encryption-Key".utf8),
      outputByteCount: 32
    )

    logger.debug(
      "HDS keys derived: controllerSalt=\(controllerKeySalt.count)B, accessorySalt=\(accessoryKeySalt.count)B"
    )

    // Check port availability BEFORE mutating state — if the listener isn't
    // ready, we must not store keys or start connections for a session the hub
    // considers failed.
    guard let listenPort = port else {
      logger.error("SetupDataStreamTransport: HDS listener not ready (port unavailable)")
      var error = TLV8.Builder()
      error.add(0x01, byte: 0x01)  // Status: Generic Error
      return error.build()
    }

    // If a TCP connection arrived before keys were available (TCP-first ordering),
    // start it now with the newly-derived keys. Otherwise, store keys as pending
    // for newConnectionHandler to pick up.
    let (oldConn, connToStart, hdsQueue) = stateLock.withLockUnchecked {
      s -> (HDSConnection?, HDSConnection?, DispatchQueue?) in
      let old = s.connection
      // If a connection is waiting (not yet encrypted), start it with keys directly.
      if let waiting = old, !waiting.isEncrypted {
        // Clear pending keys — they'll be applied directly.
        s.pendingReadKey = nil
        s.pendingWriteKey = nil
        return (nil, waiting, s.queue)
      }
      // Otherwise, cancel the old connection (different HAP session) and store
      // keys for the next newConnectionHandler call.
      s.connection = nil
      s.pendingReadKey = readKey
      s.pendingWriteKey = writeKey
      return (old, nil, s.queue)
    }
    oldConn?.cancel()

    // Start the waiting connection on the HDS queue (setupTransport runs on the HAP queue).
    if let conn = connToStart, let q = hdsQueue {
      q.async {
        conn.setupEncryption(readKey: readKey, writeKey: writeKey)
        conn.start()
      }
    }

    var transportParams = TLV8.Builder()
    transportParams.add(0x01, uint16: UInt16(listenPort))  // TCP listening port

    var response = TLV8.Builder()
    response.add(0x01, byte: 0x00)  // Status: Success
    response.add(0x02, tlv: transportParams)  // Transport session parameters
    response.add(0x03, accessoryKeySalt)  // Accessory key salt

    return response.build()
  }

  /// Stop the HDS listener and close any active connection.
  public func stop() {
    let (conn, lst) = stateLock.withLockUnchecked { s -> (HDSConnection?, NWListener?) in
      let c = s.connection
      let l = s.listener
      s.connection = nil
      s.listener = nil
      s.fragmentWriter = nil
      s.pendingReadKey = nil
      s.pendingWriteKey = nil
      return (c, l)
    }
    conn?.cancel()
    lst?.cancel()
  }
}
