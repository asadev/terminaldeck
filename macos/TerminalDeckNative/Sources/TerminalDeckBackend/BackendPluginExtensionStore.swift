import Foundation
import TerminalDeckNativeCore

/// Authoritative receipts are outside both child-readable code and child data.
/// All mutations save before publishing; children have no filesystem handle.
public final class BackendPluginExtensionStore: @unchecked Sendable {
    public let persistence: BackendTaskPersistence
    private let lock = NSLock()
    private var cache: [String: NativeRPCValue] = [:]
    private var source: [String: Bool]?
    private var sourceSequence = 0
    public init(persistence: BackendTaskPersistence) { self.persistence = persistence }
    private func name(_ id: String) throws -> String {
        guard BackendPluginsManifestReader.matches(id, #"^[a-z0-9][a-z0-9-]{0,39}$"#) else { throw PluginContract.invalid("Invalid plugin namespace") }
        return "plugin-" + id + ".json"
    }
    private func empty() -> NativeRPCValue { .object([.init("version", .number(1)), .init("kv", .object([])), .init("jobs", .array([])), .init("events", .object([.init("paused", .bool(true)), .init("pending", .array([])), .init("acknowledged", .array([])), .init("overflow", .number(0))]))]) }
    private func load(_ id: String) throws -> NativeRPCValue {
        if let current = cache[id] { return current }
        var value = try persistence.read(name(id), maximumBytes: 1024 * 1024) ?? empty()
        guard value["version"].number == 1, value["kv"].fields != nil, (value["kv"].fields?.count ?? 0) <= 100,
              let jobs = value["jobs"].elements, jobs.count <= 100, value["events"].fields != nil,
              (value["events"]["pending"].elements?.count ?? 1000) <= 50 else { throw PluginContract.invalid("Plugin private records are unreadable; nothing was resumed") }
        for field in value["kv"].fields ?? [] {
            _ = try PluginContract.key(.string(field.key), label: "saved state key")
            _ = try integer(field.value["version"])
            guard field.value["present"].bool != nil, field.value.has("value") else { throw PluginContract.invalid("Invalid saved KV row") }
            try PluginContract.json(field.value["value"])
        }
        guard try value["kv"].encodedJSON().count <= 256 * 1024, value["events"]["paused"].bool != nil else { throw PluginContract.invalid("Saved plugin state exceeds its bounds") }
        _ = try integer(value["events"]["overflow"])
        guard let acknowledged = value["events"]["acknowledged"].elements, acknowledged.count <= 100, acknowledged.allSatisfy({ $0.string != nil }) else { throw PluginContract.invalid("Invalid event receipts") }
        for event in value["events"]["pending"].elements ?? [] {
            _ = try PluginContract.text(event["id"], limit: 100); _ = try PluginContract.text(event["project"], limit: 4096)
            guard try integer(event["attempts"]) <= 3 else { throw PluginContract.invalid("Invalid saved event attempts") }
            try PluginContract.json(event, bytes: 8192)
        }
        for job in jobs {
            _ = try PluginContract.text(job["id"], limit: 64); _ = try PluginContract.text(job["attempt"], limit: 64)
            guard ["queued", "running", "pause-requested", "paused", "completed", "failed", "interrupted"].contains(job["state"].string ?? ""), (job["progress"].elements?.count ?? 1000) <= 50, (job["attempts"].elements?.count ?? 1000) <= 16 else { throw PluginContract.invalid("Invalid saved job state") }
            try PluginContract.json(job["input"]); try PluginContract.json(job["checkpoint"])
        }
        value = value.setting("jobs", .array(jobs.map { row in
            ["queued", "running", "pause-requested"].contains(row["state"].string ?? "") ? row.setting("state", .string("interrupted")).setting("reason", .string("App reopened; resume explicitly after reviewing the checkpoint.")) : row
        })).setting("events", value["events"].setting("paused", .bool(true)))
        cache[id] = value; return value
    }
    public func read(_ id: String) throws -> NativeRPCValue { try lock.withLock { try load(id) } }
    @discardableResult public func change(_ id: String, _ body: (NativeRPCValue) throws -> NativeRPCValue) throws -> NativeRPCValue {
        try lock.withLock {
            let previous = try load(id), next = try body(previous)
            try PluginContract.json(next, bytes: 1024 * 1024, depth: 20)
            try persistence.write(name(id), value: next); cache[id] = next; return next
        }
    }
    public func forget(_ id: String) throws { try lock.withLock { try persistence.remove(name(id)); cache[id] = nil } }
    public func kv(_ id: String, method: String, input: NativeRPCValue) throws -> NativeRPCValue {
        let allowed: Set<String> = method == "state/list" ? [] : method == "state/get" ? ["key"] : method == "state/delete" ? ["key", "expected"] : ["key", "value", "expected"]
        try PluginContract.closed(input, allowed, method)
        if method == "state/list" { return try read(id)["kv"] }
        let key = try PluginContract.key(input["key"], label: "state key")
        if method == "state/get" { let row = try read(id)["kv"][key]; return row.isNullish ? .object([.init("present", .bool(false)), .init("version", .number(0))]) : row }
        let expected = try integer(input["expected"])
        if method == "state/put" { guard input.has("value") else { throw PluginContract.invalid("A JSON value is required") }; try PluginContract.json(input["value"]) }
        let next = try change(id) { state in
            let kv = state["kv"], old = kv[key]
            let priorVersion: Int
            if old.isNullish { priorVersion = 0 } else { priorVersion = try integer(old["version"]) }
            guard priorVersion == expected, expected < 1_000_000_000 else { throw PluginContract.invalid("State changed; read its version before writing") }
            guard kv.has(key) || (kv.fields?.count ?? 0) < 100 else { throw PluginContract.invalid("At most 100 state keys per plugin") }
            let row = NativeRPCValue.object([.init("version", .number(Double(expected + 1))), .init("present", .bool(method == "state/put")), .init("value", method == "state/put" ? input["value"] : .null)])
            let changed = kv.setting(key, row)
            guard try changed.encodedJSON().count <= 256 * 1024 else { throw PluginContract.invalid("Plugin state exceeds 256 KB; nothing was written") }
            return state.setting("kv", changed)
        }
        return next["kv"][key]
    }
    public func integer(_ value: NativeRPCValue) throws -> Int {
        guard let n = value.number, n >= 0, n <= 1_000_000_000, n.rounded(.down) == n else { throw PluginContract.invalid("Expected a nonnegative whole version") }; return Int(n)
    }
    public func interrupt(_ id: String, reason: String, projects: [String]? = nil) throws {
        _ = try change(id) { state in
            let jobs = (state["jobs"].elements ?? []).map { row -> NativeRPCValue in
                let removed = projects.map { !$0.contains(row["project"].string ?? "") } ?? false
                var next = row
                if ["queued", "running", "pause-requested", "paused", "interrupted"].contains(row["state"].string ?? "") { next = next.setting("state", .string(removed ? "failed" : "interrupted")).setting("reason", .string(reason)) }
                if removed { next = next.setting("input", .null).setting("checkpoint", .null).setting("progress", .array([])) }
                return next
            }
            let pending = (state["events"]["pending"].elements ?? []).filter { event in projects.map { $0.contains(event["project"].string ?? "") } ?? true }
            return state.setting("jobs", .array(jobs)).setting("events", state["events"].setting("paused", .bool(true)).setting("pending", .array(pending)))
        }
    }
    /// One seeded edge source, independent of routines. Persist a sequence before
    /// fanout so legacy completions without a timestamp also have stable IDs.
    public func finished(_ rows: [BackendTaskRecord]) throws -> [NativeRPCValue] {
        try lock.withLock {
            guard rows.count <= 10000 else { throw PluginContract.invalid("Task pulse source exceeds its bound") }
            if source == nil {
                let saved = try persistence.read("tasks-source.json", maximumBytes: 1024 * 1024)
                if let saved { guard saved["version"].number == 1 else { throw PluginContract.invalid("Unsupported task pulse source record") }; sourceSequence = try integer(saved["sequence"]) }
                source = Dictionary(rows.map { ($0.id, !$0.value["completedAt"].isNullish || $0.value["crmStatus"].string == "Done") }, uniquingKeysWith: { _, b in b })
                return [] // baseline only, never backfill work after reopening
            }
            guard rows.count <= 10000 else { throw PluginContract.invalid("Task pulse source exceeds its bound") }
            var events: [NativeRPCValue] = [], next = source ?? [:], sequence = sourceSequence
            for row in rows {
                let done = !row.value["completedAt"].isNullish || row.value["crmStatus"].string == "Done"
                next[row.id] = done
                if done, source?[row.id] != true, row.project.hasPrefix("/"), !row.project.contains("\0") {
                    guard sequence < 1_000_000_000 else { throw PluginContract.invalid("Task pulse source revision limit reached") }
                    sequence += 1
                    let identity = row.value["completedAt"].number.map { row.id + ":finished:" + String($0) } ?? (row.id + ":legacy-edge:" + String(sequence))
                    let id = BackendPluginsFiles.digest(Data(identity.utf8))
                    events.append(.object([.init("id", .string(id)), .init("type", .string("tasks.finished")), .init("taskID", .string(row.id)), .init("projectID", .string(PROJProjects.resolve(projectID: row.value["projectId"].string, folder: row.project))), .init("project", .string(BackendPluginsFiles.real(row.project))), .init("finishedAt", row.value["completedAt"].number.map(NativeRPCValue.number) ?? .null), .init("revision", .number(Double(sequence))), .init("verified", row.value["result"]["verified"].bool.map(NativeRPCValue.bool) ?? .null)]))
                }
            }
            guard next.count <= 10000 else { throw PluginContract.invalid("Task pulse source identity history is full") }
            if sequence != sourceSequence { try persistence.write("tasks-source.json", value: .object([.init("version", .number(1)), .init("sequence", .number(Double(sequence)))])) }
            source = next; sourceSequence = sequence; return events
        }
    }
}
