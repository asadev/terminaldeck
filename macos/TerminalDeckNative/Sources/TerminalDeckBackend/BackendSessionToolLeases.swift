import Foundation
import Security
import Darwin
import TerminalDeckNativeCore

/// Positive grant copied from session-tools.ts, with Chrome extension controls
/// removed for the user's Safari migration. It is intersected with the actual
/// serving catalogue; unsupported/unregistered tools never get advertised.
public enum BackendOrdinarySessionToolGrant {
    public static let names: Set<String> = Set([
        "browser.open", "browser.read", "browser.step", "browser.screenshot", "browser.handover", "browser.close",
        "browser.workers", "browser.worker", "browser.lift_request", "browser.network", "browser.extract",
        "assets.rendition", "assets.ledger", "assets.fetch", "assets.coverage", "assets.blocks",
        "devices.list", "devices.open", "devices.screenshot", "devices.tree", "devices.find", "devices.tap",
        "devices.swipe", "devices.type", "devices.button", "devices.annotations",
        "memory.search", "memory.read", "knowledge.note", "tools.describe",
    ].flatMap { [$0, $0.replacingOccurrences(of: ".", with: "_")] })
}

public struct BackendPreparedToolLease: Sendable {
    public let id: UUID
    public let arguments: [String]
    public let environment: [String: String]
    public let readableFiles: [String]
    public let implementation: BackendMCPImplementation
}

