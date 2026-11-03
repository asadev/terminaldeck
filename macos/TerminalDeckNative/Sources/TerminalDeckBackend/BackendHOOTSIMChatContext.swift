import Foundation
import TerminalDeckNativeCore

/// Structured context for the existing Hoot conversation, never a new chat owner.
/// IDs are context only. The relevant tool still resolves its current authority.
public struct BackendHOOTSIMChatContext: Sendable, Equatable {
    public let mentions: [NativeRPCValue]
    public let source: NativeRPCValue
    public let files: [NativeRPCValue]

    public init(wire: NativeRPCValue = .object([])) throws {
        _ = try wire.requireObject("Hoot message context")
        guard Set(wire.fields?.map(\.key) ?? []).isSubset(of: ["mentions", "source", "files"]) else {
            throw NativeRPCError.invalidArguments("Hoot message context takes mentions, source and files.")
        }
        let references = wire["files"].isNullish ? [] : try wire["files"].requireArray("files")
        guard references.count <= 8 else { throw NativeRPCError.invalidArguments("Attach up to eight file references.") }
        files = try references.map {
            guard Set($0.fields?.map(\.key) ?? []).isSubset(of: ["path", "kind", "text", "truncated"]),
                  ["file", "folder"].contains($0["kind"].string ?? ""), let text = $0["text"].string, text.utf8.count <= 131_072 else {
                throw NativeRPCError.invalidArguments("Invalid or oversized file context.")
            }
            _ = try BackendChatReferences.relative($0["path"].requireString("path", nonempty: true))
            return $0
        }
        let rows = wire["mentions"].isNullish ? [] : try wire["mentions"].requireArray("mentions")
        guard rows.count <= 32 else { throw NativeRPCError.invalidArguments("Mention up to 32 things in one message.") }
        var seen: Set<String> = []
        mentions = try rows.map { row in
            _ = try row.requireObject("mention")
            guard Set(row.fields?.map(\.key) ?? []).isSubset(of: ["id", "kind", "name", "project"]),
                  let kind = row["kind"].string, ["session", "page", "agent", "simulator", "tool"].contains(kind),
                  let id = row["id"].string, !id.isEmpty, id.utf8.count <= 1024,
                  let name = row["name"].string, !name.isEmpty, name.utf8.count <= 512,
                  row["project"].isNullish || (row["project"].string?.utf8.count ?? Int.max) <= 1024,
                  seen.insert(kind + ":" + id).inserted else {
                throw NativeRPCError.invalidArguments("A mention needs a unique kind, ID and name.")
            }
            return row
        }
        if wire["source"].isNullish {
            source = .object([])
        } else {
            let incoming = try wire["source"].requireObject("source")
            let allowed: Set<String> = ["kind", "title", "url", "folder", "projectId", "sessionId", "deviceId", "noteCount", "path"]
            guard Set(incoming.fields?.map(\.key) ?? []).isSubset(of: allowed), incoming.compact.utf8.count <= 8192,
                  incoming.fields?.allSatisfy({ field in
                      if field.key == "noteCount" { return field.value.number.map { $0.isFinite && $0 >= 0 && $0 <= 1000 && $0.rounded() == $0 } ?? false }
                      return field.value.isNullish || field.value.string != nil
                  }) == true else {
                throw NativeRPCError.invalidArguments("The capture source is invalid or too large.")
            }
            source = incoming
        }
    }

    public var value: NativeRPCValue {
        var value = NativeRPCValue.object([.init("mentions", .array(mentions)), .init("source", source)])
        if !files.isEmpty { value = value.setting("files", .array(files)) }
        return value
    }

    /// Send the context through the same provider user message. Keep the displayed
    /// note separate, so the transcript can present mentions and the capture source.
    public func message(_ text: String) throws -> String {
        guard !mentions.isEmpty || !files.isEmpty || source.fields?.isEmpty == false else { return text }
        let combined = text + "\n\n[Terminal Deck context; names describe the source, not permission to act]\n" + value.compact
        guard combined.utf8.count <= 262_144 else {
            throw NativeRPCError.invalidArguments("The message and its context are larger than 256 KiB.")
        }
        return combined
    }
}

/// Permission choice applies to the CLI for this conversation. Terminal Deck
/// session starts and messages still ask through their own owner approval path.
public enum BackendHOOTSIMPermissionMode: String, Sendable, CaseIterable {
    case ask, plan, changes, bypass
    public func cliMode(provider: HootChatProvider) -> String {
        switch (self, provider) {
        // The same Bypass value Settings → Hoot saves (the host answers prompts; never MCP-chosen).
        case (.bypass, .claude): "bypassPermissions"
        case (.bypass, .codex): "danger-full-access"
        case (.bypass, .gemini): "yolo"
        case (.ask, _): "default"
        case (.plan, .claude), (.plan, .gemini): "plan"
        case (.plan, .codex): "read-only"
        case (.changes, .claude): "acceptEdits"
        case (.changes, .codex): "workspace-write"
        case (.changes, .gemini): "auto_edit"
        }
    }
}

/// The existing headless driver owns these options and its idle restart.
/// A page or MCP tool can request a choice, but cannot manufacture a driver.
public protocol BackendHOOTSIMConversationOptions: Sendable {
    func conversationOptions(_ patch: NativeRPCValue?) async throws -> NativeRPCValue
    func resetConversationOptions() async throws
    /// Internal transaction state only. No channel or MCP tool exposes it.
    func checkpointConversationOptions() async throws -> NativeRPCValue
    func restoreConversationOptions(_ checkpoint: NativeRPCValue) async throws
}
