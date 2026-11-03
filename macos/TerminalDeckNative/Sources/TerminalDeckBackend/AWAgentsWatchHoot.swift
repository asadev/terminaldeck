import Foundation
import TerminalDeckNativeCore

/// HOOT owns decoding, deltas and persistence. WATCH consumes its projection.
public enum AWAgentsWatchHoot {
    public static func source(runtime: BackendCopilotSessionRuntime,
                              require: @escaping @Sendable (AWWatchCaller) async throws -> Void) -> AWAgentsWatchNativeSource.StructuredHoot {
        .init(require: require, read: { _ in
            guard let chat = runtime.structuredChat else {
                throw NativeRPCError(code: "unavailable", message: "Hoot's structured conversation is not available.")
            }
            return try project(await chat.snapshot(limit: 500))
        }, readAgents: { _ in
            guard let chat = runtime.structuredChat else {
                throw NativeRPCError(code: "unavailable", message: "Hoot's structured conversation is not available.")
            }
            return try agents(await chat.snapshot(limit: 500))
        })
    }
    /// Hoot's row and its whole readable conversation (At work's conversation pane).
    public static func project(_ snapshot: NativeRPCValue, project: String = "", machineID: String = "",
                               machineName: String = "This Mac") throws -> (agents: [AWWatchAgent], entries: [AWWatchEntry]) {
        let read = try header(snapshot, project: project, machineID: machineID, machineName: machineName)
        // Every event that belongs to a row, gathered once (was one walk of all events per row).
        var related: [String: [HootChatEvent]] = [:]
        for event in read.events { related[key(event), default: []].append(event) }
        var entries: [AWWatchEntry] = []
        for row in read.rows {
            let relevant = related[row.id] ?? []
            let at = relevant.first?.at ?? 0
            let id = "hoot:\(read.conversation):\(row.id)"
            switch row.kind {
            case .user, .textDelta, .message:
                entries.append(.init(id: id, kind: .message, speaker: row.kind == .user ? "You" : "Hoot", title: "",
                    text: row.value["text"].string ?? "", at: at))
            case .toolCall:
                let name = row.value["name"].string ?? "Tool"
                let input = BackendDeckCoreSecurityActionLog.scrubArguments(row.value["input"])
                let details = (input.fields ?? []).map { $0.key + ": " + ($0.value.string ?? "Details omitted") }.joined(separator: "\n")
                entries.append(.init(id: id + ":call", kind: .tool, speaker: "Hoot", title: AWWatchProjection.action(name), text: details, at: at))
                if row.value["finished"].bool == true {
                    entries.append(result(id: id, value: row.value, title: name, at: relevant.last?.at ?? at))
                }
            case .toolResult: entries.append(result(id: id, value: row.value, title: "Tool", at: at))
            case .approval:
                entries.append(.init(id: id, kind: .status, speaker: "Hoot", title: "Hoot is waiting for you",
                    text: "Open Hoot to answer the request.", at: at))
            case .error, .interrupted:
                entries.append(.init(id: id, kind: .status, speaker: "Hoot", title: row.kind == .error ? "Activity error" : "Interrupted",
                    text: row.value["text"].string ?? "", at: at, failed: row.kind == .error))
            default: break
            }
        }
        return ([read.agent], entries)
    }
    /// Hoot's row only, for the list (`agents-watch:list` and the sidebar's "At work"): the same checks and state as
    /// `project`, without building or cleaning the conversation the list never shows.
    public static func agents(_ snapshot: NativeRPCValue, project: String = "", machineID: String = "",
                              machineName: String = "This Mac") throws -> [AWWatchAgent] {
        [try header(snapshot, project: project, machineID: machineID, machineName: machineName).agent]
    }

