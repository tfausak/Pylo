import CryptoKit
import Foundation
import SRP
import TLV8
import os

// MARK: - Pair Setup Handler
// Implements the pair-setup flow (HAP spec section 5.6).
// This is a 3-round (6-message) exchange using SRP-6a.
//
// The SRP math is delegated to an SRP implementation (see SRP.swift).
// This file handles the TLV framing, state machine, and key derivation.

// MARK: - Pair Setup Rate Limiting
// HAP spec §5.6.1: After 100 failed attempts, only process attempts every 30 seconds.

public nonisolated final class PairSetupThrottle: @unchecked Sendable {

  /// Number of failed attempts before throttling kicks in.
  public static let maxAttempts = 100

  /// Minimum seconds between attempts once throttled.
  public static let throttleDuration: TimeInterval = 30

  private struct State {
    var failedAttempts: Int = 0
    var lastFailureDate: Date?
  }

  private let lock = OSAllocatedUnfairLock(initialState: State())

  public init() {}

  public var failedAttempts: Int { lock.withLock { $0.failedAttempts } }

  /// Returns true if the next attempt should be rejected due to rate limiting.
  public func isThrottled(now: Date = Date()) -> Bool {
    lock.withLock { state in
      guard state.failedAttempts >= Self.maxAttempts, let lastFailure = state.lastFailureDate else {
        return false
      }
      return now.timeIntervalSince(lastFailure) < Self.throttleDuration
    }
  }

  /// Record a failed authentication attempt (M3 proof failure).
  /// Only proof failures count toward throttling — session initiations
  /// (M1 requests) do not, preventing self-DoS from network reconnects.
  /// Once the threshold is reached, subsequent attempts are gated by
  /// `throttleDuration`. The counter never resets on its own — only
  /// `reset()` (called after a successful pairing) clears the state.
  ///
  /// The sliding window (updating `lastFailureDate` on every failure) is
  /// intentional: since `isThrottled()` gates M1 acceptance, each failed
  /// M3 ensures the next M1 must wait the full `throttleDuration` again.
  /// A fixed-once window would allow rapid retries after the initial
  /// cooldown expires.
  public func recordFailure(now: Date = Date()) {
    lock.withLock { state in
      state.failedAttempts += 1
      if state.failedAttempts >= Self.maxAttempts {
        state.lastFailureDate = now
      }
    }
  }

  /// Reset the counter after a successful pairing.
  public func reset() {
    lock.withLock { state in
      state.failedAttempts = 0
      state.lastFailureDate = nil
    }
  }
}

