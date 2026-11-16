import Foundation
import Darwin
import CryptoKit
import TerminalDeckNativeCore

/// An import that cannot be done right now. Nothing was written; SYNC keeps
/// the encrypted item and tries again later, and the reason can be shown.
public struct BackendCloudSecretsWaiting: Error, LocalizedError, Equatable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// Cross-process exclusive writer for one existing folder. It locks the
/// folder's own descriptor, so nothing is ever created inside it.
final class BackendCloudSecretsFolderLock: @unchecked Sendable {
    private let descriptor: Int32
    init(folder: URL) throws {
        descriptor = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw BackendCloudSecretsWaiting(reason: "The project folder is not available on this Mac.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw BackendCloudSecretsWaiting(reason: "Another copy of the app is changing this project's MCP servers.")
        }
    }
    deinit { _ = flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

/// `~/.claude.json` belongs to Claude Code and running sessions write it all the
/// time; this app never writes it. User-scope MCP servers are restored only
/// through Claude Code's own command, one server at a time:
///     claude mcp add-json --scope user -- <name> <json>
/// (verified in the installed CLI: `add-json <name> <json>` with
/// `-s, --scope <scope>`; its option parser treats everything after `--` as
/// operands; it refuses a name that already exists, writes under its own
/// config lock and re-reads to confirm). The cloud value is passed as the JSON
/// argument, like the app's existing `claude mcp add` passes env/header values:
/// an accepted, written-down risk (the values are visible in the process list
/// for about a second; the command has no stdin form). A missing or failing
/// command leaves the item waiting.
///
/// Local scope is NOT restored automatically: Claude Code files local servers
/// under the repository's main folder or the real path, not necessarily the
/// path this app was given (git worktrees, linked folders), and that is
/// unproven. Such a server is parked as "add on this Mac" with the reason.
public struct BackendCloudSecretsClaudeMCP: Sendable {
    public let configuration: BackendMcpClientConfiguration
    public let loginPath: @Sendable () async throws -> String
    public let run: BackendMcpClientWriter.Run
    public init(configuration: BackendMcpClientConfiguration, loginPath: @escaping @Sendable () async throws -> String,
                run: @escaping BackendMcpClientWriter.Run) {
        self.configuration = configuration; self.loginPath = loginPath; self.run = run
    }
    /// The app's existing MCP command runner (same login PATH and executor).
    public init(writer: BackendMcpClientWriter) {
        self.init(configuration: writer.configuration, loginPath: writer.loginPath, run: writer.run)
    }
    /// Fields Claude Code keeps for a server. Others are dropped by its schema.
    static let knownFields: Set<String> = ["type", "command", "args", "env", "url", "headers", "headersHelper", "oauth", "timeout", "cwd"]
    static let localScopeParked = "Add this MCP server on this Mac: Claude Code may file project servers under a different folder than this app sees, so Cloud does not add them automatically."
    /// The app's own name rule (BackendMcpClientCommands.validName): a letter or
    /// digit first, so cloud data can never be read as a command option.
    static func acceptable(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil
    }
    /// Whether `stored` (as Claude Code saved it) is this cloud definition:
    /// every saved field equals the cloud one, except defaults Claude may add
    /// (a `type`, or an empty list, object or text the cloud value did not
    /// have), and every field Claude knows that the cloud carries was saved.
    public static func matches(_ stored: NativeRPCValue, _ incoming: CloudValue) throws -> Bool {
        guard let saved = stored.fields, let given = incoming.raw.fields else { return false }
        let byKey = Dictionary(given.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        for field in saved {
            if let value = byKey[field.key] {
                guard try CloudSecretsCanonical.encode(CloudValue(field.value)) == CloudSecretsCanonical.encode(CloudValue(value)) else { return false }
            } else if field.key != "type" && !isEmptyDefault(field.value) { return false }
        }
        let savedKeys = Set(saved.map(\.key))
        return given.allSatisfy { savedKeys.contains($0.key) || !knownFields.contains($0.key) }
    }
    private static func isEmptyDefault(_ value: NativeRPCValue) -> Bool {
        switch value {
        case .array(let items): return items.isEmpty
        case .object(let fields): return fields.isEmpty
        case .string(let text): return text.isEmpty
        case .null: return true
        default: return false
        }
    }
    public func add(name: String, definition: CloudValue, scope: String, project: String?,
                    requireWriter: @Sendable () throws -> Void) async throws -> CloudApplyStatus {
        try requireWriter()
        guard scope == "user" || scope == "local", definition.raw.fields != nil,
              scope == "user" || project?.hasPrefix("/") == true else { throw CloudFailure.invalidRequest }
        let before = try configuration.cloudDefinitions(scope: scope, project: project)[name]
        // Add-only: an existing name is never replaced. A different local one
        // stays, and the cloud one is kept as an encrypted conflict.
        if before != .missing { return try Self.matches(before, definition) ? .alreadyPresent : .keptBoth }
        guard scope == "user" else { throw BackendCloudSecretsWaiting(reason: Self.localScopeParked) }
        guard Self.acceptable(name) else {
            throw BackendCloudSecretsWaiting(reason: "This MCP server's name must start with a letter or number and use only letters, numbers, - and _. It stays saved in Cloud.")
        }
        var json = try CloudSecretsCanonical.encode(definition)
        defer { json.resetBytes(in: 0..<json.count) }
        var environment = configuration.environment
        environment["PATH"] = try await loginPath()
        let output = try await run("claude", ["mcp", "add-json", "--scope", scope, "--", name, String(decoding: json, as: UTF8.self)],
                                   environment, configuration.home, 30_000)
        let after = try configuration.cloudDefinitions(scope: scope, project: project)[name]
        if after != .missing {
            if try Self.matches(after, definition) { return output.ok ? .applied : .alreadyPresent }
            return .keptBoth // Something else saved this name meanwhile; ours stays encrypted.
        }
        if output.missing {
            throw BackendCloudSecretsWaiting(reason: "Claude Code’s command line tool is not installed on this Mac. This MCP server will be added once it is.")
        }
        throw BackendCloudSecretsWaiting(reason: "Claude Code did not add the MCP server \(name): " + Self.said(output, hiding: definition))
    }
    /// The same writer as a person's MCP Remove click. User/local config is owned by Claude Code: this
    /// app never edits ~/.claude.json. No token or definition is passed on the removal command line.
    public func remove(name: String, expecting definition: CloudValue, scope: String, project: String?,
                       requireWriter: @Sendable () throws -> Void) async throws -> Bool {
        try requireWriter()
        guard Self.acceptable(name), ["user", "local", "project"].contains(scope) else { throw CloudFailure.invalidRequest }
        let before = try configuration.cloudDefinitions(scope: scope, project: project)[name]
        guard before != .missing else { return true }
        guard try Self.matches(before, definition) else { return false }
        var environment = configuration.environment
        environment["PATH"] = try await loginPath()
        let result = try await run("claude", ["mcp", "remove", "--scope", scope, "--", name],
                                   environment, project ?? configuration.home, 30_000)
        guard result.ok else { throw CloudFailure.unavailable }
        return try configuration.cloudDefinitions(scope: scope, project: project)[name] == .missing
    }
    /// Claude's own words, only when they cannot carry a value from the
    /// definition: any value (raw or JSON-escaped, any length of 2 or more) or
    /// anything that looks like echoed JSON replaces the whole text with a
    /// plain reason.
    static func said(_ output: BackendGitOutcome, hiding definition: CloudValue) -> String {
        func strings(_ value: NativeRPCValue) -> [String] {
            switch value {
            case .string(let text): return [text]
            case .array(let items): return items.flatMap(strings)
            case .object(let fields): return fields.flatMap { strings($0.value) }
            default: return []
            }
        }
        let text = [output.stderr, output.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: " ").components(separatedBy: .newlines).joined(separator: " ")
        if text.isEmpty { return output.timedOut ? "it did not finish within 30 seconds." : "it gave no reason." }
        let values = strings(definition.raw).filter { $0.count >= 2 }
        let escaped = values.compactMap { value -> String? in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        if text.contains("{") || (values + escaped).contains(where: { text.contains($0) }) {
            return "Claude Code refused the definition (exit \(output.exitCode))."
        }
        return String(text.prefix(300))
    }
}

/// Atomic add-only replacement of a person's own project file (`.mcp.json`).
/// The clean-up is registered before anything is written, so a partial copy
/// never stays; the file is re-read immediately before the replace and left
/// alone if it changed.
enum BackendCloudSecretsProjectFile {
    /// Our own leftover temporaries for this file (they may hold secrets and
    /// sit in a git repository). Only names this writer creates are removed.
    /// ".mcp.json" -> ".mcp.json.cloud-" (a dotfile gets no second dot).
    static func temporaryPrefix(_ path: URL) -> String {
        let name = path.lastPathComponent
        return (name.hasPrefix(".") ? name : "." + name) + ".cloud-"
    }
    static func sweep(_ path: URL) {
        let folder = path.deletingLastPathComponent(), prefix = temporaryPrefix(path)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            let middle = name.dropFirst(prefix.count).dropLast(4)
            guard UUID(uuidString: String(middle)) != nil else { continue }
            _ = unlink(folder.appendingPathComponent(name).path)
        }
    }
    static func replace(_ path: URL, expected: Data?, with bytes: Data, beforeReplace: () throws -> Void) throws -> Bool {
        let folder = path.deletingLastPathComponent()
        var mode: mode_t = 0o644
        if expected != nil {
            var info = stat()
            guard lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
            mode = info.st_mode & 0o777
        }
        let temporary = folder.appendingPathComponent(temporaryPrefix(path) + UUID().uuidString.lowercased() + ".tmp")
        defer { _ = unlink(temporary.path) } // registered before the write; harmless after the rename
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        guard descriptor >= 0 else { throw CloudFailure.unavailable }
        do {
            defer { Darwin.close(descriptor) }
            guard fchmod(descriptor, mode) == 0 else { throw CloudFailure.unavailable }
            var position = 0
            while position < bytes.count {
                let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress?.advanced(by: position), bytes.count - position) }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CloudFailure.unavailable }
                position += written
            }
            guard fsync(descriptor) == 0 else { throw CloudFailure.unavailable }
        }
        try beforeReplace()
        // Re-check immediately before replacing.
        guard try BackendAccountFiles.boundedRead(path, maximum: BackendMcpClientConfiguration.maximumConfigBytes) == expected else { return false }
        if expected == nil {
            guard renamex_np(temporary.path, path.path, UInt32(RENAME_EXCL)) == 0 else {
                guard errno == EEXIST else { throw CloudFailure.unavailable }
                return false
            }
        } else {
            guard Darwin.rename(temporary.path, path.path) == 0 else { throw CloudFailure.unavailable }
        }
        let directory = Darwin.open(folder.path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 { _ = fsync(directory); Darwin.close(directory) }
        return true
    }
}

/// One MCP server from another device that waits for the person on this Mac.
public struct BackendCloudSecretsMCPPendingItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case added, changed, removed }
    public let id: String
    public let kind: Kind
    public let scope: String
    public let project: String?
    public let name: String
    /// The whole command and its arguments (or the URL), secret values masked.
    public let commandLine: String
    public let environmentNames: [String]
    public let headerNames: [String]
    /// Every setting passed to the command as NAME=value; a value is masked only
    /// when its name looks like a secret, never for a variable that changes
    /// what runs.
    public let environment: [String]
    /// Settings that change what the command loads or runs (PATH,
    /// NODE_OPTIONS, DYLD_*, ...), shown in full with a warning line.
    public let runChangingSettings: [String]
    /// `headersHelper`: a command Claude Code runs to sign in to a remote
    /// server. Shown in full.
    public let helperCommand: String?
    /// `cwd`: the folder the command runs in.
    public let workingFolder: String?
    /// Settings that send network traffic elsewhere or change which
    /// certificates are trusted (proxies, certificate overrides, base URLs).
    public let networkSettings: [String]
    /// The command is a shell or an interpreter, or runs code given in its
    /// own arguments (`sh -c`, `node -e`, ...): the sheet says to read it.
    public let runsScript: Bool
    /// `oauth`: how the server signs in, shown with secret values hidden.
    public let oauth: String?
    public init(id: String, kind: Kind, scope: String, project: String?, name: String, commandLine: String,
                environmentNames: [String], headerNames: [String], environment: [String] = [],
                runChangingSettings: [String] = [], helperCommand: String? = nil, workingFolder: String? = nil,
                networkSettings: [String] = [], runsScript: Bool = false, oauth: String? = nil) {
        self.id = id; self.kind = kind; self.scope = scope; self.project = project; self.name = name
        self.commandLine = commandLine; self.environmentNames = environmentNames; self.headerNames = headerNames
        self.environment = environment; self.runChangingSettings = runChangingSettings
        self.helperCommand = helperCommand; self.workingFolder = workingFolder
        self.networkSettings = networkSettings; self.runsScript = runsScript; self.oauth = oauth
    }
    /// Plain words for the list row.
    public var title: String {
        switch kind {
        case .added: return "Add this MCP server on this Mac: \(name)"
        case .changed: return "\(name) was changed on another device. Review it before adding it here."
        case .removed: return "\(name) was removed on another device. It was not removed here."
        }
    }
}

