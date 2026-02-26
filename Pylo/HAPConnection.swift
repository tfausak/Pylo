import Foundation
import Network
import os

// MARK: - HAP Connection
// Manages a single TCP connection from a HomeKit controller (e.g., Home.app).
// Before pairing is verified, HTTP is plaintext. After pair-verify completes,
// all HTTP traffic is encrypted with ChaCha20-Poly1305.

final class HAPConnection {

  let id: String
  private let connection: NWConnection
  private weak var server: HAPServer?
  private let queue: DispatchQueue
  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "Connection")

  /// After pair-verify, this holds the session encryption context.
  var encryptionContext: EncryptionContext?

  /// Set by pair-verify M3 handler; applied after the plaintext M4 response is sent.
  var pendingEncryptionContext: EncryptionContext?

  /// Characteristics this connection is subscribed to (for EVENT notifications).
  var eventSubscriptions: Set<CharacteristicID> = []

  /// The pairing identifier of the controller that authenticated this session.
  /// Set after pair-verify M3 succeeds; used to check admin status for /pairings.
  var verifiedControllerID: String?

  /// The pairing session state (tracks in-progress pair-setup/verify).
  var pairSetupState: PairSetupSession?
  var pairVerifyState: PairVerifySession?

  init(id: String, connection: NWConnection, server: HAPServer, queue: DispatchQueue) {
    self.id = id
    self.connection = connection
    self.server = server
    self.queue = queue
  }

  func start() {
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

  func cancel() {
    connection.cancel()
  }

  // MARK: - Receive Loop

  /// Maximum receive buffer size (1 MB). If a client sends data that never
  /// forms a complete HTTP request and exceeds this limit, we disconnect to
  /// prevent unbounded memory growth.
  static let maxBufferSize = 1_048_576

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

        self.processHTTPBuffer()
      }

      if isComplete {
        self.cancel()
      } else {
        self.receiveNextRequest()
      }
    }
  }

  /// Process accumulated HTTP data, handling multiple requests if needed
  private func processHTTPBuffer() {
    // Keep processing as long as we can extract complete requests
    while let request = HTTPRequest.parseAndConsume(&receiveBuffer) {
      logger.info("\(request.method) \(request.path)")
      if let response = routeRequest(request) {
        sendResponse(response)
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

        while let request = HTTPRequest.parseAndConsume(&self.decryptedBuffer) {
          self.logger.info("\(request.method) \(request.path)")
          if let response = self.routeRequest(request) {
            self.sendResponse(response)
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

    case ("GET", "/accessories"):
      return handleGetAccessories(server: server)

    case ("GET", let path) where path.starts(with: "/characteristics"):
      return handleGetCharacteristics(request, server: server)

    case ("PUT", "/characteristics"):
      return handlePutCharacteristics(request, server: server)

    case ("POST", "/identify"):
      return handleIdentify(server: server)

    case ("POST", "/pairings"):
      return handlePairings(request, server: server)

    case ("POST", "/resource"):
      handleResource(request, server: server)
      return nil

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
  func sendEvent(aid: Int, iid: Int, value: HAPValue) {
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
      let camera = server.accessory(aid: aid) as? HAPCameraAccessory
    else {
      sendResponse(HTTPResponse(status: 404, body: nil, contentType: "application/hap+json"))
      return
    }

    let width = json["image-width"] as? Int ?? 320
    let height = json["image-height"] as? Int ?? 240
    logger.info("Snapshot requested: \(width)x\(height) from aid \(aid)")

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let jpeg = camera.captureSnapshot(width: width, height: height)
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

// MARK: - Characteristic ID (for event subscriptions)

struct CharacteristicID: Hashable, Sendable {
  let aid: Int
  let iid: Int
}

// MARK: - Minimal HTTP Request/Response

struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data?

  /// Very basic HTTP/1.1 request parser — sufficient for HAP.
  /// Only parses headers as UTF-8; the body is kept as raw Data
  /// (TLV8 bodies may contain non-UTF-8 binary like Ed25519 keys).
  static func parse(_ data: Data) -> HTTPRequest? {
    var buffer = data
    return parseAndConsume(&buffer)
  }

  /// Parse a complete HTTP request from buffer and consume it.
  /// Returns nil if there's not enough data for a complete request.
  static func parseAndConsume(_ buffer: inout Data) -> HTTPRequest? {
    // Look for \r\n\r\n to find end of headers
    guard let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
      // No complete headers yet
      return nil
    }

    let headerEnd = headerEndRange.upperBound
    let headerData = buffer[buffer.startIndex..<headerEndRange.lowerBound]

    guard let headerStr = String(data: headerData, encoding: .utf8) else {
      // Invalid UTF-8, clear bad data
      buffer.removeAll()
      return nil
    }

    let lines = headerStr.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      buffer.removeAll()
      return nil
    }

    let requestParts = requestLine.split(separator: " ", maxSplits: 2)
    guard requestParts.count >= 2 else {
      buffer.removeAll()
      return nil
    }

    let method = String(requestParts[0])
    let path = String(requestParts[1])

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      if let colonIndex = line.firstIndex(of: ":") {
        let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
          .lowercased()
        let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        headers[key] = value
      }
    }

    // Check Content-Length
    let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0

    // Check if we have the complete body
    let totalNeeded = headerEnd + contentLength
    guard buffer.count >= totalNeeded else {
      // Not enough data yet
      return nil
    }

    // Extract body
    var body: Data?
    if contentLength > 0 {
      body = buffer[headerEnd..<(headerEnd + contentLength)]
    }

    // Remove this request from the buffer
    buffer.removeSubrange(buffer.startIndex..<totalNeeded)

    return HTTPRequest(method: method, path: path, headers: headers, body: body)
  }
}

struct HTTPResponse {
  let status: Int
  let body: Data?
  let contentType: String

  var statusText: String {
    switch status {
    case 200: return "OK"
    case 204: return "No Content"
    case 207: return "Multi-Status"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 422: return "Unprocessable Entity"
    case 500: return "Internal Server Error"
    default: return "Unknown"
    }
  }

  func serialize() -> Data {
    var result = "HTTP/1.1 \(status) \(statusText)\r\n"
    result += "Content-Type: \(contentType)\r\n"
    if let body {
      result += "Content-Length: \(body.count)\r\n"
    } else {
      result += "Content-Length: 0\r\n"
    }
    result += "\r\n"

    var data = Data(result.utf8)
    if let body {
      data.append(body)
    }
    return data
  }
}
