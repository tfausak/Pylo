import Foundation
import os

// MARK: - Pairings Handler
// Handles POST /pairings for adding, removing, and listing pairings.
// This endpoint is only accessible over an encrypted (pair-verified) session.

enum PairingsHandler {

    private static let logger = Logger(subsystem: "com.example.hap", category: "Pairings")

    // Pairing methods
    private static let methodAddPairing: UInt8    = 3
    private static let methodRemovePairing: UInt8 = 4
    private static let methodListPairings: UInt8  = 5

    static func handle(request: HTTPRequest, connection: HAPConnection, server: HAPServer) -> HTTPResponse {
        // Pairings management requires an encrypted session
        guard connection.encryptionContext != nil else {
            return errorResponse(error: .authentication)
        }

        guard let body = request.body else {
            return errorResponse(error: .unknown)
        }

        let tlv: [TLV8.Tag: Data] = TLV8.decode(body)

        guard let stateData = tlv[.state], stateData.first == 1,
              let methodData = tlv[.method], let method = methodData.first else {
            return errorResponse(error: .unknown)
        }

        switch method {
        case methodAddPairing:
            return handleAdd(tlv: tlv, server: server)
        case methodRemovePairing:
            return handleRemove(tlv: tlv, server: server)
        case methodListPairings:
            return handleList(server: server)
        default:
            return errorResponse(error: .unknown)
        }
    }

    private static func handleAdd(tlv: [TLV8.Tag: Data], server: HAPServer) -> HTTPResponse {
        guard let identifier = tlv[.identifier],
              let publicKey = tlv[.publicKey],
              let permissions = tlv[.permissions] else {
            return errorResponse(error: .unknown)
        }

        let id = String(data: identifier, encoding: .utf8) ?? ""
        let isAdmin = permissions.first == 1

        server.pairingStore.addPairing(PairingStore.Pairing(
            identifier: id,
            publicKey: publicKey,
            isAdmin: isAdmin
        ))

        logger.info("Added pairing: \(id)")
        return successResponse()
    }

    private static func handleRemove(tlv: [TLV8.Tag: Data], server: HAPServer) -> HTTPResponse {
        guard let identifier = tlv[.identifier] else {
            return errorResponse(error: .unknown)
        }

        let id = String(data: identifier, encoding: .utf8) ?? ""
        server.pairingStore.removePairing(identifier: id)

        // If no pairings remain, update advertisement
        if !server.pairingStore.isPaired {
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
