import Foundation
import TerminalDeckNativeCore

public struct BackendServersStoragePolicy: Sendable {
    public let mayRead: Bool
    public let mayWrite: Bool
    public init(mayRead: Bool, mayWrite: Bool) { self.mayRead = mayRead; self.mayWrite = mayWrite }
    func requireRead() throws { guard mayRead else { throw NativeRPCError(code: "unavailable", message: "The native server store has not been given permission to read this data root.") } }
    func requireWrite() throws { guard mayWrite else { throw NativeRPCError(code: "unavailable", message: "The native server store has not taken exclusive ownership from the existing backend.") } }
}

public enum BackendServersCredentialKind: String, Codable, Sendable { case password, key, none, sshConfig = "ssh-config" }
public struct BackendServersHostKeyRecord: Codable, Equatable, Sendable {
    public var algorithm: String
    public var fingerprint: String
    public var firstSeenAt: Double
    public init(algorithm: String, fingerprint: String, firstSeenAt: Double) { self.algorithm = algorithm; self.fingerprint = fingerprint; self.firstSeenAt = firstSeenAt }
}
public struct BackendServersStoredServer: Codable, Equatable, Sendable {
    public var id: String, name: String, address: String, username: String
    public var projectId: String?
    public var port: Int
    public var credential: BackendServersCredentialKind
    public var hostKey: BackendServersHostKeyRecord?
    public var addedAt: Double, lastConnectedAt: Double?
    public var startIn: String?
    public var drivesWindows: Bool
    public var aiKeyIDs: [String]?
    /// Added from the person's own SSH settings: ssh reads their config and
    /// key files at connect time. The app keeps only this name, never a key.
    public var sshAlias: String?
    /// Look only: nothing on this server may be changed through this app.
    public var lookOnly: Bool?
    /// Show only these apps (container names). nil = show every app.
    public var shownApps: [String]?
    public init(id: String, name: String, address: String, port: Int = 22, username: String,
                credential: BackendServersCredentialKind = .none, hostKey: BackendServersHostKeyRecord? = nil,
                addedAt: Double = 0, lastConnectedAt: Double? = nil, startIn: String? = nil, drivesWindows: Bool = true, aiKeyIDs: [String]? = nil,
                sshAlias: String? = nil, lookOnly: Bool? = nil, projectId: String? = nil) {
        self.id = id; self.name = name; self.address = address; self.port = port; self.username = username
        self.credential = credential; self.hostKey = hostKey; self.addedAt = addedAt; self.lastConnectedAt = lastConnectedAt
        self.startIn = startIn; self.drivesWindows = drivesWindows
        self.aiKeyIDs = aiKeyIDs
        self.sshAlias = sshAlias; self.lookOnly = lookOnly
        let explicit = projectId?.trimmingCharacters(in: .whitespacesAndNewlines)
        // No server name means a project by itself (11 Oct: two server names of the builder's own Mac did).
        self.projectId = explicit?.isEmpty == false ? explicit : nil
    }
    public var projectIdInferred: Bool { projectId == nil }
    public var resolvedProjectId: String { PROJProjects.resolve(projectID: projectId, folder: startIn) }
    public var isLookOnly: Bool { lookOnly == true }
    public var wireValue: NativeRPCValue {
        var value = NativeRPCValue.object([.init("projectId", .string(resolvedProjectId)), .init("id", .string(id)), .init("name", .string(name)), .init("address", .string(address)),
            .init("port", .number(Double(port))), .init("username", .string(username)), .init("credential", .string(credential.rawValue)),
            .init("hostKey", hostKey.map { .object([.init("algorithm", .string($0.algorithm)), .init("fingerprint", .string($0.fingerprint)), .init("firstSeenAt", .number($0.firstSeenAt))]) } ?? .null),
            .init("addedAt", .number(addedAt)), .init("lastConnectedAt", lastConnectedAt.map(NativeRPCValue.number) ?? .null),
            .init("startIn", startIn.map(NativeRPCValue.string) ?? .null), .init("drivesWindows", .bool(drivesWindows))])
        if projectIdInferred { value = value.setting("projectIdInferred", .bool(true)) }
        return value
    }
}
public struct BackendServersNewServer: Sendable {
    public var name: String, address: String, username: String
    public var port: Int?
    public var projectId: String?
    public init(name: String, address: String, port: Int? = nil, username: String, projectId: String? = nil) { self.name = name; self.address = address; self.port = port; self.username = username; self.projectId = projectId }
}

