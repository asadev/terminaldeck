import Foundation
import TerminalDeckNativeCore

/// Native-only. This deliberately has no Codable conformance or bridge value.
public enum BackendServersCredential: Sendable, Equatable {
    case password(String)
    case key(privateKey: String, passphrase: String?)
    public var kind: BackendServersCredentialKind { switch self { case .password: .password; case .key: .key } }
    fileprivate var storedFields: [NativeRPCValue.Field] {
        switch self {
        case .password(let value): [.init("kind", .string("password")), .init("password", .string(value))]
        case .key(let value, let opener): [.init("kind", .string("key")), .init("privateKey", .string(value)), .init("passphrase", opener.map(NativeRPCValue.string) ?? .null)]
        }
    }
}
public struct BackendServersSaveOutcome: Sendable, Equatable {
    public let ok: Bool, message: String
    public init(ok: Bool, message: String) { self.ok = ok; self.message = message }
    public var wireValue: NativeRPCValue { .object([.init("ok", .bool(ok)), .init("message", .string(message))]) }
}
public enum BackendServersDraftOutcome: Sendable {
    case accepted(BackendServersCredential)
    case refused(problem: String, sentence: String)
}
public struct BackendServersKeyValidator: Sendable {
    /// Return nil only after parsing/decrypting the complete private key. A
    /// missing validator must throw unavailable; recognizing a header is not a
    /// successful validation of a key.
    public let validate: @Sendable (String, String?) async throws -> String?
    public init(validate: @escaping @Sendable (String, String?) async throws -> String?) { self.validate = validate }
}

/// Source credentials.ts, including the Electron safeStorage-compatible blob.
/// Keychain identity and availability are supplied by the exclusive facade.
/// Initializers perform no reads, Keychain calls, directory creation or probes.
public final class BackendServersCredentials: @unchecked Sendable {
    public static let fileName = "server-credentials.bin"
    public static let noSecureStore = "This computer has no secure store available, so a sign-in cannot be saved here. On Linux that usually means no keyring is running; start one and try again."
    public let file: URL
    private let dataRoot: URL, cipher: BackendBrowserPasswordsCipher, policy: BackendServersStoragePolicy
    private let keyValidator: BackendServersKeyValidator
    private let lock = NSLock()
    private var saved: [String: BackendServersCredential]?
    private var held: [String: BackendServersCredential] = [:]
    public init(dataRoot: URL, cipher: BackendBrowserPasswordsCipher, policy: BackendServersStoragePolicy, keyValidator: BackendServersKeyValidator) {
        self.dataRoot = dataRoot; self.cipher = cipher; self.policy = policy; self.keyValidator = keyValidator
        file = dataRoot.appendingPathComponent(Self.fileName)
    }
    public func available() throws -> Bool { try cipher.available() }
    private func load() throws -> [String: BackendServersCredential] {
        try policy.requireRead()
        if let saved { return saved }
        var list: [String: BackendServersCredential] = [:]
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let size = attrs[.size] as? NSNumber,
           size.intValue <= 4 * 1024 * 1024, let encoded = try? String(contentsOf: file, encoding: .utf8),
           let blob = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
           let plain = try? cipher.decrypt(blob), let raw = try? NativeRPCValue.parseJSON(Data(plain.utf8), maximumBytes: 4 * 1024 * 1024) {
            for row in raw["entries"].elements ?? [] {
                guard let id = row["serverId"].string, !id.isEmpty else { continue }
                if row["kind"].string == "password", let value = row["password"].string { list[id] = .password(value) }
                if row["kind"].string == "key", let value = row["privateKey"].string { list[id] = .key(privateKey: value, passphrase: row["passphrase"].string) }
            }
        }
        saved = list; return list
    }
    private func persist(_ next: [String: BackendServersCredential]) throws -> BackendServersSaveOutcome {
        try policy.requireWrite()
        guard try cipher.available() else { return .init(ok: false, message: Self.noSecureStore) }
        let entries = next.keys.sorted().compactMap { id -> NativeRPCValue? in
            guard let value = next[id] else { return nil }
            return .object([.init("serverId", .string(id))] + value.storedFields)
        }
        let raw = NativeRPCValue.object([.init("version", .number(1)), .init("entries", .array(entries))])
        let text = String(decoding: try raw.encodedJSON(), as: UTF8.self)
        let blob = try cipher.encrypt(text, FileManager.default.fileExists(atPath: file.path))
        try BackendRemoteServeSecretFile.write(directory: dataRoot, file: file, contents: Data(blob.base64EncodedString().utf8))
        saved = next; return .init(ok: true, message: "Saved.")
    }
    public func save(_ serverID: String, credential: BackendServersCredential) throws -> BackendServersSaveOutcome {
        try lock.withLock { var next = try load(); next[serverID] = credential; held[serverID] = nil; return try persist(next) }
    }
    public func holdForSession(_ serverID: String, credential: BackendServersCredential) { lock.withLock { held[serverID] = credential } }
    /// Internal by design. IPC/MCP files cannot obtain a sign-in by calling a
    /// public reader; only the connection pool in this module consumes it.
    func read(_ serverID: String) throws -> BackendServersCredential? { try lock.withLock { if let value = held[serverID] { return value }; return try load()[serverID] } }
    public func kindOf(_ serverID: String) throws -> BackendServersCredentialKind { try read(serverID)?.kind ?? .none }
    public func isHeldForSessionOnly(_ serverID: String) -> Bool { lock.withLock { held[serverID] != nil } }
    public func forget(_ serverID: String) throws -> BackendServersSaveOutcome {
        try lock.withLock {
            held[serverID] = nil; var current = try load()
            guard current.removeValue(forKey: serverID) != nil else { return .init(ok: true, message: "Nothing was stored.") }
            return try persist(current)
        }
    }
    public func close() { lock.withLock { held = [:]; saved = nil } }
    public func keyProblem(_ privateKey: String, passphrase: String?) async throws -> String? {
        if privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Paste the key file, including its first and last lines." }
        if privateKey.utf16.count > 64 * 1024 { return "That is much too long to be a key file." }
        return try await keyValidator.validate(privateKey, passphrase)
    }
    public func credentialFromDraft(_ draft: NativeRPCValue) async throws -> BackendServersDraftOutcome {
        if draft["method"].string == "password" {
            let value = draft["password"].string ?? ""
            return value.isEmpty ? .refused(problem: "nothing-typed", sentence: "Type the password for that server.") : .accepted(.password(value))
        }
        let value = draft["key"].string ?? "", opener = draft["passphrase"].string
        if let issue = try await keyProblem(value, passphrase: opener) {
            let locked = BackendServersKeyfiles.describeKey(value, name: "")?.locked == true
            return .refused(problem: locked ? (opener == nil ? "needs-passphrase" : "bad-passphrase") : "key-unreadable", sentence: issue)
        }
        return .accepted(.key(privateKey: value, passphrase: opener))
    }
}
