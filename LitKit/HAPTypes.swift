import Foundation
import CryptoKit
import os

// MARK: - Keychain Helper

private enum KeychainHelper {

    private static let service = "com.example.hap"
    private static let signingKeyAccount = "device-signing-key"
    private static let deviceIDAccount = "device-id"

    static func save(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func saveSigningKey(_ rawKey: Data) {
        save(key: signingKeyAccount, data: rawKey)
    }

    static func loadSigningKey() -> Data? {
        load(key: signingKeyAccount)
    }

    static func saveDeviceID(_ id: String) {
        save(key: deviceIDAccount, data: Data(id.utf8))
    }

    static func loadDeviceID() -> String? {
        guard let data = load(key: deviceIDAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Device Identity
// The accessory's long-term Ed25519 key pair and device ID.

final class DeviceIdentity {

    private static let logger = Logger(subsystem: "com.example.hap", category: "Identity")

    /// Persistent Ed25519 signing key.
    let signingKey: Curve25519.Signing.PrivateKey

    /// Device ID in AA:BB:CC:DD:EE:FF format (derived from key or randomly generated once).
    let deviceID: String

    /// Accessory's pairing identifier (matches the device ID but without colons for HAP).
    var pairingIdentifier: String {
        deviceID
    }

    init() {
        // Try loading from Keychain first
        if let keyData = KeychainHelper.loadSigningKey(),
           let savedID = KeychainHelper.loadDeviceID() {
            do {
                self.signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
                self.deviceID = savedID
                Self.logger.info("Loaded identity from Keychain: \(savedID)")
                return
            } catch {
                Self.logger.warning("Failed to restore signing key: \(error)")
            }
        }

        // Generate fresh identity and persist
        let newKey = Curve25519.Signing.PrivateKey()
        self.signingKey = newKey

        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let newID = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        self.deviceID = newID

        KeychainHelper.saveSigningKey(newKey.rawRepresentation)
        KeychainHelper.saveDeviceID(newID)
        Self.logger.info("Generated new identity: \(newID)")
    }

    init(signingKey: Curve25519.Signing.PrivateKey, deviceID: String) {
        self.signingKey = signingKey
        self.deviceID = deviceID
    }

    var publicKey: Curve25519.Signing.PublicKey {
        signingKey.publicKey
    }
}

// MARK: - Pairing Store
// Stores paired controllers (their Ed25519 public keys and identifiers).

final class PairingStore {

    struct Pairing: Codable {
        let identifier: String          // Controller's pairing ID (UUID string)
        let publicKey: Data             // Controller's Ed25519 LTPK (32 bytes)
        let isAdmin: Bool
    }

    private static let logger = Logger(subsystem: "com.example.hap", category: "PairingStore")

    /// All known pairings, persisted to disk as JSON.
    private(set) var pairings: [String: Pairing] = [:]

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("pairings.json")
    }

    var isPaired: Bool {
        !pairings.isEmpty
    }

    init() {
        let url = Self.storageURL
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Pairing].self, from: data) {
            self.pairings = decoded
            Self.logger.info("Loaded \(decoded.count) pairing(s) from disk")
        }
    }

    func addPairing(_ pairing: Pairing) {
        pairings[pairing.identifier] = pairing
        save()
    }

    func removePairing(identifier: String) {
        pairings.removeValue(forKey: identifier)
        save()
    }

    func getPairing(identifier: String) -> Pairing? {
        pairings[identifier]
    }

    func removeAll() {
        pairings.removeAll()
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(pairings)
            try data.write(to: Self.storageURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save pairings: \(error)")
        }
    }
}

// MARK: - Encryption Context
// After pair-verify succeeds, this handles encrypting/decrypting HAP frames
// using ChaCha20-Poly1305 with incrementing nonce counters.

final class EncryptionContext {

    private let readKey: SymmetricKey    // Controller-to-Accessory
    private let writeKey: SymmetricKey   // Accessory-to-Controller
    private var readCounter: UInt64 = 0
    private var writeCounter: UInt64 = 0
    private let logger = Logger(subsystem: "com.example.hap", category: "Crypto")

