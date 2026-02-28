import CryptoKit
import Foundation
import Network
import os

// MARK: - HomeKit Data Stream (HDS)

/// Implements the HomeKit Data Stream protocol for HKSV video transfer.
/// HDS runs on a separate TCP connection with its own ChaCha20-Poly1305 encryption,
/// derived from the HAP pair-verify shared secret.
nonisolated final class HAPDataStream: @unchecked Sendable {

  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "DataStream")

  /// TCP listener for HDS connections.
  private var listener: NWListener?

  /// Active HDS connection to the hub.
  private(set) var connection: HDSConnection?

  /// Port the listener is bound to.
  var port: UInt16? {
    listener?.port?.rawValue
  }

  /// The fragment writer to serve prebuffered and live video from.
  weak var fragmentWriter: FragmentedMP4Writer?

  /// Encryption keys derived in setupTransport(), stored until the hub
  /// actually opens the TCP connection (which happens after the HAP write).
  private var pendingReadKey: SymmetricKey?
  private var pendingWriteKey: SymmetricKey?

  /// Start the HDS TCP listener on a random port.
  func startListener() throws {
    let params = NWParameters.tcp
    let listener = try NWListener(using: params)

    let queue = DispatchQueue(label: "me.fausak.taylor.Pylo.datastream")

    listener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        if let port = self?.listener?.port {
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
      // Only allow one connection at a time
      self.connection?.cancel()

      let conn = HDSConnection(connection: nwConnection, queue: queue)
      conn.fragmentWriter = self.fragmentWriter
      self.connection = conn

      // Apply encryption keys that were derived in setupTransport()
      if let readKey = self.pendingReadKey, let writeKey = self.pendingWriteKey {
        conn.setupEncryption(readKey: readKey, writeKey: writeKey)
        conn.start()
        self.pendingReadKey = nil
        self.pendingWriteKey = nil
      }
    }

    listener.start(queue: queue)
    self.listener = listener
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
  func setupTransport(requestTLV: Data, sharedSecret: SharedSecret) -> Data {
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
    let hkdfSalt = controllerKeySalt + accessoryKeySalt
    let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }

    let readKey = HKDF<SHA512>.deriveSymmetricKey(
      inputKeyMaterial: sharedSecretData,
      salt: hkdfSalt,
      info: Data("HDS-Read-Encryption-Key".utf8),
      outputByteCount: 32
    )

    let writeKey = HKDF<SHA512>.deriveSymmetricKey(
      inputKeyMaterial: sharedSecretData,
      salt: hkdfSalt,
      info: Data("HDS-Write-Encryption-Key".utf8),
      outputByteCount: 32
    )

    logger.info(
      "HDS keys derived: controllerSalt=\(controllerKeySalt.count)B, accessorySalt=\(accessoryKeySalt.count)B"
    )

    // Store keys — the hub connects AFTER this HAP write completes,
    // so the connection doesn't exist yet.  Keys are applied in
    // newConnectionHandler when the TCP connection actually arrives.
    pendingReadKey = readKey
    pendingWriteKey = writeKey

    // If the connection already exists (hub connected early), apply immediately.
    if let conn = connection {
      conn.setupEncryption(readKey: readKey, writeKey: writeKey)
      conn.start()
      pendingReadKey = nil
      pendingWriteKey = nil
    }

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
  func stop() {
    connection?.cancel()
    connection = nil
    listener?.cancel()
    listener = nil
  }
}

// MARK: - HDS Connection