/// Real pending caller + private files + 60-second claim deadline. Each run
/// has a private namespace, so assembly alongside the still-active Node owner
/// cannot delete its existing configs or tokens.
public actor BackendSessionToolLeases: BackendLaunchCapability {
    public nonisolated let readiness: BackendLaunchReadiness
    private let endpoint: any BackendMCPToolEndpoint
    private let clock: any BackendDeckCoreEventsClock
    private let root: URL
    private let runID = UUID().uuidString.lowercased()
    private struct Lease: Sendable {
        let directory: URL
        let registration: BackendMCPRegistration?
        var sessionID: String?
        let deadline: UUID
    }
    private var leases: [UUID: Lease] = [:]
    private var stopped = false
    private var ownerDescriptor: Int32?

    public init(endpoint: any BackendMCPToolEndpoint, userData: URL,
                clock: any BackendDeckCoreEventsClock = BackendDeckCoreEventsRealClock()) throws {
        guard userData.isFileURL, userData.path.hasPrefix("/"), userData.path != "/" else {
            throw BackendSessionFailure.invalidInput("Session tool leases need Terminal Deck's own absolute user-data root.")
        }
        self.endpoint = endpoint; self.clock = clock; root = userData.standardizedFileURL.appendingPathComponent("session-tools", isDirectory: true)
        readiness = endpoint.readiness
    }

    public func prepareOrdinary() async throws -> BackendPreparedToolLease {
        try await prepare(serverName: "deck-control", allowed: BackendOrdinarySessionToolGrant.names, projectRoot: nil)
    }
    public func prepareOrdinary(restricting allowedTools: [String]?, deniedTools: [String], taskID: String? = nil, taskProject: String? = nil) async throws -> BackendPreparedToolLease? {
        let allowed = BackendTAGToolPolicy.filter(BackendTAGToolPolicy.sessionNames(taskID: taskID), server: "deck-control", allowed: allowedTools, denied: deniedTools)
        guard !allowed.isEmpty else { return nil }
        return try await prepare(serverName: "deck-control", allowed: allowed, projectRoot: taskID == nil ? nil : taskProject, taskProject: taskID == nil ? nil : taskProject)
    }

    /// A configured project tool endpoint supplies its actual tool ids; a
    /// project grant is never the entire app/Commander catalogue.
    public func prepare(serverName: String, allowed: Set<String>, projectRoot: String?, taskProject: String? = nil) async throws -> BackendPreparedToolLease {
        guard !stopped, readiness == .ready else { throw BackendSessionFailure.missingCapability("the serving session MCP endpoint") }
        guard serverName.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil,
              let serving = try await endpoint.description() else { throw BackendSessionFailure.missingCapability("the listening session MCP endpoint") }
        let catalogue = try await endpoint.catalogue()
        guard !stopped else { throw BackendSessionFailure.closed }
        var grant: Set<String> = []
        for spec in catalogue where RNMHootMCPCompatibility.permits(spec.id, granted: allowed) || RNMHootMCPCompatibility.permits(spec.wireName, granted: allowed) {
            grant.insert(spec.id); grant.insert(spec.wireName)
        }
        guard !grant.isEmpty else { throw BackendSessionFailure.missingCapability("registered tools for this session's actual grant") }
        try prepareNamespace()
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw BackendSessionFailure.invalidInput("macOS could not generate a private session MCP token.")
        }
        let token = random.map { String(format: "%02x", $0) }.joined()
        let id = UUID()
        let directory = root.appendingPathComponent("native-" + runID, isDirectory: true).appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        let config = directory.appendingPathComponent(serverName + ".json")
        let tokenFile = directory.appendingPathComponent(serverName + ".token")
        let registration = try await endpoint.register(token: token,
            grant: BackendMCPCallerGrant(attended: true, allowedTools: grant, allowedTiers: [.read, .act, .alter], projectRoot: projectRoot, taskProject: taskProject))
        do {
            guard !stopped else { throw BackendSessionFailure.closed }
            let server = NativeRPCValue.object([.init("type", .string("http")), .init("url", .string(serving.url.absoluteString)),
                .init("headers", .object([.init("Authorization", .string("Bearer " + token))]))])
            let bytes = try NativeRPCValue.object([.init("mcpServers", .object([.init(serverName, server)]))]).encodedJSON(pretty: true)
            try BackendPrivateLaunchFiles.createDirectory(directory, under: root)
            try BackendPrivateLaunchFiles.write(bytes, to: config)
            // The native stdio relay may read this file; the token is never
            // inserted into argv or logged. The file has the same lease lifetime.
            try BackendPrivateLaunchFiles.write(Data(token.utf8), to: tokenFile)
        } catch {
            await endpoint.revoke(registration)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let deadline = clock.schedule(after: 60_000) { [weak self] in Task { await self?.expire(id) } }
        leases[id] = Lease(directory: directory, registration: registration, deadline: deadline)
        return BackendPreparedToolLease(id: id, arguments: ["--mcp-config", config.path], environment: [:],
            readableFiles: [config.path, tokenFile.path], implementation: serving.implementation)
    }

    /// A lease in this exact existing owner namespace, with NO MCP caller token.
    public func reserveAgentSettingsFiles() throws -> BackendAGSLaunchFileLease {
        guard !stopped, readiness == .ready else { throw BackendSessionFailure.closed }
        try prepareNamespace()
        let id = UUID(), directory = root.appendingPathComponent("native-" + runID).appendingPathComponent(id.uuidString.lowercased())
        try BackendPrivateLaunchFiles.createDirectory(directory, under: root)
        let deadline = clock.schedule(after: 60_000) { [weak self] in Task { await self?.expire(id) } }
        leases[id] = Lease(directory: directory, registration: nil, sessionID: nil, deadline: deadline)
        return BackendAGSLaunchFileLease(id: id, directory: directory, write: { [weak self] files in
            guard let self else { throw BackendSessionFailure.closed }; try await self.writeAgentSettingsFiles(id, files: files)
        }, bind: { [weak self] session in
            guard let self else { throw BackendSessionFailure.closed }; try await self.bind(id, sessionID: session)
        }, abandon: { [weak self] in await self?.abandon(id) })
    }
    private func writeAgentSettingsFiles(_ id: UUID, files: [String: Data]) throws {
        guard !stopped, let lease = leases[id], lease.registration == nil, lease.sessionID == nil,
              files.count <= 50 else { throw BackendSessionFailure.closed }
        for (name, bytes) in files {
            guard name.hasPrefix("ags-"), name.hasSuffix(".json"), !name.contains("/"), !name.contains("\0"), bytes.count <= 2 * 1024 * 1024 else { throw BackendSessionFailure.invalidInput("Invalid private agent settings file.") }
            try BackendPrivateLaunchFiles.write(bytes, to: lease.directory.appendingPathComponent(name))
        }
    }
    public func agentSettingsConfiguration(_ id: UUID) throws -> NativeRPCValue {
        guard !stopped, let lease = leases[id], lease.registration != nil else { throw BackendSessionFailure.closed }
        let files = try FileManager.default.contentsOfDirectory(at: lease.directory, includingPropertiesForKeys: nil)
        let configs = files.filter { $0.pathExtension == "json" }
        guard configs.count == 1, let bytes = try BackendAccountFiles.boundedRead(configs[0], maximum: 2 * 1024 * 1024) else { throw BackendSessionFailure.invalidInput("The actual session MCP configuration is missing.") }
        let value = try NativeRPCValue.parseJSON(bytes)["mcpServers"]
        guard value.fields != nil else { throw BackendSessionFailure.invalidInput("The actual session MCP configuration is malformed.") }; return value
    }

    public func nativeStdioSpec(_ prepared: BackendPreparedToolLease, serverName: String,
                                launcher: BackendNativeMCPStdioLauncher) async throws -> BackendProjectMCPServerSpec {
        guard let lease = leases[prepared.id], let serving = try await endpoint.description() else {
            throw BackendSessionFailure.missingCapability("the pending native stdio MCP caller")
        }
        let tokenFile = lease.directory.appendingPathComponent(serverName + ".token")
        guard BackendNativeProviders.lookup(launcher.command, path: "") != nil else {
            throw BackendSessionFailure.missingCapability("the native MCP stdio relay executable")
        }
        return try BackendProjectMCPServerSpec(name: serverName, command: launcher.command,
            arguments: launcher.argumentsPrefix + [serving.url.absoluteString, tokenFile.path], environment: [:],
            implementation: serving.implementation)
    }

    public func bind(_ id: UUID, sessionID: String, machineID: String = "") async throws {
        guard var lease = leases[id], lease.sessionID == nil else { throw BackendSessionFailure.invalidInput("The session MCP caller expired or was already claimed.") }
        if let registration = lease.registration { try await endpoint.bind(registration, sessionID: sessionID, machineID: machineID) }
        guard !stopped, leases[id] != nil else { if let registration = lease.registration { await endpoint.revoke(registration) }; throw BackendSessionFailure.closed }
        clock.cancel(lease.deadline); lease.sessionID = sessionID; leases[id] = lease
    }
    public func abandon(_ id: UUID) async { await forget(id) }
    public func release(sessionID: String) async {
        let ids = leases.compactMap { $0.value.sessionID == sessionID ? $0.key : nil }
        for id in ids { await forget(id) }
    }
    public func stop() async {
        stopped = true
        for id in Array(leases.keys) { await forget(id) }
        if let ownerDescriptor { flock(ownerDescriptor, LOCK_UN); Darwin.close(ownerDescriptor); self.ownerDescriptor = nil }
        // Only this run's own private namespace is removed.
        try? FileManager.default.removeItem(at: root.appendingPathComponent("native-" + runID))
    }
    public var pendingCount: Int { leases.values.filter { $0.sessionID == nil }.count }
    public var count: Int { leases.count }
    private func expire(_ id: UUID) async { if leases[id]?.sessionID == nil { await forget(id) } }
    private func forget(_ id: UUID) async {
        guard let lease = leases.removeValue(forKey: id) else { return }
        clock.cancel(lease.deadline)
        if let registration = lease.registration { await endpoint.revoke(registration) } // Revoke before removing secret files.
        try? FileManager.default.removeItem(at: lease.directory)
    }

    private func prepareNamespace() throws {
        guard ownerDescriptor == nil else { return }
        let namespace = root.appendingPathComponent("native-" + runID, isDirectory: true)
        try BackendPrivateLaunchFiles.createDirectory(namespace, under: root)
        let marker = namespace.appendingPathComponent("owner.lock")
        let descriptor = open(marker.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BackendSessionFailure.operatingSystem(operation: "own the native MCP launch namespace", code: errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let status = errno; Darwin.close(descriptor)
            throw BackendSessionFailure.operatingSystem(operation: "lock the native MCP launch namespace", code: status)
        }
        let pid = Data((String(getpid()) + "\n").utf8)
        let written = pid.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
        guard written == pid.count else { flock(descriptor, LOCK_UN); Darwin.close(descriptor); throw BackendSessionFailure.invalidInput("The native MCP namespace owner could not be recorded.") }
        ownerDescriptor = descriptor
        // Source cleanup, narrowed to native namespaces with our own owner
        // marker. Node configs and any active native process are preserved.
        let directories = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        for directory in directories.prefix(10_000) where directory != namespace && directory.lastPathComponent.hasPrefix("native-") {
            guard UUID(uuidString: String(directory.lastPathComponent.dropFirst(7))) != nil,
                  let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let file = directory.appendingPathComponent("owner.lock")
            guard let fileValues = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                  let size = fileValues.fileSize, size <= 128, fileValues.isRegularFile == true, fileValues.isSymbolicLink != true,
                  let bytes = try? Data(contentsOf: file), let text = String(data: bytes, encoding: .utf8),
                  let owner = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), owner > 0 else { continue }
            if Darwin.kill(owner, 0) == 0 || errno == EPERM { continue }
            let old = open(file.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard old >= 0 else { continue }
            if flock(old, LOCK_EX | LOCK_NB) == 0 { try? FileManager.default.removeItem(at: directory); flock(old, LOCK_UN) }
            Darwin.close(old)
        }
    }
}

enum BackendPrivateLaunchFiles {
    static func createDirectory(_ directory: URL, under rawRoot: URL) throws {
        let root = rawRoot.standardizedFileURL
        let target = directory.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { throw BackendSessionFailure.invalidInput("A private launch file escaped the app's own launch directory.") }
        var cursor = target
        while cursor.path.hasPrefix(root.path) {
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw BackendSessionFailure.invalidInput("Private MCP launch directories cannot be symbolic links.")
            }
            if cursor == root { break }; cursor.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
    }
    static func write(_ bytes: Data, to file: URL) throws {
        let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BackendSessionFailure.operatingSystem(operation: "create a private MCP launch file", code: errno) }
        defer { Darwin.close(fd) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BackendSessionFailure.operatingSystem(operation: "write a private MCP launch file", code: errno) }
            offset += count
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw BackendSessionFailure.operatingSystem(operation: "save a private MCP launch file", code: errno) }
    }
}
