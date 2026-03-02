import CryptoKit
import FragmentedMP4
import Foundation
import Network
import TLV8
import os

// MARK: - HomeKit Data Stream (HDS)

/// Implements the HomeKit Data Stream protocol for HKSV video transfer.
/// HDS runs on a separate TCP connection with its own ChaCha20-Poly1305 encryption,
/// derived from the HAP pair-verify shared secret.
public nonisolated final class HAPDataStream: @unchecked Sendable {

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "DataStream")

  /// All mutable state protected by stateLock, since setupTransport runs
  /// on the HAP queue and newConnectionHandler/listener callbacks run on
  /// the HDS queue.
  private struct State {
    var listener: NWListener?
    var connection: HDSConnection?
    var fragmentWriter: FragmentedMP4Writer?
    var pendingReadKey: SymmetricKey?
    var pendingWriteKey: SymmetricKey?
  }
  private let stateLock = OSAllocatedUnfairLock(initialState: State())

  /// Port the listener is bound to.
  public var port: UInt16? {
    stateLock.withLock { $0.listener?.port?.rawValue }
  }

  /// Active HDS connection to the hub.
  public var connection: HDSConnection? {
    stateLock.withLock { $0.connection }
  }

  /// The fragment writer to serve prebuffered and live video from.
  public weak var fragmentWriter: FragmentedMP4Writer? {
    get { stateLock.withLock { $0.fragmentWriter } }
    set { stateLock.withLock { $0.fragmentWriter = newValue } }
  }

  public init() {}

  /// Start the HDS TCP listener on a random port.
  public func startListener() throws {
    let params = NWParameters.tcp
    let listener = try NWListener(using: params)

    let queue = DispatchQueue(label: "me.fausak.taylor.Pylo.datastream")

    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        if let port = self?.stateLock.withLock({ $0.listener?.port }) {
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
      let (oldConn, writer, keys) = self.stateLock.withLock { s -> (HDSConnection?, FragmentedMP4Writer?, (SymmetricKey, SymmetricKey)?) in
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
      }
    }

    listener.start(queue: queue)
    stateLock.withLock { $0.listener = listener }
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

    logger.info(
      "SetupDataStreamTransport: cmd=\(sessionCommand) transport=\(transportType) salt=\(controllerKeySalt.count)B"
    )

    guard sessionCommand == 0x00, transportType == 0x00, controllerKeySalt.count == 32 else {
      logger.error("SetupDataStreamTransport: invalid request")
      var error = TLV8.Builder()
      error.add(0x01, byte: 0x01)  // Status: Generic Error
      return error.build()
    }

    // Generate accessory key salt (32 bytes random)
    var accessoryKeySalt = Data(count: 32)
    accessoryKeySalt.withUnsafeMutableBytes {
      _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
    }

    // Derive HDS encryption keys via HKDF-SHA512
    // Salt = controllerKeySalt || accessoryKeySalt
    // IKM = shared secret from pair-verify
    //
    // Key names are from the controller's perspective:
    //   "HDS-Read-Encryption-Key"  = what the controller reads (accessory→controller)
    //   "HDS-Write-Encryption-Key" = what the controller writes (controller→accessory)
    let hkdfSalt = controllerKeySalt + accessoryKeySalt
    let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }

    let readKey = HKDF<SHA512>.deriveSymmetricKey(
      inputKeyMaterial: sharedSecretData,
      salt: hkdfSalt,
      info: Data("HDS-Write-Encryption-Key".utf8),
      outputByteCount: 32
    )

    let writeKey = HKDF<SHA512>.deriveSymmetricKey(
      inputKeyMaterial: sharedSecretData,
      salt: hkdfSalt,
      info: Data("HDS-Read-Encryption-Key".utf8),
      outputByteCount: 32
    )

    logger.info(
      "HDS keys derived: controllerSalt=\(controllerKeySalt.count)B, accessorySalt=\(accessoryKeySalt.count)B"
    )

    let oldConn = stateLock.withLock { s -> HDSConnection? in
      // Cancel any existing encrypted connection.
      let old = s.connection
      s.connection = nil

      // Store keys — typically the hub connects AFTER this HAP write completes,
      // so the connection doesn't exist yet.  Keys are applied in
      // newConnectionHandler when the TCP connection actually arrives.
      s.pendingReadKey = readKey
      s.pendingWriteKey = writeKey
      return old
    }
    oldConn?.cancel()

    // Build response TLV (flat format matching HAP-NodeJS)
    let listenPort = port ?? 0

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
    let (conn, lst) = stateLock.withLock { s -> (HDSConnection?, NWListener?) in
      let c = s.connection
      let l = s.listener
      s.connection = nil
      s.listener = nil
      s.pendingReadKey = nil
      s.pendingWriteKey = nil
      return (c, l)
    }
    conn?.cancel()
    lst?.cancel()
  }
}

// MARK: - HDS Connection

