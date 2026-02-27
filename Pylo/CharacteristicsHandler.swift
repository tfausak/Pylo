import Foundation

// MARK: - Characteristics Handler
// Handles GET /characteristics?id=1.9,1.10 and PUT /characteristics

nonisolated enum CharacteristicsHandler {

  static func handleGet(request: HTTPRequest, server: HAPServer) -> HTTPResponse {
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

  static func handlePut(request: HTTPRequest, connection: HAPConnection, server: HAPServer)
    -> HTTPResponse
  {
    guard let body = request.body,
      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let characteristics = json["characteristics"] as? [[String: Any]]
    else {
      return errorResponse(status: 400)
    }

    var results: [[String: Any]] = []
    var allOK = true

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

      // Validate the characteristic exists before processing
      guard server.accessory(aid: aid)?.readCharacteristic(iid: iid) != nil else {
        allOK = false
        results.append(["aid": aid, "iid": iid, "status": -70409])
        continue
      }

      // Handle value write first, then apply event subscription only on success
      if let rawValue = char["value"], let value = HAPValue(fromJSON: rawValue) {
        let success =
          server.accessory(aid: aid)?.writeCharacteristic(iid: iid, value: value) ?? false
        if !success {
          allOK = false
          results.append(["aid": aid, "iid": iid, "status": -70402])
          continue
        }
      }

      // Apply event subscription (only reached if no write or write succeeded)
      if let ev = char["ev"] as? Bool {
        let charID = CharacteristicID(aid: aid, iid: iid)
        if ev {
          connection.subscribe(to: charID)
        } else {
          connection.unsubscribe(from: charID)
        }
      }

      results.append(["aid": aid, "iid": iid, "status": 0])
    }

    if allOK {
      // All succeeded — return 204 No Content
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
