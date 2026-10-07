import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Port of src/main/account-vault/fake-cipher.fixture.ts: reversed bytes behind
/// a marker — not the plaintext, trivially undone, and never a real Keychain.
final class BackendF4FakeCipher: BackendAccountVaultCipher, @unchecked Sendable {
    static let mark = Data("fake-v1:".utf8)
    private let lock = NSLock()
    private var isAvailable: Bool
    private var decryptCount = 0
    private var encryptError: String?
    init(available: Bool = true, encryptFailure: String? = nil) { isAvailable = available; encryptError = encryptFailure }
    var decrypts: Int { lock.withLock { decryptCount } }
    func setAvailable(_ value: Bool) { lock.withLock { isAvailable = value } }
    func available() -> Bool { lock.withLock { isAvailable } }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data {
        if let failure = lock.withLock({ encryptError }) { throw BackendAccountFailure(failure) }
        return Self.encrypt(text)
    }
    func decrypt(_ blob: Data) throws -> String { lock.withLock { decryptCount += 1 }; return try Self.decrypt(blob) }
    static func encrypt(_ text: String) -> Data { mark + Data(Data(text.utf8).reversed()) }
    static func decrypt(_ blob: Data) throws -> String {
        guard blob.count >= mark.count, Data(blob.prefix(mark.count)) == mark else { throw BackendAccountFailure("not our ciphertext") }
        return String(decoding: Data(Data(blob.dropFirst(mark.count)).reversed()), as: UTF8.self)
    }
}

/// fake-cipher.fixture.ts `claudeLogin()`: the same JSON, key order included.
func BackendF4ClaudeLogin(_ token: String, plan: String = "max", expiresAt: Int64 = 4_102_444_800_000) -> String {
    "{\"claudeAiOauth\":{\"accessToken\":\"sk-ant-oat01-\(token)\",\"refreshToken\":\"sk-ant-ort01-\(token)\",\"expiresAt\":\(expiresAt),\"scopes\":[\"user:inference\",\"user:profile\"],\"subscriptionType\":\"\(plan)\"}}"
}

/// A thread-safe value for injected clocks, counters and switches.
final class BackendF4Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// A vault over the fixture's temporary data folder with a fake cipher.
func BackendF4Vault(_ f: BackendFoundationTestsAccountsFixture, cipher: any BackendAccountVaultCipher = BackendF4FakeCipher(),
                    now: (@Sendable () -> Double)? = nil, writeFile: (@Sendable (Data, URL) throws -> Void)? = nil) throws -> BackendAccountVault {
    if let now { return try BackendAccountVault(configuration: f.configuration, stateStore: f.state, vaultCipher: cipher, now: now, writeFile: writeFile) }
    return try BackendAccountVault(configuration: f.configuration, stateStore: f.state, vaultCipher: cipher, writeFile: writeFile)
}
