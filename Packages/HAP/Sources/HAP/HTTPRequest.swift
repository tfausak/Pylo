import Foundation

// MARK: - Minimal HTTP Request

public nonisolated struct HTTPRequest: Sendable {
  public let method: String
  public let path: String
  public let headers: [String: String]
  public let body: Data?

  public init(method: String, path: String, headers: [String: String], body: Data?) {
    self.method = method
    self.path = path
    self.headers = headers
    self.body = body
  }

  /// Very basic HTTP/1.1 request parser — sufficient for HAP.
  /// Only parses headers as UTF-8; the body is kept as raw Data
  /// (TLV8 bodies may contain non-UTF-8 binary like Ed25519 keys).
  public static func parse(_ data: Data) -> HTTPRequest? {
    var buffer = Data(data)  // normalize startIndex to 0 for slices
    switch parseAndConsume(&buffer) {
    case .request(let request): return request
    case .needsMoreData, .malformed: return nil
    }
  }

  public enum ParseResult: Sendable {
    case request(HTTPRequest)
    case needsMoreData
    case malformed
  }

  /// Parse a complete HTTP request from buffer and consume it.
  public static func parseAndConsume(_ buffer: inout Data) -> ParseResult {
    // Look for \r\n\r\n to find end of headers
    guard let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
      // No complete headers yet
      return .needsMoreData
    }

    let headerEnd = headerEndRange.upperBound
    let headerData = buffer[buffer.startIndex..<headerEndRange.lowerBound]

    guard let headerStr = String(data: headerData, encoding: .utf8) else {
      buffer.removeAll()
      return .malformed
    }

    let lines = headerStr.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      buffer.removeAll()
      return .malformed
    }

    let requestParts = requestLine.split(separator: " ", maxSplits: 2)
    guard requestParts.count >= 2 else {
      buffer.removeAll()
      return .malformed
    }

    let method = String(requestParts[0])
    let path = String(requestParts[1])

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      // Reject obsolete line folding (RFC 7230 §3.2.4): a continuation line
      // starting with SP or HTAB could smuggle a split Content-Length.
      if let first = line.first, first == " " || first == "\t" {
        buffer.removeAll()
        return .malformed
      }
      if let colonIndex = line.firstIndex(of: ":") {
        let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
          .lowercased()
        let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        // Reject duplicate Content-Length with differing values (RFC 7230 §3.3.2).
        if key == "content-length", let existing = headers[key], existing != value {
          buffer.removeAll()
          return .malformed
        }
        headers[key] = value
      }
    }

    // Check Content-Length — HAP messages are small; reject obviously oversized
    // payloads early rather than buffering until the 1 MB maxBufferSize limit.
    let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
    guard contentLength >= 0, contentLength <= 65536 else {
      buffer.removeAll()
      return .malformed
    }

    // Check if we have the complete body
    let totalNeeded = headerEnd + contentLength
    guard buffer.count >= totalNeeded else {
      // Not enough data yet
      return .needsMoreData
    }

    // Extract body
    var body: Data?
    if contentLength > 0 {
      body = buffer[headerEnd..<(headerEnd + contentLength)]
    }

    // Remove this request from the buffer.
    // O(n) for pipelined requests, but HAP uses sequential request/response
    // over encrypted sessions, so the buffer typically contains exactly one
    // request and this effectively clears it (O(1)).
    buffer.removeSubrange(buffer.startIndex..<totalNeeded)

    return .request(HTTPRequest(method: method, path: path, headers: headers, body: body))
  }
}
