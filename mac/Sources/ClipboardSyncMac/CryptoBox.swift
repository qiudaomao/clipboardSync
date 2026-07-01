import CommonCrypto
import CryptoKit
import Foundation

enum CryptoBox {
    private static let type = "encrypted"
    private static let version = 1
    private static let saltBytes = 16
    private static let nonceBytes = 12
    private static let tagBytes = 16
    private static let keyBytes = 32
    private static let pbkdf2Rounds = 100_000

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

    static func decrypt(_ envelope: EncryptedEnvelope, password: String) throws -> Data {
        guard envelope.type == type, envelope.version == version else {
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

        let key = try deriveKey(password: password, salt: salt)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(sealedBox, using: key)
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
