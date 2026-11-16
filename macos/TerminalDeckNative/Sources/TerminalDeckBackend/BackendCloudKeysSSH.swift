import Foundation
import Darwin
import TerminalDeckNativeCore

/// Keys travel, part 2 (Decker's decision, 15 Nov 2026): a server saved in Terminal Deck that signs in through his own
/// SSH settings carries what THAT server needs to his other devices, as one saved-passwords entry of its own kind
/// ("Server key · <server name>"): the settings his SSH config resolves for it (host name, user, port), the private key
/// file(s) it names, and the known-host lines for that host. Sealed like every saved password, same delete rule, listed
/// by name on phones and web.
///
/// On another device the copy lives in the app's OWN folder (owner-only), never in his SSH folder, and is used for that
/// server only when the device's own SSH settings have no entry of their own for it (his own always wins; nothing is
/// overwritten). His SSH folder is only READ, and only as far as the server's entry leads (`ssh -G` for that name, the
/// key files it names, the known-host lines for that host). A key protected by a passphrase travels as it is.
public struct BackendCloudKeysSSHValue: Codable, Equatable, Sendable {
    public struct KeyFile: Codable, Equatable, Sendable {
        public let name: String
        public let bytes: Data
    }
    public struct HostLine: Codable, Equatable, Sendable {
        public let algorithm: String
        public let key: Data
    }
    public let server: BackendCloudSecretsServerDefinition
    public let alias: String
    public let hostname: String
    public let user: String
    public let port: Int
    public let keys: [KeyFile]
    public let knownHosts: [HostLine]

    static let maximumKeys = 8, maximumKeyBytes = 64 * 1024, maximumHostLines = 16
    var valid: Bool {
        func plain(_ text: String, _ limit: Int) -> Bool {
            !text.isEmpty && text.utf8.count <= limit && !text.hasPrefix("-") && !text.unicodeScalars.contains { $0.value < 33 || $0.value == 127 }
        }
        guard server.valid, BackendDockerMCPServerSSHConfig.validAlias(alias), plain(hostname, 255), plain(user, 64), (1...65535).contains(port),
              !keys.isEmpty, keys.count <= Self.maximumKeys, knownHosts.count <= Self.maximumHostLines else { return false }
        for key in keys {
            guard !key.bytes.isEmpty, key.bytes.count <= Self.maximumKeyBytes, plain(key.name, 128), !key.name.contains("/"), key.name != "..", key.name != "." else { return false }
        }
        return knownHosts.allSatisfy { plain($0.algorithm, 64) && !$0.key.isEmpty && $0.key.count <= 8_192 }
    }
}

/// What a connection uses from a travelled copy: the settings and the app's own key files.
public struct BackendServersSSHTravelled: Sendable, Equatable {
    public let hostname: String
    public let user: String
    public let port: Int
    public let identityFiles: [String]
    let knownHosts: [BackendServersSSH.ScannedKey]
}

