import CryptoKit
import Foundation
import os

// MARK: - Characteristics Handler
// Handles GET /characteristics?id=1.9,1.10 and PUT /characteristics

public nonisolated enum CharacteristicsHandler {

  private static let logger = Logger(
    subsystem: "me.fausak.taylor.Pylo", category: "Characteristics")

  public static func handleGet(request: HTTPRequest, server: HAPServer) -> HTTPResponse {
    // Parse query string: /characteristics?id=1.9,1.10
    guard let queryStart = request.path.firstIndex(of: "?") else {
      return errorResponse(status: 400)
    }

    let query = String(request.path[request.path.index(after: queryStart)...])
    let params = query.split(separator: "&").reduce(into: [String: String]()) { dict, param in
      let kv = param.split(separator: "=", maxSplits: 1)
      if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
    }

    guard let idParam = params["id"] else {
      return errorResponse(status: 400)
    }

    let ids = idParam.split(separator: ",")
    var characteristics: [[String: Any]] = []

    for idStr in ids {
      let parts = idStr.split(separator: ".")
      guard parts.count == 2,
        let aid = Int(parts[0]),
        let iid = Int(parts[1])
      else {
        // HAP spec §6.7.2: every requested characteristic must produce a result
        characteristics.append(["status": -70409])
        continue
      }

      var entry: [String: Any] = ["aid": aid, "iid": iid]
      if let accessory = server.accessory(aid: aid),
        let value = accessory.readCharacteristic(iid: iid)
      {
        entry["value"] = value.jsonValue
        entry["status"] = 0
      } else {
        entry["status"] = -70409  // Resource does not exist
      }
      characteristics.append(entry)
    }

    let body: [String: Any] = ["characteristics": characteristics]
    guard let data = try? JSONSerialization.data(withJSONObject: body) else {
      return errorResponse(status: 500)
    }

    // NOTE: HAP spec §6.7.2.1 says to return 200 when all reads succeed and 207 only
    // for mixed results, but Apple's Home.app / HomeKit treats 200 as invalid here and
    // shows "No Response" for all accessories. Always use 207.
    return HTTPResponse(status: 207, body: data, contentType: "application/hap+json")
  }

  public static func handlePut(request: HTTPRequest, connection: HAPConnection, server: HAPServer)
    -> HTTPResponse
  {
    guard let body = request.body,
      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let characteristics = json["characteristics"] as? [[String: Any]]
    else {
      return errorResponse(status: 400)
    }

    // Validate timed write PID/TTL (HAP §6.7.2.4)
    let pid = (json["pid"] as? Int).map { UInt64($0) }
    if !connection.validateTimedWrite(pid: pid) {
      logger.warning("Timed write validation failed (expired or PID mismatch)")
      return errorResponse(status: -70410)
    }

    // Log PUT summary for diagnostics
    let hasPID = pid != nil
    var putSummary: [String] = []
    for c in characteristics {
      let aid = c["aid"] as? Int ?? 0
      let iid = c["iid"] as? Int ?? 0
      var flags = ""
      if c["value"] != nil { flags += "v" }
      if c["ev"] != nil { flags += "e" }
      if c["r"] as? Bool == true { flags += "r" }
      putSummary.append("\(aid).\(iid)[\(flags)]")
    }
    logger.info("PUT chars: \(putSummary.joined(separator: ", "))\(hasPID ? " (timed)" : "")")

    var results: [[String: Any]] = []
    var allOK = true
    var hasWriteResponse = false

    for char in characteristics {
      guard let aid = char["aid"] as? Int,
        let iid = char["iid"] as? Int
      else {
        // HAP spec §6.7.2.2: every entry must include aid/iid for correlation.
        // Include whatever was parsed; use 0 as fallback for missing fields.
        allOK = false
        results.append([
          "aid": (char["aid"] as? Int) ?? 0,
          "iid": (char["iid"] as? Int) ?? 0,
          "status": -70409,
        ])
        continue
      }

      // Handle value write first, then apply event subscription only on success.
      // writeCharacteristic returns false for unknown iids, so it doubles as an
      // existence check for write-only characteristics (HAP spec §6.7.2.2).
      if let rawValue = char["value"] {
        guard let value = HAPValue(fromJSON: rawValue) else {
          allOK = false
          logger.warning("PUT write \(aid).\(iid) invalid value type")
          results.append(["aid": aid, "iid": iid, "status": -70410])
          continue
        }
        logger.debug("PUT write \(aid).\(iid) = \(String(describing: value))")
        // Pass the writing connection's shared secret so that downstream
        // callbacks (e.g. SetupDataStreamTransport) can derive HDS keys
        // from the correct pair-verify session.
        let success =
          server.accessory(aid: aid)?.writeCharacteristic(
            iid: iid, value: value, sharedSecret: connection.pairVerifySharedSecret) ?? false
        if !success {
          allOK = false
          logger.warning("PUT write \(aid).\(iid) FAILED")
          results.append(["aid": aid, "iid": iid, "status": -70402])
          continue
        }

        // Write-response: read back the value and include in response (HAP §6.7.2.2)
        if char["r"] as? Bool == true {
          hasWriteResponse = true
          // Apply ev subscription even on write-response entries (HAP §6.7.2.2:
          // event subscriptions and writes are independent operations).
          if let ev = char["ev"] as? Bool {
            let charID = CharacteristicID(aid: aid, iid: iid)
            if ev { connection.subscribe(to: charID) } else { connection.unsubscribe(from: charID) }
          }
          var entry: [String: Any] = ["aid": aid, "iid": iid, "status": 0]
          if let responseValue = server.accessory(aid: aid)?.readCharacteristic(iid: iid) {
            entry["value"] = responseValue.jsonValue
          }
          results.append(entry)
          continue
        }
      } else if char["ev"] == nil {
        // No value to write and no event subscription — validate the characteristic exists.
        guard server.accessory(aid: aid)?.readCharacteristic(iid: iid) != nil else {
          allOK = false
          results.append(["aid": aid, "iid": iid, "status": -70409])
          continue
        }
      }

      // Apply event subscription (only reached if no write or write succeeded)
      if let ev = char["ev"] as? Bool {
        let charID = CharacteristicID(aid: aid, iid: iid)
        if ev {
          logger.debug("Subscribe \(aid).\(iid)")
          connection.subscribe(to: charID)
        } else {
          connection.unsubscribe(from: charID)
        }
      }

      results.append(["aid": aid, "iid": iid, "status": 0])
    }

    if allOK && !hasWriteResponse {
      // All succeeded with no write-response — return 204 No Content
      return HTTPResponse(status: 204, body: nil, contentType: "application/hap+json")
    } else {
      let body: [String: Any] = ["characteristics": results]
      guard let data = try? JSONSerialization.data(withJSONObject: body) else {
        return errorResponse(status: 500)
      }
      return HTTPResponse(status: 207, body: data, contentType: "application/hap+json")
    }
  }

  private static func errorResponse(status: Int) -> HTTPResponse {
    HTTPResponse(status: status, body: nil, contentType: "application/hap+json")
  }
}
