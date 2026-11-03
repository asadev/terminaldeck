import Foundation
import TerminalDeckNativeCore

/// SRV2: app variables on top of the ONE existing protected settings file
/// (`.env`, written by BackendAppsStore). Values that don't fit on one line are
/// kept on one line as `td-json:<JSON-escaped text>`; the deploy recipe passes
/// that text straight into the Engine API. Flags live in a protected sidecar.
/// Callers hold the app lock for every change.
public struct BackendAppsSRV2Variables: Sendable {
    public struct Flags: Codable, Sendable, Equatable {
        public var build: Bool
        public var run: Bool
        public var locked: Bool
        public init(build: Bool = false, run: Bool = true, locked: Bool = true) { self.build = build; self.run = run; self.locked = locked }
    }
    struct Sidecar: Codable { var version = 1; var keys: [String: Flags] = [:] }

    /// One requested change. A nil value keeps the saved value (flags-only change).
    public struct Change: Sendable, Equatable {
        public var key: String
        public var value: String?
        public var build: Bool?
        public var run: Bool?
        public var locked: Bool?
        public init(key: String, value: String? = nil, build: Bool? = nil, run: Bool? = nil, locked: Bool? = nil) {
            self.key = key; self.value = value; self.build = build; self.run = run; self.locked = locked
        }
    }

    public let store: BackendAppsStore
    public init(store: BackendAppsStore) { self.store = store }