/// Source servers/store.ts. Construction is inert. The explicitly supplied root
/// is the servers directory, not the profile parent, and all writes are atomic.
public final class BackendServersStore: @unchecked Sendable {
    public static let fileName = "servers.json", maximumServers = 64, defaultPort = 22
    public let file: URL
    private let dataRoot: URL, policy: BackendServersStoragePolicy
    private let serverAccessEnabled: Bool
    private let now: @Sendable () -> Double, makeID: @Sendable () -> String
    private let lock = NSRecursiveLock()
    private var cache: [BackendServersStoredServer]?
    private var denies: [String]?
    /// U1: what the last read of servers.json could not understand; `blocked` when not even a copy could be kept.
    private var problem: String?, blocked = false
    /// Why some saved servers may be missing, until the next successful write.
    public func loadProblem() -> String? { lock.withLock { _ = try? load(); return problem } }
    public convenience init(dataRoot: URL, policy: BackendServersStoragePolicy,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.init(dataRoot: dataRoot, policy: policy, now: now, makeID: makeID,
                  serverAccessEnabled: BackendDockerMCPServerKeyScope.enabled)
    }
    public init(dataRoot: URL, policy: BackendServersStoragePolicy,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
                serverAccessEnabled: Bool) {
        self.dataRoot = dataRoot; self.policy = policy; self.now = now; self.makeID = makeID
        self.serverAccessEnabled = serverAccessEnabled
        file = dataRoot.appendingPathComponent(Self.fileName)
    }
    static func clean(_ text: String?, limit: Int) -> String {
        guard let text else { return "" }
        let flat = String(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(decoding: flat.utf16.prefix(limit), as: UTF16.self)
    }
    public static func addressProblem(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "An address is needed — the name or number this server answers on." }
        if value.utf16.count > 255 { return "That address is too long to be a real one." }
        if value.contains(where: \.isWhitespace) { return "An address cannot contain a space." }
        if value.contains("@") { return "Put only the address here — the part after the @ — and the username in its own box." }
        if value.contains("/") { return "Put only the address here, with no web address around it." }
        return nil
    }
    public static func normaliseAddress(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("[") && value.hasSuffix("]") ? String(value.dropFirst().dropLast()) : value
    }
    public static func readServers(_ raw: NativeRPCValue) -> [BackendServersStoredServer] {
        var output: [BackendServersStoredServer] = []
        for row in raw["servers"].elements ?? [] {
            guard row.fields != nil else { continue }
            let id = clean(row["id"].string, limit: 64), address = normaliseAddress(clean(row["address"].string, limit: 255))
            guard !id.isEmpty, addressProblem(address) == nil else { continue }
            let rawPort = row["port"].number ?? 22
            let port = rawPort.isFinite && rawPort.rounded() == rawPort && (1...65535).contains(rawPort) ? Int(rawPort) : 22
            let mark = clean(row["hostKey"]["fingerprint"].string, limit: 128)
            let hostKey: BackendServersHostKeyRecord? = mark.hasPrefix("SHA256:") ? .init(algorithm: clean(row["hostKey"]["algorithm"].string, limit: 64), fingerprint: mark, firstSeenAt: row["hostKey"]["firstSeenAt"].number ?? 0) : nil
            let name = clean(row["name"].string, limit: 64), folder = clean(row["startIn"].string, limit: 4096)
            output.append(.init(id: id, name: name.isEmpty ? address : name, address: address, port: port,
                username: clean(row["username"].string, limit: 64), credential: BackendServersCredentialKind(rawValue: row["credential"].string ?? "") ?? .none,
                hostKey: hostKey, addedAt: row["addedAt"].number ?? 0, lastConnectedAt: row["lastConnectedAt"].number,
                startIn: folder.isEmpty ? nil : folder, drivesWindows: row["drivesWindows"].bool != false,
                aiKeyIDs: row["aiKeyIDs"] == .missing ? nil : readAIKeyIDs(row["aiKeyIDs"]),
                sshAlias: row["sshAlias"].string.flatMap { BackendDockerMCPServerSSHConfig.validAlias($0) ? $0 : nil },
                lookOnly: row["lookOnly"].bool == true ? true : nil,
                projectId: row["projectIdInferred"].bool == true ? nil : row["projectId"].string))
            if let names = row["shownApps"].elements {
                output[output.count - 1].shownApps = BackendServersShownApps.clean(names.compactMap(\.string))
            }
            if output.count >= maximumServers { break }
        }
        return output
    }
    private func read(_ url: URL, maximum: Int) -> NativeRPCValue {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let size = attrs[.size] as? NSNumber,
              size.intValue <= maximum, let bytes = try? Data(contentsOf: url), let raw = try? NativeRPCValue.parseJSON(bytes, maximumBytes: maximum) else { return .null }
        return raw
    }
    private func load() throws -> [BackendServersStoredServer] {
        try policy.requireRead()
        if let cache { return cache }
        let raw = read(dataRoot.appendingPathComponent("window-denies.json"), maximum: 65536)
        var ids: [String] = []
        for item in raw["denied"].elements ?? [] {
            guard let rawID = item.string else { continue }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.utf16.count <= 200, !ids.contains(id), ids.count < 64 else { continue }
            ids.append(id)
        }
        denies = ids
        let saved = read(file, maximum: 256 * 1024)
        var list = Self.readServers(saved)
        // U1: a file that does not read, or a row skipped from it, is kept as a .damaged copy before the next
        // write replaces it; without that copy nothing is written and the next read tries again.
        if FileManager.default.fileExists(atPath: file.path), (saved["servers"].elements?.count ?? -1) != list.count {
            let copy = DamagedFile.keepCopy(of: file)
            problem = DamagedFile.sentence("The saved server list", copy: copy); blocked = copy == nil
        } else { problem = nil; blocked = false }
        for index in list.indices {
            if !list[index].drivesWindows && !ids.contains(list[index].id) {
                // Backfill is best effort, exactly like applyWindowDenies. The
                // record's refusal holds even if the durable copy cannot write.
                if ids.count < 64 { ids.append(list[index].id) }
            }
            if ids.contains(list[index].id) { list[index].drivesWindows = false }
        }
        if ids != denies { try? writeDenies(ids) }
        if !blocked { cache = list }
        Self.mirrorShownApps(list); return list
    }
    private func persist(_ list: [BackendServersStoredServer]) throws {
        try policy.requireWrite()
        if blocked { throw NativeRPCError(code: "servers-unreadable", message: problem ?? DamagedFile.sentence("The saved server list", copy: nil)) }
        let value: NativeRPCValue = .object([.init("version", .number(1)), .init("servers", .array(list.map { row in
            var value = row.wireValue
            if serverAccessEnabled { value = value.setting("aiKeyIDs", .array((row.aiKeyIDs ?? []).map(NativeRPCValue.string))) }
            if let alias = row.sshAlias { value = value.setting("sshAlias", .string(alias)) }
            if row.isLookOnly { value = value.setting("lookOnly", .bool(true)) }
            if let names = row.shownApps { value = value.setting("shownApps", .array(names.map(NativeRPCValue.string))) }
            return value
        }))])
        try BackendRemoteServeSecretFile.write(directory: dataRoot, file: file, contents: value.encodedJSON())
        cache = list; problem = nil
        Self.mirrorShownApps(list)
    }
    private static func mirrorShownApps(_ list: [BackendServersStoredServer]) {
        BackendServersShownApps.shared.replaceAll(Dictionary(list.map { ($0.id, $0.shownApps) }, uniquingKeysWith: { first, _ in first }))
    }
    private func writeDenies(_ ids: [String]) throws {
        try policy.requireWrite()
        try BackendRemoteServeSecretFile.write(directory: dataRoot, file: dataRoot.appendingPathComponent("window-denies.json"),
            contents: NativeRPCValue.object([.init("version", .number(1)), .init("denied", .array(ids.map(NativeRPCValue.string)))]).encodedJSON())
        denies = ids
    }
    public func list(projectId: String? = nil) throws -> [BackendServersStoredServer] { try lock.withLock { try load().filter { projectId == nil || $0.resolvedProjectId == projectId } } }
    public func get(_ id: String) throws -> BackendServersStoredServer? { try lock.withLock { try load().first { $0.id == id } } }
    public func add(_ candidate: BackendServersNewServer, creatorKeyID: String? = nil,
                    sshAlias: String? = nil, lookOnly: Bool = false) throws -> BackendServersStoredServer {
        try lock.withLock {
            let address = Self.normaliseAddress(Self.clean(candidate.address, limit: 255))
            if let issue = Self.addressProblem(address) { throw NativeRPCError.invalidArguments(issue) }
            let username = Self.clean(candidate.username, limit: 64)
            guard !username.isEmpty else { throw NativeRPCError.invalidArguments("A username is needed — the name you sign in to this server with.") }
            var list = try load()
            guard list.count < Self.maximumServers else { throw NativeRPCError.invalidArguments("This app keeps up to 64 servers. Remove one to add another.") }
            let name = Self.clean(candidate.name, limit: 64), port = candidate.port ?? 22
            let record = BackendServersStoredServer(id: makeID(), name: name.isEmpty ? address : name, address: address,
                port: (1...65535).contains(port) ? port : 22, username: username, addedAt: now(), drivesWindows: !lookOnly,
                aiKeyIDs: try (serverAccessEnabled ? validatedAIKeyIDs(creatorKeyID.map { [$0] } ?? []) : nil),
                sshAlias: sshAlias, lookOnly: lookOnly ? true : nil, projectId: PROJProjects.resolve(projectID: candidate.projectId, folder: nil))
            if let sshAlias {
                guard BackendDockerMCPServerSSHConfig.validAlias(sshAlias) else { throw NativeRPCError.invalidArguments("Choose one SSH settings name without spaces or symbols.") }
                guard !list.contains(where: { $0.sshAlias == sshAlias }) else { throw NativeRPCError.invalidArguments("\(sshAlias) is already added.") }
            }
            list.append(record); try persist(list)
            // Look only starts with window driving off; turning it on is the owner's choice.
            if lookOnly, !(denies ?? []).contains(record.id), (denies ?? []).count < 64 { try writeDenies((denies ?? []) + [record.id]) }
            return record
        }
    }
    private func update(_ id: String, _ change: (inout BackendServersStoredServer) -> Void) throws -> Bool {
        var list = try load(); guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
        change(&list[index]); try persist(list); return true
    }
    private static func readAIKeyIDs(_ value: NativeRPCValue) -> [String] {
        var ids: [String] = []
        for item in value.elements ?? [] {
            guard let id = item.string, validAIKeyID(id), !ids.contains(id), ids.count < 128 else { continue }
            ids.append(id)
        }
        return ids
    }
    private static func validAIKeyID(_ id: String) -> Bool {
        !id.isEmpty && id.utf16.count <= 200 && !id.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    private func validatedAIKeyIDs(_ ids: [String]) throws -> [String] {
        guard ids.count <= 128, ids.allSatisfy(Self.validAIKeyID) else { throw NativeRPCError.invalidArguments("Choose valid AI app key IDs for this server.") }
        return Array(Set(ids)).sorted()
    }
    /// Call only from the owner UI or the shared core's approved scope handler.
    public func setAIKeyAccess(_ id: String, keyIDs: [String]) throws -> Bool {
        try lock.withLock { let ids = try validatedAIKeyIDs(keyIDs); return try update(id) { $0.aiKeyIDs = ids } }
    }
    public func grantAIKeyAccess(_ id: String, keyID: String) throws -> Bool {
        try lock.withLock {
            guard let row = try load().first(where: { $0.id == id }) else { return false }
            let ids = try validatedAIKeyIDs(Array(Set((row.aiKeyIDs ?? []) + [keyID])))
            return try update(id) { $0.aiKeyIDs = ids }
        }
    }
    /// Owner UI, or an approved change. Nothing else lowers this protection.
    public func setLookOnly(_ id: String, _ value: Bool) throws -> Bool {
        try lock.withLock {
            guard try update(id, { $0.lookOnly = value ? true : nil }) else { return false }
            // Choosing Look only also stops sessions there driving windows here.
            if value { _ = try setDrivesWindows(id, allowed: false) }
            return true
        }
    }
    public func rename(_ id: String, name: String) throws -> Bool { try lock.withLock { let name = Self.clean(name, limit: 64); return name.isEmpty ? false : try update(id) { $0.name = name } } }
    public func setStartIn(_ id: String, path: String?) throws -> Bool { try lock.withLock { let value = Self.clean(path, limit: 4096); return try update(id) { $0.startIn = value.isEmpty ? nil : value } } }
    /// Show only these apps; nil or every-known-name means show all.
    public func setShownApps(_ id: String, names: [String]?) throws -> Bool {
        try lock.withLock { try update(id) { $0.shownApps = names.map(BackendServersShownApps.clean) } }
    }
    public func drivesWindows(_ id: String) throws -> Bool { try get(id)?.drivesWindows == true }
    public func setDrivesWindows(_ id: String, allowed: Bool) throws -> Bool {
        try lock.withLock {
            guard try get(id) != nil else { return false }
            var ids = denies ?? []
            if allowed { ids.removeAll { $0 == id } } else if !ids.contains(id), ids.count < 64 { ids.append(id) }
            try writeDenies(ids)
            guard try update(id, { $0.drivesWindows = allowed }) else { return false }; return allowed
        }
    }
    public func setCredentialKind(_ id: String, credential: BackendServersCredentialKind) throws -> Bool { try lock.withLock { try update(id) { $0.credential = credential } } }
    public func rememberHostKey(_ id: String, algorithm: String, fingerprint: String) throws -> Bool {
        try lock.withLock {
            guard let record = try get(id), record.hostKey == nil else { return false }
            return try update(id) { $0.hostKey = .init(algorithm: Self.clean(algorithm, limit: 64), fingerprint: Self.clean(fingerprint, limit: 128), firstSeenAt: now()) }
        }
    }
    public func forgetHostKey(_ id: String) throws -> Bool { try lock.withLock { try update(id) { $0.hostKey = nil } } }
    public func markConnected(_ id: String) throws -> Bool { try lock.withLock { try update(id) { $0.lastConnectedAt = now() } } }
    public func forget(_ id: String) throws -> Bool {
        try lock.withLock {
            let list = try load(), next = list.filter { $0.id != id }; guard next.count != list.count else { return false }
            try persist(next); try writeDenies((denies ?? []).filter { $0 != id }); return true
        }
    }
}
