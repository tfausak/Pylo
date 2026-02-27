import CryptoKit
import Foundation
import os

// MARK: - Pair Setup Handler
// Implements the pair-setup flow (HAP spec section 5.6).
// This is a 3-round (6-message) exchange using SRP-6a.
//
// The SRP math is delegated to an SRP implementation (see SRP.swift).
// This file handles the TLV framing, state machine, and key derivation.

// MARK: - Pair Setup Rate Limiting
// HAP spec §5.6.1: After 100 failed attempts, only process attempts every 30 seconds.

nonisolated final class PairSetupThrottle {

  /// Number of failed attempts before throttling kicks in.
  static let maxAttempts = 100

  /// Minimum seconds between attempts once throttled.
  static let throttleDuration: TimeInterval = 30

  private struct State {
    var failedAttempts: Int = 0
    var lastFailureDate: Date?
  }

  private let lock = OSAllocatedUnfairLock(initialState: State())

  var failedAttempts: Int { lock.withLock { $0.failedAttempts } }

  /// Returns true if the next attempt should be rejected due to rate limiting.
  func isThrottled(now: Date = Date()) -> Bool {
    lock.withLock { state in
      guard state.failedAttempts >= Self.maxAttempts, let lastFailure = state.lastFailureDate else {
        return false
      }
      return now.timeIntervalSince(lastFailure) < Self.throttleDuration
    }
  }

  /// Record a pair-setup attempt (successful or not).
  /// Counts towards the throttle threshold so that an attacker cannot
  /// start unlimited M1 sessions without triggering rate limiting.
  func recordAttempt(now: Date = Date()) {
    lock.withLock { state in
      state.failedAttempts += 1
      if state.failedAttempts >= Self.maxAttempts {
        state.lastFailureDate = now
      }
    }
  }

  /// Record a failed authentication attempt (M3 proof failure).
  /// Once the threshold is reached, subsequent attempts are gated by
  /// `throttleDuration`. The counter never resets on its own — only
  /// `reset()` (called after a successful pairing) clears the state.
  func recordFailure(now: Date = Date()) {
    lock.withLock { state in
      state.failedAttempts += 1
      // Record/update the timestamp once throttled so each subsequent
      // attempt must wait the full throttle duration.
      if state.failedAttempts >= Self.maxAttempts {
        state.lastFailureDate = now
      }
    }
  }

  /// Reset the counter after a successful pairing.
  func reset() {
    lock.withLock { state in
      state.failedAttempts = 0
      state.lastFailureDate = nil
    }
  }
}

