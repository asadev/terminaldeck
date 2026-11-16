import Foundation
import TerminalDeckNativeCore

/// Native-only. This deliberately has no Codable conformance or bridge value.
public enum BackendServersCredential: Sendable, Equatable {
    case password(String)
    case key(privateKey: String, passphrase: String?)
    /// The person's own SSH settings name. Holds no secret: ssh reads their
    /// config and key files itself when connecting. Never saved or copied here.
    case sshConfig(alias: String)
    public var kind: BackendServersCredentialKind { switch self { case .password: .password; case .key: .key; case .sshConfig: .sshConfig } }
    fileprivate var storedFields: [NativeRPCValue.Field] {
        switch self {
        case .sshConfig(let alias): [.init("kind", .string("ssh-config")), .init("alias", .string(alias))]
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
    private let dataRoot: URL, policy: BackendServersStoragePolicy
    private var cipher: BackendBrowserPasswordsCipher
    private var cloudFile: URL?
    private var activeFile: URL { cloudFile ?? file }
    private let keyValidator: BackendServersKeyValidator
    private let lock = NSLock()
    private var saved: [String: BackendServersCredential]?
    private var held: [String: BackendServersCredential] = [:]
    /// U1: what the last read could not understand. `blocked` means not even a copy of the file could be
    /// kept, so nothing is saved over it and the next read tries again.
    private var problem: String?, blocked = false
    /// Cloud saved passwords (lane V): told after each successful save or forget, on a background queue and never
    /// under this object's lock. One observer; nil removes it. While Cloud is off there is none and nothing runs.
    private var cloudObserver: (@Sendable () -> Void)?
    /// 13 Nov: the earlier (Electron) app's key, for sign-ins it sealed that were never moved to this app's key.
    private let earlierKey: BackendServersEarlierAppKey?
    /// `needsOK` is remembered until the person's press (or close) so the quiet lookup is not repeated on every read.
    private var earlierNeedsOK = false, earlierBlocked = false
    func cloudObserve(_ observer: (@Sendable () -> Void)?) { lock.withLock { cloudObserver = observer } }
    public init(dataRoot: URL, cipher: BackendBrowserPasswordsCipher, policy: BackendServersStoragePolicy, keyValidator: BackendServersKeyValidator,
                earlierKey: BackendServersEarlierAppKey? = nil) {
        self.dataRoot = dataRoot; self.cipher = cipher; self.policy = policy; self.keyValidator = keyValidator; self.earlierKey = earlierKey
        file = dataRoot.appendingPathComponent(Self.fileName)
    }
    public func available() throws -> Bool { try lock.withLock { try cipher.available() } }
    private func load() throws -> [String: BackendServersCredential] {
        try policy.requireRead()
        if let saved { return saved }
        // 13 Nov: sign-ins the earlier app sealed with its own key are converted before they are read. While they
        // wait (macOS must ask first, or this copy may not write), nothing is saved over them and no damaged copy
        // is made: they are not damaged.
        if earlierKey != nil, cloudFile == nil {
            let earlier = settleEarlierQuietly()
            if earlier.pending { problem = earlier.sentence; blocked = true; earlierBlocked = true; return [:] }
            if earlierBlocked { problem = nil; blocked = false; earlierBlocked = false }
        }
        var list: [String: BackendServersCredential] = [:], damaged = false
        if FileManager.default.fileExists(atPath: activeFile.path) {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: activeFile.path), let size = attrs[.size] as? NSNumber,
               size.intValue <= 4 * 1024 * 1024, let encoded = try? String(contentsOf: activeFile, encoding: .utf8),
               let blob = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
               let plain = try? cipher.decrypt(blob), let raw = try? NativeRPCValue.parseJSON(Data(plain.utf8), maximumBytes: 4 * 1024 * 1024) {
                for row in raw["entries"].elements ?? [] {
                    guard let id = row["serverId"].string, !id.isEmpty else { damaged = true; continue }
                    if row["kind"].string == "password", let value = row["password"].string { list[id] = .password(value) }
                    else if row["kind"].string == "key", let value = row["privateKey"].string { list[id] = .key(privateKey: value, passphrase: row["passphrase"].string) }
                    else if row["kind"].string != "ssh-config" { damaged = true }
                }
            } else { damaged = true }
        }
        // U1: an unreadable file or row is kept as a .damaged copy before any save; without that copy, nothing is saved.
        if damaged {
            let copy = DamagedFile.keepCopy(of: activeFile)
            problem = DamagedFile.sentence("The saved server sign-ins", copy: copy); blocked = copy == nil
            if blocked { return list }
        }
        saved = list; return list
    }
    private func persist(_ next: [String: BackendServersCredential]) throws -> BackendServersSaveOutcome {
        try policy.requireWrite()
        if blocked { return .init(ok: false, message: problem ?? DamagedFile.sentence("The saved server sign-ins", copy: nil)) }
        guard try cipher.available() else { return .init(ok: false, message: Self.noSecureStore) }
        let entries = next.keys.sorted().compactMap { id -> NativeRPCValue? in
            guard let value = next[id] else { return nil }
            return .object([.init("serverId", .string(id))] + value.storedFields)
        }
        let raw = NativeRPCValue.object([.init("version", .number(1)), .init("entries", .array(entries))])
        let text = String(decoding: try raw.encodedJSON(), as: UTF8.self)
        let blob = try cipher.encrypt(text, FileManager.default.fileExists(atPath: activeFile.path))
        try BackendRemoteServeSecretFile.write(directory: activeFile.deletingLastPathComponent(), file: activeFile, contents: Data(blob.base64EncodedString().utf8))
        defer { problem = nil }
        saved = next
        if let cloudObserver { DispatchQueue.global(qos: .utility).async { cloudObserver() } }
        return .init(ok: true, message: problem.map { "Saved. " + $0 } ?? "Saved.")
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
    /// Portable records exclude session-only credentials and do not expose an RPC value.
    func cloudRecords() throws -> [String: BackendServersCredential] {
        try lock.withLock {
            let entries = try load()
            guard problem == nil, !blocked else { throw CloudFailure.secretsLocked }
            return entries.filter { $0.value.kind != .sshConfig }
        }
    }
    func cloudMerge(_ id: String, credential: BackendServersCredential) throws -> CloudApplyStatus {
        try lock.withLock {
            var entries = try load()
            guard problem == nil, !blocked else { throw CloudFailure.secretsLocked }
            if let active = held[id] { return active == credential ? .alreadyPresent : .keptBoth }
            if let existing = entries[id] { return existing == credential ? .alreadyPresent : .keptBoth }
            entries[id] = credential
            guard try persist(entries).ok, try load()[id] == credential else { throw CloudFailure.unavailable }
            return .applied
        }
    }
    func cloudNeedsRecovery() throws -> Bool {
        try lock.withLock {
            guard let bytes = try BackendAccountFiles.boundedRead(activeFile, maximum: 4 * 1024 * 1024) else { return false }
            guard let blob = Data(base64Encoded: String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { return true }
            return (try? cipher.decrypt(blob)) == nil
        }
    }
    func cloudAdopt(file restored: URL, cipher replacement: BackendBrowserPasswordsCipher) throws {
        try lock.withLock {
            try policy.requireWrite()
            let alreadyExists = FileManager.default.fileExists(atPath: restored.path)
            // Keep any still-readable local values (for example a key lost
            // while this process still holds its old cipher) before switching.
            var previous: [String: BackendServersCredential] = [:]
            if let bytes = try BackendAccountFiles.boundedRead(activeFile, maximum: 4 * 1024 * 1024),
               let blob = Data(base64Encoded: String(decoding: bytes, as: UTF8.self)), (try? cipher.decrypt(blob)) != nil {
                previous = try cloudRecordsUnlocked()
            }
            cloudFile = restored; cipher = replacement; saved = nil; problem = nil; blocked = false
            _ = try cloudRecordsUnlocked()
            if !alreadyExists, !previous.isEmpty { guard try persist(previous).ok else { throw CloudFailure.unavailable } }
        }
    }
    private func cloudRecordsUnlocked() throws -> [String: BackendServersCredential] {
        let rows = try load()
        guard problem == nil, !blocked else { throw CloudFailure.secretsLocked }
        return rows
    }
    private struct CloudSSHFile: Codable { let id: String; let value: BackendCloudSecretsSSHValue }
    private func cloudSSHPath(_ id: String) throws -> URL {
        guard !id.isEmpty, id.utf8.count <= 512, !id.contains(where: \.isNewline) else { throw CloudFailure.invalidRequest }
        return activeFile.deletingLastPathComponent().appendingPathComponent("cloud-ssh", isDirectory: true)
            .appendingPathComponent(CloudSecretsCrypto.hash(Data(id.utf8)) + ".bin")
    }
    private func cloudSSHReadUnlocked(_ id: String) throws -> BackendCloudSecretsSSHValue? {
        guard let bytes = try BackendAccountFiles.boundedRead(cloudSSHPath(id), maximum: CloudWire.maximumBlobBytes) else { return nil }
        guard let blob = Data(base64Encoded: String(decoding: bytes, as: UTF8.self)) else { throw CloudFailure.secretsLocked }
        let value = try JSONDecoder().decode(CloudSSHFile.self, from: Data(cipher.decrypt(blob).utf8))
        guard value.id == id else { throw CloudFailure.checksumMismatch }
        return value.value
    }
    func cloudSSHRead(_ id: String) throws -> BackendCloudSecretsSSHValue? {
        try lock.withLock { try policy.requireRead(); return try cloudSSHReadUnlocked(id) }
    }
    func cloudSSHRecords() throws -> [String: BackendCloudSecretsSSHValue] {
        try lock.withLock {
            try policy.requireRead()
            let directory = activeFile.deletingLastPathComponent().appendingPathComponent("cloud-ssh", isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard files.count <= 4096 else { throw CloudFailure.invalidRequest }
            var result: [String: BackendCloudSecretsSSHValue] = [:]
            for file in files where file.pathExtension == "bin" {
                guard let bytes = try BackendAccountFiles.boundedRead(file, maximum: CloudWire.maximumBlobBytes),
                      let blob = Data(base64Encoded: String(decoding: bytes, as: UTF8.self)) else { throw CloudFailure.secretsLocked }
                let value = try JSONDecoder().decode(CloudSSHFile.self, from: Data(cipher.decrypt(blob).utf8))
                // Same folder by construction; compare the name only. Comparing
                // whole URLs failed when the folder is reached through a system
                // link (/var is /private/var), so an honest file read as tampered.
                guard try cloudSSHPath(value.id).lastPathComponent == file.lastPathComponent,
                      result[value.id] == nil else { throw CloudFailure.checksumMismatch }
                result[value.id] = value.value
            }
            return result
        }
    }
    func cloudSSHMaterialize(_ selection: BackendCloudSecretsSSHSelection, value: BackendCloudSecretsSSHValue) throws -> CloudApplyStatus {
        try lock.withLock {
            try policy.requireWrite()
            guard selection.kind == value.kind else { throw CloudFailure.invalidRequest }
            return try BackendCloudSecretsSSHFiles.add(value.bytes, to: selection.file)
        }
    }
    func cloudSSHMerge(_ id: String, value: BackendCloudSecretsSSHValue) throws -> CloudApplyStatus {
        try lock.withLock {
            try policy.requireWrite()
            if let existing = try cloudSSHReadUnlocked(id) { return existing == value ? .alreadyPresent : .keptBoth }
            let path = try cloudSSHPath(id)
            let plain = String(decoding: try JSONEncoder().encode(CloudSSHFile(id: id, value: value)), as: UTF8.self)
            let blob = try cipher.encrypt(plain, false)
            let encoded = Data(blob.base64EncodedString().utf8)
            guard encoded.count <= CloudWire.maximumBlobBytes else { throw CloudFailure.invalidRequest }
            try BackendAccountFiles.writeAtomic(encoded, to: path)
            guard try cloudSSHReadUnlocked(id) == value else { throw CloudFailure.checksumMismatch }
            return .applied
        }
    }
    public func close() { lock.withLock { held = [:]; saved = nil; problem = nil; blocked = false; earlierNeedsOK = false; earlierBlocked = false } }
    /// What is known about sign-ins left by the earlier app. Converts them when that needs no question from macOS.
    public func earlierAppStanding() -> BackendServersEarlierStanding { lock.withLock { settleEarlierQuietly() } }
    /// The person's own press on the Servers page (the caller enforces that): macOS may ask once for the earlier
    /// app's key. Neither Keychain item is changed; the original file is kept as a dated backup beside it.
    public func convertEarlierAppSignIns() throws -> BackendServersEarlierStanding {
        try lock.withLock {
            guard let earlierKey, unconvertedEarlierBlob() != nil else { return settleEarlierQuietly() }
            let key = try earlierKey.withPermission()
            earlierNeedsOK = false
            return try convertEarlier(with: key)
        }
    }
    /// The live file's blob when this app's key cannot open it; nil when there is nothing an earlier key could help with.
    private func unconvertedEarlierBlob() -> Data? {
        guard cloudFile == nil, let bytes = try? BackendAccountFiles.boundedRead(file, maximum: BackendServersEarlierAppMigration.maximum),
              let blob = Data(base64Encoded: String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              (try? cipher.decrypt(blob)) == nil else { return nil }
        return blob
    }
    /// Under the lock. Never prompts and never throws; a file it cannot convert is left exactly as it is.
    private func settleEarlierQuietly() -> BackendServersEarlierStanding {
        guard unconvertedEarlierBlob() != nil else { earlierNeedsOK = false; return .clear }
        guard let earlierKey else { return .keyGone }
        if earlierNeedsOK { return .needsOK }
        switch earlierKey.quiet() {
        case .missing: return .keyGone
        case .needsPermission: earlierNeedsOK = true; return .needsOK
        case .key(let key): return (try? convertEarlier(with: key)) ?? .notConverted
        }
    }
    private func convertEarlier(with key: Data) throws -> BackendServersEarlierStanding {
        try policy.requireWrite()
        switch try BackendServersEarlierAppMigration.convert(file: file, earlierKey: key, cipher: cipher) {
        case .notNeeded: return .clear
        case .oldKeyCannotOpen: return .keyGone
        case .converted:
            saved = nil; earlierNeedsOK = false
            if earlierBlocked { problem = nil; blocked = false; earlierBlocked = false }
            NSLog("[servers] Saved server sign-ins from the earlier app were converted to this app's key; the original file is kept beside them.")
            return .converted
        }
    }
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