/// The app's own folder of travelled copies: `<root>/<server id>/value.json` (the sealed record's value, kept so it can be
/// compared and put back) and `key-<n>` (what ssh reads with -i). Folders 0700, files 0600, written by temp + rename,
/// never through a link. Never his SSH folder.
public struct BackendCloudKeysSSHFolder: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    static func validId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    private func folder(_ id: String) throws -> URL {
        guard Self.validId(id) else { throw CloudFailure.invalidRequest }
        return root.appendingPathComponent(id, isDirectory: true)
    }
    private static func makeFolder(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == getuid() else { throw CloudFailure.unavailable }
            chmod(url.path, 0o700); return
        }
        guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw CloudFailure.unavailable }
    }
    private static func write(_ data: Data, to file: URL) throws {
        let temp = file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + "." + UUID().uuidString.lowercased())
        let handle = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard handle >= 0 else { throw CloudFailure.unavailable }
        let wrote = data.withUnsafeBytes { buffer in buffer.count == 0 ? 0 : Darwin.write(handle, buffer.baseAddress, buffer.count) }
        let synced = fsync(handle) == 0
        close(handle)
        guard wrote == data.count, synced, rename(temp.path, file.path) == 0 else { unlink(temp.path); throw CloudFailure.unavailable }
    }
    public func value(_ id: String) throws -> BackendCloudKeysSSHValue? {
        let file = try folder(id).appendingPathComponent("value.json")
        guard let bytes = try BackendAccountFiles.boundedRead(file, maximum: CloudWire.maximumPlainChunkBytes) else { return nil }
        guard let value = try? JSONDecoder().decode(BackendCloudKeysSSHValue.self, from: bytes), value.valid else { return nil }
        return value
    }
    public func ids() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter(Self.validId).sorted()
    }
    public func put(_ id: String, _ value: BackendCloudKeysSSHValue) throws {
        guard value.valid else { throw CloudFailure.invalidRequest }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.makeFolder(root)
        let place = try folder(id)
        try Self.makeFolder(place)
        for (index, key) in value.keys.enumerated() { try Self.write(key.bytes, to: place.appendingPathComponent("key-" + String(index))) }
        // Key files beyond this copy's count are old ones: removed, so ssh never offers a key that no longer travels.
        for index in value.keys.count..<BackendCloudKeysSSHValue.maximumKeys { unlink(place.appendingPathComponent("key-" + String(index)).path) }
        try Self.write(try JSONEncoder().encode(value), to: place.appendingPathComponent("value.json"))
    }
    public func remove(_ id: String) throws {
        let place = try folder(id)
        for index in 0..<BackendCloudKeysSSHValue.maximumKeys { unlink(place.appendingPathComponent("key-" + String(index)).path) }
        unlink(place.appendingPathComponent("value.json").path)
        rmdir(place.path)
    }
    /// What a connection to server `id` would use from the copy here (nil: none).
    public func travelled(_ id: String) -> BackendServersSSHTravelled? {
        guard let value = try? value(id), let place = try? folder(id) else { return nil }
        let files = value.keys.indices.map { place.appendingPathComponent("key-" + String($0)).path }
            .filter { FileManager.default.isReadableFile(atPath: $0) }
        guard !files.isEmpty else { return nil }
        return .init(hostname: value.hostname, user: value.user, port: value.port, identityFiles: files,
                     knownHosts: value.knownHosts.map { .init(algorithm: $0.algorithm, key: $0.key) })
    }
}

/// The servers' one SSH dialer asks here for a travelled copy (set by the app when saved passwords start; nil = none).
public final class BackendServersSSHTravelledBox: @unchecked Sendable {
    public static let shared = BackendServersSSHTravelledBox()
    private let lock = NSLock()
    private var held: BackendCloudKeysSSHFolder?
    public func set(_ folder: BackendCloudKeysSSHFolder?) { lock.withLock { held = folder } }
    public func travelled(_ serverId: String) -> BackendServersSSHTravelled? { lock.withLock { held }?.travelled(serverId) }
}

extension BackendServersSSH {
    /// The settings one SSH-settings server connects with. His own entry wins whenever it is his own: it names a key
    /// file that exists here, and it gives the name its own host (or the travelled copy has none to offer, or names the
    /// same host as the name itself). Otherwise the travelled copy, when there is one. Otherwise his own as before
    /// (the existing "no key file" refusal follows).
    struct SSHSettingsChoice: Equatable {
        let hostname: String, user: String, port: Int
        let identities: [String]
        let extraTrusted: [ScannedKey]
        let travelled: Bool
    }
    static func isOwnEntry(alias: String, _ own: BackendDockerMCPServerSSHConfig.Resolution) -> Bool {
        !own.fromDefaults || own.hostname.lowercased() != alias.lowercased()
    }
    static func chooseSSHSettings(alias: String, own: BackendDockerMCPServerSSHConfig.Resolution?, travelled: BackendServersSSHTravelled?,
                                  readable: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }) -> SSHSettingsChoice? {
        let ownIdentities = own?.identityFiles.filter(readable) ?? []
        // Review fix 2: his own entry = an IdentityFile line for this name, or a host name of its own. `ssh -G` answers
        // with the default key files for ANY name, so defaults alone never outrank a copy from his other device.
        if let own, Self.isOwnEntry(alias: alias, own), !ownIdentities.isEmpty {
            return .init(hostname: own.hostname, user: own.user, port: own.port, identities: ownIdentities, extraTrusted: [], travelled: false)
        }
        if let travelled {
            let files = travelled.identityFiles.filter(readable)
            if !files.isEmpty {
                return .init(hostname: travelled.hostname, user: travelled.user, port: travelled.port, identities: files,
                             extraTrusted: travelled.knownHosts, travelled: true)
            }
        }
        guard let own else { return nil }
        return .init(hostname: own.hostname, user: own.user, port: own.port, identities: ownIdentities, extraTrusted: [], travelled: false)
    }
}