public nonisolated enum PairSetupHandler {

  private static let logger = Logger(subsystem: logSubsystem, category: "PairSetup")

  /// Rate limiter for pair-setup attempts (shared across all connections).
  public static let throttle = PairSetupThrottle()

  /// Global flag: a pair-setup exchange is in progress on some connection.
  /// HAP spec §5.6.1: additional M1 requests while another is in progress must return .busy.
  ///
  /// This is static (process-wide) rather than per-HAPServer. In this app only one
  /// HAPServer exists per process, so global scope is acceptable. All cleanup paths
  /// (M3/M5 guard failures, auth failures, M5 success, HAPServer.removeConnection,
  /// and terminateSessions) reset this flag to prevent it from getting stuck.
  private static let _pairSetupInProgress = OSAllocatedUnfairLock(initialState: false)
  static var isPairSetupInProgress: Bool {
    get { _pairSetupInProgress.withLock { $0 } }
    set { _pairSetupInProgress.withLock { $0 = newValue } }
  }

  /// Atomically claims the pair-setup slot. Returns true if claimed, false if already in progress.
  private static func claimPairSetup() -> Bool {
    _pairSetupInProgress.withLock { inProgress in
      guard !inProgress else { return false }
      inProgress = true
      return true
    }
  }

  /// Codes excluded by HAP spec Table 5-8.
  public static let invalidSetupCodes: Set<String> = {
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
  public static func isValidSetupCode(_ code: String) -> Bool {
    !invalidSetupCodes.contains(code)
  }

  /// Generates a random setup code in XXX-XX-XXX format, excluding invalid codes.
  public static func generateSetupCode() -> String {
    while true {
      let d = (0..<8).map { _ in Int.random(in: 0...9) }
      let code = "\(d[0])\(d[1])\(d[2])-\(d[3])\(d[4])-\(d[5])\(d[6])\(d[7])"
      if isValidSetupCode(code) {
        return code
      }
    }
  }

  /// Key store for persisting setup code and setup ID.
  /// Must be set by the app before the server starts.
  /// Protected by a lock to avoid data races from nonisolated(unsafe).
  ///
  /// Design note: keyStore, setupCode, and setupID are static because only
  /// one HAPServer exists per process. Instance injection would require
  /// threading a configuration object through the server and all handlers,
  /// adding complexity with no practical benefit for a single-server app.
  private static let _keyStore = OSAllocatedUnfairLock<KeyStore?>(initialState: nil)
  public static var keyStore: KeyStore! {
    get { _keyStore.withLock { $0 } }
    set { _keyStore.withLock { $0 = newValue } }
  }

  /// The setup code displayed to the user (format: XXX-XX-XXX).
  /// Generated randomly on first launch and persisted via keyStore.
  /// Cached after first access so subsequent reads are free.
  private static let _setupCode = OSAllocatedUnfairLock<String?>(initialState: nil)
  public static var setupCode: String {
    // Fast path: return cached value without touching keyStore.
    if let code = _setupCode.withLock({ $0 }) { return code }
    // Slow path: read keyStore outside _setupCode lock to avoid
    // nesting _setupCode → _keyStore (potential deadlock if the
    // acquisition order were ever inverted).
    precondition(
      keyStore != nil, "PairSetupHandler.keyStore must be set before accessing setupCode")
    let ks = keyStore!
    return _setupCode.withLock { cached in
      // Re-check under lock in case another thread raced us.
      if let code = cached { return code }
      let code: String
      if let data = ks.load(key: "setup-code"),
        let stored = String(data: data, encoding: .utf8)
      {
        code = stored
      } else {
        code = generateSetupCode()
        ks.save(key: "setup-code", data: Data(code.utf8))
      }
      cached = code
      return code
    }
  }

  /// 4-character alphanumeric Setup ID required for QR code pairing.
  /// Generated once and persisted via keyStore.
  private static let _setupID = OSAllocatedUnfairLock<String?>(initialState: nil)
  public static var setupID: String {
    if let id = _setupID.withLock({ $0 }) { return id }
    precondition(
      keyStore != nil, "PairSetupHandler.keyStore must be set before accessing setupID")
    let ks = keyStore!
    return _setupID.withLock { cached in
      if let id = cached { return id }
      let id: String
      if let data = ks.load(key: "setup-id"),
        let stored = String(data: data, encoding: .utf8)
      {
        id = stored
      } else {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        id = String((0..<4).map { _ in chars[Int.random(in: chars.indices)] })
        ks.save(key: "setup-id", data: Data(id.utf8))
      }
      cached = id
      return id
    }
  }

  /// Compute the Setup Hash (sh) for the Bonjour TXT record.
  /// sh = Base64(SHA512(setupID + deviceID)[0..<4])
  public static func setupHash(deviceID: String) -> String {
    return setupHash(setupID: setupID, deviceID: deviceID)
  }

  /// Testable overload that accepts an explicit setupID.
  public static func setupHash(setupID: String, deviceID: String) -> String {
    let input = Data((setupID + deviceID).utf8)
    let digest = SHA512.hash(data: input)
    return Data(digest.prefix(4)).base64EncodedString()
  }

  public static func handle(request: HTTPRequest, connection: HAPConnection, server: HAPServer)
    -> HTTPResponse
  {
    precondition(keyStore != nil, "PairSetupHandler.keyStore must be set before the server starts")

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
    // Validate method is 0x00 (pair setup without MFi). HAP §5.6.1 requires
    // this field; reject with .unknown if missing or not the expected value.
    if let methodData = tlv[.method], methodData.first != 0x00 {
      logger.warning("Unsupported pair-setup method: \(methodData.first.map(String.init) ?? "nil")")
      return errorResponse(state: 0x02, error: .unknown)
    }

    // Reject if this connection already has a session.
    if connection.pairSetupState != nil {
      logger.warning("Pair-setup M1 received while session already in progress on this connection")
      return errorResponse(state: 0x02, error: .busy)
    }

    // Reject if rate-limited (HAP spec §5.6.1)
    if throttle.isThrottled() {
      logger.warning("Pair-setup throttled after \(throttle.failedAttempts) failed attempts")
      return errorResponse(state: 0x02, error: .maxTries)
    }

    // Reject if already paired
    if server.pairingStore.isPaired {
      logger.warning("Already paired, rejecting pair-setup")
      return errorResponse(state: 0x02, error: .unavailable)
    }

    // Atomically claim the pair-setup slot.
    // HAP spec §5.6.1: only one pair-setup may proceed at a time.
    guard claimPairSetup() else {
      logger.warning("Pair-setup M1 received while session already in progress")
      return errorResponse(state: 0x02, error: .busy)
    }

    // Create SRP session
    // Username for HAP is always "Pair-Setup", password is the setup code.
    guard let srpSession = SRPServer(username: "Pair-Setup", password: setupCode) else {
      isPairSetupInProgress = false
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
      session.phase == .awaitingM3,
      let srpSession = session.srpSession,
      let clientPublicKey = tlv[.publicKey],
      let clientProof = tlv[.proof]
    else {
      // If this connection owns the pair-setup slot (has a session), release it
      // so future pairing attempts aren't permanently blocked.
      if connection.pairSetupState != nil {
        connection.setPairSetupState(nil)
        isPairSetupInProgress = false
      }
      return errorResponse(state: 0x04, error: .authentication)
    }

    // Set the client's public key and verify the proof
    guard srpSession.setClientPublicKey(clientPublicKey) else {
      logger.error("Invalid client public key")
      throttle.recordFailure()
      connection.setPairSetupState(nil)
      isPairSetupInProgress = false
      return errorResponse(state: 0x04, error: .authentication)
    }

    guard let serverProof = srpSession.verifyClientProof(clientProof) else {
      logger.error("Client proof verification failed (wrong setup code?)")
      throttle.recordFailure()
      connection.setPairSetupState(nil)
      isPairSetupInProgress = false
      return errorResponse(state: 0x04, error: .authentication)
    }

    // Store the shared session key for M5, advance the phase, and
    // invalidate the SRP session to prevent a replayed M3.
    session.sessionKey = srpSession.sessionKey
    session.phase = .awaitingM5
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
      session.phase == .awaitingM5,
      let sessionKey = session.sessionKey,
      let encryptedData = tlv[.encryptedData]
    else {
      if connection.pairSetupState != nil {
        connection.setPairSetupState(nil)
        isPairSetupInProgress = false
      }
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
      let iosDeviceXKey = HKDF<SHA512>.deriveKey(
        inputKeyMaterial: sessionKey,
        salt: Data("Pair-Setup-Controller-Sign-Salt".utf8),
        info: Data("Pair-Setup-Controller-Sign-Info".utf8),
        outputByteCount: 32
      )

      // Validate controller identifier is valid UTF-8 before signature verification
      guard let iosID = String(data: iosIdentifier, encoding: .utf8), !iosID.isEmpty else {
        logger.error("Invalid or empty controller identifier")
        return errorResponse(state: 0x06, error: .authentication)
      }

      // Verify iOS device signature
      var iosDeviceInfo = iosDeviceXKey.withUnsafeBytes { Data($0) }
      iosDeviceInfo.append(iosIdentifier)
      iosDeviceInfo.append(iosLTPK)

      let iosSigningKey = try Curve25519.Signing.PublicKey(rawRepresentation: iosLTPK)
      guard iosSigningKey.isValidSignature(iosSignature, for: iosDeviceInfo) else {
        logger.error("iOS device signature verification failed")
        return errorResponse(state: 0x06, error: .authentication)
      }

      // Build the accessory's response (M6) BEFORE persisting the pairing.
      // If any crypto step throws, we must not leave a stranded pairing on disk.
      // Derive AccessoryX
      let accessoryXKey = HKDF<SHA512>.deriveKey(
        inputKeyMaterial: sessionKey,
        salt: Data("Pair-Setup-Accessory-Sign-Salt".utf8),
        info: Data("Pair-Setup-Accessory-Sign-Info".utf8),
        outputByteCount: 32
      )

      let accessoryID = Data(server.deviceIdentity.deviceID.utf8)
      let accessoryLTPK = Data(server.deviceIdentity.publicKey.rawRepresentation)

      // Sign: AccessoryX + AccessoryPairingID + AccessoryLTPK
      var accessoryInfo = accessoryXKey.withUnsafeBytes { Data($0) }
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
        connection.setPairSetupState(nil)
        isPairSetupInProgress = false
        return errorResponse(state: 0x06, error: .unavailable)
      }

      logger.info("Pairing stored for controller: \(iosID)")
      throttle.reset()

      // Clean up
      connection.setPairSetupState(nil)
      isPairSetupInProgress = false

      // Update Bonjour to indicate we're now paired
      server.updateAdvertisement()

      logger.info("Pair-Setup M6 sent — pairing complete!")
      return HTTPResponse(status: 200, body: responseTLV, contentType: "application/pairing+tlv8")

    } catch {
      logger.error("Pair-Setup M5 error: \(error)")
      connection.setPairSetupState(nil)
      isPairSetupInProgress = false
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