    public static let prefix = "td-json:"
    public static func encode(_ value: String) -> String {
        let plain = !value.hasPrefix(prefix) && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        if plain { return value }
        var body = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": body += "\\\""
            case "\\": body += "\\\\"
            case "\n": body += "\\n"
            case "\r": body += "\\r"
            case "\t": body += "\\t"
            default:
                if scalar.value < 32 || scalar.value == 127 { body += String(format: "\\u%04x", scalar.value) }
                else { body.unicodeScalars.append(scalar) }
            }
        }
        return prefix + body
    }
    public static func decode(_ stored: String) -> String {
        guard stored.hasPrefix(prefix) else { return stored }
        let body = String(stored.dropFirst(prefix.count))
        guard let value = try? JSONDecoder().decode(String.self, from: Data(("\"" + body + "\"").utf8)) else { return stored }
        return value
    }

    func directory(_ appID: String) throws -> String { try store.directory(appID) }

    func sidecar(_ serverID: String, _ appID: String) async throws -> Sidecar {
        guard let data = try await store.readFile(serverID, path: directory(appID) + "/variables.json") else { return Sidecar() }
        guard let value = try? JSONDecoder().decode(Sidecar.self, from: data), value.version == 1 else {
            throw NativeRPCError(code: "state-failed", message: "The app's variable settings are damaged.")
        }
        return value
    }

    /// Decoded values with flags (server-side use only; never returned as is).
    public func all(_ serverID: String, _ appID: String) async throws -> [(key: String, value: String, flags: Flags)] {
        let stored = try await store.environment(serverID, appID)
        let flags = try await sidecar(serverID, appID).keys
        return stored.keys.sorted().map { ($0, Self.decode(stored[$0]!), flags[$0] ?? Flags()) }
    }

    public func read(_ serverID: String, _ appID: String) async throws -> [NativeAppsVariable] {
        try await all(serverID, appID).map { row in
            NativeAppsVariable(key: row.key, value: row.flags.locked ? NativeAppsVariable.mask : row.value, build: row.flags.build,
                               run: row.flags.run, locked: row.flags.locked, multiline: row.value.contains("\n"))
        }
    }

    public func keys(_ serverID: String, _ appID: String) async throws -> (build: [String], run: [String]) {
        let rows = try await all(serverID, appID)
        return (rows.filter { $0.flags.build && !$0.value.contains("\n") && !NativeAppsVariable.reservedForBuild($0.key) }.map(\.key),
                rows.filter { $0.flags.run }.map(\.key))
    }

    /// Values to hide from logs and command output: only the secret ones (#571).
    public func secrets(_ serverID: String, _ appID: String) async throws -> [String] {
        let rows = try await all(serverID, appID)
        return BackendAppsValidation.secretValues(rows.map { ($0.key, $0.value) }, locked: Set(rows.filter { $0.flags.locked }.map { $0.key }))
    }

    public static func validate(_ changes: [Change], remove: [String]) throws {
        guard changes.count + remove.count <= 256 else { throw NativeRPCError.invalidArguments("Change up to 256 variables at a time.") }
        var seen = Set<String>()
        for change in changes {
            guard NativeAppsVariable.validKey(change.key) else { throw NativeRPCError.invalidArguments("Variable names use letters, numbers and underscores, and don't start with a number.") }
            guard seen.insert(change.key).inserted, !remove.contains(change.key) else { throw NativeRPCError.invalidArguments("Each variable can be changed once per save.") }
            if let value = change.value {
                guard ![NativeAppsVariable.mask, "••••••", "[redacted]"].contains(value) else { throw NativeRPCError.invalidArguments("Masked values can't be saved as real values. Leave them unchanged.") }
                guard !value.contains("\0"), encode(value).utf8.count <= 65_536 else { throw NativeRPCError.invalidArguments("Keep each value under 48 KB, without NUL characters.") }
            }
            if change.build == true, NativeAppsVariable.reservedForBuild(change.key) {
                throw NativeRPCError.invalidArguments("\(change.key) steers the server's build tools, so it can't be used during the build.")
            }
        }
        for key in remove { guard NativeAppsVariable.validKey(key) else { throw NativeRPCError.invalidArguments("A variable name to remove is invalid.") } }
    }

    /// Applies changes; untouched values stay exactly as saved. The caller holds the lock.
    public func patch(_ serverID: String, _ appID: String, changes: [Change], remove: [String]) async throws -> [NativeAppsVariable] {
        try Self.validate(changes, remove: remove)
        var stored = try await store.environment(serverID, appID)
        var side = try await sidecar(serverID, appID)
        for key in remove { stored[key] = nil; side.keys[key] = nil }
        for change in changes {
            guard change.value != nil || stored[change.key] != nil else {
                throw NativeRPCError.invalidArguments("\(change.key) has no saved value yet. Enter a value to add it.")
            }
            var flags = side.keys[change.key] ?? Flags()
            if let build = change.build { flags.build = build }
            if let run = change.run { flags.run = run }
            if let locked = change.locked { flags.locked = locked }
            let value = change.value.map(Self.encode) ?? stored[change.key]!
            if flags.build, Self.decode(value).contains("\n") { throw NativeRPCError.invalidArguments("Values used during the build must fit on one line.") }
            guard flags.build || flags.run else { throw NativeRPCError.invalidArguments("\(change.key) must be available during the build, while running, or both.") }
            stored[change.key] = value
            side.keys[change.key] = flags
        }
        side.keys = side.keys.filter { stored[$0.key] != nil }
        try await store.applyEnvironment(serverID, appID, stored)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try await store.writeFile(serverID, path: directory(appID) + "/variables.json", contents: encoder.encode(side))
        return try await read(serverID, appID)
    }

    public static func changes(_ value: NativeRPCValue) throws -> [Change] {
        if value.isNullish { return [] }
        guard let rows = value.elements else { throw NativeRPCError.invalidArguments("set must be a list of variables.") }
        return try rows.map { row in
            guard let fields = row.fields, fields.allSatisfy({ ["key", "value", "build", "run", "locked"].contains($0.key) }),
                  let key = row["key"].string else { throw NativeRPCError.invalidArguments("Each variable change needs a key.") }
            func flag(_ name: String) throws -> Bool? {
                if row[name].isNullish { return nil }
                guard let value = row[name].bool else { throw NativeRPCError.invalidArguments("\(name) must be true or false.") }
                return value
            }
            guard row["value"].isNullish || row["value"].string != nil else { throw NativeRPCError.invalidArguments("Variable values must be text.") }
            return Change(key: key, value: row["value"].string, build: try flag("build"), run: try flag("run"), locked: try flag("locked"))
        }
    }
}
