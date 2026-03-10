import Foundation

// MARK: - HDS Message

/// Represents an HDS protocol message with header and body.
public struct HDSMessage {

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
  /// Message body as untyped dictionary.
  /// Uses `[String: Any]` because HDS messages are decoded by `HDSCodec` from
  /// an arbitrary binary format, and the same type flows through both encode and
  /// decode paths. Known body shapes:
  /// - dataSend/open: {target: String, type: String, reason: String, streamId: Int}
  /// - dataSend/close: {streamId: Int?, reason: Int?}
  /// - dataSend/ack: {streamId: Int?, endOfStream: Bool?}
  /// - control/hello: {}
  /// A typed enum would require conversion boilerplate at every codec boundary
  /// for minimal safety gain given the small, stable set of message types.
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
      status = Status(rawValue: statusRaw) ?? .protocolError
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
