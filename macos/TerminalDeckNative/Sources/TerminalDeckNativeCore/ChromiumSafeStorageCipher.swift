import Foundation
import CommonCrypto

/// The persisted macOS Electron format. This uses only the documented format
/// facts from Chromium's OSCrypt; no implementation code is imported.
public enum ChromiumSafeStorageCipher {
    public enum Failure: Error, LocalizedError {
        case derivation, encryption, invalidCiphertext, invalidText

        public var errorDescription: String? {
            switch self {
            case .derivation: return "Could not derive the safe-storage encryption key."
            case .encryption: return "Could not encrypt the safe-storage value."
            case .invalidCiphertext: return "The safe-storage blob is invalid or its Keychain key does not match."
            case .invalidText: return "The decrypted safe-storage value is not UTF-8 text."
            }
        }
    }

    public static func encrypt(_ text: String, password: Data) throws -> Data {
        // OSCrypt preserves the empty string as an empty buffer.
        guard !text.isEmpty else { return Data() }
        let key = try derive(password)
        return Data("v10".utf8) + (try crypt(Data(text.utf8), key: key, operation: CCOperation(kCCEncrypt)))
    }

    public static func decrypt(_ blob: Data, password: Data) throws -> String {
        let plain = try decryptData(blob, password: password)
        guard let text = String(data: plain, encoding: .utf8) else { throw Failure.invalidText }
        return text
    }

    /// Cookie databases may prefix decrypted bytes with a host digest. Keep
    /// those bytes intact so migration validates the host before decoding text.
    public static func decryptData(_ blob: Data, password: Data) throws -> Data {
        guard !blob.isEmpty else { return Data() }
        guard blob.starts(with: Data("v10".utf8)), blob.count > 3,
              (blob.count - 3).isMultiple(of: kCCBlockSizeAES128) else { throw Failure.invalidCiphertext }
        return try crypt(Data(blob.dropFirst(3)), key: derive(password), operation: CCOperation(kCCDecrypt))
    }

    private static func derive(_ password: Data) throws -> Data {
        guard !password.isEmpty else { throw Failure.derivation }
        let salt = Data("saltysalt".utf8)
        var derived = Data(count: kCCKeySizeAES128)
        let status = password.withUnsafeBytes { secret in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        secret.bindMemory(to: Int8.self).baseAddress, password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                        output.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.derivation }
        return derived
    }

    private static func crypt(_ input: Data, key: Data, operation: CCOperation) throws -> Data {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let capacity = input.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                input.withUnsafeBytes { inputBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inputBytes.baseAddress, input.count, outputBytes.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw operation == CCOperation(kCCDecrypt) ? Failure.invalidCiphertext : Failure.encryption
        }
        return Data(output.prefix(written))
    }
}
