import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// F29: put back the files a Claude Chat changed since one of its own messages. This is not conversation
/// rewind (history is untouched) and not Git revert: the provider restores only what its own edit tools
/// changed, from the snapshots it took before each message. Shell commands and outside edits are not
/// covered, and the result says so. A restore is always preceded by a provider preview, and it only runs
/// when the person's approved preview still matches a fresh one.
public enum BackendChatFileCheckpoints {
    public typealias Request = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    public static let operations = ["checkpoints/list", "checkpoints/preview", "checkpoints/restore"]
    public static func changes(_ operation: String) -> Bool { operation == "checkpoints/restore" }
    static let scope = "Restores files this chat changed with its own edit tools since that message. Changes made by shell commands, other programs or other chats are not covered. The conversation itself is not rewound."

    private static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }

    /// `checkpoints`: `{turnId, messageUuid, text}` rows the store recorded when it sent each Claude message.
    /// `quietNow`: asked again immediately before the real restore (the preview in between is a provider round trip).
    public static func invoke(operation: String, args: NativeRPCValue, provider: HootChatProvider, checkpoints: [NativeRPCValue],
                              quiet: Bool, quietNow: (@Sendable () async -> Bool)? = nil, request: Request) async throws -> NativeRPCValue {
        guard operations.contains(operation), args.fields != nil, try args.encodedJSON().count <= 4_096 else {
            throw NativeRPCError.invalidArguments("Choose a supported file-checkpoint action with bounded arguments.")
        }
        let allowed: Set<String> = operation == "checkpoints/list" ? [] : operation == "checkpoints/preview" ? ["turnId"] : ["turnId", "approvedDigest"]
        guard Set(args.fields?.map(\.key) ?? []).isSubset(of: allowed) else {
            throw NativeRPCError.invalidArguments("Use a turnId from checkpoints/list. Provider message IDs and file paths are not accepted.")
        }
        guard provider == .claude else {
            if operation == "checkpoints/list" {
                return object([("available", .bool(false)), ("provider", .string(provider.rawValue)), ("items", .array([])),
                    ("reason", .string(unsupported(provider))), ("scope", .string(scope))])
            }
            throw NativeRPCError(code: "unavailable", message: unsupported(provider))
        }
        if operation == "checkpoints/list" {
            return object([("available", .bool(true)), ("provider", .string(provider.rawValue)),
                ("items", .array(checkpoints.suffix(100).reversed().map { row in
                    object([("turnId", row["turnId"]), ("text", .string(String((row["text"].string ?? "").prefix(200)))), ("at", row["at"])])
                })), ("scope", .string(scope)),
                ("note", .string("Only messages sent after file checkpoints were enabled for this chat are listed. The provider still decides at preview whether a snapshot exists."))])
        }
        let turn = try args["turnId"].requireString("turnId", nonempty: true)
        guard let checkpoint = checkpoints.first(where: { $0["turnId"].string == turn }), let message = checkpoint["messageUuid"].string, !message.isEmpty else {
            throw NativeRPCError(code: "access-denied", message: "That message has no recorded file checkpoint in this chat.")
        }
        let preview = try await dryRun(message, turn: turn, request: request)
        if operation == "checkpoints/preview" { return preview.value }
        guard quiet else { throw NativeRPCError(code: "busy", message: "Wait for the AI to finish its answer before restoring files.") }
        guard let approved = args["approvedDigest"].string, approved == preview.digest else {
            throw NativeRPCError(code: "preview-changed", message: "The files changed since you looked at the preview. Preview again and approve what it now shows.")
        }
        guard preview.canRewind, !preview.files.isEmpty else {
            throw NativeRPCError(code: "nothing-to-restore", message: preview.error ?? "No files differ from that checkpoint.")
        }
        // The preview above is a provider round trip. A message sent from another surface in that pause would
        // start a turn that is editing these files, so quiet is checked again right before the real restore.
        if let quietNow, await !quietNow() { throw NativeRPCError(code: "busy", message: "The AI started working again. Wait for it to finish, then preview and restore again.") }
        let done = try await request("rewind_files", object([("user_message_id", .string(message)), ("dry_run", .bool(false))]))
        guard done["canRewind"].bool == true else {
            throw NativeRPCError(code: "restore-refused", message: done["error"].string ?? "The provider did not restore the files.")
        }
        return object([("restored", .bool(true)), ("turnId", .string(turn)), ("files", .array(preview.files.map(NativeRPCValue.string))),
            ("insertions", .number(preview.insertions)), ("deletions", .number(preview.deletions)),
            ("skippedLinks", done["skippedLinks"]), ("conversationRewound", .bool(false)), ("scope", .string(scope))])
    }

    struct Preview {
        var canRewind: Bool, error: String?, files: [String], insertions: Double, deletions: Double, digest: String, value: NativeRPCValue
    }
    static func dryRun(_ message: String, turn: String, request: Request) async throws -> Preview {
        let response = try await request("rewind_files", object([("user_message_id", .string(message)), ("dry_run", .bool(true))]))
        let can = response["canRewind"].bool == true
        let files = (response["filesChanged"].elements ?? []).compactMap(\.string).filter { $0.utf8.count <= 4_096 && !$0.contains("\0") }
        let shown = Array(files.prefix(200))
        let ins = max(0, response["insertions"].number ?? 0), del = max(0, response["deletions"].number ?? 0)
        // The digest binds the approval to this exact checkpoint and file set. A different outcome needs a new approval.
        let canonical = [message, can ? "1" : "0", String(Int(ins)), String(Int(del))] + files.sorted()
        let digest = SHA256.hash(data: Data(canonical.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        let error = response["error"].string
        let value = object([("turnId", .string(turn)), ("canRewind", .bool(can)), ("error", error.map(NativeRPCValue.string) ?? .null),
            ("files", .array(shown.map(NativeRPCValue.string))), ("fileCount", .number(Double(files.count))),
            ("moreFiles", .bool(files.count > shown.count)), ("insertions", .number(ins)), ("deletions", .number(del)),
            ("digest", .string(digest)), ("conversationRewound", .bool(false)), ("scope", .string(scope)),
            ("next", .string("Approve by calling checkpoints/restore with this turnId and approvedDigest."))])
        return Preview(canRewind: can, error: error, files: files, insertions: ins, deletions: del, digest: digest, value: value)
    }
    private static func unsupported(_ provider: HootChatProvider) -> String {
        provider == .codex
            ? "Codex's app-server (0.159) can drop conversation turns but has no request that restores files. Use Git or the app's diff review to undo file changes."
            : "This provider exposes no file-checkpoint protocol in this installation."
    }
}
