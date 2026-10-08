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
        })
    }
    public static func project(_ snapshot: NativeRPCValue, project: String = "", machineID: String = "",
                               machineName: String = "This Mac") throws -> (agents: [AWWatchAgent], entries: [AWWatchEntry]) {
        let conversation = try snapshot["conversationId"].requireString("Hoot conversation", nonempty: true)
        let events = try (snapshot["events"].elements ?? []).map(HootChatEvent.init(wire:))
        guard events.allSatisfy({ $0.conversationID == conversation }) else { throw NativeRPCError.malformed("Hoot's event belongs to another conversation") }
        let state: AWWatchState = !(snapshot["pending"].elements ?? []).isEmpty ? .waiting :
            snapshot["busy"].bool == true ? .working : .idle
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
        var entries: [AWWatchEntry] = []
        for row in rows {
            let relevant = events.filter { event in
                event.turnID + ":" + (event.record.messageID.isEmpty ? event.id : event.record.messageID) == row.id
            }
            let at = relevant.first?.at ?? 0
            let id = "hoot:\(conversation):\(row.id)"
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
        return ([agent], entries)
    }
    private static func result(id: String, value: NativeRPCValue, title: String, at: Double) -> AWWatchEntry {
        let output = value["output"].string ?? (value["output"].elements ?? []).compactMap { item in
            item["type"].string == "text" ? item["text"].string : nil
        }.joined(separator: "\n")
        return .init(id: id + ":result", kind: .result, speaker: "Tool", title: "Result · " + title,
            text: BackendGitHubSecretRedaction.redact(output, home: ""), at: at, failed: value["isError"].bool == true)
    }
}
