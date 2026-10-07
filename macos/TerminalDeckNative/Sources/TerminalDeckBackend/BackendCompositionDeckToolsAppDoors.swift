import Foundation
import TerminalDeckNativeCore

/// copilot-admin-tools.ts small doors (`tools.status`, `notifications.status`,
/// `links.open`) over the real owners (INT-A, 7 Oct 2026), as sessions-lane.ts:296-313
/// wires them: deck-control's own status, os-notifications.ts, link-open.ts.
public struct BackendCompositionDeckToolsAppSmallDoors: BackendDeckToolsAppSmallDoorsService, Sendable {
    /// `parts.deckControl()`: the running core, or nil while it has not finished starting.
    public typealias Core = @Sendable () async -> BackendDeckCoreRuntime?
    /// link-open.ts openSystemUrl → shell.openExternal: the app target opens an
    /// http(s) URL in the Mac's default browser (NSWorkspace) and says whether it did.
    public typealias OpenURL = @Sendable (_ url: URL) async -> Bool
    private let core: Core
    private let notifications: BackendOSNotificationEvidence
    private let open: OpenURL

    public init(core: @escaping Core, notifications: BackendOSNotificationEvidence, openURL: @escaping OpenURL) {
        self.core = core; self.notifications = notifications; self.open = openURL
    }

    /// deck-status.ts deckControlStatus — the same composition `deck-control:status` answers.
    public func toolStatus() async throws -> NativeRPCValue? {
        guard let runtime = await core() else { return nil }
        do { return try await runtime.status() }
        catch BackendSessionFailure.closed { return nil }
    }
    /// os-notifications.ts notificationSupport.
    public func notificationSupport() async throws -> NativeRPCValue { notifications.support() }
    /// os-notifications.ts notificationDelivery(sinceMs).
    public func notificationDelivery(sinceMs: Double) async throws -> NativeRPCValue { try await notifications.delivery(since: sinceMs) }
    /// os-notifications.ts openNotificationSettings: `{ opened }` or `{ opened: false, message }`.
    public func openNotificationSettings() async throws -> NativeRPCValue { await notifications.openSettings() }
    /// link-open.ts:197 openSystemUrl: false for anything that cannot leave the app.
    /// The factory has already normalised the address to http(s).
    public func openURL(_ url: String) async throws -> Bool {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return await open(parsed)
    }
}

/// ui-tools.ts over the native window instead of renderer evaluation
/// (deck-tools-HANDOFF: "native UI dispatch contract replaces renderer evaluation").
///
/// The app target supplies two MainActor-backed closures over AppCommands'
/// real handlers (the same ones a person's menu/chord runs):
///  - `list`:    nil when no app window is open; otherwise ui-bridge.ts UiListing
///               `{ commands: [{ id, title, group?, enabled? }], sessions: [{ id, title }], sections: [String] }`.
///  - `perform`: (kind ∈ run|focus|settings, target) → nil when no window; otherwise
///               ui-bridge.ts UiAnswer `{ ok: true, did }` or `{ ok: false, why }`.
/// Strings are arguments, never evaluated code. The answer is copied field by
/// field (ui-bridge.ts:92), so nothing else the window holds can leave in it.
public struct BackendCompositionDeckToolsAppUI: BackendDeckToolsAppUIService, Sendable {
    public typealias List = @Sendable () async throws -> NativeRPCValue?
    public typealias Perform = @Sendable (_ kind: String, _ target: String) async throws -> NativeRPCValue?
    private let listing: List
    private let dispatch: Perform

    public init(list: @escaping List, perform: @escaping Perform) { listing = list; dispatch = perform }

    public func list() async throws -> NativeRPCValue? {
        guard let raw = try await listing(), raw != .null, raw != .missing else { return nil }
        guard raw.fields != nil else { throw Self.malformed }
        let commands = (raw["commands"].elements ?? []).compactMap { command -> NativeRPCValue? in
            guard let id = command["id"].string, let title = command["title"].string else { return nil }
            var row = BackendDeckToolsSupport.object([("id", .string(id)), ("title", .string(title))])
            if let group = command["group"].string { row = row.setting("group", .string(group)) }
            if let enabled = command["enabled"].bool { row = row.setting("enabled", .bool(enabled)) }
            return row
        }
        let sessions = (raw["sessions"].elements ?? []).compactMap { session -> NativeRPCValue? in
            guard let id = session["id"].string, let title = session["title"].string else { return nil }
            return BackendDeckToolsSupport.object([("id", .string(id)), ("title", .string(title))])
        }
        let sections = (raw["sections"].elements ?? []).compactMap(\.string).map(NativeRPCValue.string)
        return BackendDeckToolsSupport.object([("commands", .array(commands)), ("sessions", .array(sessions)), ("sections", .array(sections))])
    }

    public func perform(kind: String, target: String) async throws -> NativeRPCValue? {
        guard ["run", "focus", "settings"].contains(kind) else { throw BackendDeckToolsArgs.bad("action must be \"run\", \"focus\" or \"settings\"") }
        guard let raw = try await dispatch(kind, target), raw != .null, raw != .missing else { return nil }
        guard let ok = raw["ok"].bool, let text = raw[ok ? "did" : "why"].string else { throw Self.malformed }
        return BackendDeckToolsSupport.object([("ok", .bool(ok)), (ok ? "did" : "why", .string(text))])
    }

    /// An answer in no shape the bridge defines is an explicit failure, never "no window".
    static var malformed: NativeRPCError {
        NativeRPCError(code: "unavailable", message: "The app window answered in a shape this build does not read, so nothing is reported as done.")
    }
}

/// voice-tools.ts over the one `BackendOSVoiceService` the `voice:*` channels use
/// (agents-area-live.ts:256-264: VOICE_PROVIDERS, voiceStatus, saveCheckedVoiceKey,
/// clearVoiceKey, transcribeWithStoredKey). The key is checked against the
/// provider before it is stored, and never returned.
public struct BackendCompositionDeckToolsAppVoice: BackendDeckToolsAppVoiceService, Sendable {
    private let voice: BackendOSVoiceService
    public init(voice: BackendOSVoiceService) { self.voice = voice }

    public func providers() async throws -> [NativeRPCValue] { BackendOSVoiceRules.providers.map(\.wireValue) }
    public func status() async throws -> NativeRPCValue { await voice.status() }
    public func save(provider: String, key: String) async throws -> NativeRPCValue { try await voice.save(providerID: provider, key: key) }
    public func forget() async throws { try await voice.forget() }
    public func transcribe(audio: Data, filename: String) async throws -> NativeRPCValue {
        try await voice.transcribeStored(audio: audio, filename: filename)
    }
}