    private static func key(_ event: HootChatEvent) -> String {
        event.turnID + ":" + (event.record.messageID.isEmpty ? event.id : event.record.messageID)
    }
    private static func header(_ snapshot: NativeRPCValue, project: String, machineID: String, machineName: String) throws
        -> (agent: AWWatchAgent, conversation: String, events: [HootChatEvent], rows: [HootChatRow]) {
        let conversation = try snapshot["conversationId"].requireString("Hoot conversation", nonempty: true)
        let events = try (snapshot["events"].elements ?? []).map(HootChatEvent.init(wire:))
        guard events.allSatisfy({ $0.conversationID == conversation }) else { throw NativeRPCError.malformed("Hoot's event belongs to another conversation") }
        // One source with the Hoot page: a Hoot whose CLI is not running is offline,
        // never "idle", so the Agents page cannot say Awake while the Hoot page says Stopped.
        let state: AWWatchState = !(snapshot["pending"].elements ?? []).isEmpty ? .waiting :
            snapshot["busy"].bool == true ? .working : snapshot["alive"].bool == false ? .offline : .idle
        let rows = HootChatProjection.rows(events)
        let currentTool = rows.last { $0.kind == .toolCall && $0.value["finished"].bool != true }?.value["name"].string
        let since = events.last { event in
            state == .waiting ? event.record.kind == .approval : state == .working ? event.record.kind == .user : event.record.kind == .completed
        }?.at
        let source = NativeRPCValue.object([
            .init("id", .string(AWWatchAgent.identity(machine: machineID, kind: "hoot", source: conversation))),
            .init("sourceID", .string(conversation)), .init("kind", .string("hoot")), .init("name", .string("Hoot")),
            .init("provider", snapshot["provider"]), .init("project", .string(project)), .init("machineID", .string(machineID)),
            .init("machineName", .string(machineName)), .init("state", .string(state.rawValue)),
            .init("action", .string(state == .working ? currentTool.map(AWWatchProjection.action) ?? state.label : state.label)),
            .init("since", since.map(NativeRPCValue.number) ?? .null),
            .init("updatedAt", events.last.map { .number($0.at) } ?? .null)])
        guard let agent = AWWatchAgent.decode(source) else { throw NativeRPCError.malformed("Hoot's activity state is invalid") }
        return (agent, conversation, events, rows)
    }
    private static func result(id: String, value: NativeRPCValue, title: String, at: Double) -> AWWatchEntry {
        let output = value["output"].string ?? (value["output"].elements ?? []).compactMap { item in
            item["type"].string == "text" ? item["text"].string : nil
        }.joined(separator: "\n")
        return .init(id: id + ":result", kind: .result, speaker: "Tool", title: "Result · " + title,
            text: Cleaned.shared.text(output), at: at, failed: value["isError"].bool == true)
    }

    /// Each tool result is cleaned once: a refresh of an unchanged conversation reuses the cleaned text. Keyed by the
    /// whole output, so a hit is always the same content; bounded, and emptied when it grows past its limit.
    final class Cleaned: @unchecked Sendable {
        static let shared = Cleaned()
        static let maximumEntries = 1_024
        static let maximumCharacters = 8_000_000
        private let lock = NSLock()
        private var cleaned: [String: String] = [:]
        private var characters = 0
        private(set) var hits = 0, misses = 0
        func text(_ output: String) -> String {
            if output.isEmpty { return output }
            lock.lock()
            if let known = cleaned[output] { hits += 1; lock.unlock(); return known }
            misses += 1
            lock.unlock()
            let clean = BackendGitHubSecretRedaction.redact(output, home: "")
            let size = output.utf16.count + clean.utf16.count
            guard size <= Self.maximumCharacters / 8 else { return clean }
            lock.lock(); defer { lock.unlock() }
            if cleaned.count >= Self.maximumEntries || characters + size > Self.maximumCharacters { cleaned.removeAll(); characters = 0 }
            if cleaned.updateValue(clean, forKey: output) == nil { characters += size }
            return clean
        }
        func reset() { lock.lock(); cleaned.removeAll(); characters = 0; hits = 0; misses = 0; lock.unlock() }
    }
}