/// Encrypted list of MCP servers waiting for the person's click. Values are
/// sealed with the local protected-store cipher; a file that cannot be read is
/// kept and skipped, never deleted.
public actor BackendCloudSecretsMCPPending {
    struct Entry: Codable, Equatable {
        let kind: BackendCloudSecretsMCPPendingItem.Kind
        let scope: String
        let project: String?
        let name: String
        let definition: CloudValue?
    }
    private let directory: URL
    private let cipher: BackendBrowserPasswordsCipher
    private let requireWriter: @Sendable () throws -> Void
    public init(dataRoot: URL, cipher: BackendBrowserPasswordsCipher, requireWriter: @escaping @Sendable () throws -> Void) {
        directory = dataRoot.appendingPathComponent("cloud-mcp-pending", isDirectory: true)
        self.cipher = cipher; self.requireWriter = requireWriter
    }
    private var nameKey: SymmetricKey?
    /// File names are keyed like the marks files (round-7 S-5): HMAC under a
    /// random key that is stored only sealed with the local protected-store
    /// cipher, so the folder alone cannot confirm a guessed server name.
    func id(scope: String, project: String?, name: String) throws -> String {
        let key = try namingKey()
        return HMAC<SHA256>.authenticationCode(for: Data((scope + "\u{0}" + (project ?? "") + "\u{0}" + name).utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()
    }
    private func namingKey() throws -> SymmetricKey {
        if let nameKey { return nameKey }
        let file = directory.appendingPathComponent("names.key")
        if let bytes = try BackendAccountFiles.boundedRead(file, maximum: 4096) {
            guard let blob = Data(base64Encoded: String(decoding: bytes, as: UTF8.self)),
                  let raw = Data(base64Encoded: try cipher.decrypt(blob)), raw.count == 32 else { throw CloudFailure.secretsLocked }
            nameKey = SymmetricKey(data: raw); return nameKey!
        }
        try requireWriter()
        let raw = try CloudSecretsCrypto.random(32)
        let blob = try cipher.encrypt(raw.base64EncodedString(), false)
        try BackendAccountFiles.writeAtomic(Data(blob.base64EncodedString().utf8), to: file)
        nameKey = SymmetricKey(data: raw); return nameKey!
    }
    private func file(_ id: String) throws -> URL {
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { throw CloudFailure.invalidRequest }
        return directory.appendingPathComponent(id + ".bin")
    }
    func put(_ entry: Entry) throws {
        try requireWriter()
        let fileId = try self.id(scope: entry.scope, project: entry.project, name: entry.name)
        let blob = try cipher.encrypt(String(decoding: try JSONEncoder().encode(entry), as: UTF8.self), false)
        try BackendAccountFiles.writeAtomic(Data(blob.base64EncodedString().utf8), to: file(fileId))
        guard try read(fileId) == entry else { throw CloudFailure.checksumMismatch }
    }
    func read(_ id: String) throws -> Entry? {
        guard let bytes = try BackendAccountFiles.boundedRead(file(id), maximum: CloudWire.maximumBlobBytes) else { return nil }
        guard let blob = Data(base64Encoded: String(decoding: bytes, as: UTF8.self)) else { throw CloudFailure.secretsLocked }
        return try JSONDecoder().decode(Entry.self, from: Data(cipher.decrypt(blob).utf8))
    }
    func entries() throws -> [(String, Entry)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".bin") }.sorted()
        return names.compactMap { name in
            let id = String(name.dropLast(4))
            return (try? read(id)).flatMap { $0 }.map { (id, $0) }
        }
    }
    func remove(_ id: String) throws {
        try requireWriter()
        let path = try file(id)
        guard unlink(path.path) == 0 || errno == ENOENT else { throw CloudFailure.unavailable }
    }
}

