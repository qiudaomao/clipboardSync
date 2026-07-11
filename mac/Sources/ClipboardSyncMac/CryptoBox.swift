import CommonCrypto
import CryptoKit
import Foundation

enum CryptoBox {
    private static let type = "encrypted"
    private static let version = 1
    private static let realtimeVersion = 2
    private static let saltBytes = 16
    private static let nonceBytes = 12
    private static let tagBytes = 16
    private static let keyBytes = 32
    private static let pbkdf2Rounds = 100_000
    private static let realtimeSalt = Data("ClipboardSync realtime input v1".utf8)
    private static let signedSalt = Data("ClipboardSync signed transport v1".utf8)
    private static let keyCacheQueue = DispatchQueue(label: "ClipboardSyncMac.crypto.keyCache")
    private static var cachedKeys: [String: SymmetricKey] = [:]

    static func encrypt(_ plaintext: Data, password: String) throws -> EncryptedEnvelope {
        let salt = randomData(count: saltBytes)
        let nonceData = randomData(count: nonceBytes)
        let key = try deriveKey(password: password, salt: salt)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        return EncryptedEnvelope(
            type: type,
            version: version,
            salt: salt.base64EncodedString(),
            nonce: nonceData.base64EncodedString(),
            ciphertext: sealedBox.ciphertext.base64EncodedString(),
            tag: sealedBox.tag.base64EncodedString()
        )
    }

    static func encryptRealtime(_ plaintext: Data, password: String) throws -> EncryptedEnvelope {
        let nonceData = randomData(count: nonceBytes)
        let key = try cachedKey(password: password, salt: realtimeSalt)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        return EncryptedEnvelope(
            type: type,
            version: realtimeVersion,
            salt: realtimeSalt.base64EncodedString(),
            nonce: nonceData.base64EncodedString(),
            ciphertext: sealedBox.ciphertext.base64EncodedString(),
            tag: sealedBox.tag.base64EncodedString()
        )
    }

    /// Authenticated-plaintext transport: the payload travels unencrypted but
    /// carries an HMAC-SHA256 keyed by a password-derived key, so the password
    /// still authenticates every message when transport encryption is off.
    static func sign(_ plaintext: Data, password: String) throws -> SignedEnvelope {
        let key = try cachedKey(password: password, salt: signedSalt)
        let mac = HMAC<SHA256>.authenticationCode(for: plaintext, using: key)
        return SignedEnvelope(
            type: "signed",
            version: 1,
            payload: plaintext.base64EncodedString(),
            mac: Data(mac).base64EncodedString(),
            from: nil,
            to: nil
        )
    }

    static func verify(_ envelope: SignedEnvelope, password: String) throws -> Data {
        guard envelope.type == "signed", envelope.version == 1 else {
            throw CryptoError.unsupportedEnvelope
        }
        guard
            let plaintext = Data(base64Encoded: envelope.payload),
            let mac = Data(base64Encoded: envelope.mac)
        else {
            throw CryptoError.invalidEnvelope
        }
        let key = try cachedKey(password: password, salt: signedSalt)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: plaintext, using: key) else {
            throw CryptoError.invalidEnvelope
        }
        return plaintext
    }

    static func decrypt(_ envelope: EncryptedEnvelope, password: String) throws -> Data {
        guard envelope.type == type, envelope.version == version || envelope.version == realtimeVersion else {
            throw CryptoError.unsupportedEnvelope
        }
        guard
            let salt = Data(base64Encoded: envelope.salt),
            let nonceData = Data(base64Encoded: envelope.nonce),
            let ciphertext = Data(base64Encoded: envelope.ciphertext),
            let tag = Data(base64Encoded: envelope.tag),
            tag.count == tagBytes
        else {
            throw CryptoError.invalidEnvelope
        }

        let key = envelope.version == realtimeVersion
            ? try cachedKey(password: password, salt: salt)
            : try deriveKey(password: password, salt: salt)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: key)
    }

    private static func cachedKey(password: String, salt: Data) throws -> SymmetricKey {
        let cacheKey = "\(password)\u{0}\(salt.base64EncodedString())"
        if let key = keyCacheQueue.sync(execute: { cachedKeys[cacheKey] }) {
            return key
        }

        let key = try deriveKey(password: password, salt: salt)
        keyCacheQueue.sync {
            cachedKeys[cacheKey] = key
        }
        return key
    }

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        guard let passwordData = password.data(using: .utf8) else {
            throw CryptoError.invalidPassword
        }

        var key = Data(count: keyBytes)
        let derivedKeyCount = key.count
        let result = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(pbkdf2Rounds),
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedKeyCount
                    )
                }
            }
        }

        guard result == kCCSuccess else {
            throw CryptoError.keyDerivationFailed
        }
        return SymmetricKey(data: key)
    }

    private static func randomData(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.bindMemory(to: UInt8.self).baseAddress!)
        }
        return data
    }
}

enum CryptoError: Error {
    case invalidPassword
    case invalidEnvelope
    case unsupportedEnvelope
    case keyDerivationFailed
}
