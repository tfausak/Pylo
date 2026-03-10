import Foundation

// MARK: - Minimal HTTP Response

public struct HTTPResponse: Sendable {
  public let status: Int
  public let body: Data?
  public let contentType: String

  public init(status: Int, body: Data?, contentType: String) {
    self.status = status
    self.body = body
    self.contentType = contentType
  }

  public var statusText: String {
    switch status {
    case 200: return "OK"
    case 204: return "No Content"
    case 207: return "Multi-Status"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 422: return "Unprocessable Entity"
    case 470: return "Connection Authorization Required"
    case 500: return "Internal Server Error"
    default: return "Unknown"
    }
  }

  public func serialize() -> Data {
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
