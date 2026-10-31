import Foundation
import TerminalDeckNativeCore

/// A small counts-only ledger on the existing task persistence owner. No
/// transcript content, paths, keys or credentials are written here. When it is
/// full, the least recently updated conversation makes room for a new one.
actor BackendAGOPTTokenLedger {
    private struct Record: Codable {
        var version = 1; var conversations: [String: [String: Double]] = [:]
        /// Update order per conversation (higher is newer); older files have none.
        var updated: [String: Double]? = nil
    }
    private let persistence: BackendTaskPersistence?
    private var record = Record(), loaded = false
    private static let file = "agopt-token-usage.json", maximumBytes = 4 * 1024 * 1024
    private let maximumConversations: Int
    init(persistence: BackendTaskPersistence?, maximumConversations: Int = 512) {
        self.persistence = persistence; self.maximumConversations = maximumConversations
    }
    func observe(key: String, amounts: [String: Double], claudeMessageIDs: Set<String> = []) throws -> Double {
        if !loaded {
            if let value = try persistence?.read(Self.file, maximumBytes: Self.maximumBytes) {
                let saved = try JSONDecoder().decode(Record.self, from: value.encodedJSON())
                guard saved.version == 1, saved.conversations.count <= max(512, maximumConversations),
                      saved.conversations.values.allSatisfy({ values in values.count <= 50_000 && values.values.allSatisfy({ $0.isFinite && $0 >= 0 }) }) else {
                    throw NativeRPCError(code: "usage-unavailable", message: "Saved token counts could not be verified.")
                }
                record = saved
            }
            loaded = true
        }
        var next = record
        var values = next.conversations[key] ?? [:]
        for legacy in values.keys where !legacy.hasPrefix("message:") {
            guard claudeMessageIDs.filter({ legacy.hasSuffix(":" + $0) }).count <= 1 else {
                throw NativeRPCError(code: "usage-unavailable", message: "Legacy token message identities could not be verified.")
            }
        }
        // Normalize only known exact message identities. Former requestId:id
        // keys for one streaming message are aliases, never extra requests.
        for id in claudeMessageIDs.sorted(by: { $0.count > $1.count }) {
            let stable = "message:" + id
            let aliases = values.keys.filter { $0 == stable || !$0.hasPrefix("message:") && $0.hasSuffix(":" + id) }
            if let maximum = aliases.compactMap({ values[$0] }).max() {
                for alias in aliases { values[alias] = nil }; values[stable] = maximum
            }
        }
        for (id, amount) in amounts { values[id] = max(values[id] ?? 0, amount) }
        guard values.count <= 50_000 else {
            throw NativeRPCError(code: "usage-unavailable", message: "This conversation has too many counted messages. Usage is unavailable rather than guessed.")
        }
        if next.conversations[key] != values {
            var order = next.updated ?? [:]
            order[key] = (order.values.max() ?? 0) + 1
            next.updated = order
        }
        next.conversations[key] = values
        while next.conversations.count > maximumConversations, Self.evictOldest(&next, keeping: key) {}
        if next.conversations != record.conversations {
            var bytes = try JSONEncoder().encode(next)
            while bytes.count > Self.maximumBytes, Self.evictOldest(&next, keeping: key) { bytes = try JSONEncoder().encode(next) }
            guard bytes.count <= Self.maximumBytes else { throw NativeRPCError(code: "usage-unavailable", message: "The saved token count ledger is full.") }
            if let persistence { try persistence.write(Self.file, value: NativeRPCValue.parseJSON(bytes, maximumBytes: Self.maximumBytes)) }
            record = next
        }
        return values.values.reduce(0, +)
    }
    /// Drops the least recently updated conversation other than `key`;
    /// conversations saved before update order existed go first.
    private static func evictOldest(_ record: inout Record, keeping key: String) -> Bool {
        let order = record.updated ?? [:]
        guard let oldest = record.conversations.keys.filter({ $0 != key })
            .min(by: { (order[$0] ?? 0, $0) < (order[$1] ?? 0, $1) }) else { return false }
        record.conversations[oldest] = nil; record.updated?[oldest] = nil
        return true
    }
}
