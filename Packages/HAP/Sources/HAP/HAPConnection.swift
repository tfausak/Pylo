import CryptoKit
import Foundation
import Network
import os
import TLV8

// MARK: - HAP Connection
// Manages a single TCP connection from a HomeKit controller (e.g., Home.app).
// Before pairing is verified, HTTP is plaintext. After pair-verify completes,
// all HTTP traffic is encrypted with ChaCha20-Poly1305.

public nonisolated final class HAPConnection: @unchecked Sendable {

  public let id: String
  private let connection: NWConnection
  private weak var server: HAPServer?
  private let queue: DispatchQueue
  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Connection")

  // All mutable state below is accessed exclusively on `queue`. The properties
  // use private(set) to enforce that external callers use the setter methods,
  // which document the queue-affinity contract.

  /// After pair-verify, this holds the session encryption context.
  public private(set) var encryptionContext: EncryptionContext?

  /// Set by pair-verify M3 handler; applied after the plaintext M4 response is sent.
  public private(set) var pendingEncryptionContext: EncryptionContext?

  /// Characteristics this connection is subscribed to (for EVENT notifications).
  public private(set) var eventSubscriptions: Set<CharacteristicID> = []

  /// The pairing identifier of the controller that authenticated this session.
  /// Set after pair-verify M3 succeeds; used to check admin status for /pairings.
  public private(set) var verifiedControllerID: String?

  /// The pairing session state (tracks in-progress pair-setup/verify).
  public private(set) var pairSetupState: PairSetupSession?
  public private(set) var pairVerifyState: PairVerifySession?

  /// The Curve25519 shared secret from pair-verify, stored for HDS key derivation.
  public private(set) var pairVerifySharedSecret: SharedSecret?

  public init(id: String, connection: NWConnection, server: HAPServer, queue: DispatchQueue) {
    self.id = id
    self.connection = connection
    self.server = server
    self.queue = queue
  }

  // MARK: - Queue-Affine Mutators
  // All callers must already be executing on `queue` (the connection's serial
  // dispatch queue). These methods enforce the @unchecked Sendable contract.

  public func setPendingEncryptionContext(_ ctx: EncryptionContext) {
    pendingEncryptionContext = ctx
  }

  public func setVerifiedControllerID(_ id: String?) {
    verifiedControllerID = id
  }

  public func setPairSetupState(_ state: PairSetupSession?) {
    pairSetupState = state
  }

  public func setPairVerifyState(_ state: PairVerifySession?) {
    pairVerifyState = state
  }

  public func setPairVerifySharedSecret(_ secret: SharedSecret?) {
    pairVerifySharedSecret = secret
  }

  public func subscribe(to charID: CharacteristicID) {
    eventSubscriptions.insert(charID)
  }

  public func unsubscribe(from charID: CharacteristicID) {
    eventSubscriptions.remove(charID)
  }

  public func start() {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.logger.debug("Connection \(self.id) ready")
        self.receiveNextRequest()
      case .failed(let error):
        self.logger.error("Connection \(self.id) failed: \(error)")
        self.cancel()
      case .cancelled:
        self.server?.removeConnection(self.id)
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  public func cancel() {
    connection.cancel()
  }

  // MARK: - Receive Loop

  /// Maximum receive buffer size (1 MB). If a client sends data that never
  /// forms a complete HTTP request and exceeds this limit, we disconnect to
  /// prevent unbounded memory growth.
  public static let maxBufferSize = 1_048_576

  /// Buffer for accumulating incoming data
  private var receiveBuffer = Data()

  /// Buffer for accumulating decrypted frame data into complete HTTP requests
  private var decryptedBuffer = Data()

  private func receiveNextRequest() {
    // Apply deferred encryption context from pair-verify (M4 was sent plaintext)
    if let pending = pendingEncryptionContext {
      encryptionContext = pending
      pendingEncryptionContext = nil
    }

    if encryptionContext != nil {
      receiveEncryptedFrame()
    } else {
      receivePlaintextHTTP()
    }
  }

  /// Read plaintext HTTP (before pair-verify is complete).
  private func receivePlaintextHTTP() {
    // Read up to 64KB — HAP messages are small.
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }

      if let error {
        self.logger.error("Receive error: \(error)")
        self.cancel()
        return
      }

      if let data, !data.isEmpty {
        // Append to buffer and try to parse complete requests
        self.receiveBuffer.append(data)

        if self.receiveBuffer.count > HAPConnection.maxBufferSize {
          self.logger.warning(
            "Receive buffer exceeded \(HAPConnection.maxBufferSize) bytes, disconnecting"
          )
          self.cancel()
          return
        }

        if !self.processHTTPBuffer() {
          return  // connection was cancelled (e.g. malformed request)
        }
      }

      if isComplete {
        self.cancel()
      } else {
        self.receiveNextRequest()
      }
    }
  }

  /// Process accumulated HTTP data, handling multiple requests if needed.
  /// Returns `true` if the connection is still alive and should continue receiving,
  /// `false` if the connection was cancelled (e.g. malformed request).
  @discardableResult
  private func processHTTPBuffer() -> Bool {
    // Keep processing as long as we can extract complete requests
    while true {
      switch HTTPRequest.parseAndConsume(&receiveBuffer) {
      case .request(let request):
        logger.info("\(request.method) \(request.path)")
        if let response = routeRequest(request) {
          sendResponse(response)
        }
      case .needsMoreData:
        return true
      case .malformed:
        logger.warning("Malformed HTTP request, sending 400 and closing")
        sendResponse(HTTPResponse(status: 400, body: nil, contentType: "application/hap+json"))
        cancel()
        return false
      }
    }
  }

  /// Read an encrypted HAP frame: [2-byte little-endian length][encrypted data][16-byte auth tag]
  /// Accumulates decrypted frames until a complete HTTP request is available.
  private func receiveEncryptedFrame() {
    // First read the 2-byte length prefix
    connection.receive(minimumIncompleteLength: 2, maximumLength: 2) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }

      if let error {
        self.logger.error("Encrypted receive error (length): \(error)")
        self.cancel()
        return
      }

      if isComplete {
        self.cancel()
        return
      }

      guard let data, data.count == 2 else {
        self.cancel()
        return
      }

      let frameLength = Int(data[0]) | (Int(data[1]) << 8)

      // HAP spec §6.5: frames are capped at 1024 plaintext bytes
      // and must carry at least 1 byte of payload.
      guard frameLength > 0, frameLength <= 1024 else {
        self.logger.error("Encrypted frame too large (\(frameLength) bytes), disconnecting")
        self.cancel()
        return
      }

      let totalLength = frameLength + 16  // + Poly1305 auth tag

      // Now read the encrypted payload + tag
      self.connection.receive(minimumIncompleteLength: totalLength, maximumLength: totalLength) {
        [weak self] payload, _, isComplete, error in
        guard let self else { return }

        if let error {
          self.logger.error("Encrypted receive error (payload): \(error)")
          self.cancel()
          return
        }

        if isComplete {
          self.cancel()
          return
        }

        guard let payload, payload.count == totalLength else {
          self.cancel()
          return
        }

        guard
          let decrypted = self.encryptionContext?.decrypt(
            lengthBytes: data,
            ciphertext: payload
          )
        else {
          self.logger.error("Decryption failed")
          self.cancel()
          return
        }

        // Accumulate decrypted data and try to parse complete HTTP requests
        self.decryptedBuffer.append(decrypted)

        if self.decryptedBuffer.count > HAPConnection.maxBufferSize {
          self.logger.warning(
            "Decrypted buffer exceeded \(HAPConnection.maxBufferSize) bytes, disconnecting"
          )
          self.cancel()
          return
        }

        loop: while true {
          switch HTTPRequest.parseAndConsume(&self.decryptedBuffer) {
          case .request(let request):
            self.logger.info("\(request.method) \(request.path)")
            if let response = self.routeRequest(request) {
              self.sendResponse(response)
            }
          case .needsMoreData:
            break loop
          case .malformed:
            self.logger.warning("Malformed HTTP request (encrypted), sending 400 and closing")
            self.sendResponse(
              HTTPResponse(status: 400, body: nil, contentType: "application/hap+json"))
            self.cancel()
            return
          }
        }

        self.receiveNextRequest()
      }
    }
  }

  // MARK: - Routing

  /// Routes a request and returns the response, or nil if the response
  /// will be sent asynchronously (e.g. snapshot capture).
  private func routeRequest(_ request: HTTPRequest) -> HTTPResponse? {
    guard let server else {
      return HTTPResponse(status: 500, body: nil, contentType: "application/hap+json")
    }

    switch (request.method, request.path) {
    case ("POST", "/pair-setup"):
      return handlePairSetup(request, server: server)

    case ("POST", "/pair-verify"):
      return handlePairVerify(request, server: server)

    case ("POST", "/identify"):
      return handleIdentify(server: server)

    case ("GET", "/accessories"),
      ("GET", _) where request.path.starts(with: "/characteristics"),
      ("PUT", "/characteristics"),
      ("PUT", "/prepare"),
      ("POST", "/resource"),
      ("POST", "/pairings"):
      // All post-verification endpoints require an encrypted session (HAP §5.13.1)
      guard encryptionContext != nil else {
        logger.warning("Rejected \(request.method) \(request.path) — session not verified")
        return HTTPResponse(status: 470, body: nil, contentType: "application/hap+json")
      }

      switch (request.method, request.path) {
      case ("GET", "/accessories"):
        return handleGetAccessories(server: server)
      case ("GET", _):
        return handleGetCharacteristics(request, server: server)
      case ("PUT", "/prepare"):
        return handlePrepare(request)
      case ("PUT", _):
        return handlePutCharacteristics(request, server: server)
      case ("POST", "/pairings"):
        return handlePairings(request, server: server)
      case ("POST", "/resource"):
        handleResource(request, server: server)
        return nil
      default:
        fatalError("unreachable")
      }

    default:
      logger.warning("Unknown route: \(request.method) \(request.path)")
      return HTTPResponse(status: 404, body: nil, contentType: "application/hap+json")
    }
  }

  // MARK: - Send Response

  private func sendResponse(_ response: HTTPResponse) {
    let httpData = response.serialize()

    if let ctx = encryptionContext {
      // Encrypt the response — close on failure since the write counter
      // is consumed and the session would be permanently desynced.
      guard let encrypted = ctx.encrypt(plaintext: httpData) else {
        logger.error("Encrypt failed, closing connection")
        cancel()
        return
      }
      connection.send(
        content: encrypted,
        completion: .contentProcessed { [weak self] error in
          if let error {
            self?.logger.error("Send error: \(error)")
          }
        })
    } else {
      connection.send(
        content: httpData,
        completion: .contentProcessed { [weak self] error in
          if let error {
            self?.logger.error("Send error: \(error)")
          }
        })
    }
  }

  // MARK: - EVENT Notifications

  /// Send an EVENT/1.0 200 OK notification to this connection for a characteristic change.
  public func sendEvent(aid: Int, iid: Int, value: HAPValue) {
    guard let ctx = encryptionContext else { return }

    let characteristic: [String: Any] = ["aid": aid, "iid": iid, "value": value.jsonValue]
    let body: [String: Any] = ["characteristics": [characteristic]]
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

    var event = "EVENT/1.0 200 OK\r\n"
    event += "Content-Type: application/hap+json\r\n"
    event += "Content-Length: \(bodyData.count)\r\n"
    event += "\r\n"
    var data = Data(event.utf8)
    data.append(bodyData)

    guard let encrypted = ctx.encrypt(plaintext: data) else {
      logger.error("EVENT encrypt failed, closing connection")
      cancel()
      return
    }
    connection.send(
      content: encrypted,
      completion: .contentProcessed { [weak self] error in
        if let error {
          self?.logger.error("EVENT send error: \(error)")
        }
      })
  }

  // MARK: - Endpoint Handlers (stubs — implemented in separate files)

  private func handlePairSetup(_ request: HTTPRequest, server: HAPServer) -> HTTPResponse {
    // Implemented in PairSetup.swift
    PairSetupHandler.handle(request: request, connection: self, server: server)
  }

  private func handlePairVerify(_ request: HTTPRequest, server: HAPServer) -> HTTPResponse {
    // Implemented in PairVerify.swift
    PairVerifyHandler.handle(request: request, connection: self, server: server)
  }

  private func handleGetAccessories(server: HAPServer) -> HTTPResponse {
    // Return all accessories (bridge + sub-accessories), sorted by aid
    let allJSON = server.accessories.keys.sorted().compactMap { server.accessories[$0]?.toJSON() }
    let responseObj: [String: Any] = ["accessories": allJSON]
    guard let data = try? JSONSerialization.data(withJSONObject: responseObj) else {
      return HTTPResponse(status: 500, body: nil, contentType: "application/hap+json")
    }
    logger.debug("GET /accessories response (\(data.count) bytes)")
    return HTTPResponse(status: 200, body: data, contentType: "application/hap+json")
  }

  private func handleGetCharacteristics(_ request: HTTPRequest, server: HAPServer) -> HTTPResponse {
    // Parse ?id=1.10,1.11 from query string
    // For PoC, return current characteristic values
    return CharacteristicsHandler.handleGet(request: request, server: server)
  }

  private func handlePutCharacteristics(_ request: HTTPRequest, server: HAPServer) -> HTTPResponse {
    return CharacteristicsHandler.handlePut(request: request, connection: self, server: server)
  }

  /// Handle PUT /prepare for HAP timed writes (HAP §6.7.2.4).
  /// The hub sends a prepare request with a PID and TTL before timed writes.
  /// We acknowledge the prepare — the subsequent PUT /characteristics with
  /// the matching PID is processed normally (we don't enforce the TTL).
  private func handlePrepare(_ request: HTTPRequest) -> HTTPResponse {
    // Just acknowledge the prepare — we accept all timed writes.
    let body = try? JSONSerialization.data(withJSONObject: ["status": 0])
    return HTTPResponse(status: 200, body: body, contentType: "application/hap+json")
  }

  private func handleIdentify(server: HAPServer) -> HTTPResponse {
    // Identify is only valid when not paired. Flash the torch briefly.
    if server.pairingStore.isPaired {
      // Return -70401 (insufficient privileges) when paired
      let body = try? JSONSerialization.data(withJSONObject: ["status": -70401])
      return HTTPResponse(status: 400, body: body, contentType: "application/hap+json")
    }
    // Trigger identify on all accessories
    for accessory in server.accessories.values {
      accessory.identify()
    }
    return HTTPResponse(status: 204, body: nil, contentType: "application/hap+json")
  }

  private func handlePairings(_ request: HTTPRequest, server: HAPServer) -> HTTPResponse {
    return PairingsHandler.handle(request: request, connection: self, server: server)
  }

  /// Handles POST /resource asynchronously — dispatches snapshot capture
  /// to a background queue so it doesn't block the server's connection handling.
  private func handleResource(_ request: HTTPRequest, server: HAPServer) {
    // POST /resource — Home.app requests JPEG snapshots for camera tiles.
    // Body: {"aid": 3, "image-width": 320, "image-height": 240, "resource-type": "image"}
    guard let body = request.body,
      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let aid = json["aid"] as? Int,
      let resourceType = json["resource-type"] as? String,
      resourceType == "image",
      let camera = server.accessory(aid: aid) as? HAPSnapshotProvider
    else {
      sendResponse(HTTPResponse(status: 404, body: nil, contentType: "application/hap+json"))
      return
    }

    // Respect Camera Operating Mode snapshot settings
    let reason = json["reason"] as? Int
    if camera.hksvEnabled {
      if reason == 0 && !camera.periodicSnapshotsActive {
        let body = try? JSONSerialization.data(withJSONObject: ["status": -70412])
        sendResponse(HTTPResponse(status: 200, body: body, contentType: "application/hap+json"))
        return
      }
      if reason == 1 && !camera.eventSnapshotsActive {
        let body = try? JSONSerialization.data(withJSONObject: ["status": -70412])
        sendResponse(HTTPResponse(status: 200, body: body, contentType: "application/hap+json"))
        return
      }
    }

    let width = json["image-width"] as? Int ?? 320
    let height = json["image-height"] as? Int ?? 240
    logger.info(
      "Snapshot requested: \(width)x\(height) from aid \(aid), reason=\(reason.map(String.init) ?? "none")"
    )

    // camera is @unchecked Sendable in practice (concrete types conform);
    // use nonisolated(unsafe) to satisfy strict concurrency in SPM.
    nonisolated(unsafe) let unsafeCamera = camera
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let jpeg = unsafeCamera.captureSnapshot(width: width, height: height)
      // Dispatch back to the server queue so sendResponse (which uses
      // the encryption context) doesn't race with other I/O.
      self?.queue.async {
        if let jpeg {
          self?.sendResponse(HTTPResponse(status: 200, body: jpeg, contentType: "image/jpeg"))
        } else {
          self?.logger.warning("Snapshot capture failed")
          self?.sendResponse(
            HTTPResponse(status: 500, body: nil, contentType: "application/hap+json"))
        }
      }
    }
  }
}
