import Foundation
import TerminalDeckNativeCore

public struct BackendTAGProfileConsentBatch: Sendable, Equatable {
    public let keyID: String
    public let keyName: String
    public let kind = "task-agent-profiles"
    public var items: [String]
    public var waitsWhileOwnerActive = false
    public init(keyID: String, keyName: String, items: [String]) {
        self.keyID = keyID; self.keyName = keyName
        self.items = Self.names(items)
    }
    public var summary: String {
        items.isEmpty ? "\(keyName) wants to save agents" : "\(keyName) wants to save \(items.count) \(items.count == 1 ? "agent" : "agents")"
    }
    public var wireValue: NativeRPCValue {
        .object([.init("keyId", .string(keyID)), .init("keyName", .string(keyName)), .init("kind", .string(kind)),
            .init("items", .array(items.map(NativeRPCValue.string))), .init("itemCount", .number(Double(items.count))),
            .init("batchWindowSeconds", .number(5)), .init("allowKindMinutes", .number(10)),
            .init("allowKindLabel", .string("Allow all of this kind from \(keyName) for 10 minutes")),
            .init("waitsWhileOwnerActive", .bool(waitsWhileOwnerActive))])
    }
    public mutating func append(_ names: [String]) { items = Self.names(items + names) }
    private static func names(_ input: [String]) -> [String] {
        var out: [String] = []
        for raw in input.prefix(200) {
            let value = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            if !value.isEmpty && !out.contains(value) { out.append(value) }
        }
        return out
    }
}

/// A consent kind describes an already-authorized operation; it grants no tool,
/// project, key scope or profile setting. Every call keeps its own prechecks.
public enum BackendTAGProfileConsent {
    public typealias Inspector = @Sendable (String, NativeRPCValue, BackendDeckCoreSecurityCallContext) async throws -> [String]
    public static let shortBatchMilliseconds: Double = 5_000
    public static let kindMilliseconds: Double = 600_000
    public static func isProfileSave(tool: String, arguments: NativeRPCValue) -> Bool {
        (["tasks.agents", "tasks_agents"].contains(tool) && ["save", "save-many"].contains(arguments["do"].string ?? "")) || ["tasks.agents_import", "tasks_agents_import"].contains(tool)
            || BackendAGTDirectoryTools.changeTools.contains(tool) // AGT: icon, reports-to and profile edits group the same way
    }
    public static func batch(tool: String, arguments: NativeRPCValue, caller: BackendDeckCoreSecurityCaller, items: [String]? = nil) -> BackendTAGProfileConsentBatch? {
        guard caller.kind == .key, caller.tasks, let id = caller.keyID, !id.isEmpty, isProfileSave(tool: tool, arguments: arguments) else { return nil }
        return .init(keyID: id, keyName: caller.keyName ?? "This AI app", items: items ?? names(arguments))
    }
    /// The agents a profile request names: the one agent, every agent of an `agents` list, or the ids of a shared change.
    public static func names(_ arguments: NativeRPCValue) -> [String] {
        let rows = arguments["agents"].elements ?? [arguments["agent"]]
        var out = rows.compactMap { $0["name"].string ?? $0["id"].string }
        if out.isEmpty { out = (arguments["ids"].elements ?? []).compactMap(\.string) }
        if out.isEmpty, let id = arguments["id"].string { out = [id] }
        return out.filter { !$0.isEmpty }
    }
    /// The card's sentence for an agent save, so the person reads what is asked ("Add the agent Reviewer").
    public static func sentence(tool: String, arguments: NativeRPCValue) -> String? {
        guard ["tasks.agents", "tasks_agents"].contains(tool), ["save", "save-many"].contains(arguments["do"].string ?? "") else { return nil }
        let list = names(arguments)
        if list.count == 1 { return "Save the agent " + list[0] }
        let shown = list.prefix(8).joined(separator: ", ") + (list.count > 8 ? " and \(list.count - 8) more" : "")
        return list.isEmpty ? "Save agents" : "Save \(list.count) agents: " + shown
    }
    public static func honorsStandingKey(tool: String, arguments: NativeRPCValue, caller: BackendDeckCoreSecurityCaller) -> Bool {
        caller.askFirst == false && batch(tool: tool, arguments: arguments, caller: caller) != nil
    }
}
