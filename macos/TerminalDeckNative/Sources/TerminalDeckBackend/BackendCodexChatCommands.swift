import Foundation
import TerminalDeckNativeCore

/// Codex 0.159.3's installed menu and app-server schema, checked on 13 Oct 2026.
/// Terminal pickers are omitted. Skill names/paths come from this account's skills/list.
enum BackendCodexChatCommands {
    static func contextReading(tokens: Int, window: Int?, reportedAt: Double?, sessionID: String?) -> NativeRPCValue {
        guard tokens > 0, let reportedAt else { return .null }
        return .object([.init("state", .string("ok")), .init("tokens", .number(Double(tokens))),
            .init("window", window.map { .number(Double($0)) } ?? .null),
            .init("percent", window.flatMap { $0 > 0 ? .number(Double(tokens) / Double($0) * 100) : nil } ?? .null),
            .init("windowBasis", .string("reported")), .init("reportedAt", .number(reportedAt)),
            .init("source", .object([.init("sessionId", sessionID.map(NativeRPCValue.string) ?? .null), .init("chosen", .string("reported"))]))])
    }
    static func builtins(model: String?) -> [NativeRPCValue] {
        var rows = [("model", "Choose the model and effort in Settings."),
                    ("permissions", "Choose permissions in Settings."),
                    ("status", "Show the account and usage in Settings."),
                    ("compact", "Summarize this conversation to free context."),
                    ("review", "Review current changes, or add review instructions."),
                    ("init", "Create AGENTS.md instructions for this project.")]
        if model?.isEmpty == false { rows.append(("plan", "Plan the next task before making changes.")) }
        return rows.map { .object([.init("name", .string($0.0)), .init("description", .string($0.1))]) }
    }
    static func skills(_ result: NativeRPCValue, cwd: String) -> [String: NativeRPCValue] {
        var found: [String: NativeRPCValue] = [:]
        for entry in result["data"].elements ?? [] where entry["cwd"].string == cwd {
            for skill in entry["skills"].elements ?? [] where skill["enabled"].bool == true {
                guard let name = skill["name"].string, !name.isEmpty, name.count <= 80,
                      !name.contains(where: { $0.isWhitespace || $0 == "/" }),
                      skill["path"].string?.hasPrefix("/") == true, found[name] == nil else { continue }
                found[name] = skill
            }
        }
        return found
    }
    static func menu(model: String?, skills: [String: NativeRPCValue]) -> NativeRPCValue {
        let builtins = builtins(model: model), names = Set(builtins.compactMap { $0["name"].string })
        return .array(builtins + skills.keys.sorted().filter { !names.contains($0) }.map { name in
            .object([.init("name", .string(name)),
                     .init("description", skills[name]!["shortDescription"].string.map(NativeRPCValue.string) ?? skills[name]!["description"]),
                     .init("argumentHint", .string("[instructions]"))])
        })
    }
    static func split(_ text: String) -> (name: String, arguments: String)? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let first = parts.first else { return nil }
        return (String(first), parts.count > 1 ? String(parts[1]) : "")
    }
}