/// Whole raw MCP definitions are S, including URL/header/env/argument values.
/// Security ruling (12 Nov): a definition carries the command that runs, and a
/// taken-over account could push one. So nothing from another device is ever
/// added automatically, in any scope: new or changed servers and removals are
/// listed, and a server is added only after the person clicks "Add this MCP
/// server" in this Mac's sheet, which shows the whole command (secrets masked).
/// User scope then goes through `claude mcp add-json` and project scope through
/// the person's own `.mcp.json`, add-only, exactly as before.
public actor BackendCloudSecretsMCPStore: CloudSecretsLogicalStore, CloudSecretsRemovalListing {
    public nonisolated let sourceId: String
    public nonisolated let inventoryRow = "I16"
    public nonisolated let domain = CloudSecretsDomain.mcp
    private let configuration: BackendMcpClientConfiguration
    private let scope: String
    private let project: String?
    private let mergeDefinition: @Sendable (String, CloudValue) async throws -> CloudApplyStatus
    private let pending: BackendCloudSecretsMCPPending?
    private let confirm: @Sendable (BackendCloudSecretsMCPPendingItem) async -> Bool
    private let removeDefinition: (@Sendable (String, CloudValue) async throws -> Bool)?
    /// Keys travel (owner, 15 Nov 2026: "every single thing in cloud", no click and no question on the other device).
    /// When true, the 12 Nov sheet is gone for this store: a server new here is added at once; the same server is one;
    /// a different one under the same name is added beside his as "<name>-<other Mac>" (his is never replaced).
    private let automatic: Bool
    private let thisMac: @Sendable () async -> String?
    private let exchanged = BackendCloudKeysExchanged()
    /// `from`: the sending Mac's name, only for naming a copy apart; never part of "the same server".
    struct Value: Codable {
        let definition: CloudValue
        let from: String?
        init(definition: CloudValue, from: String? = nil) { self.definition = definition; self.from = from }
    }
    /// `mergeDefinition` is the add itself; it runs only from `add(_:)` after
    /// `confirm` (the native sheet) returned the person's click. Tools never
    /// receive `confirm`.
    public init(sourceId: String, configuration: BackendMcpClientConfiguration, scope: String, project: String?,
                mergeDefinition: @escaping @Sendable (String, CloudValue) async throws -> CloudApplyStatus,
                pending: BackendCloudSecretsMCPPending? = nil,
                confirm: @escaping @Sendable (BackendCloudSecretsMCPPendingItem) async -> Bool = { _ in false },
                removeDefinition: (@Sendable (String, CloudValue) async throws -> Bool)? = nil,
                automatic: Bool = false, thisMac: @escaping @Sendable () async -> String? = { nil }) throws {
        guard ["user", "local", "project"].contains(scope), scope == "user" || project != nil else { throw CloudFailure.invalidRequest }
        self.sourceId = sourceId; self.configuration = configuration; self.scope = scope; self.project = project
        self.mergeDefinition = mergeDefinition; self.pending = pending; self.confirm = confirm; self.removeDefinition = removeDefinition
        self.automatic = automatic; self.thisMac = thisMac
    }
    /// Keys travel: his user-scope MCP servers (Claude Code's own list) travel with no click. Added through the app's
    /// existing writer (`claude mcp add-json`, add-only) and removed through it (compare-and-remove), as before.
    /// A server whose program is not on this Mac is still listed and shows its normal "cannot start" state.
    public static func travelling(sourceId: String = "mcp-user", claude: BackendCloudSecretsClaudeMCP,
                                  thisMac: @escaping @Sendable () async -> String?,
                                  requireWriter: @escaping @Sendable () throws -> Void) throws -> BackendCloudSecretsMCPStore {
        try .init(sourceId: sourceId, configuration: claude.configuration, scope: "user", project: nil, mergeDefinition: { name, value in
            try await claude.add(name: name, definition: value, scope: "user", project: nil, requireWriter: requireWriter)
        }, removeDefinition: { name, value in
            try await claude.remove(name: name, expecting: value, scope: "user", project: nil, requireWriter: requireWriter)
        }, automatic: true, thisMac: thisMac)
    }
    public static func bound(sourceId: String, configuration: BackendMcpClientConfiguration, scope: String, project: String?,
                             claude: BackendCloudSecretsClaudeMCP, pending: BackendCloudSecretsMCPPending,
                             confirm: @escaping @Sendable (BackendCloudSecretsMCPPendingItem) async -> Bool,
                             requireWriter: @escaping @Sendable () throws -> Void) throws -> BackendCloudSecretsMCPStore {
        try .init(sourceId: sourceId, configuration: configuration, scope: scope, project: project, mergeDefinition: { name, value in
            if scope == "project", let project {
                return try configuration.cloudMergeProjectDefinition(name: name, definition: value, project: project, requireWriter: requireWriter)
            }
            return try await claude.add(name: name, definition: value, scope: scope, project: project, requireWriter: requireWriter)
        }, pending: pending, confirm: confirm, removeDefinition: { name, value in
            try await claude.remove(name: name, expecting: value, scope: scope, project: project, requireWriter: requireWriter)
        })
    }
    /// The composition passes THIS wrapper to the graph, retaining this raw store for Add's review sheet.
    public nonisolated func deleteRuleStore(stateRoot: URL, gate: @escaping @Sendable () async -> Bool,
                                           macName: @escaping @Sendable (String) async -> String? = { _ in nil },
                                           serviceClock: @escaping @Sendable () async -> Int64? = { nil },
                                           vanished: BackendCloudKeysVanished? = nil,
                                           now: @escaping @Sendable () -> Int64) -> BackendProjectSecretFilesSavedDeleteOwner {
        let owner = BackendProjectSecretFilesSavedDeleteOwner(store: self, stateRoot: stateRoot, gate: gate, name: { $0.recordId }, remove: { record in
            try await self.removeCompared(record)
        }, restore: { record in
            try await self.restoreCompared(record)
        }, macName: macName, serviceClock: serviceClock, now: now, sameValue: { one, other in
            // Keys travel: the sending Mac's name rides beside the definition; the definition alone decides.
            guard one.recordId == other.recordId,
                  let a = try? BackendCloudSecretsRecords.decode(Value.self, one, source: one.sourceId, domain: .mcp),
                  let b = try? BackendCloudSecretsRecords.decode(Value.self, other, source: other.sourceId, domain: .mcp),
                  let left = try? CloudSecretsCanonical.encode(a.definition), let right = try? CloudSecretsCanonical.encode(b.definition) else { return false }
            return left == right
        }, vanished: vanished)
        exchanged.set(owner)
        return owner
    }
    /// The definition inside a record this store made or took (nil when it cannot be read).
    private func definition(_ record: CloudSecretRecord?) -> CloudValue? {
        guard let record, let read = try? BackendCloudSecretsRecords.decode(Value.self, record, source: sourceId, domain: domain) else { return nil }
        return read.definition
    }
    private func restoreCompared(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        let expected = try value(record).definition
        let current = try configuration.cloudDefinitions(scope: scope, project: project)[record.recordId]
        if current != .missing { return try same(current, expected) ? .alreadyPresent : .keptBoth }
        do { return try await mergeDefinition(record.recordId, expected) }
        catch { throw CloudFailure.unavailable }
    }
    private func removeCompared(_ record: CloudSecretRecord) async throws -> Bool {
        guard let removeDefinition else { throw CloudFailure.unavailable }
        let expected = try value(record).definition
        let current = try configuration.cloudDefinitions(scope: scope, project: project)[record.recordId]
        guard current != .missing else { return true }
        guard try same(current, expected) else { return false }
        do { return try await removeDefinition(record.recordId, expected) }
        catch { throw CloudFailure.unavailable }
    }
    public func capture() async throws -> [CloudSecretRecord] { try await captureRead().records }
    /// Review fix 4: the capture plus whether the settings file was there (false = missing: nobody can tell what went).
    /// An unreadable or invalid file throws, as `capture` does.
    public func captureRead() async throws -> (records: [CloudSecretRecord], fileFound: Bool) {
        let mac = automatic ? await thisMac() : nil
        var output: [CloudSecretRecord] = []
        guard let all = try configuration.cloudDefinitionsRead(scope: scope, project: project) else { return ([], false) }
        for field in all.fields ?? [] {
            // Review fix 3: still the server last exchanged for this name: that very record again (no echo).
            if automatic, let last = await exchanged.last(field.key), let before = definition(last), try same(field.value, before) {
                output.append(last); continue
            }
            output.append(try BackendCloudSecretsRecords.record(sourceId, field.key, domain, Value(definition: .init(field.value), from: mac)))
        }
        return (output, true)
    }
    private func value(_ record: CloudSecretRecord) throws -> Value {
        let value = try BackendCloudSecretsRecords.decode(Value.self, record, source: sourceId, domain: domain)
        guard record.recordId.utf8.count <= 512, !record.recordId.contains(where: \.isNewline), value.definition.raw.fields != nil,
              (value.from?.count ?? 0) <= 128 else { throw CloudFailure.invalidRequest }
        return value
    }
    private func same(_ local: NativeRPCValue, _ incoming: CloudValue) throws -> Bool {
        if scope == "project" { return try CloudSecretsCanonical.encode(CloudValue(local)) == CloudSecretsCanonical.encode(incoming) }
        return try BackendCloudSecretsClaudeMCP.matches(local, incoming)
    }
    public func validate(_ record: CloudSecretRecord) async throws { _ = try value(record) }
    /// Called by the sync import. Never adds anything: the same server already
    /// here is "already present"; a new or changed one is listed for the person
    /// ("kept both": the cloud copy also stays as an encrypted conflict).
    public func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        if automatic { return try await mergeAutomatically(record) }
        let incoming = try value(record).definition
        let local = try configuration.cloudDefinitions(scope: scope, project: project)[record.recordId]
        if local != .missing, try same(local, incoming) { return .alreadyPresent }
        guard let pending else { throw BackendCloudSecretsWaiting(reason: "This Mac cannot list MCP servers from Cloud yet.") }
        try await pending.put(.init(kind: local == .missing ? .added : .changed, scope: scope, project: project,
                                    name: record.recordId, definition: incoming))
        return .keptBoth
    }
    /// The copy's name for a different server under the same name: "<name>-<other Mac>" (the MCP name rule holds).
    static func apartName(_ name: String, from: String?) -> String {
        let suffix = "-" + BackendCloudKeysTravel.slug(from)
        return String(name.prefix(max(1, 64 - suffix.count))) + suffix
    }
    private func mergeAutomatically(_ record: CloudSecretRecord) async throws -> CloudApplyStatus {
        let value = try value(record), incoming = value.definition
        let all = try configuration.cloudDefinitions(scope: scope, project: project)
        let local = all[record.recordId]
        if local != .missing, try same(local, incoming) { return .alreadyPresent }
        // The same server under another name here (a copy made earlier, or his own): one server. Kept both, so this
        // name is not taken as one this Mac has (a later look must never read it as removed here).
        for field in all.fields ?? [] { if try same(field.value, incoming) { return .keptBoth } }
        if local == .missing {
            do { return try await mergeDefinition(record.recordId, incoming) }
            catch let waiting as BackendCloudSecretsWaiting { throw waiting }
            catch { throw CloudFailure.unavailable }
        }
        // Review fix 3: unchanged here since the last server exchanged for this name: the newer one replaces it in
        // place (compare-and-remove, then add). Both changed: his stays and the other is added beside it.
        if let before = definition(await exchanged.last(record.recordId)), try same(local, before), let removeDefinition {
            let removed: Bool
            do { removed = try await removeDefinition(record.recordId, before) } catch { throw CloudFailure.unavailable }
            if removed {
                do { return try await mergeDefinition(record.recordId, incoming) }
                catch {
                    // The new one could not be added: his previous one goes back, nothing is lost.
                    _ = try? await mergeDefinition(record.recordId, before)
                    if let waiting = error as? BackendCloudSecretsWaiting { throw waiting }
                    throw CloudFailure.unavailable
                }
            }
        }
        let copy = Self.apartName(record.recordId, from: value.from)
        if all[copy] != .missing { return try same(all[copy], incoming) ? .alreadyPresent : .keptBoth }
        do { _ = try await mergeDefinition(copy, incoming) }
        catch let waiting as BackendCloudSecretsWaiting { throw waiting }
        catch { throw CloudFailure.unavailable }
        return .keptBoth
    }
    public func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool {
        if automatic {
            let incoming = try value(record).definition
            let all = try configuration.cloudDefinitions(scope: scope, project: project)
            if outcome == .keptBoth {
                if all[record.recordId] != .missing { return true }
                for field in all.fields ?? [] { if try same(field.value, incoming) { return true } }
                return false
            }
            for field in all.fields ?? [] { if try same(field.value, incoming) { return true } }
            return false
        }
        let local = try configuration.cloudDefinitions(scope: scope, project: project)[record.recordId]
        let incoming = try value(record).definition
        if outcome == .keptBoth {
            guard let pending else { return false }
            let listedId = try await pending.id(scope: scope, project: project, name: record.recordId)
            let listed = try await pending.read(listedId)
            return listed?.definition == incoming
        }
        guard local != .missing else { return false }
        return try same(local, incoming)
    }
    /// A removal on another device: listed, never applied here.
    public func listRemoval(recordId: String) async throws {
        guard !automatic, let pending else { return }
        try await pending.put(.init(kind: .removed, scope: scope, project: project, name: recordId, definition: nil))
    }
    /// Everything waiting for the person, for the list in this Mac's window.
    public func pendingItems() async throws -> [BackendCloudSecretsMCPPendingItem] {
        guard let pending else { return [] }
        return try await pending.entries().filter { $0.1.scope == scope && $0.1.project == project }.map { Self.item($0.0, $0.1) }
    }
    static func item(_ id: String, _ entry: BackendCloudSecretsMCPPending.Entry) -> BackendCloudSecretsMCPPendingItem {
        let raw = entry.definition?.raw ?? .null
        let env = (raw["env"].fields ?? []).sorted { $0.key < $1.key }
        let runChanging = env.map(\.key).filter(Self.changesWhatRuns)
        let network = env.map(\.key).filter(Self.redirectsNetwork)
        let shown = env.map { field -> String in
            let value = Self.text(field.value)
            if Self.redirectsNetwork(field.key) { return field.key + "=" + Self.hidingURLPassword(value) }
            return field.key + "=" + (Self.changesWhatRuns(field.key) || !Self.looksSecret(field.key) ? value : "••••")
        }
        // Every string a person reads on the sheet has its control and
        // direction characters made visible (round-8 S-4).
        let v = Self.visible
        return .init(id: id, kind: entry.kind, scope: entry.scope, project: entry.project, name: v(entry.name),
                     commandLine: v(entry.definition.map(Self.maskedCommand) ?? ""),
                     environmentNames: env.map { v($0.key) },
                     headerNames: (raw["headers"].fields ?? []).map { v($0.key) }.sorted(),
                     environment: shown.map(v), runChangingSettings: runChanging.map(v),
                     helperCommand: raw["headersHelper"].string.map(v), workingFolder: raw["cwd"].string.map(v),
                     networkSettings: network.map(v), runsScript: entry.definition.map { Self.runsScript($0.raw) } ?? false,
                     oauth: raw["oauth"].isNullish ? nil : v(Self.oauthText(raw["oauth"])))
    }
    static func text(_ value: NativeRPCValue) -> String {
        value.string ?? (try? value.encodedJSON()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    /// `oauth` as plain `name: value` pairs; a secret-looking name (a client
    /// secret) has its value hidden, everything else (client id, callback
    /// port, sign-in address) is shown.
    static func oauthText(_ value: NativeRPCValue) -> String {
        guard let fields = value.fields else { return text(value) }
        return fields.sorted { $0.key < $1.key }.map { field in
            field.key + ": " + (looksSecret(field.key) && !field.key.lowercased().hasSuffix("url") ? "••••" : text(field.value))
        }.joined(separator: ", ")
    }
    /// A proxy address keeps its host; only a password inside it is hidden.
    static func hidingURLPassword(_ value: String) -> String {
        guard var parts = URLComponents(string: value), parts.password != nil else { return value }
        parts.percentEncodedPassword = "****"
        return parts.string ?? value
    }
    /// Control characters (newlines, tabs, escape, NUL...), invisible format
    /// characters (zero-width, right-to-left and other direction marks) and
    /// line/paragraph separators are written out as \u{XXXX}, so nothing on
    /// the sheet can hide, reorder or overwrite what runs.
    static func visible(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse:
                out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
    /// A name that looks like a secret: its value is masked on screen.
    static func looksSecret(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["key", "token", "secret", "password", "passwd", "auth", "bearer", "credential"].contains { lower.contains($0) }
    }
    /// Settings that change what a command loads or runs. Always shown in full.
    static func changesWhatRuns(_ name: String) -> Bool {
        let upper = name.uppercased()
        let exact: Set<String> = ["PATH", "NODE_OPTIONS", "NODE_PATH", "PYTHONPATH", "PYTHONSTARTUP", "PYTHONHOME", "PYTHONUSERBASE",
            "BASH_ENV", "ENV", "ZDOTDIR", "SHELL", "SHELLOPTS", "BASHOPTS", "PS4", "PROMPT_COMMAND", "IFS",
            "GIT_SSH_COMMAND", "GIT_SSH", "GIT_EXEC_PATH", "GIT_ASKPASS", "SSH_ASKPASS", "SUDO_ASKPASS", "GIT_EDITOR", "GIT_PAGER",
            "GIT_TEMPLATE_DIR", "GIT_DIR", "GIT_WORK_TREE", "EDITOR", "VISUAL", "PAGER", "BROWSER",
            "PERL5LIB", "PERL5OPT", "PERLLIB", "RUBYOPT", "RUBYLIB", "GEM_HOME", "GEM_PATH", "BUNDLE_GEMFILE",
            "JAVA_HOME", "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS", "CLASSPATH", "MAVEN_OPTS", "GRADLE_OPTS",
            "DENO_DIR", "BUN_INSTALL", "BUN_OPTIONS", "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "VIRTUAL_ENV", "CONDA_PREFIX",
            "DOTNET_STARTUP_HOOKS", "DOTNET_ROOT", "RUSTC", "RUSTC_WRAPPER", "RUSTFLAGS", "CARGO_HOME", "CARGO_BUILD_RUSTC_WRAPPER",
            "GOFLAGS", "GOROOT", "GOPATH", "GOBIN", "GOTOOLCHAIN", "GOENV", "CC", "CXX", "LDFLAGS", "CFLAGS",
            "DOCKER_HOST", "DOCKER_CONFIG", "DOCKER_CONTEXT", "KUBECONFIG", "TMPDIR"]
        return exact.contains(upper) || ["DYLD_", "LD_", "NPM_CONFIG_", "YARN_", "PIP_", "UV_", "PYTHON", "BASH_FUNC_",
            "GIT_CONFIG", "CORECLR_", "COMPLUS_", "DOTNET_ADDITIONAL_DEPS"].contains { upper.hasPrefix($0) }
    }
    /// Settings that send network traffic elsewhere or change which
    /// certificates are trusted: proxies, certificate overrides, base URLs.
    /// Shown in full (a password inside an address is hidden) with their own
    /// warning (round-8 S-3).
    static func redirectsNetwork(_ name: String) -> Bool {
        let upper = name.uppercased()
        let exact: Set<String> = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "FTP_PROXY", "NO_PROXY", "SOCKS_PROXY", "SOCKS5_PROXY",
            "NODE_EXTRA_CA_CERTS", "NODE_TLS_REJECT_UNAUTHORIZED", "NODE_USE_ENV_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR",
            "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "AWS_CA_BUNDLE", "GIT_SSL_NO_VERIFY", "GIT_SSL_CAINFO", "GIT_SSL_CAPATH",
            "GIT_PROXY_COMMAND", "PYTHONHTTPSVERIFY", "GRPC_DEFAULT_SSL_ROOTS_FILE_PATH", "DENO_CERT", "DENO_TLS_CA_STORE",
            "NPM_CONFIG_PROXY", "NPM_CONFIG_HTTPS_PROXY", "NPM_CONFIG_REGISTRY", "NPM_CONFIG_STRICT_SSL", "NPM_CONFIG_CAFILE",
            "PIP_INDEX_URL", "PIP_EXTRA_INDEX_URL", "PIP_CERT", "PIP_TRUSTED_HOST", "UV_INDEX_URL", "UV_EXTRA_INDEX_URL", "GOPROXY",
            "GONOSUMDB", "GOINSECURE", "GOPRIVATE", "GONOSUMCHECK", "GOSUMDB"]
        return exact.contains(upper) || upper.hasPrefix("GLOBAL_AGENT_")
            || ["_PROXY", "_BASE_URL", "_API_BASE", "_API_URL", "_ENDPOINT", "_HOST_URL", "_CA_BUNDLE", "_CA_CERTS", "_CAFILE"].contains { upper.hasSuffix($0) }
    }
    /// Programs that run a script or code given to them. With one of these, or
    /// with an argument such as `-c` or `--eval`, nothing in the arguments is
    /// masked: the person must read the script (round-8 review R8-1).
    static let interpreters: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "env", "osascript",
        "python", "python2", "python3", "node", "nodejs", "deno", "bun", "ruby", "perl", "php", "lua", "luajit", "rscript",
        "pwsh", "powershell", "awk", "gawk", "tclsh", "expect", "xargs", "eval", "exec"]
    static let scriptFlags: Set<String> = ["-c", "-e", "-E", "-p", "-r", "--eval", "--print", "--command", "-command", "/c", "--exec", "-x", "--require", "-i"]
    /// Whether the definition runs a script given in its own arguments.
    static func runsScript(_ raw: NativeRPCValue) -> Bool {
        let command = (raw["command"].string ?? "").split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        let base = command.replacingOccurrences(of: #"[0-9.]+$"#, with: "", options: .regularExpression)
        let args = (raw["args"].elements ?? []).compactMap(\.string)
        return interpreters.contains(command) || interpreters.contains(base) || args.contains { scriptFlags.contains($0) }
    }
    /// A single plain token: letters, digits and ._~+/=:@%- only. Anything
    /// else (spaces, quotes, ;, |, $, !, backticks...) is shown in full.
    static func plainToken(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[A-Za-z0-9._~+/=:@%-]+$"#, options: .regularExpression) != nil
    }
    /// The whole command and every argument as they would run. A value is
    /// masked only when it is a single plain token AND it follows a flag or
    /// NAME= whose name looks like a secret; never by equality with a setting,
    /// and never for a shell, an interpreter or a script flag. A URL keeps its
    /// host and path; user info and query values are masked.
    static func maskedCommand(_ definition: CloudValue) -> String {
        let raw = definition.raw
        let mask = "••••"
        if let url = raw["url"].string, var parts = URLComponents(string: url) {
            // ASCII mask inside a URL so it is not percent-encoded on screen.
            if parts.user != nil || parts.password != nil { parts.percentEncodedUser = "****"; parts.password = nil }
            parts.percentEncodedQueryItems = parts.percentEncodedQueryItems?.map { URLQueryItem(name: $0.name, value: $0.value == nil ? nil : "****") }
            return (raw["type"].string.map { $0 + " " } ?? "") + (parts.string ?? mask)
        }
        let arguments = (raw["args"].elements ?? []).compactMap(\.string)
        var words = [raw["command"].string ?? ""]
        if runsScript(raw) { return BackendMcpClientCommands.quoteArgv((words + arguments).filter { !$0.isEmpty }) }
        var hideNext = false
        for argument in arguments {
            if hideNext, plainToken(argument) { words.append(mask); hideNext = false; continue }
            hideNext = false
            if let equals = argument.firstIndex(of: "="), looksSecret(String(argument[..<equals])),
               plainToken(String(argument[argument.index(after: equals)...])) {
                words.append(String(argument[...equals]) + mask); continue
            }
            words.append(argument)
            hideNext = argument.hasPrefix("-") && !argument.contains("=") && looksSecret(argument)
        }
        return BackendMcpClientCommands.quoteArgv(words.filter { !$0.isEmpty })
    }
    /// The person clicked the row in this Mac's window. The native sheet shows
    /// the whole command; only its "Add this MCP server" click adds it, add-only
    /// (a changed server whose name already exists here is not replaced).
    public func add(_ id: String) async throws -> CloudApplyStatus {
        guard let pending, let entry = try await pending.read(id), entry.scope == scope, entry.project == project else { throw CloudFailure.invalidRequest }
        let item = Self.item(id, entry)
        guard await confirm(item) else { throw CancellationError() }
        guard let definition = entry.definition else { try await pending.remove(id); return .alreadyPresent } // a removal: acknowledged only
        let status = try await mergeDefinition(entry.name, definition)
        if status != .keptBoth { try await pending.remove(id) }
        return status
    }
    /// The person dismissed the row: nothing is added or removed here.
    public func dismiss(_ id: String) async throws { try await pending?.remove(id) }
}
