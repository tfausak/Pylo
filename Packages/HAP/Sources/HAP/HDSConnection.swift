import CryptoKit
import Foundation
import FragmentedMP4
import Network
import os

// MARK: - HDS Connection

/// A single HDS TCP connection with encryption and message framing.
///
/// All mutable state is accessed exclusively on `queue` (the HDS serial dispatch queue).
/// The only public methods callable from other queues are `cancel()` (thread-safe via
/// NWConnection) and `finishRecording(completion:)` which dispatches to `queue`.
public nonisolated final class HDSConnection: @unchecked Sendable {

  private let connection: NWConnection
  private let queue: DispatchQueue
  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "HDSConn")

  // Encryption keys — set once in setupEncryption (on queue), then read-only.
  private var readKey: SymmetricKey?
  private var writeKey: SymmetricKey?
  private let nonces = OSAllocatedUnfairLock(initialState: (read: UInt64(0), write: UInt64(0)))

  /// The fragment writer to serve video from.
  /// Set from the HDS queue (newConnectionHandler) before start() is called.
  /// Weak because HAPDataStream owns the writer's lifetime — if the writer is
  /// cleared (e.g., when stopping recording), live delivery callbacks naturally
  /// stop via the weak capture in setupLiveFragmentDelivery.
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

  /// Configure encryption keys. Must be called on `queue` before `start()`.
  public func setupEncryption(readKey: SymmetricKey, writeKey: SymmetricKey) {
    dispatchPrecondition(condition: .onQueue(queue))
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

      guard let data, data.count == 4 else {
        // Always cancel on nil/short data — without this, a partial close
        // (!isComplete but no data) would leave the connection in limbo
        // with no further receives scheduled and no cleanup.
        self.logger.info("HDS connection closed by hub")
        self.cancel()
        return
      }

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
      ) { [weak self] payload, _, isPayloadComplete, error in
        guard let self else { return }

        if let error {
          self.logger.error("HDS receive payload error: \(error)")
          return
        }

        guard let payload, payload.count == totalRead else {
          // Always cancel on nil/short data — without this, a partial read
          // with !isPayloadComplete leaves the connection with no further
          // receives scheduled and no cleanup (limbo state).
          self.cancel()
          return
        }

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

    let nonce = nonces.withLock { state -> ChaChaPoly.Nonce in
      let n = Self.makeHDSNonce(counter: state.read)
      state.read += 1
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

    let nonce = nonces.withLock { state -> ChaChaPoly.Nonce in
      let n = Self.makeHDSNonce(counter: state.write)
      state.write += 1
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

  /// HDS nonces are 4 bytes of zero + 8 bytes LE counter (12 bytes total).
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
      // Hub acknowledges received data -- log and continue
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

    // Send prebuffered fragments, yielding between each to avoid blocking the queue.
    let fragments = writer.ringBuffer.snapshot()
    logger.info("HDS sending \(fragments.count) prebuffered fragment(s)")
    sendPrebufferedBatch(fragments: fragments, index: 0, writer: writer)
  }

  /// Sends prebuffered fragments one at a time via recursive async dispatch,
  /// yielding between each so the HDS queue can process other work.
  private func sendPrebufferedBatch(
    fragments: [MP4Fragment], index: Int, writer: FragmentedMP4Writer
  ) {
    guard index < fragments.count else {
      // All prebuffered fragments sent — set up live delivery.
      setupLiveFragmentDelivery(writer: writer)
      return
    }
    sendDataChunks(fragments[index].data, dataType: "mediaFragment", isLast: false)
    queue.async { [weak self] in
      self?.sendPrebufferedBatch(fragments: fragments, index: index + 1, writer: writer)
    }
  }

  /// Wire up the live fragment callback after prebuffered fragments are flushed.
  private func setupLiveFragmentDelivery(writer: FragmentedMP4Writer) {
    pendingEndOfStream = false
    writer.onFragmentReady = { [weak self, weak writer] (fragment: MP4Fragment) in
      self?.queue.async {
        guard let self, let writer, self.activeStreamID != nil,
          self.fragmentWriter === writer
        else { return }

        // Send init segment before first fragment if it wasn't available at open time
        if !self.initSegmentSent, let initSeg = writer.initSegment {
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
  ///
  /// Each chunk requires two copies: one for message assembly (HDS framing
  /// requires the complete message before encryption) and one for ChaCha20
  /// encryption output. This is inherent to the protocol.
  private func sendDataChunks(_ data: Data, dataType: String, isLast: Bool) {
    guard let streamID = activeStreamID else { return }
    guard !data.isEmpty else {
      logger.warning("HDS sendDataChunks called with empty data, skipping")
      return
    }

    let maxChunk = Self.maxChunkSize
    var offset = 0
    var chunkSeq = 1
    let totalSize = data.count

    while offset < data.count {
      let end = min(offset + maxChunk, data.count)
      let chunk = data[offset..<end]
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
  /// matching positron's known-working implementation. This bypasses HDSCodec
  /// which sorts keys alphabetically — a different order than the hub expects.
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

    // streamId -> number
    buf.append(contentsOf: [0x48, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x49, 0x64])
    Self.appendHDSInt(&buf, streamID)

    // endOfStream -> true (optional)
    if endOfStream {
      buf.append(contentsOf: [
        0x4B,  // string of 11
        0x65, 0x6E, 0x64, 0x4F, 0x66, 0x53, 0x74, 0x72, 0x65, 0x61, 0x6D,
        0x01,  // TRUE
      ])
    }

    // packets -> array(1) -> dict(2){metadata, data}
    buf.append(contentsOf: [
      0x47, 0x70, 0x61, 0x63, 0x6B, 0x65, 0x74, 0x73,  // "packets"
      0xD1,  // array of 1
      0xE2,  // dict of 2 (metadata + data)
      0x48, 0x6D, 0x65, 0x74, 0x61, 0x64, 0x61, 0x74, 0x61,  // "metadata"
    ])

    // metadata dict (4 or 5 entries)
    buf.append(dataTotalSize != nil ? 0xE5 : 0xE4)

    // dataType -> string (HDS short-string encoding: 0x40 + length, max 32 bytes)
    buf.append(contentsOf: [0x48, 0x64, 0x61, 0x74, 0x61, 0x54, 0x79, 0x70, 0x65])
    let dtBytes = Data(dataType.utf8)
    precondition(
      dtBytes.count <= 32, "dataType too long for HDS short-string encoding (\(dtBytes.count) > 32)"
    )
    buf.append(UInt8(0x40 + dtBytes.count))
    buf.append(dtBytes)

    // dataSequenceNumber -> number
    buf.append(contentsOf: [
      0x52,  // string of 18
      0x64, 0x61, 0x74, 0x61, 0x53, 0x65, 0x71, 0x75, 0x65, 0x6E, 0x63, 0x65,
      0x4E, 0x75, 0x6D, 0x62, 0x65, 0x72,
    ])
    Self.appendHDSInt(&buf, dataSequenceNumber)

    // isLastDataChunk -> bool
    buf.append(contentsOf: [
      0x4F,  // string of 15
      0x69, 0x73, 0x4C, 0x61, 0x73, 0x74, 0x44, 0x61, 0x74, 0x61, 0x43, 0x68,
      0x75, 0x6E, 0x6B,
    ])
    buf.append(isLastDataChunk ? 0x01 : 0x02)

    // dataChunkSequenceNumber -> number
    buf.append(contentsOf: [
      0x57,  // string of 23
      0x64, 0x61, 0x74, 0x61, 0x43, 0x68, 0x75, 0x6E, 0x6B, 0x53, 0x65, 0x71,
      0x75, 0x65, 0x6E, 0x63, 0x65, 0x4E, 0x75, 0x6D, 0x62, 0x65, 0x72,
    ])
    Self.appendHDSInt(&buf, dataChunkSequenceNumber)

    // dataTotalSize -> number (only on first chunk)
    if let totalSize = dataTotalSize {
      buf.append(contentsOf: [
        0x4D,  // string of 13
        0x64, 0x61, 0x74, 0x61, 0x54, 0x6F, 0x74, 0x61, 0x6C, 0x53, 0x69,
        0x7A, 0x65,
      ])
      Self.appendHDSInt(&buf, totalSize)
    }

    // data -> binary (always DATA_LENGTH32LE = 0x93, matching positron)
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