    init(readKey: SymmetricKey, writeKey: SymmetricKey) {
        self.readKey = readKey
        self.writeKey = writeKey
    }

    /// Decrypt an incoming HAP encrypted frame.
    /// - Parameters:
    ///   - lengthBytes: The 2-byte little-endian length prefix (used as AAD).
    ///   - ciphertext: The encrypted payload + 16-byte Poly1305 tag.
    func decrypt(lengthBytes: Data, ciphertext: Data) -> Data? {
        let nonce = makeNonce(counter: readCounter)
        readCounter += 1

        // Split ciphertext from tag
        guard ciphertext.count >= 16 else { return nil }
        let encrypted = ciphertext[ciphertext.startIndex..<ciphertext.endIndex - 16]
        let tag = ciphertext[ciphertext.endIndex - 16..<ciphertext.endIndex]

        do {
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: encrypted,
                tag: tag
            )
            return try ChaChaPoly.open(sealedBox, using: readKey, authenticating: lengthBytes)
        } catch {
            logger.error("Decrypt failed: \(error)")
            return nil
        }
    }

    /// Encrypt an outgoing HAP message, splitting into frames of max 1024 bytes.
    /// Each frame: [2-byte LE length][encrypted data][16-byte tag]
    func encrypt(plaintext: Data) -> Data {
        var result = Data()
        var offset = plaintext.startIndex

        while offset < plaintext.endIndex {
            let chunkEnd = min(offset + 1024, plaintext.endIndex)
            let chunk = plaintext[offset..<chunkEnd]

            let nonce = makeNonce(counter: writeCounter)
            writeCounter += 1

            var lengthBytes = Data(count: 2)
            lengthBytes[0] = UInt8(chunk.count & 0xFF)
            lengthBytes[1] = UInt8((chunk.count >> 8) & 0xFF)

            do {
                let sealed = try ChaChaPoly.seal(
                    chunk,
                    using: writeKey,
                    nonce: nonce,
                    authenticating: lengthBytes
                )
                result.append(lengthBytes)
                result.append(sealed.ciphertext)
                result.append(sealed.tag)
            } catch {
                logger.error("Encrypt failed: \(error)")
                return Data()
            }

            offset = chunkEnd
        }

        return result
    }

    /// HAP nonces are 12 bytes: 4 zero bytes + 8-byte little-endian counter.
    private func makeNonce(counter: UInt64) -> ChaChaPoly.Nonce {
        var nonceData = Data(repeating: 0, count: 4)  // 4 zero bytes
        var le = counter.littleEndian
        nonceData.append(Data(bytes: &le, count: 8))
        return try! ChaChaPoly.Nonce(data: nonceData)
    }
}

// MARK: - Pair Setup Session State

/// Tracks in-progress pair-setup state for a connection.
final class PairSetupSession {
    // SRP session values — filled in progressively during the M1→M6 exchange.
    var salt: Data?
    var serverPublicKey: Data?    // B
    var serverPrivateKey: Data?   // b
    var sharedSecret: Data?       // S -> K
    var clientPublicKey: Data?    // A
    var sessionKey: Data?         // K (derived from shared secret)
    var srpSession: SRPServer?
}

// MARK: - Pair Verify Session State

/// Tracks in-progress pair-verify state for a connection.
final class PairVerifySession {
    var sharedSecret: SharedSecret?
    var accessoryEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    var controllerEphemeralPublicKey: Curve25519.KeyAgreement.PublicKey?
    var sessionKey: Data?  // Derived encryption key for verifying signatures
}

// MARK: - HKDF Convenience

extension HKDF<SHA512> {
    /// Derive a key using HKDF-SHA512 (as required by HAP).
    static func deriveKey(
        inputKeyMaterial: Data,
        salt: Data,
        info: Data,
        outputByteCount: Int = 32
    ) -> Data {
        let ikm = SymmetricKey(data: inputKeyMaterial)
        let derived = Self.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}