/// A single HDS TCP connection with encryption and message framing.
public nonisolated final class HDSConnection: @unchecked Sendable {

  private let connection: NWConnection
  private let queue: DispatchQueue
  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "HDSConn")

  private var readKey: SymmetricKey?
  private var writeKey: SymmetricKey?
  private var readNonce: UInt64 = 0
  private var writeNonce: UInt64 = 0
  private let nonceLock = OSAllocatedUnfairLock(initialState: ())

  /// The fragment writer to serve video from.
  public weak var fragmentWriter: FragmentedMP4Writer?

  /// Active dataSend stream ID (assigned by the hub in dataSend/open).
  private var activeStreamID: Int?

  /// Whether the init segment has been sent for the current recording session.
  private var initSegmentSent = false

  /// Whether we've logged the first data event for diagnostics.
  private var hasLoggedFirstDataEvent = false

  /// Data sequence counter for dataSend chunks.
  private var dataSequenceNumber = 0

  public init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  public func setupEncryption(readKey: SymmetricKey, writeKey: SymmetricKey) {
    self.readKey = readKey
    self.writeKey = writeKey
  }

  public func start() {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        self?.logger.info("HDS connection ready")
        self?.receiveFrame()
      case .failed(let error):
        self?.logger.error("HDS connection failed: \(error)")
      case .cancelled:
        self?.logger.info("HDS connection cancelled")
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  public func cancel() {
    connection.cancel()
  }

  // MARK: - Frame Protocol

  /// HDS frame format:
  /// [1-byte type] [3-byte BE payload length] [encrypted payload] [16-byte auth tag]
  /// Type 1 = regular encrypted frame
  private func receiveFrame() {
    // Read the 4-byte header: 1 byte type + 3 bytes big-endian length
    connection.receive(minimumIncompleteLength: 4, maximumLength: 4) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }

      if let error {
        self.logger.error("HDS receive header error: \(error)")
        return
      }

      if isComplete {
        self.logger.info("HDS connection closed by hub")
        return
      }

      guard let data, data.count == 4 else { return }

      let frameType = data[data.startIndex]
      let payloadLen =
        Int(data[data.startIndex + 1]) << 16
        | Int(data[data.startIndex + 2]) << 8
        | Int(data[data.startIndex + 3])

      // Cap at 512 KB to prevent memory exhaustion from malformed frames.
      // Real HDS frames (fMP4 fragments) are well under this limit.
      guard payloadLen > 0, payloadLen <= 512_000 else {
        self.logger.error("HDS frame too large (\(payloadLen) bytes), disconnecting")
        self.cancel()
        return
      }

      let totalRead = payloadLen + 16  // + Poly1305 tag

      self.connection.receive(
        minimumIncompleteLength: totalRead, maximumLength: totalRead
      ) { [weak self] payload, _, _, error in
        guard let self else { return }

        if let error {
          self.logger.error("HDS receive payload error: \(error)")
          return
        }

        guard let payload, payload.count == totalRead else { return }

        guard let decrypted = self.decryptFrame(type: frameType, header: data, payload: payload)
        else {
          self.logger.error("HDS decryption failed, closing connection")
          self.cancel()
          return
        }
        self.handleDecryptedMessage(decrypted)

        self.receiveFrame()
      }
    }
  }

  private func decryptFrame(type: UInt8, header: Data, payload: Data) -> Data? {
    guard let readKey else { return nil }

    let nonce = nonceLock.withLock { _ -> ChaChaPoly.Nonce in
      let n = Self.makeHDSNonce(counter: readNonce)
      readNonce += 1
      return n
    }

    guard payload.count >= 16 else { return nil }
    let ciphertext = payload[payload.startIndex..<payload.endIndex - 16]
    let tag = payload[payload.endIndex - 16..<payload.endIndex]

    // AAD = the 4-byte frame header
    do {
      let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
      return try ChaChaPoly.open(sealedBox, using: readKey, authenticating: header)
    } catch {
      logger.error("HDS decrypt failed: \(error)")
      return nil
    }
  }

  /// Send an encrypted HDS frame.
  private func sendFrame(_ plaintext: Data) {
    guard let writeKey else { return }

    let nonce = nonceLock.withLock { _ -> ChaChaPoly.Nonce in
      let n = Self.makeHDSNonce(counter: writeNonce)
      writeNonce += 1
      return n
    }

    // Build the 4-byte header
    var header = Data(count: 4)
    header[0] = 0x01  // Type: encrypted frame
    header[1] = UInt8((plaintext.count >> 16) & 0xFF)
    header[2] = UInt8((plaintext.count >> 8) & 0xFF)
    header[3] = UInt8(plaintext.count & 0xFF)

    do {
      let sealed = try ChaChaPoly.seal(
        plaintext, using: writeKey, nonce: nonce, authenticating: header)
      var frame = header
      frame.append(sealed.ciphertext)
      frame.append(sealed.tag)

      connection.send(
        content: frame,
        completion: .contentProcessed { [weak self] error in
          if let error {
            self?.logger.error("HDS send error: \(error)")
          }
        })
    } catch {
      logger.error("HDS encrypt failed: \(error)")
    }
  }

  /// HDS nonces are 8 bytes of zero + 4 bytes LE counter (12 bytes total).
  private static func makeHDSNonce(counter: UInt64) -> ChaChaPoly.Nonce {
    var nonceData = Data(repeating: 0, count: 4)
    var le = counter.littleEndian
    nonceData.append(Data(bytes: &le, count: 8))
    guard let nonce = try? ChaChaPoly.Nonce(data: nonceData) else {
      preconditionFailure("HDS nonce construction failed")
    }
    return nonce
  }

  // MARK: - HDS Message Protocol

  /// HDS messages are encoded as header + body.
  /// Header fields: protocol (string), topic (string), identifier (int), status (int, response only)
  /// The encoding uses a custom compact binary format.
  private func handleDecryptedMessage(_ data: Data) {
    // Parse the HDS message
    guard let message = HDSMessage.decode(data) else {
      let hex = data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
      logger.warning("Failed to decode HDS message (\(data.count) bytes): \(hex)")
      return
    }

    logger.info(
      "HDS message: type=\(message.type.rawValue) protocol=\(message.protocol) topic=\(message.topic) id=\(message.identifier)"
    )

    switch (message.protocol, message.topic, message.type) {
    case ("control", "hello", .request):
      // Respond to hello with a hello response
      let response = HDSMessage(
        type: .response,
        protocol: "control",
        topic: "hello",
        identifier: message.identifier,
        status: .success,
        body: [:]
      )
      sendMessage(response)

    case ("dataSend", "open", .request):
      handleDataSendOpen(message)

    case ("dataSend", "close", .request):
      handleDataSendClose(message)

    case ("dataSend", "close", .event):
      // Hub may send close events for specific streams or for cleanup.
      // Only clear our active stream if the event matches.
      // Reason codes: 0=normal, 5=unexpected_failure, 6=timeout, 7=bad_data, 9=invalid_config
      let closeStreamID = message.body["streamId"] as? Int
      let closeReason = message.body["reason"] as? Int
      let bodyKeys = message.body.keys.sorted().joined(separator: ",")
      logger.warning(
        "HDS dataSend/close event: streamId=\(closeStreamID.map(String.init) ?? "nil"), reason=\(closeReason.map(String.init) ?? "nil"), active=\(self.activeStreamID.map(String.init) ?? "nil"), bodyKeys=[\(bodyKeys)]"
      )
      if closeStreamID == nil || closeStreamID == activeStreamID {
        activeStreamID = nil
      }

    case ("dataSend", "ack", .event):
      // Hub acknowledges received data — log and continue
      let ackStreamID = message.body["streamId"] as? Int
      let ackEndOfStream = message.body["endOfStream"] as? Bool
      logger.info(
        "HDS dataSend/ack (streamId=\(ackStreamID.map(String.init) ?? "nil"), endOfStream=\(ackEndOfStream.map(String.init) ?? "nil"))"
      )

    default:
      logger.info("HDS unhandled: \(message.protocol)/\(message.topic)")
      // Send error response for requests
      if message.type == .request {
        let response = HDSMessage(
          type: .response,
          protocol: message.protocol,
          topic: message.topic,
          identifier: message.identifier,
          status: .protocolError,
          body: [:]
        )
        sendMessage(response)
      }
    }
  }

  private func handleDataSendOpen(_ message: HDSMessage) {
    // The hub requests to open a data channel for camera recording.
    // Fields: target="controller", type="ipcamera.recording", streamId, reason
    let target = message.body["target"] as? String ?? ""
    let type = message.body["type"] as? String ?? ""
    let reason = message.body["reason"] as? String ?? ""

    guard type == "ipcamera.recording" else {
      logger.warning("HDS dataSend/open: unsupported type=\(type) target=\(target)")
      let response = HDSMessage(
        type: .response,
        protocol: "dataSend",
        topic: "open",
        identifier: message.identifier,
        status: .protocolError,
        body: ["status": 1]
      )
      sendMessage(response)
      return
    }

    let streamID = message.body["streamId"] as? Int ?? 1
    activeStreamID = streamID
    dataSequenceNumber = 1
    initSegmentSent = false
    hasLoggedFirstDataEvent = false

    logger.info(
      "HDS dataSend/open: type=\(type) target=\(target) reason=\(reason) streamId=\(streamID)")

    // Respond with success
    let response = HDSMessage(
      type: .response,
      protocol: "dataSend",
      topic: "open",
      identifier: message.identifier,
      status: .success,
      body: ["status": 0]
    )
    sendMessage(response)

    // Start sending prebuffered + live fragments
    sendPrebufferedFragments()
  }

  private func handleDataSendClose(_ message: HDSMessage) {
    let closeStreamID = message.body["streamId"] as? Int
    let closeReason = message.body["reason"] as? Int
    logger.info(
      "HDS dataSend/close request (streamId=\(closeStreamID.map(String.init) ?? "nil"), reason=\(closeReason.map(String.init) ?? "nil"), active=\(self.activeStreamID.map(String.init) ?? "nil"))"
    )
    if closeStreamID == nil || closeStreamID == activeStreamID {
      activeStreamID = nil
    }

    let response = HDSMessage(
      type: .response,
      protocol: "dataSend",
      topic: "close",
      identifier: message.identifier,
      status: .success,
      body: [:]
    )
    sendMessage(response)
  }

  private func sendMessage(_ message: HDSMessage) {
    let encoded = message.encode()
    sendFrame(encoded)
  }

  // MARK: - Data Sending

  private static let maxChunkSize = 262_144  // 256KB

  /// Whether to send endOfStream after the next live fragment completes.
  private var pendingEndOfStream = false
  /// Called after endOfStream is sent, so the caller can delay notifications.
  private var endOfStreamCompletion: (() -> Void)?

  /// Send prebuffered fragments from the ring buffer, then set up live streaming.
  private func sendPrebufferedFragments() {
    guard let writer = fragmentWriter else {
      logger.warning("HDS sendPrebufferedFragments: no fragmentWriter")
      return
    }

    // Send the init segment first (ftyp + moov)
    if let initSeg = writer.initSegment {
      let hex = initSeg.prefix(128).map { String(format: "%02x", $0) }.joined(separator: " ")
      logger.info("HDS sending init segment: \(initSeg.count) bytes, hex: \(hex)")
      sendDataChunks(initSeg, dataType: "mediaInitialization", isLast: false)
      initSegmentSent = true
    } else {
      logger.warning("HDS: no init segment available (will send with first fragment)")
    }

    // Send prebuffered fragments
    let fragments = writer.ringBuffer.snapshot()
    logger.info("HDS sending \(fragments.count) prebuffered fragment(s)")
    for fragment in fragments {
      sendDataChunks(fragment.data, dataType: "mediaFragment", isLast: false)
    }

    // Set up live fragment delivery
    pendingEndOfStream = false
    writer.onFragmentReady = { [weak self] (fragment: MP4Fragment) in
      self?.queue.async {
        guard let self, self.activeStreamID != nil else { return }

        // Send init segment before first fragment if it wasn't available at open time
        if !self.initSegmentSent, let w = self.fragmentWriter, let initSeg = w.initSegment {
          self.logger.info("HDS sending deferred init segment: \(initSeg.count) bytes")
          self.sendDataChunks(initSeg, dataType: "mediaInitialization", isLast: false)
          self.initSegmentSent = true
        }

        // Embed endOfStream in the last chunk of the last fragment (HAP-NodeJS pattern)
        let isLast = self.pendingEndOfStream
        self.sendDataChunks(fragment.data, dataType: "mediaFragment", isLast: isLast)

        if isLast {
          self.pendingEndOfStream = false
          self.logger.info("HDS endOfStream sent with final fragment")
          self.activeStreamID = nil
          let completion = self.endOfStreamCompletion
          self.endOfStreamCompletion = nil
          completion?()
        }
      }
    }
  }

  /// Signal that the current recording should end after the next fragment completes.
  /// The optional completion handler is called after endOfStream is sent, allowing
  /// the caller to delay motion-cleared notifications until the stream is done.
  public func finishRecording(completion: (() -> Void)? = nil) {
    queue.async { [weak self] in
      guard let self else { return }
      if self.activeStreamID != nil {
        self.logger.info("HDS: finishing recording (will send endOfStream after next fragment)")
        self.pendingEndOfStream = true
        self.endOfStreamCompletion = completion
      } else {
        completion?()
      }
    }
  }

  /// Split data into chunks and send as dataSend/data events.
  /// Uses manual byte construction to match positron's exact HDS encoding
  /// (fixed key ordering + DATA_LENGTH32LE for the data field).
  private func sendDataChunks(_ data: Data, dataType: String, isLast: Bool) {
    guard let streamID = activeStreamID else { return }

    let maxChunk = Self.maxChunkSize
    var offset = 0
    var chunkSeq = 1
    let totalSize = data.count

    while offset < data.count {
      let end = min(offset + maxChunk, data.count)
      let chunk = Data(data[offset..<end])
      let isLastChunk = end >= data.count

      let message = buildRawDataSendEvent(
        streamID: streamID,
        dataType: dataType,
        dataSequenceNumber: dataSequenceNumber,
        dataChunkSequenceNumber: chunkSeq,
        isLastDataChunk: isLastChunk,
        dataTotalSize: chunkSeq == 1 ? totalSize : nil,
        endOfStream: isLast && isLastChunk,
        chunk: chunk
      )

      // Log first data event for diagnostics (header + metadata only, not the bulk data)
      if !hasLoggedFirstDataEvent {
        hasLoggedFirstDataEvent = true
        let headerEnd = min(message.count, 200)
        let hex = message.prefix(headerEnd).map { String(format: "%02x", $0) }.joined(
          separator: " ")
        logger.info("HDS first data event (\(message.count) bytes): \(hex)")
      }

      sendFrame(message)

      offset = end
      chunkSeq += 1
    }

    dataSequenceNumber += 1
  }

  // MARK: - Raw dataSend/data Message Builder

  /// Build a raw dataSend/data HDS event message with exact byte ordering
  /// matching positron's known-working implementation. This bypasses HDSCodec's
  /// generic dictionary encoding which produces non-deterministic key ordering.
  private func buildRawDataSendEvent(
    streamID: Int,
    dataType: String,
    dataSequenceNumber: Int,
    dataChunkSequenceNumber: Int,
    isLastDataChunk: Bool,
    dataTotalSize: Int?,
    endOfStream: Bool,
    chunk: Data
  ) -> Data {
    var buf = Data()

    // ---- Header: dict{protocol: "dataSend", event: "data"} ----
    let headerBytes: [UInt8] = [
      0xE2,  // dict of 2
      0x48, 0x70, 0x72, 0x6F, 0x74, 0x6F, 0x63, 0x6F, 0x6C,  // "protocol"
      0x48, 0x64, 0x61, 0x74, 0x61, 0x53, 0x65, 0x6E, 0x64,  // "dataSend"
      0x45, 0x65, 0x76, 0x65, 0x6E, 0x74,  // "event"
      0x44, 0x64, 0x61, 0x74, 0x61,  // "data"
    ]
    buf.append(UInt8(headerBytes.count))  // header length
    buf.append(contentsOf: headerBytes)

    // ---- Body dict (2 or 3 entries) ----
    buf.append(endOfStream ? 0xE3 : 0xE2)

    // streamId → number
    buf.append(contentsOf: [0x48, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x49, 0x64])
    Self.appendHDSInt(&buf, streamID)

    // endOfStream → true (optional)
    if endOfStream {
      buf.append(contentsOf: [
        0x4B,  // string of 11
        0x65, 0x6E, 0x64, 0x4F, 0x66, 0x53, 0x74, 0x72, 0x65, 0x61, 0x6D,
        0x01,  // TRUE
      ])
    }

    // packets → array(1) → dict(2){metadata, data}
    buf.append(contentsOf: [
      0x47, 0x70, 0x61, 0x63, 0x6B, 0x65, 0x74, 0x73,  // "packets"
      0xD1,  // array of 1
      0xE2,  // dict of 2 (metadata + data)
      0x48, 0x6D, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61,  // "metadata"
    ])

    // metadata dict (4 or 5 entries)
    buf.append(dataTotalSize != nil ? 0xE5 : 0xE4)

    // dataType → string (HDS short-string encoding: 0x40 + length, max 32 bytes)
    buf.append(contentsOf: [0x48, 0x64, 0x61, 0x74, 0x61, 0x54, 0x79, 0x70, 0x65])
    let dtBytes = Data(dataType.utf8)
    precondition(dtBytes.count <= 32, "dataType too long for HDS short-string encoding (\(dtBytes.count) > 32)")
    buf.append(UInt8(0x40 + dtBytes.count))
    buf.append(dtBytes)

    // dataSequenceNumber → number
    buf.append(contentsOf: [
      0x52,  // string of 18
      0x64, 0x61, 0x74, 0x61, 0x53, 0x65, 0x71, 0x75, 0x65, 0x6E, 0x63, 0x65,
      0x4E, 0x75, 0x6D, 0x62, 0x65, 0x72,
    ])
    Self.appendHDSInt(&buf, dataSequenceNumber)

    // isLastDataChunk → bool
    buf.append(contentsOf: [
      0x4F,  // string of 15
      0x69, 0x73, 0x4C, 0x61, 0x73, 0x74, 0x44, 0x61, 0x74, 0x61, 0x43, 0x68,
      0x75, 0x6E, 0x6B,
    ])
    buf.append(isLastDataChunk ? 0x01 : 0x02)

    // dataChunkSequenceNumber → number
    buf.append(contentsOf: [
      0x57,  // string of 23
      0x64, 0x61, 0x74, 0x61, 0x43, 0x68, 0x75, 0x6E, 0x6B, 0x53, 0x65, 0x71,
      0x75, 0x65, 0x6E, 0x63, 0x65, 0x4E, 0x75, 0x6D, 0x62, 0x65, 0x72,
    ])
    Self.appendHDSInt(&buf, dataChunkSequenceNumber)

    // dataTotalSize → number (only on first chunk)
    if let totalSize = dataTotalSize {
      buf.append(contentsOf: [
        0x4D,  // string of 13
        0x64, 0x61, 0x74, 0x61, 0x54, 0x6F, 0x74, 0x61, 0x6C, 0x53, 0x69,
        0x7A, 0x65,
      ])
      Self.appendHDSInt(&buf, totalSize)
    }

    // data → binary (always DATA_LENGTH32LE = 0x93, matching positron)
    buf.append(contentsOf: [0x44, 0x64, 0x61, 0x74, 0x61])  // "data"
    buf.append(0x93)
    var dataLen = UInt32(chunk.count).littleEndian
    buf.append(Data(bytes: &dataLen, count: 4))
    buf.append(chunk)

    return buf
  }

  /// Append an integer in HDS codec format (matching positron's writeNumber).
  private static func appendHDSInt(_ buf: inout Data, _ value: Int) {
    if value == -1 {
      buf.append(0x07)
    } else if value >= 0 && value <= 39 {
      buf.append(UInt8(0x08 + value))
    } else if value >= -128 && value <= 127 {
      buf.append(0x30)
      buf.append(UInt8(bitPattern: Int8(value)))
    } else if value >= -32768 && value <= 32767 {
      buf.append(0x31)
      var le = Int16(value).littleEndian
      buf.append(Data(bytes: &le, count: 2))
    } else if value >= Int(Int32.min) && value <= Int(Int32.max) {
      buf.append(0x32)
      var le = Int32(value).littleEndian
      buf.append(Data(bytes: &le, count: 4))
    } else {
      buf.append(0x33)
      var le = Int64(value).littleEndian
      buf.append(Data(bytes: &le, count: 8))
    }
  }

}

