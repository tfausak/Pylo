import Foundation

// MARK: - Minimal HTTP Response

nonisolated struct HTTPResponse {
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
    case 470: return "Connection Authorization Required"
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
