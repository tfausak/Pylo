import CryptoKit
import Foundation
import os

// MARK: - Pair Verify Handler
// Implements the pair-verify flow (HAP spec section 5.7).
// This is a 2-step exchange using Curve25519 ECDH.
// Much simpler than pair-setup — no SRP involved.

nonisolated enum PairVerifyHandler {

  private static let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "PairVerify")

  static func handle(request: HTTPRequest, connection: HAPConnection, server: HAPServer)
    -> HTTPResponse
  {
    guard let body = request.body else {
      return errorResponse(state: 0x02, .unknown)
    }

    let tlv: [TLV8.Tag: Data] = TLV8.decode(body)

    guard let stateData = tlv[.state],
      let state = stateData.first
    else {
      return errorResponse(state: 0x02, .unknown)
    }

    switch state {
    case 1:
      return handleM1(tlv: tlv, connection: connection, server: server)
    case 3:
      return handleM3(tlv: tlv, connection: connection, server: server)
    default:
      logger.error("Unknown pair-verify state: \(state)")
      return errorResponse(state: 0x02, .unknown)
    }
  }

  // MARK: - M1: Controller → Accessory
  // Controller sends its ephemeral Curve25519 public key.
  // Accessory generates its own ephemeral key, computes shared secret,
  // derives session key, signs, encrypts, and responds.

  private static func handleM1(tlv: [TLV8.Tag: Data], connection: HAPConnection, server: HAPServer)
    -> HTTPResponse
  {
    guard let controllerPublicKeyData = tlv[.publicKey],
      controllerPublicKeyData.count == 32
    else {
      return errorResponse(state: 0x02, .unknown)
    }

    do {
      let controllerPublicKey = try Curve25519.KeyAgreement.PublicKey(
        rawRepresentation: controllerPublicKeyData)

      // Generate ephemeral key pair
      let accessoryPrivateKey = Curve25519.KeyAgreement.PrivateKey()
      let accessoryPublicKey = accessoryPrivateKey.publicKey

      // Compute shared secret
      let sharedSecret = try accessoryPrivateKey.sharedSecretFromKeyAgreement(
        with: controllerPublicKey)

      // Derive session key for encryption
      let sessionKey = sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA512.self,
        salt: Data("Pair-Verify-Encrypt-Salt".utf8),
        sharedInfo: Data("Pair-Verify-Encrypt-Info".utf8),
        outputByteCount: 32
      )

      // Build the info to sign: accessory ephemeral public key + accessory ID + controller ephemeral public key
      let accessoryID = Data(server.deviceIdentity.deviceID.utf8)
      var accessoryInfo = Data()
      accessoryInfo.append(accessoryPublicKey.rawRepresentation)
      accessoryInfo.append(accessoryID)
      accessoryInfo.append(controllerPublicKeyData)

      // Sign with the accessory's long-term Ed25519 key
      let signature = try server.deviceIdentity.signingKey.signature(for: accessoryInfo)

      // Build the sub-TLV (identifier + signature)
      let subTLV = TLV8.encode([
        (.identifier, accessoryID),
        (.signature, Data(signature)),
      ])

      // Encrypt the sub-TLV
      let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + Data("PV-Msg02".utf8))
      let sealed = try ChaChaPoly.seal(subTLV, using: sessionKey, nonce: nonce)
      var encryptedData = Data(sealed.ciphertext)
      encryptedData.append(sealed.tag)

      // Save session state
      let session = PairVerifySession()
      session.accessoryEphemeralPrivateKey = accessoryPrivateKey
      session.controllerEphemeralPublicKey = controllerPublicKey
      session.sharedSecret = sharedSecret
      session.sessionKey = sessionKey
      connection.setPairVerifyState(session)

      // Respond with M2
      let responseTLV = TLV8.encode([
        (.state, Data([0x02])),
        (.publicKey, Data(accessoryPublicKey.rawRepresentation)),
        (.encryptedData, encryptedData),
      ])

      logger.info("Pair-Verify M2 sent")
      return HTTPResponse(status: 200, body: responseTLV, contentType: "application/pairing+tlv8")

    } catch {
      logger.error("Pair-Verify M1 error: \(error)")
      return errorResponse(state: 0x02, .unknown)
    }
  }

  // MARK: - M3: Controller → Accessory
  // Controller sends encrypted {controller ID, signature}.
  // Accessory decrypts, verifies the controller is a known pairing,
  // verifies the signature, then establishes the encrypted session.

  private static func handleM3(tlv: [TLV8.Tag: Data], connection: HAPConnection, server: HAPServer)
    -> HTTPResponse
  {
    guard let encryptedData = tlv[.encryptedData],
      let session = connection.pairVerifyState,
      let sessionKey = session.sessionKey,
      let sharedSecret = session.sharedSecret,
      let controllerPublicKey = session.controllerEphemeralPublicKey,
      let accessoryPrivateKey = session.accessoryEphemeralPrivateKey
    else {
      return errorResponse(state: 0x04, .authentication)
    }

    do {

      // Decrypt the sub-TLV
      guard encryptedData.count > 16 else {
        return errorResponse(state: 0x04, .authentication)
      }
      let ciphertext = encryptedData[encryptedData.startIndex..<encryptedData.endIndex - 16]
      let tag = encryptedData[encryptedData.endIndex - 16..<encryptedData.endIndex]
      let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + Data("PV-Msg03".utf8))
      let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
      let decrypted = try ChaChaPoly.open(sealedBox, using: sessionKey)

      // Parse the sub-TLV
      let subTLV: [TLV8.Tag: Data] = TLV8.decode(decrypted)
      guard let controllerIdentifier = subTLV[.identifier],
        let controllerSignature = subTLV[.signature]
      else {
        return errorResponse(state: 0x04, .authentication)
      }

      let controllerID = String(data: controllerIdentifier, encoding: .utf8) ?? ""

      // Look up the controller's long-term public key from our pairing store
      guard let pairing = server.pairingStore.getPairing(identifier: controllerID) else {
        logger.error("Unknown controller: \(controllerID)")
        return errorResponse(state: 0x04, .authentication)
      }

      // Verify the signature
      let controllerLTPK = try Curve25519.Signing.PublicKey(rawRepresentation: pairing.publicKey)
      var controllerInfo = Data()
      controllerInfo.append(controllerPublicKey.rawRepresentation)
      controllerInfo.append(controllerIdentifier)
      controllerInfo.append(accessoryPrivateKey.publicKey.rawRepresentation)

      guard controllerLTPK.isValidSignature(Data(controllerSignature), for: controllerInfo) else {
        logger.error("Controller signature verification failed")
        return errorResponse(state: 0x04, .authentication)
      }

      // SUCCESS — derive the transport encryption keys
      // HAP names keys from the controller's perspective:
      //   "Control-Write" = what controller sends → accessory reads
      //   "Control-Read"  = what controller reads → accessory writes
      let readKey = sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA512.self,
        salt: Data("Control-Salt".utf8),
        sharedInfo: Data("Control-Write-Encryption-Key".utf8),
        outputByteCount: 32
      )
      let writeKey = sharedSecret.hkdfDerivedSymmetricKey(
        using: SHA512.self,
        salt: Data("Control-Salt".utf8),
        sharedInfo: Data("Control-Read-Encryption-Key".utf8),
        outputByteCount: 32
      )

      // Defer encryption until after the plaintext M4 response is sent
      connection.setPendingEncryptionContext(EncryptionContext(readKey: readKey, writeKey: writeKey))

      // Record which controller authenticated this session (for admin checks)
      connection.setVerifiedControllerID(controllerID)

      // Store the shared secret for HDS key derivation
      connection.setPairVerifySharedSecret(sharedSecret)

      // Clean up verify session
      connection.setPairVerifyState(nil)

      let responseTLV = TLV8.encode([
        (.state, Data([0x04]))
      ])

      logger.info("Pair-Verify complete — session encrypted")
      return HTTPResponse(status: 200, body: responseTLV, contentType: "application/pairing+tlv8")

    } catch {
      logger.error("Pair-Verify M3 error: \(error)")
      return errorResponse(state: 0x04, .authentication)
    }
  }

  // MARK: - Helpers

  private static func errorResponse(state: UInt8, _ error: TLV8.ErrorCode) -> HTTPResponse {
    let tlv = TLV8.encode([
      (.state, Data([state])),
      (.error, Data([error.rawValue])),
    ])
    return HTTPResponse(status: 200, body: tlv, contentType: "application/pairing+tlv8")
  }
}
