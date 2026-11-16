import Foundation
import TerminalDeckNativeCore

/// I20 — app chat history, attachments and unsent drafts.
///
/// - `D/session-chats/<tab>/{chat.json,chat-*.json,job.json,composer-settings.json,media/**}` (BackendSessionChats,
///   NativeCompositionSessionChats): create-only for a tab folder file that does not exist; a live tab's open chat is
///   never written (its file exists, so a different incoming version is kept beside it as a conflict).
/// - `<hoot>/{chat.json,chat-*.json,media/**}` (BackendHootChatStore): same create-only rule.
/// - `D/session-chats/delivery-requests/**`, `D/chat-outgoing/**`: unsent drafts. Uploaded and kept readable, never
///   placed where a delivery queue could send them (archive-only).
/// - `D/copilot/**`: legacy read-old folder. Uploaded and kept readable, never placed live (archive-only).
///
/// Runtime fields are neutralised in the file placed locally; the raw bytes stay unchanged in Cloud and in the archive
/// (S11). Chat files: `queuedMessages` (would send automatically), `busy`, `foreground`, `pid`, `processPID`, `hostPID`,
/// `socket`, `socketPath`, `running`, `cliStatus`, `lease`, `leaseId`. Team-chat `job.json` additionally drops
/// `resumeInput` (launch input of another Mac), `interruptedAt` (would offer Resume), `turnID` and `cursor`.
public enum BackendCloudBrainAppChats {
    public static let chatRuntimeKeys: Set<String> = ["queuedMessages", "busy", "foreground", "pid", "processPID", "hostPID", "socket", "socketPath",
                                                      "running", "cliStatus", "lease", "leaseId"]
    public static let jobRuntimeKeys: Set<String> = ["resumeInput", "interruptedAt", "turnID", "cursor"]
    public static let notBuilt = ["Conversation links (app session, provider conversation and project folder) are not built yet."]

    public static func adapter(dataRoot: URL, hootRoot: URL, deviceId: String, stateRoot: URL) throws -> BackendCloudBrainFiles {
        let chats = dataRoot.appendingPathComponent("session-chats", isDirectory: true)
        let neutral: @Sendable (String, Data) throws -> Data = { relative, bytes in try neutralise(relative, bytes) }
        let sources = [
            BackendCloudBrainFilesSource(
                sourceId: "session-chats", root: chats,
                include: ["*/chat.json", "*/chat-*.json", "*/job.json", "*/composer-settings.json", "*/media/**"],
                exclude: ["delivery-requests/**"] + BackendCloudBrainFilesNames.locks, projection: .createOnly(transform: neutral)),
            BackendCloudBrainFilesSource(
                sourceId: "hoot-chat", root: hootRoot, include: ["chat.json", "chat-*.json", "media/**"], exclude: BackendCloudBrainFilesNames.locks,
                projection: .createOnly(transform: neutral)),
            BackendCloudBrainFilesSource(
                sourceId: "drafts/delivery", root: chats.appendingPathComponent("delivery-requests", isDirectory: true), include: ["**"],
                exclude: BackendCloudBrainFilesNames.locks, projection: .archiveOnly("An unsent message; kept readable and never sent from another device.")),
            BackendCloudBrainFilesSource(
                sourceId: "drafts/outgoing", root: dataRoot.appendingPathComponent("chat-outgoing", isDirectory: true), include: ["**"],
                exclude: BackendCloudBrainFilesNames.locks, projection: .archiveOnly("An unsent message; kept readable and never sent from another device.")),
            BackendCloudBrainFilesSource(
                sourceId: "legacy-copilot", root: dataRoot.appendingPathComponent("copilot", isDirectory: true), include: ["**"],
                exclude: BackendCloudBrainFilesNames.locks, projection: .archiveOnly("The old Hoot folder; kept readable."))
        ]
        return try BackendCloudBrainFiles(inventoryRow: "I20", deviceId: deviceId, stateRoot: stateRoot, sources: sources, pendingCategories: notBuilt)
    }

    /// Removes only top-level runtime fields of a JSON object. Anything else (or a non-object) is returned byte-identical.
    public static func neutralise(_ relative: String, _ bytes: Data) throws -> Data {
        guard relative.hasSuffix(".json"), !relative.contains("/media/"), !relative.hasPrefix("media/") else { return bytes }
        guard let value = try? NativeRPCValue.parseJSON(bytes), let fields = value.fields else { return bytes }
        let name = (relative as NSString).lastPathComponent
        let drop = name == "job.json" ? chatRuntimeKeys.union(jobRuntimeKeys) : chatRuntimeKeys
        let kept = fields.filter { !drop.contains($0.key) }
        guard kept.count != fields.count else { return bytes }
        return try NativeRPCValue.object(kept).encodedJSON()
    }
}
