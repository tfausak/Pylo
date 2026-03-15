import Foundation
import TLV8
import os

// MARK: - Pairings Handler
// Handles POST /pairings for adding, removing, and listing pairings.
// This endpoint is only accessible over an encrypted (pair-verified) session.

public enum PairingsHandler {

  private static let logger = Logger(subsystem: logSubsystem, category: "Pairings")

  // Pairing methods
  private static let methodAddPairing: UInt8 = 3
  private static let methodRemovePairing: UInt8 = 4
  private static let methodListPairings: UInt8 = 5

  public static func handle(request: HTTPRequest, connection: HAPConnection, server: HAPServer)
    -> HTTPResponse
  {
    // routeRequest already gates POST /pairings on encryptionContext != nil
    // and returns 470 if not verified. This assert documents the invariant.
    assert(connection.encryptionContext != nil, "POST /pairings reached without encryption")

    guard let body = request.body else {
      return errorResponse(error: .unknown)
    }

    let tlv: [TLV8.Tag: Data] = TLV8.decode(body)

    guard let stateData = tlv[.state], stateData.first == 1,
      let methodData = tlv[.method], let method = methodData.first
    else {
      return errorResponse(error: .unknown)
    }

    // HAP spec §5.10-5.12: all pairing operations require admin privileges
    if method == methodAddPairing || method == methodRemovePairing
      || method == methodListPairings
    {
      guard let controllerID = connection.verifiedControllerID,
        let pairing = server.pairingStore.getPairing(identifier: controllerID),
        pairing.isAdmin
      else {
        logger.warning("Non-admin controller attempted pairing operation")
        return errorResponse(error: .authentication)
      }
    }

    switch method {
    case methodAddPairing:
      return handleAdd(tlv: tlv, server: server)
    case methodRemovePairing:
      return handleRemove(tlv: tlv, connection: connection, server: server)
    case methodListPairings:
      return handleList(server: server)
    default:
      return errorResponse(error: .unknown)
    }
  }

  private static func handleAdd(tlv: [TLV8.Tag: Data], server: HAPServer) -> HTTPResponse {
    guard let identifier = tlv[.identifier],
      let publicKey = tlv[.publicKey], publicKey.count == 32,
      let permissions = tlv[.permissions]
    else {
      return errorResponse(error: .unknown)
    }

    guard let id = String(data: identifier, encoding: .utf8), !id.isEmpty else {
      return errorResponse(error: .unknown)
    }
    let isAdmin = permissions.first == 1

    logger.info("Add pairing request: \(id) admin=\(isAdmin)")

    // HAP spec §5.10: if the identifier already exists, the public key must
    // match — only permission updates are allowed.
    if let existing = server.pairingStore.getPairing(identifier: id) {
      guard existing.publicKey == publicKey else {
        logger.warning("Add pairing rejected: key mismatch for existing identifier \(id)")
        return errorResponse(error: .authentication)
      }
      // Prevent demoting the last admin to non-admin, which would leave
      // the device with pairings but no admin to manage them.
      if existing.isAdmin && !isAdmin && server.pairingStore.adminCount <= 1 {
        logger.warning("Add pairing rejected: cannot demote last admin \(id)")
        return errorResponse(error: .authentication)
      }
    }
    server.pairingStore.addPairing(
      PairingStore.Pairing(identifier: id, publicKey: publicKey, isAdmin: isAdmin)
    )

    return successResponse()
  }

  private static func handleRemove(
    tlv: [TLV8.Tag: Data], connection: HAPConnection, server: HAPServer
  ) -> HTTPResponse {
    guard let identifier = tlv[.identifier] else {
      return errorResponse(error: .unknown)
    }

    guard let id = String(data: identifier, encoding: .utf8), !id.isEmpty else {
      return errorResponse(error: .unknown)
    }

    // HAP spec §5.11: if removing the last admin, remove ALL pairings
    // and return the accessory to unpaired state. Without this, removing
    // an accessory from Home.app leaves stale hub pairings on the device,
    // blocking re-pairing (isPaired stays true) while no controller can
    // pair-verify (their identifiers don't match the stale entries).
    let isLastAdmin: Bool
    if let target = server.pairingStore.getPairing(identifier: id),
      target.isAdmin, server.pairingStore.adminCount <= 1
    {
      isLastAdmin = true
      logger.info("Removing last admin pairing — clearing all pairings")
      server.pairingStore.removeAll()
    } else {
      isLastAdmin = false
      server.pairingStore.removePairing(identifier: id)
    }

    // HAP spec §5.11: terminate sessions after a short delay to ensure the
    // response is flushed before teardown.
    if isLastAdmin {
      // All pairings cleared — every active session is now orphaned.
      server.terminateAllSessionsAfterResponse()
    } else {
      // Normalize to uppercase to match verifiedControllerID (set in PairVerify).
      server.terminateSessionsAfterResponse(forController: id.uppercased())
    }

    // If last admin was removed (all pairings cleared) or no pairings
    // remain, update advertisement to indicate unpaired state.
    if isLastAdmin || !server.pairingStore.isPaired {
      server.updateAdvertisement()
    }

    logger.info("Removed pairing: \(id)")
    return successResponse()
  }

  private static func handleList(server: HAPServer) -> HTTPResponse {
    var items: [(TLV8.Tag, Data)] = [(.state, Data([0x02]))]

    let pairings = Array(server.pairingStore.pairings.values)
    for (index, pairing) in pairings.enumerated() {
      items.append((.identifier, Data(pairing.identifier.utf8)))
      items.append((.publicKey, pairing.publicKey))
      items.append((.permissions, Data([pairing.isAdmin ? 1 : 0])))

      // Add separator between pairings (but not after the last one)
      if index < pairings.count - 1 {
        items.append((.separator, Data()))
      }
    }

    let tlv = TLV8.encode(items)
    return HTTPResponse(status: 200, body: tlv, contentType: "application/pairing+tlv8")
  }

  private static func successResponse() -> HTTPResponse {
    let tlv = TLV8.encode([(.state, Data([0x02]))])
    return HTTPResponse(status: 200, body: tlv, contentType: "application/pairing+tlv8")
  }

  private static func errorResponse(error: TLV8.ErrorCode) -> HTTPResponse {
    let tlv = TLV8.encode([
      (.state, Data([0x02])),
      (.error, Data([error.rawValue])),
    ])
    return HTTPResponse(status: 200, body: tlv, contentType: "application/pairing+tlv8")
  }
}