/// A single HDS TCP connection with encryption and message framing.
nonisolated final class HDSConnection: @unchecked Sendable {

  private let connection: NWConnection
  private let queue: DispatchQueue
  private let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "HDSConn")

  private var readKey: SymmetricKey?
  private var writeKey: SymmetricKey?
  private var readNonce: UInt64 = 0
  private var writeNonce: UInt64 = 0
  private let nonceLock = OSAllocatedUnfairLock(initialState: ())

  /// The fragment writer to serve video from.
  weak var fragmentWriter: FragmentedMP4Writer?

  /// Active dataSend stream ID (assigned by the hub in dataSend/open).
  private var activeStreamID: Int?

  /// Data sequence counter for dataSend chunks.
  private var dataSequenceNumber = 0

  init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  func setupEncryption(readKey: SymmetricKey, writeKey: SymmetricKey) {
    self.readKey = readKey
    self.writeKey = writeKey
  }

  func start() {
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

  func cancel() {
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

        if let decrypted = self.decryptFrame(type: frameType, header: data, payload: payload) {
          self.handleDecryptedMessage(decrypted)
        }

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
      logger.warning("Failed to decode HDS message")
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

    case ("dataSend", "ack", .event):
      // Hub acknowledges received data — log and continue
      logger.debug("HDS dataSend ack received")

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
    dataSequenceNumber = 0

    logger.info("HDS dataSend/open: type=\(type) target=\(target) reason=\(reason) streamId=\(streamID)")

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
    logger.info("HDS dataSend/close")
    activeStreamID = nil

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

  /// Send prebuffered fragments from the ring buffer, then set up live streaming.
  private func sendPrebufferedFragments() {
    guard let writer = fragmentWriter else {
      logger.warning("HDS sendPrebufferedFragments: no fragmentWriter")
      return
    }

    // Send the init segment first (ftyp + moov)
    if let initSeg = writer.initSegment {
      logger.info("HDS sending init segment: \(initSeg.count) bytes")
      sendDataChunks(initSeg, dataType: "mediaInitialization", isLast: false)
    } else {
      logger.warning("HDS: no init segment available")
    }

    // Send prebuffered fragments
    let fragments = writer.ringBuffer.snapshot()
    logger.info("HDS sending \(fragments.count) prebuffered fragment(s)")
    for fragment in fragments {
      sendDataChunks(fragment.data, dataType: "mediaFragment", isLast: false)
    }

    // Set up live fragment delivery
    pendingEndOfStream = false
    writer.onFragmentReady = { [weak self] fragment in
      self?.queue.async {
        guard let self, self.activeStreamID != nil else { return }
        self.sendDataChunks(fragment.data, dataType: "mediaFragment", isLast: false)

        // If motion cleared, send endOfStream after this fragment
        if self.pendingEndOfStream {
          self.pendingEndOfStream = false
          self.sendEndOfStream()
        }
      }
    }
  }

  /// Signal that the current recording should end after the next fragment completes.
  func finishRecording() {
    queue.async { [weak self] in
      guard let self else { return }
      if self.activeStreamID != nil {
        self.logger.info("HDS: finishing recording (will send endOfStream after next fragment)")
        self.pendingEndOfStream = true
      }
    }
  }

  /// Split data into chunks and send as dataSend/data events.
  private func sendDataChunks(_ data: Data, dataType: String, isLast: Bool) {
    guard activeStreamID != nil else { return }

    let maxChunk = Self.maxChunkSize
    var offset = 0
    var chunkSeq = 0
    let totalSize = data.count

    while offset < data.count {
      let end = min(offset + maxChunk, data.count)
      let chunk = data[offset..<end]
      let isLastChunk = end >= data.count

      var body: [String: Any] = [
        "packets": [
          [
            "data": chunk,
            "metadata": [
              "dataType": dataType,
              "dataSequenceNumber": dataSequenceNumber,
              "dataChunkSequenceNumber": chunkSeq,
              "isLastDataChunk": isLastChunk,
              "dataTotalSize": totalSize,
            ] as [String: Any],
          ]
        ]
      ]

      if isLast && isLastChunk {
        body["endOfStream"] = true
      }

      let event = HDSMessage(
        type: .event,
        protocol: "dataSend",
        topic: "data",
        identifier: 0,
        status: .success,
        body: body
      )
      sendMessage(event)

      offset = end
      chunkSeq += 1
    }

    dataSequenceNumber += 1
  }

  /// Send end-of-stream marker.
  func sendEndOfStream() {
    guard activeStreamID != nil else { return }
    logger.info("HDS sending endOfStream")

    let event = HDSMessage(
      type: .event,
      protocol: "dataSend",
      topic: "data",
      identifier: 0,
      status: .success,
      body: [
        "endOfStream": true,
        "packets": [] as [[String: Any]],
      ]
    )
    sendMessage(event)
    activeStreamID = nil
  }
}

// MARK: - HDS Message

/// Represents an HDS protocol message with header and body.
nonisolated struct HDSMessage {

  enum MessageType: UInt8 {
    case event = 1
    case request = 2
    case response = 3
  }

  enum Status: Int {
    case success = 0
    case protocolError = 1
  }

  let type: MessageType
  let `protocol`: String
  let topic: String
  let identifier: Int
  let status: Status
  let body: [String: Any]

  // MARK: - Encoding

  /// Encode this message into the HDS binary format.
  /// Format: [header opack] [body opack]
  /// The header and body are each encoded with a simple dictionary serializer.
  func encode() -> Data {
    var header: [String: Any] = [
      "protocol": self.protocol,
      "event": topic,
    ]

    switch type {
    case .event:
      header["type"] = 1
    case .request:
      header["type"] = 2
      header["id"] = identifier
    case .response:
      header["type"] = 3
      header["id"] = identifier
      header["status"] = status.rawValue
    }

    let headerData = OPack.encode(header)
    let bodyData = OPack.encode(body)

    var result = Data()
    result.append(headerData)
    result.append(bodyData)
    return result
  }

  // MARK: - Decoding

  /// Decode an HDS message from binary data.
  static func decode(_ data: Data) -> HDSMessage? {
    // Decode header
    var offset = 0
    guard let (headerDict, headerLen) = OPack.decode(data, offset: offset) as? ([String: Any], Int)
    else { return nil }
    offset += headerLen

    // Decode body (may be empty)
    var bodyDict: [String: Any] = [:]
    if offset < data.count {
      if let (bd, _) = OPack.decode(data, offset: offset) as? ([String: Any], Int) {
        bodyDict = bd
      }
    }

    guard let typeRaw = headerDict["type"] as? Int,
      let messageType = MessageType(rawValue: UInt8(typeRaw)),
      let proto = headerDict["protocol"] as? String,
      let topic = headerDict["event"] as? String
    else { return nil }

    let identifier = headerDict["id"] as? Int ?? 0
    let statusRaw = headerDict["status"] as? Int ?? 0

    return HDSMessage(
      type: messageType,
      protocol: proto,
      topic: topic,
      identifier: identifier,
      status: Status(rawValue: statusRaw) ?? .success,
      body: bodyDict
    )
  }
}

// MARK: - OPack Encoder/Decoder

/// Minimal OPack (Object Pack) encoder/decoder for HDS messages.
/// OPack is Apple's compact binary dictionary serialization format used in HDS.
/// It's similar to bplist but with different type tags.
nonisolated enum OPack {

  // Type tags
  private static let typeNull: UInt8 = 0x04
  private static let typeFalse: UInt8 = 0x05
  private static let typeTrue: UInt8 = 0x06
  private static let typeTerminator: UInt8 = 0x03

  /// Encode a dictionary to OPack format.
  static func encode(_ dict: [String: Any]) -> Data {
    var data = Data()
    // Dictionary marker
    data.append(0x07)
    for (key, value) in dict {
      encodeString(key, into: &data)
      encodeValue(value, into: &data)
    }
    data.append(typeTerminator)
    return data
  }

  private static func encodeValue(_ value: Any, into data: inout Data) {
    switch value {
    case let v as Bool:
      data.append(v ? typeTrue : typeFalse)

    case let v as Int:
      encodeInt(v, into: &data)

    case let v as String:
      encodeString(v, into: &data)

    case let v as Data:
      encodeBinary(v, into: &data)

    case let v as [String: Any]:
      data.append(contentsOf: encode(v))

    case let v as [[String: Any]]:
      // Array marker
      data.append(0x06 | 0x80)  // array type
      for item in v {
        data.append(contentsOf: encode(item))
      }
      data.append(typeTerminator)

    case let v as [Any]:
      data.append(0x06 | 0x80)
      for item in v {
        encodeValue(item, into: &data)
      }
      data.append(typeTerminator)

    default:
      data.append(typeNull)
    }
  }

  private static func encodeInt(_ value: Int, into data: inout Data) {
    if value >= 0 && value <= 0x27 {
      // Small positive integer: inline (0x08–0x2F)
      data.append(UInt8(0x08 + value))
    } else if value >= 0 && value <= 0xFF {
      data.append(0x30)
      data.append(UInt8(value))
    } else if value >= 0 && value <= 0xFFFF {
      data.append(0x31)
      var le = UInt16(value).littleEndian
      data.append(Data(bytes: &le, count: 2))
    } else if value >= 0 && value <= 0xFFFF_FFFF {
      data.append(0x32)
      var le = UInt32(value).littleEndian
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
    if len <= 0x20 {
      // Short string: length in tag byte (0x48–0x68)
      data.append(UInt8(0x48 + len))
    } else if len <= 0xFF {
      data.append(0x69)
      data.append(UInt8(len))
    } else if len <= 0xFFFF {
      data.append(0x6A)
      var le = UInt16(len).littleEndian
      data.append(Data(bytes: &le, count: 2))
    } else {
      data.append(0x6B)
      var le = UInt32(len).littleEndian
      data.append(Data(bytes: &le, count: 4))
    }
    data.append(utf8)
  }

  private static func encodeBinary(_ binary: Data, into data: inout Data) {
    let len = binary.count
    if len <= 0x20 {
      data.append(UInt8(0x88 + len))
    } else if len <= 0xFF {
      data.append(0xA9)
      data.append(UInt8(len))
    } else if len <= 0xFFFF {
      data.append(0xAA)
      var le = UInt16(len).littleEndian
      data.append(Data(bytes: &le, count: 2))
    } else {
      data.append(0xAB)
      var le = UInt32(len).littleEndian
      data.append(Data(bytes: &le, count: 4))
    }
    data.append(binary)
  }

  /// Decode an OPack value starting at the given offset.
  /// Returns (value, bytesConsumed).
  static func decode(_ data: Data, offset: Int) -> (Any, Int)? {
    guard offset < data.count else { return nil }

    let tag = data[offset]

    // Dictionary
    if tag == 0x07 {
      return decodeDictionary(data, offset: offset + 1)
    }

    // Array
    if tag == (0x06 | 0x80) {
      return decodeArray(data, offset: offset + 1)
    }

    // Null
    if tag == typeNull {
      return (NSNull(), 1)
    }

    // Bool
    if tag == typeFalse { return (false, 1) }
    if tag == typeTrue { return (true, 1) }

    // Small positive integer (0x08–0x2F)
    if tag >= 0x08 && tag <= 0x2F {
      return (Int(tag - 0x08), 1)
    }

    // Integer types
    if tag == 0x30 {
      guard offset + 1 < data.count else { return nil }
      return (Int(data[offset + 1]), 2)
    }
    if tag == 0x31 {
      guard offset + 2 < data.count else { return nil }
      let v = UInt16(data[offset + 1]) | UInt16(data[offset + 2]) << 8
      return (Int(v), 3)
    }
    if tag == 0x32 {
      guard offset + 4 < data.count else { return nil }
      let v = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 1, as: UInt32.self) }
      return (Int(UInt32(littleEndian: v)), 5)
    }
    if tag == 0x33 {
      guard offset + 8 < data.count else { return nil }
      let v = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 1, as: Int64.self) }
      return (Int(Int64(littleEndian: v)), 9)
    }

    // Negative integer
    if tag == 0x38 {
      guard offset + 1 < data.count else { return nil }
      return (-Int(data[offset + 1]) - 1, 2)
    }

    // Short string (0x48–0x68)
    if tag >= 0x48 && tag <= 0x68 {
      let len = Int(tag - 0x48)
      guard offset + 1 + len <= data.count else { return nil }
      let str = String(data: data[offset + 1..<offset + 1 + len], encoding: .utf8) ?? ""
      return (str, 1 + len)
    }

    // String with 1-byte length
    if tag == 0x69 {
      guard offset + 1 < data.count else { return nil }
      let len = Int(data[offset + 1])
      guard offset + 2 + len <= data.count else { return nil }
      let str = String(data: data[offset + 2..<offset + 2 + len], encoding: .utf8) ?? ""
      return (str, 2 + len)
    }

    // String with 2-byte length
    if tag == 0x6A {
      guard offset + 2 < data.count else { return nil }
      let len = Int(UInt16(data[offset + 1]) | UInt16(data[offset + 2]) << 8)
      guard offset + 3 + len <= data.count else { return nil }
      let str = String(data: data[offset + 3..<offset + 3 + len], encoding: .utf8) ?? ""
      return (str, 3 + len)
    }

    // Short binary data (0x88–0xA8)
    if tag >= 0x88 && tag <= 0xA8 {
      let len = Int(tag - 0x88)
      guard offset + 1 + len <= data.count else { return nil }
      return (Data(data[offset + 1..<offset + 1 + len]), 1 + len)
    }

    // Binary with 1-byte length
    if tag == 0xA9 {
      guard offset + 1 < data.count else { return nil }
      let len = Int(data[offset + 1])
      guard offset + 2 + len <= data.count else { return nil }
      return (Data(data[offset + 2..<offset + 2 + len]), 2 + len)
    }

    // Binary with 2-byte length
    if tag == 0xAA {
      guard offset + 2 < data.count else { return nil }
      let len = Int(UInt16(data[offset + 1]) | UInt16(data[offset + 2]) << 8)
      guard offset + 3 + len <= data.count else { return nil }
      return (Data(data[offset + 3..<offset + 3 + len]), 3 + len)
    }

    // Binary with 4-byte length
    if tag == 0xAB {
      guard offset + 4 < data.count else { return nil }
      let v = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 1, as: UInt32.self) }
      let len = Int(UInt32(littleEndian: v))
      guard offset + 5 + len <= data.count else { return nil }
      return (Data(data[offset + 5..<offset + 5 + len]), 5 + len)
    }

    // Unknown tag — skip one byte
    return (NSNull(), 1)
  }

  private static func decodeDictionary(_ data: Data, offset: Int) -> (Any, Int)? {
    var dict: [String: Any] = [:]
    var pos = offset

    while pos < data.count {
      if data[pos] == typeTerminator {
        return (dict, pos - offset + 2)  // +2 for dict marker + terminator
      }

      guard let (key, keyLen) = decode(data, offset: pos) else { break }
      pos += keyLen

      guard let keyStr = key as? String else { break }

      guard let (value, valLen) = decode(data, offset: pos) else { break }
      pos += valLen

      dict[keyStr] = value
    }

    return (dict, pos - offset + 1)
  }

  private static func decodeArray(_ data: Data, offset: Int) -> (Any, Int)? {
    var arr: [Any] = []
    var pos = offset

    while pos < data.count {
      if data[pos] == typeTerminator {
        return (arr, pos - offset + 2)  // +2 for array marker + terminator
      }

      guard let (value, len) = decode(data, offset: pos) else { break }
      pos += len
      arr.append(value)
    }

    return (arr, pos - offset + 1)
  }
}