// MARK: - HDS Message

/// Represents an HDS protocol message with header and body.
public nonisolated struct HDSMessage {

  public enum MessageType: UInt8 {
    case event = 1
    case request = 2
    case response = 3
  }

  public enum Status: Int {
    case success = 0
    case protocolError = 1
  }

  public let type: MessageType
  public let `protocol`: String
  public let topic: String
  public let identifier: Int
  public let status: Status
  public let body: [String: Any]

  public init(
    type: MessageType,
    protocol proto: String,
    topic: String,
    identifier: Int,
    status: Status,
    body: [String: Any]
  ) {
    self.type = type
    self.protocol = proto
    self.topic = topic
    self.identifier = identifier
    self.status = status
    self.body = body
  }

  // MARK: - Encoding

  /// Encode this message into the HDS binary format.
  /// Format: [1-byte header length] [header] [body]
  /// Header and body are each encoded with the HDS DataStream codec.
  public func encode() -> Data {
    var header: [String: Any] = [
      "protocol": self.protocol
    ]

    switch type {
    case .event:
      header["event"] = topic
    case .request:
      header["request"] = topic
      header["id"] = identifier
    case .response:
      header["response"] = topic
      header["id"] = identifier
      header["status"] = status.rawValue
    }

    let headerData = HDSCodec.encode(header)
    let bodyData = HDSCodec.encode(body)

    var result = Data()
    precondition(headerData.count <= 255, "HDS header too large: \(headerData.count) bytes")
    result.append(UInt8(headerData.count))  // 1-byte header length prefix
    result.append(headerData)
    result.append(bodyData)
    return result
  }

  // MARK: - Decoding

  /// Decode an HDS message from binary data.
  /// Format: [1-byte header length] [header] [body]
  public static func decode(_ data: Data) -> HDSMessage? {
    guard data.count >= 1 else { return nil }

    let headerLen = Int(data[0])
    let headerStart = 1
    let bodyStart = headerStart + headerLen

    guard bodyStart <= data.count else { return nil }

    // Decode header dictionary
    let headerSlice = Data(data[headerStart..<bodyStart])
    guard let headerDict = HDSCodec.decode(headerSlice) as? [String: Any] else { return nil }

    // Decode body dictionary (may be empty)
    var bodyDict: [String: Any] = [:]
    if bodyStart < data.count {
      let bodySlice = Data(data[bodyStart...])
      if let bd = HDSCodec.decode(bodySlice) as? [String: Any] {
        bodyDict = bd
      }
    }

    guard let proto = headerDict["protocol"] as? String else { return nil }

    // Determine message type from header keys (not a "type" field)
    let messageType: MessageType
    let topic: String
    var identifier = 0
    var status = Status.success

    if let event = headerDict["event"] as? String {
      messageType = .event
      topic = event
    } else if let request = headerDict["request"] as? String {
      messageType = .request
      topic = request
      identifier = headerDict["id"] as? Int ?? 0
    } else if let response = headerDict["response"] as? String {
      messageType = .response
      topic = response
      identifier = headerDict["id"] as? Int ?? 0
      let statusRaw = headerDict["status"] as? Int ?? 0
      status = Status(rawValue: statusRaw) ?? .success
    } else {
      return nil
    }

    return HDSMessage(
      type: messageType,
      protocol: proto,
      topic: topic,
      identifier: identifier,
      status: status,
      body: bodyDict
    )
  }
}