nonisolated enum PairSetupHandler {

  private static let logger = Logger(subsystem: "me.fausak.taylor.Pylo", category: "PairSetup")

  /// Rate limiter for pair-setup attempts (shared across all connections).
  static let throttle = PairSetupThrottle()

  /// Codes excluded by HAP spec Table 5-8.
  static let invalidSetupCodes: Set<String> = {
    var codes: Set<String> = [
      "000-00-000",
      "123-45-678",
      "876-54-321",
    ]
    for d in 1...9 {
      codes.insert("\(d)\(d)\(d)-\(d)\(d)-\(d)\(d)\(d)")
    }
    return codes
  }()

  /// Returns true if the setup code is valid per HAP spec Table 5-8.
  static func isValidSetupCode(_ code: String) -> Bool {
    !invalidSetupCodes.contains(code)
  }

  /// Generates a random setup code in XXX-XX-XXX format, excluding invalid codes.
  static func generateSetupCode() -> String {
    while true {
      let d = (0..<8).map { _ in Int.random(in: 0...9) }
      let code = "\(d[0])\(d[1])\(d[2])-\(d[3])\(d[4])-\(d[5])\(d[6])\(d[7])"
      if isValidSetupCode(code) {
        return code
      }
    }
  }

  /// The setup code displayed to the user (format: XXX-XX-XXX).
  /// Generated randomly on first launch and persisted to Keychain.
  static let setupCode: String = {
    if let data = KeychainHelper.load(key: "setup-code"),
      let code = String(data: data, encoding: .utf8)
    {
      return code
    }
    let code = generateSetupCode()
    KeychainHelper.save(
      key: "setup-code", data: Data(code.utf8),
      accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    )
    return code
  }()

  /// 4-character alphanumeric Setup ID required for QR code pairing.
  /// Generated once and persisted to Keychain.
  static let setupID: String = {
    if let data = KeychainHelper.load(key: "setup-id"),
      let id = String(data: data, encoding: .utf8)
    {
      return id
    }
    let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    let id = String((0..<4).map { _ in chars[Int.random(in: chars.indices)] })
    KeychainHelper.save(
      key: "setup-id", data: Data(id.utf8),
      accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    )
    return id
  }()

  /// Compute the Setup Hash (sh) for the Bonjour TXT record.
  /// sh = Base64(SHA512(setupID + deviceID)[0..<4])
  static func setupHash(deviceID: String) -> String {
    return setupHash(setupID: setupID, deviceID: deviceID)
  }

  /// Testable overload that accepts an explicit setupID.
  static func setupHash(setupID: String, deviceID: String) -> String {
    let input = Data((setupID + deviceID).utf8)
    let digest = SHA512.hash(data: input)
    return Data(digest.prefix(4)).base64EncodedString()
  }

  static func handle(request: HTTPRequest, connection: HAPConnection, server: HAPServer)
    -> HTTPResponse
  {
    guard let body = request.body else {
      return errorResponse(state: 0x02, error: .unknown)
    }

    let tlv: [TLV8.Tag: Data] = TLV8.decode(body)

    guard let stateData = tlv[.state],
      let state = stateData.first
    else {
      return errorResponse(state: 0x02, error: .unknown)
    }

    switch state {
    case 1:
      return handleM1(tlv: tlv, connection: connection, server: server)
    case 3:
      return handleM3(tlv: tlv, connection: connection, server: server)
    case 5:
      return handleM5(tlv: tlv, connection: connection, server: server)
    default:
      logger.error("Unknown pair-setup state: \(state)")
      return errorResponse(state: 0x02, error: .unknown)
    }
  }

  // MARK: - M1: iOS → Accessory (Start Request)
  // iOS sends: state=1, method=0 (pair setup without MFi)
  // Accessory responds with: state=2, salt, publicKey (B)

  private static func handleM1(tlv: [TLV8.Tag: Data], connection: HAPConnection, server: HAPServer)
    -> HTTPResponse
  {
    // Reject if a pair-setup session is already in progress on this connection
    if connection.pairSetupState != nil {
      logger.warning("Pair-setup M1 received while session already in progress")
      return errorResponse(state: 0x02, error: .busy)
    }

    // Reject if rate-limited (HAP spec §5.6.1)
    if throttle.isThrottled() {
      logger.warning("Pair-setup throttled after \(throttle.failedAttempts) failed attempts")
      return errorResponse(state: 0x02, error: .maxTries)
    }
    throttle.recordAttempt()

    // Reject if already paired
    if server.pairingStore.isPaired {
      logger.warning("Already paired, rejecting pair-setup")
      return errorResponse(state: 0x02, error: .unavailable)
    }

    // Create SRP session
    // Username for HAP is always "Pair-Setup", password is the setup code.
    guard let srpSession = SRPServer(username: "Pair-Setup", password: setupCode) else {
      return errorResponse(state: 0x02, error: .unknown)
    }

    // Store SRP state on the connection
    let session = PairSetupSession()
    session.salt = srpSession.salt
    session.serverPublicKey = srpSession.publicKey  // B
    connection.setPairSetupState(session)

    // We need to keep the SRP session around for M3.
    // Store it on the PairSetupSession (extend if needed) or use associated storage.
    // For simplicity, we'll store the full SRP session:
    session.srpSession = srpSession

    let responseTLV = TLV8.encode([
      (.state, Data([0x02])),
      (.publicKey, srpSession.publicKey),
      (.salt, srpSession.salt),
    ])

    logger.info("Pair-Setup M2 sent (salt + public key B)")
    return HTTPResponse(status: 200, body: responseTLV, contentType: "application/pairing+tlv8")
  }

  // MARK: - M3: iOS → Accessory (Verify Request)
  // iOS sends: state=3, publicKey (A), proof (M1)
  // Accessory verifies proof, responds with: state=4, proof (M2)

  private static func handleM3(tlv: [TLV8.Tag: Data], connection: HAPConnection, server: HAPServer)
    -> HTTPResponse
  {
    guard let session = connection.pairSetupState,
      let srpSession = session.srpSession,
      let clientPublicKey = tlv[.publicKey],
      let clientProof = tlv[.proof]
    else {
      return errorResponse(state: 0x04, error: .authentication)
    }

    // Set the client's public key and verify the proof
    guard srpSession.setClientPublicKey(clientPublicKey) else {
      logger.error("Invalid client public key")
      connection.setPairSetupState(nil)
      return errorResponse(state: 0x04, error: .authentication)
    }

    guard let serverProof = srpSession.verifyClientProof(clientProof) else {
      logger.error("Client proof verification failed (wrong setup code?)")
      throttle.recordFailure()
      connection.setPairSetupState(nil)
      return errorResponse(state: 0x04, error: .authentication)
    }

    // Store the shared session key for M5 and invalidate the SRP session
    // to prevent a replayed M3 from mutating state mid-exchange.
    session.sessionKey = srpSession.sessionKey
    session.srpSession = nil

    let responseTLV = TLV8.encode([
      (.state, Data([0x04])),
      (.proof, serverProof),
    ])

    logger.info("Pair-Setup M4 sent (server proof M2)")
    return HTTPResponse(status: 200, body: responseTLV, contentType: "application/pairing+tlv8")
  }

  // MARK: - M5: iOS → Accessory (Exchange Request)
  // iOS sends: state=5, encryptedData (contains iOS_LTPK, iOS_ID, signature)
  // Accessory decrypts, stores pairing, responds with encrypted accessory info.

  private static func handleM5(tlv: [TLV8.Tag: Data], connection: HAPConnection, server: HAPServer)
    -> HTTPResponse
  {
    guard let session = connection.pairSetupState,
      let sessionKey = session.sessionKey,
      let encryptedData = tlv[.encryptedData]
    else {
      return errorResponse(state: 0x06, error: .authentication)
    }

    do {
      // Derive the key used to decrypt M5
      let symmetricKey = HKDF<SHA512>.deriveSymmetricKey(
        inputKeyMaterial: sessionKey,
        salt: Data("Pair-Setup-Encrypt-Salt".utf8),
        info: Data("Pair-Setup-Encrypt-Info".utf8),
        outputByteCount: 32
      )

      // Decrypt
      guard encryptedData.count > 16 else {
        return errorResponse(state: 0x06, error: .authentication)
      }
      let ciphertext = encryptedData[encryptedData.startIndex..<encryptedData.endIndex - 16]
      let tag = encryptedData[encryptedData.endIndex - 16..<encryptedData.endIndex]
      let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 4) + Data("PS-Msg05".utf8))
      let sealedBox = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
      let decrypted = try ChaChaPoly.open(sealedBox, using: symmetricKey)

      // Parse the sub-TLV: identifier, publicKey (LTPK), signature
      let subTLV: [TLV8.Tag: Data] = TLV8.decode(decrypted)
      guard let iosIdentifier = subTLV[.identifier],
        let iosLTPK = subTLV[.publicKey],
        let iosSignature = subTLV[.signature],
        iosLTPK.count == 32
      else {
        return errorResponse(state: 0x06, error: .authentication)
      }

      // Derive iOSDeviceX from the SRP session key
      let iosDeviceX = HKDF<SHA512>.deriveKey(
        inputKeyMaterial: sessionKey,
        salt: Data("Pair-Setup-Controller-Sign-Salt".utf8),
        info: Data("Pair-Setup-Controller-Sign-Info".utf8),
        outputByteCount: 32
      )

      // Verify iOS device signature
      var iosDeviceInfo = iosDeviceX
      iosDeviceInfo.append(iosIdentifier)
      iosDeviceInfo.append(iosLTPK)

      let iosSigningKey = try Curve25519.Signing.PublicKey(rawRepresentation: iosLTPK)
      guard iosSigningKey.isValidSignature(iosSignature, for: iosDeviceInfo) else {
        logger.error("iOS device signature verification failed")
        return errorResponse(state: 0x06, error: .authentication)
      }

      guard let iosID = String(data: iosIdentifier, encoding: .utf8), !iosID.isEmpty else {
        logger.error("Invalid or empty controller identifier")
        return errorResponse(state: 0x06, error: .authentication)
      }

      // Build the accessory's response (M6) BEFORE persisting the pairing.
      // If any crypto step throws, we must not leave a stranded pairing on disk.
      // Derive AccessoryX
      let accessoryX = HKDF<SHA512>.deriveKey(
        inputKeyMaterial: sessionKey,
        salt: Data("Pair-Setup-Accessory-Sign-Salt".utf8),
        info: Data("Pair-Setup-Accessory-Sign-Info".utf8),
        outputByteCount: 32
      )

      let accessoryID = Data(server.deviceIdentity.deviceID.utf8)
      let accessoryLTPK = Data(server.deviceIdentity.publicKey.rawRepresentation)

      // Sign: AccessoryX + AccessoryPairingID + AccessoryLTPK
      var accessoryInfo = accessoryX
      accessoryInfo.append(accessoryID)
      accessoryInfo.append(accessoryLTPK)
      let accessorySignature = try server.deviceIdentity.signingKey.signature(for: accessoryInfo)

      // Build response sub-TLV
      let responseSubTLV = TLV8.encode([
        (.identifier, accessoryID),
        (.publicKey, accessoryLTPK),
        (.signature, Data(accessorySignature)),
      ])

      // Encrypt the response
      let responseNonce = try ChaChaPoly.Nonce(
        data: Data(repeating: 0, count: 4) + Data("PS-Msg06".utf8))
      let sealed = try ChaChaPoly.seal(responseSubTLV, using: symmetricKey, nonce: responseNonce)
      var responseEncrypted = Data(sealed.ciphertext)
      responseEncrypted.append(sealed.tag)

      let responseTLV = TLV8.encode([
        (.state, Data([0x06])),
        (.encryptedData, responseEncrypted),
      ])

      // M6 crypto succeeded — now it's safe to persist the pairing.
      // Use addPairingIfUnpaired to atomically check that no other connection
      // completed pair-setup between our M1 check and now (TOCTOU).
      guard
        server.pairingStore.addPairingIfUnpaired(
          PairingStore.Pairing(
            identifier: iosID,
            publicKey: iosLTPK,
            isAdmin: true  // First pairing is always admin
          ))
      else {
        logger.warning("Pair-Setup M5 rejected — already paired (concurrent pair-setup race)")
        return errorResponse(state: 0x06, error: .unavailable)
      }

      logger.info("Pairing stored for controller: \(iosID)")
      throttle.reset()

      // Clean up
      connection.setPairSetupState(nil)

      // Update Bonjour to indicate we're now paired
      server.updateAdvertisement()

      logger.info("Pair-Setup M6 sent — pairing complete!")
      return HTTPResponse(status: 200, body: responseTLV, contentType: "application/pairing+tlv8")

    } catch {
      logger.error("Pair-Setup M5 error: \(error)")
      return errorResponse(state: 0x06, error: .authentication)
    }
  }

  // MARK: - Helpers

  private static func errorResponse(state: UInt8, error: TLV8.ErrorCode) -> HTTPResponse {
    let tlv = TLV8.encode([
      (.state, Data([state])),
      (.error, Data([error.rawValue])),
    ])
    return HTTPResponse(status: 200, body: tlv, contentType: "application/pairing+tlv8")
  }
}