/// Source "ssh", domain ssh (already on the lean list). One record per server that signs in through his SSH settings,
/// named by the server id. Tests hand scratch callbacks; the app hands the servers owner's own (`cloudSSHKeys`).
public actor BackendCloudKeysSSHStore: CloudSecretsLogicalStore {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I14"
    public nonisolated let domain = CloudSecretsDomain.ssh
    /// This Mac's servers that sign in through SSH settings (with their settings name).
    private let servers: @Sendable () async throws -> [BackendServersStoredServer]
    /// `ssh -G <name>` over his own SSH settings; throws when this device cannot resolve it.
    private let resolve: @Sendable (String) async throws -> BackendDockerMCPServerSSHConfig.Resolution
    /// His known-host lines for one host and port (read only).
    private let trusted: @Sendable (String, Int) async -> [BackendServersSSH.ScannedKey]
    /// Adds the server row itself when it is not on this device yet (same id, add-only).
    private let addServer: @Sendable (String, BackendCloudKeysSSHValue) async throws -> Void
    private let folder: BackendCloudKeysSSHFolder
    init(sourceId: String = "ssh", servers: @escaping @Sendable () async throws -> [BackendServersStoredServer],
         resolve: @escaping @Sendable (String) async throws -> BackendDockerMCPServerSSHConfig.Resolution,
         trusted: @escaping @Sendable (String, Int) async -> [BackendServersSSH.ScannedKey],
         addServer: @escaping @Sendable (String, BackendCloudKeysSSHValue) async throws -> Void,
         folder: BackendCloudKeysSSHFolder) {
        self.sourceId = sourceId; self.servers = servers; self.resolve = resolve; self.trusted = trusted
        self.addServer = addServer; self.folder = folder
    }

    /// His own entry for this name here (review fix 2: an IdentityFile line or a host name of its own, with a key file
    /// that exists). nil: no entry of his own on this device.
    private func ownEntry(_ alias: String) async -> BackendDockerMCPServerSSHConfig.Resolution? {
        guard let resolved = try? await resolve(alias), BackendServersSSH.isOwnEntry(alias: alias, resolved),
              resolved.identityFiles.contains(where: { FileManager.default.isReadableFile(atPath: $0) }) else { return nil }
        return resolved
    }
    /// What his own entry would send, read from his SSH folder exactly as far as the entry leads.
    private func own(_ server: BackendServersStoredServer, alias: String) async -> BackendCloudKeysSSHValue? {
        // Review fix C: an entry of his own (IdentityFile line, or a host name of its own) sends the key it uses, also
        // a default key file. A name his settings do not know never gets here (ownEntry), so it sends nothing.
        guard let resolved = await ownEntry(alias) else { return nil }
        guard let choice = BackendServersSSH.chooseSSHSettings(alias: alias, own: resolved, travelled: nil), !choice.travelled else { return nil }
        var keys: [BackendCloudKeysSSHValue.KeyFile] = []
        for path in choice.identities.prefix(BackendCloudKeysSSHValue.maximumKeys) {
            let file = URL(fileURLWithPath: path)
            guard let bytes = try? BackendAccountFiles.boundedRead(file, maximum: BackendCloudKeysSSHValue.maximumKeyBytes), !bytes.isEmpty else { continue }
            keys.append(.init(name: file.lastPathComponent, bytes: bytes))
        }
        guard !keys.isEmpty else { return nil }
        let lines = await trusted(resolved.hostname, resolved.port).prefix(BackendCloudKeysSSHValue.maximumHostLines).map { BackendCloudKeysSSHValue.HostLine(algorithm: $0.algorithm, key: $0.key) }
        let value = BackendCloudKeysSSHValue(server: BackendCloudSecretsServerDefinition(server), alias: alias, hostname: resolved.hostname,
                                             user: resolved.user, port: resolved.port, keys: keys, knownHosts: Array(lines))
        return value.valid ? value : nil
    }
    public func capture() async throws -> [CloudSecretRecord] {
        var output: [CloudSecretRecord] = []
        for server in try await servers() {
            guard let alias = server.sshAlias, BackendCloudKeysSSHFolder.validId(server.id) else { continue }
            // His own entry here (never his default keys), else the copy from another device (so the item stays one).
            let value: BackendCloudKeysSSHValue?
            if await ownEntry(alias) != nil { value = await own(server, alias: alias) } else { value = try? folder.value(server.id) }
            guard let value else { continue }
            output.append(try BackendCloudSecretsRecords.record(sourceId, server.id, domain, value))
        }
        return output
    }
    func value(_ record: CloudSecretRecord) throws -> BackendCloudKeysSSHValue {
        let value = try BackendCloudSecretsRecords.decode(BackendCloudKeysSSHValue.self, record, source: sourceId, domain: domain)
        guard BackendCloudKeysSSHFolder.validId(record.recordId), value.valid else { throw CloudFailure.invalidRequest }
        return value
    }
    public func validate(_ record: CloudSecretRecord) async throws { _ = try value(record) }
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        let incoming = try value(record)
        var server = try await servers().first { $0.id == record.recordId }
        if server == nil {
            do { try await addServer(record.recordId, incoming) } catch { throw CloudFailure.unavailable }
            server = try await servers().first { $0.id == record.recordId }
        }
        guard let server, server.sshAlias == incoming.alias else { return .keptBoth }
        // His own entry on this device always wins: nothing is stored, nothing overwritten.
        if await ownEntry(incoming.alias) != nil {
            return await own(server, alias: incoming.alias) == incoming ? .alreadyPresent : .keptBoth
        }
        if try folder.value(record.recordId) == incoming { return .alreadyPresent }
        // The app's own copy (never his): the newest from his other device replaces it, so a changed key arrives.
        do { try folder.put(record.recordId, incoming) } catch { throw CloudFailure.unavailable }
        return .applied
    }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        let incoming = try value(record)
        if outcome == .applied { return try folder.value(record.recordId) == incoming }
        return true
    }
    /// The delete rule: only the app's own copy is removed. His SSH folder is never changed, so on the device where it
    /// is his own entry the server keeps working with his own settings, and the delete rule keeps it out of Cloud.
    func removeCompared(_ record: CloudSecretRecord) async throws -> Bool {
        let incoming = try value(record)
        guard let held = try folder.value(record.recordId) else { return true }
        guard held == incoming else { return false }
        do { try folder.remove(record.recordId) } catch { throw CloudFailure.unavailable }
        return true
    }
    /// Put back: the copy goes back into the app's folder when this device has no entry of its own.
    func restoreCompared(_ record: CloudSecretRecord) async throws -> CloudApplyStatus { try await merge(record) }
    public nonisolated func deleteRuleStore(stateRoot: URL, gate: @escaping @Sendable () async -> Bool,
                                           macName: @escaping @Sendable (String) async -> String? = { _ in nil },
                                           serviceClock: @escaping @Sendable () async -> Int64? = { nil },
                                           now: @escaping @Sendable () -> Int64) -> BackendProjectSecretFilesSavedDeleteOwner {
        .init(store: self, stateRoot: stateRoot, gate: gate, name: { record in
            let name = (try? BackendCloudSecretsRecords.decode(BackendCloudKeysSSHValue.self, record, source: record.sourceId, domain: .ssh))?.server.name
            return "Server key · " + (name ?? "server")
        }, remove: { record in try await self.removeCompared(record) },
        restore: { record in try await self.restoreCompared(record) }, macName: macName, serviceClock: serviceClock, now: now)
    }
}
