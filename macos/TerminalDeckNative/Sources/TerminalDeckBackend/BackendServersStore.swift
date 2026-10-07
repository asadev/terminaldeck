import Foundation
import TerminalDeckNativeCore

public struct BackendServersStoragePolicy: Sendable {
    public let mayRead: Bool
    public let mayWrite: Bool
    public init(mayRead: Bool, mayWrite: Bool) { self.mayRead = mayRead; self.mayWrite = mayWrite }
    func requireRead() throws { guard mayRead else { throw NativeRPCError(code: "unavailable", message: "The native server store has not been given permission to read this data root.") } }
    func requireWrite() throws { guard mayWrite else { throw NativeRPCError(code: "unavailable", message: "The native server store has not taken exclusive ownership from the existing backend.") } }
}

public enum BackendServersCredentialKind: String, Codable, Sendable { case password, key, none }
public struct BackendServersHostKeyRecord: Codable, Equatable, Sendable {
    public var algorithm: String
    public var fingerprint: String
    public var firstSeenAt: Double
    public init(algorithm: String, fingerprint: String, firstSeenAt: Double) { self.algorithm = algorithm; self.fingerprint = fingerprint; self.firstSeenAt = firstSeenAt }
}
public struct BackendServersStoredServer: Codable, Equatable, Sendable {
    public var id: String, name: String, address: String, username: String
    public var port: Int
    public var credential: BackendServersCredentialKind
    public var hostKey: BackendServersHostKeyRecord?
    public var addedAt: Double, lastConnectedAt: Double?
    public var startIn: String?
    public var drivesWindows: Bool
    public init(id: String, name: String, address: String, port: Int = 22, username: String,
                credential: BackendServersCredentialKind = .none, hostKey: BackendServersHostKeyRecord? = nil,
                addedAt: Double = 0, lastConnectedAt: Double? = nil, startIn: String? = nil, drivesWindows: Bool = true) {
        self.id = id; self.name = name; self.address = address; self.port = port; self.username = username
        self.credential = credential; self.hostKey = hostKey; self.addedAt = addedAt; self.lastConnectedAt = lastConnectedAt
        self.startIn = startIn; self.drivesWindows = drivesWindows
    }
    public var wireValue: NativeRPCValue {
        .object([.init("id", .string(id)), .init("name", .string(name)), .init("address", .string(address)),
            .init("port", .number(Double(port))), .init("username", .string(username)), .init("credential", .string(credential.rawValue)),
            .init("hostKey", hostKey.map { .object([.init("algorithm", .string($0.algorithm)), .init("fingerprint", .string($0.fingerprint)), .init("firstSeenAt", .number($0.firstSeenAt))]) } ?? .null),
            .init("addedAt", .number(addedAt)), .init("lastConnectedAt", lastConnectedAt.map(NativeRPCValue.number) ?? .null),
            .init("startIn", startIn.map(NativeRPCValue.string) ?? .null), .init("drivesWindows", .bool(drivesWindows))])
    }
}
public struct BackendServersNewServer: Sendable {
    public var name: String, address: String, username: String
    public var port: Int?
    public init(name: String, address: String, port: Int? = nil, username: String) { self.name = name; self.address = address; self.port = port; self.username = username }
}

/// Source servers/store.ts. Construction is inert. The explicitly supplied root
/// is the servers directory, not the profile parent, and all writes are atomic.
public final class BackendServersStore: @unchecked Sendable {
    public static let fileName = "servers.json", maximumServers = 64, defaultPort = 22
    public let file: URL
    private let dataRoot: URL, policy: BackendServersStoragePolicy
    private let now: @Sendable () -> Double, makeID: @Sendable () -> String
    private let lock = NSRecursiveLock()
    private var cache: [BackendServersStoredServer]?
    private var denies: [String]?
    public init(dataRoot: URL, policy: BackendServersStoragePolicy,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.dataRoot = dataRoot; self.policy = policy; self.now = now; self.makeID = makeID
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
                startIn: folder.isEmpty ? nil : folder, drivesWindows: row["drivesWindows"].bool != false))
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
        var list = Self.readServers(read(file, maximum: 256 * 1024))
        for index in list.indices {
            if !list[index].drivesWindows && !ids.contains(list[index].id) {
                // Backfill is best effort, exactly like applyWindowDenies. The
                // record's refusal holds even if the durable copy cannot write.
                if ids.count < 64 { ids.append(list[index].id) }
            }
            if ids.contains(list[index].id) { list[index].drivesWindows = false }
        }
        if ids != denies { try? writeDenies(ids) }
        cache = list; return list
    }
    private func persist(_ list: [BackendServersStoredServer]) throws {
        try policy.requireWrite()
        let value: NativeRPCValue = .object([.init("version", .number(1)), .init("servers", .array(list.map(\.wireValue)))])
        try BackendRemoteServeSecretFile.write(directory: dataRoot, file: file, contents: value.encodedJSON())
        cache = list
    }
    private func writeDenies(_ ids: [String]) throws {
        try policy.requireWrite()
        try BackendRemoteServeSecretFile.write(directory: dataRoot, file: dataRoot.appendingPathComponent("window-denies.json"),
            contents: NativeRPCValue.object([.init("version", .number(1)), .init("denied", .array(ids.map(NativeRPCValue.string)))]).encodedJSON())
        denies = ids
    }
    public func list() throws -> [BackendServersStoredServer] { try lock.withLock { try load() } }
    public func get(_ id: String) throws -> BackendServersStoredServer? { try lock.withLock { try load().first { $0.id == id } } }
    public func add(_ candidate: BackendServersNewServer) throws -> BackendServersStoredServer {
        try lock.withLock {
            let address = Self.normaliseAddress(Self.clean(candidate.address, limit: 255))
            if let issue = Self.addressProblem(address) { throw NativeRPCError.invalidArguments(issue) }
            let username = Self.clean(candidate.username, limit: 64)
            guard !username.isEmpty else { throw NativeRPCError.invalidArguments("A username is needed — the name you sign in to this server with.") }
            var list = try load()
            guard list.count < Self.maximumServers else { throw NativeRPCError.invalidArguments("This app keeps up to 64 servers. Remove one to add another.") }
            let name = Self.clean(candidate.name, limit: 64), port = candidate.port ?? 22
            let record = BackendServersStoredServer(id: makeID(), name: name.isEmpty ? address : name, address: address,
                port: (1...65535).contains(port) ? port : 22, username: username, addedAt: now())
            list.append(record); try persist(list); return record
        }
    }
    private func update(_ id: String, _ change: (inout BackendServersStoredServer) -> Void) throws -> Bool {
        var list = try load(); guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
        change(&list[index]); try persist(list); return true
    }
    public func rename(_ id: String, name: String) throws -> Bool { try lock.withLock { let name = Self.clean(name, limit: 64); return name.isEmpty ? false : try update(id) { $0.name = name } } }
    public func setStartIn(_ id: String, path: String?) throws -> Bool { try lock.withLock { let value = Self.clean(path, limit: 4096); return try update(id) { $0.startIn = value.isEmpty ? nil : value } } }
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