// MARK: - HDS DataStream Codec

/// Binary codec for HDS (HomeKit Data Stream) messages.
/// This implements the DataStream serialization format used by HomeKit hubs
/// for the HDS protocol. It uses different tag values from Apple's OPack format.
public nonisolated enum HDSCodec {

  // MARK: - Encode

  /// Encode a dictionary to HDS binary format.
  public static func encode(_ dict: [String: Any]) -> Data {
    var data = Data()
    encodeDict(dict, into: &data)
    return data
  }

  private static func encodeDict(_ dict: [String: Any], into data: inout Data) {
    let count = dict.count
    if count <= 14 {
      data.append(UInt8(0xE0 + count))  // Length-prefixed dictionary
    } else {
      data.append(0xEF)  // Terminated dictionary
    }
    for key in dict.keys.sorted() {
      encodeString(key, into: &data)
      encodeValue(dict[key]!, into: &data)
    }
    if count > 14 {
      data.append(0x03)  // Terminator
    }
  }

  private static func encodeValue(_ value: Any, into data: inout Data) {
    switch value {
    case let v as Bool:
      data.append(v ? 0x01 : 0x02)  // TRUE=0x01, FALSE=0x02

    case let v as Int:
      encodeInt(v, into: &data)

    case let v as String:
      encodeString(v, into: &data)

    case let v as Data:
      encodeBinary(v, into: &data)

    case let v as [String: Any]:
      encodeDict(v, into: &data)

    case let v as [[String: Any]]:
      encodeArray(v.map { $0 as Any }, into: &data)

    case let v as [Any]:
      encodeArray(v, into: &data)

    default:
      data.append(0x04)  // NULL
    }
  }

  private static func encodeArray(_ arr: [Any], into data: inout Data) {
    let count = arr.count
    if count <= 14 {
      data.append(UInt8(0xD0 + count))  // Length-prefixed array
    } else {
      data.append(0xDF)  // Terminated array
    }
    for item in arr {
      encodeValue(item, into: &data)
    }
    if count > 14 {
      data.append(0x03)  // Terminator
    }
  }

  private static func encodeInt(_ value: Int, into data: inout Data) {
    if value == -1 {
      data.append(0x07)  // INTEGER_MINUS_ONE
    } else if value >= 0 && value <= 39 {
      data.append(UInt8(0x08 + value))  // Inline 0–39
    } else if value >= -128 && value <= 127 {
      data.append(0x30)
      data.append(UInt8(bitPattern: Int8(value)))
    } else if value >= -32768 && value <= 32767 {
      data.append(0x31)
      var le = Int16(value).littleEndian
      data.append(Data(bytes: &le, count: 2))
    } else if value >= -2_147_483_648 && value <= 2_147_483_647 {
      data.append(0x32)
      var le = Int32(value).littleEndian
      data.append(Data(bytes: &le, count: 4))
    } else {
      data.append(0x33)
      var le = Int64(value).littleEndian
      data.append(Data(bytes: &le, count: 8))
    }
  }

  private static func encodeString(_ string: String, into data: inout Data) {
    let utf8 = Data(string.utf8)
    let len = utf8.count
    if len <= 32 {
      data.append(UInt8(0x40 + len))  // Short string (0x40–0x60)
    } else if len <= 0xFF {
      data.append(0x61)
      data.append(UInt8(len))
    } else if len <= 0xFFFF {
      data.append(0x62)
      var le = UInt16(len).littleEndian
      data.append(Data(bytes: &le, count: 2))
    } else {
      data.append(0x63)
      var le = UInt32(len).littleEndian
      data.append(Data(bytes: &le, count: 4))
    }
    data.append(utf8)
  }

  private static func encodeBinary(_ binary: Data, into data: inout Data) {
    let len = binary.count
    if len <= 32 {
      data.append(UInt8(0x70 + len))  // Short data (0x70–0x90)
    } else if len <= 0xFF {
      data.append(0x91)
      data.append(UInt8(len))
    } else if len <= 0xFFFF {
      data.append(0x92)
      var le = UInt16(len).littleEndian
      data.append(Data(bytes: &le, count: 2))
    } else {
      data.append(0x93)
      var le = UInt32(len).littleEndian
      data.append(Data(bytes: &le, count: 4))
    }
    data.append(binary)
  }

  // MARK: - Decode

  /// Decode an HDS binary blob into a Swift value (typically a dictionary).
  public static func decode(_ data: Data) -> Any? {
    var tracked: [Any] = []
    var offset = 0
    return decodeValue(data, offset: &offset, tracked: &tracked)
  }

  private static func decodeValue(
    _ data: Data, offset: inout Int, tracked: inout [Any]
  ) -> Any? {
    guard offset < data.count else { return nil }

    let tag = data[offset]
    offset += 1

    switch tag {
    case 0x00:  // INVALID
      return nil

    case 0x01:  // TRUE
      tracked.append(true)
      return true

    case 0x02:  // FALSE
      tracked.append(false)
      return false

    case 0x04:  // NULL
      return NSNull()

    case 0x05:  // UUID (16 bytes big-endian)
      guard offset + 16 <= data.count else { return nil }
      let bytes = [UInt8](data[offset..<offset + 16])
      offset += 16
      let str = NSUUID(uuidBytes: bytes).uuidString
      tracked.append(str)
      return str

    case 0x06:  // DATE (float64 seconds since 2001-01-01)
      guard offset + 8 <= data.count else { return nil }
      let bits =
        UInt64(data[offset])
        | UInt64(data[offset + 1]) << 8
        | UInt64(data[offset + 2]) << 16
        | UInt64(data[offset + 3]) << 24
        | UInt64(data[offset + 4]) << 32
        | UInt64(data[offset + 5]) << 40
        | UInt64(data[offset + 6]) << 48
        | UInt64(data[offset + 7]) << 56
      offset += 8
      let v = Double(bitPattern: bits)
      tracked.append(v)
      return v

    case 0x07:  // INTEGER -1
      tracked.append(-1)
      return -1

    case 0x08...0x2F:  // Small integer 0–39
      let v = Int(tag - 0x08)
      tracked.append(v)
      return v

    case 0x30:  // Int8
      guard offset < data.count else { return nil }
      let v = Int(Int8(bitPattern: data[offset]))
      offset += 1
      tracked.append(v)
      return v

    case 0x31:  // Int16 LE
      guard offset + 2 <= data.count else { return nil }
      let v = Int(Int16(littleEndian: Int16(data[offset]) | Int16(data[offset + 1]) << 8))
      offset += 2
      tracked.append(v)
      return v

    case 0x32:  // Int32 LE
      guard offset + 4 <= data.count else { return nil }
      let raw =
        UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
      let v = Int(Int32(bitPattern: raw))
      offset += 4
      tracked.append(v)
      return v

    case 0x33:  // Int64 LE
      guard offset + 8 <= data.count else { return nil }
      let raw =
        UInt64(data[offset])
        | UInt64(data[offset + 1]) << 8
        | UInt64(data[offset + 2]) << 16
        | UInt64(data[offset + 3]) << 24
        | UInt64(data[offset + 4]) << 32
        | UInt64(data[offset + 5]) << 40
        | UInt64(data[offset + 6]) << 48
        | UInt64(data[offset + 7]) << 56
      let v = Int(Int64(bitPattern: raw))
      offset += 8
      tracked.append(v)
      return v

    case 0x35:  // Float32 LE
      guard offset + 4 <= data.count else { return nil }
      let raw =
        UInt32(data[offset])
        | UInt32(data[offset + 1]) << 8
        | UInt32(data[offset + 2]) << 16
        | UInt32(data[offset + 3]) << 24
      offset += 4
      let v = Double(Float(bitPattern: raw))
      tracked.append(v)
      return v

    case 0x36:  // Float64 LE
      guard offset + 8 <= data.count else { return nil }
      let bits =
        UInt64(data[offset])
        | UInt64(data[offset + 1]) << 8
        | UInt64(data[offset + 2]) << 16
        | UInt64(data[offset + 3]) << 24
        | UInt64(data[offset + 4]) << 32
        | UInt64(data[offset + 5]) << 40
        | UInt64(data[offset + 6]) << 48
        | UInt64(data[offset + 7]) << 56
      offset += 8
      let v = Double(bitPattern: bits)
      tracked.append(v)
      return v

    case 0x40...0x60:  // Short UTF-8 string (len 0–32)
      let len = Int(tag - 0x40)
      guard offset + len <= data.count else { return nil }
      let str = String(data: data[offset..<offset + len], encoding: .utf8) ?? ""
      offset += len
      tracked.append(str)
      return str

    case 0x61:  // String with 1-byte length
      guard offset < data.count else { return nil }
      let len = Int(data[offset])
      offset += 1
      guard offset + len <= data.count else { return nil }
      let str = String(data: data[offset..<offset + len], encoding: .utf8) ?? ""
      offset += len
      tracked.append(str)
      return str

    case 0x62:  // String with 2-byte LE length
      guard offset + 2 <= data.count else { return nil }
      let len = Int(UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
      offset += 2
      guard offset + len <= data.count else { return nil }
      let str = String(data: data[offset..<offset + len], encoding: .utf8) ?? ""
      offset += len
      tracked.append(str)
      return str

    case 0x63:  // String with 4-byte LE length
      guard offset + 4 <= data.count else { return nil }
      let len = Int(
        UInt32(data[offset])
          | UInt32(data[offset + 1]) << 8
          | UInt32(data[offset + 2]) << 16
          | UInt32(data[offset + 3]) << 24)
      offset += 4
      guard offset + len <= data.count else { return nil }
      let str = String(data: data[offset..<offset + len], encoding: .utf8) ?? ""
      offset += len
      tracked.append(str)
      return str

    case 0x6F:  // Null-terminated string
      var end = offset
      while end < data.count && data[end] != 0 { end += 1 }
      let str = String(data: data[offset..<end], encoding: .utf8) ?? ""
      offset = min(end + 1, data.count)
      tracked.append(str)
      return str

    case 0x70...0x90:  // Short binary data (len 0–32)
      let len = Int(tag - 0x70)
      guard offset + len <= data.count else { return nil }
      let d = Data(data[offset..<offset + len])
      offset += len
      tracked.append(d)
      return d

    case 0x91:  // Data with 1-byte length
      guard offset < data.count else { return nil }
      let len = Int(data[offset])
      offset += 1
      guard offset + len <= data.count else { return nil }
      let d = Data(data[offset..<offset + len])
      offset += len
      tracked.append(d)
      return d

    case 0x92:  // Data with 2-byte LE length
      guard offset + 2 <= data.count else { return nil }
      let len = Int(UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
      offset += 2
      guard offset + len <= data.count else { return nil }
      let d = Data(data[offset..<offset + len])
      offset += len
      tracked.append(d)
      return d

    case 0x93:  // Data with 4-byte LE length
      guard offset + 4 <= data.count else { return nil }
      let len = Int(
        UInt32(data[offset])
          | UInt32(data[offset + 1]) << 8
          | UInt32(data[offset + 2]) << 16
          | UInt32(data[offset + 3]) << 24)
      offset += 4
      guard offset + len <= data.count else { return nil }
      let d = Data(data[offset..<offset + len])
      offset += len
      tracked.append(d)
      return d

    case 0xA0...0xCF:  // Compression back-reference
      let index = Int(tag - 0xA0)
      guard index < tracked.count else { return nil }
      return tracked[index]

    case 0xD0...0xDE:  // Array with length (0–14 elements)
      let count = Int(tag - 0xD0)
      var arr: [Any] = []
      for _ in 0..<count {
        guard let v = decodeValue(data, offset: &offset, tracked: &tracked) else { break }
        arr.append(v)
      }
      return arr

    case 0xDF:  // Terminated array
      var arr: [Any] = []
      while offset < data.count {
        if data[offset] == 0x03 {
          offset += 1
          break
        }
        guard let v = decodeValue(data, offset: &offset, tracked: &tracked) else { break }
        arr.append(v)
      }
      return arr

    case 0xE0...0xEE:  // Dictionary with length (0–14 entries)
      let count = Int(tag - 0xE0)
      var dict: [String: Any] = [:]
      for _ in 0..<count {
        guard let key = decodeValue(data, offset: &offset, tracked: &tracked) as? String
        else { break }
        guard let value = decodeValue(data, offset: &offset, tracked: &tracked) else { break }
        dict[key] = value
      }
      return dict

    case 0xEF:  // Terminated dictionary
      var dict: [String: Any] = [:]
      while offset < data.count {
        if data[offset] == 0x03 {
          offset += 1
          break
        }
        guard let key = decodeValue(data, offset: &offset, tracked: &tracked) as? String
        else { break }
        guard let value = decodeValue(data, offset: &offset, tracked: &tracked) else { break }
        dict[key] = value
      }
      return dict

    default:
      return nil
    }
  }
}
