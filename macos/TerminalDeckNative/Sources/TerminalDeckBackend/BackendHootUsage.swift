import Foundation
import TerminalDeckNativeCore

/// What Hoot's chat knows about its own context window right now (`BackendHootChatStore.contextFacts`).
/// Hoot's chat is not a listed session, so the session usage reader cannot find it; its own AI's reports can.
public struct BackendHootContextFacts: Sendable, Equatable {
    public var provider: String
    public var model: String?
    /// Tokens in Hoot's context after its latest step, as its AI reported them; nil before the first step of this conversation.
    public var tokens: Int?
    /// The window its AI reported for the model in use (Claude's turn result, Codex's token usage); nil until it does.
    public var window: Int?
    public var reportedAt: Double?
    /// The AI's own conversation (Claude session, Codex thread) the figure belongs to.
    public var conversation: String?
    public var alive: Bool
    public init(provider: String, model: String? = nil, tokens: Int? = nil, window: Int? = nil, reportedAt: Double? = nil,
                conversation: String? = nil, alive: Bool = false) {
        self.provider = provider; self.model = model; self.tokens = tokens; self.window = window; self.reportedAt = reportedAt
        self.conversation = conversation; self.alive = alive
    }
}

/// Item 74 (2 Nov): the phones' session ring (CPU · memory · context window · weekly limit) had nothing for Hoot.
/// This is Hoot's usage reader, answering exactly as a session's does (`BackendRemoteServeUsageService.reading`):
/// `context` is the same object as `BackendUsageService.contextWindow`, `plan` the same `BackendUsageReport`, `refresh`
/// the same answer with its report. Ids: `hoot` (the chat) and `hoot:task:<task id>` (each task's own Hoot while its
/// turn runs). The change handler fires after each step that moves a figure, for `BackendRemoteServeUsagePush`.
public actor BackendHootUsage {
    public static let chatID = "hoot"
    public static let taskPrefix = "hoot:task:"
    public static func owns(_ id: String) -> Bool { id == chatID || (id.hasPrefix(taskPrefix) && id.count > taskPrefix.count) }
    /// The account the Hoot runs as (else the one it will run as): its plan limits are that account's.
    public typealias Account = @Sendable () async -> BackendUsageAccount?
    /// Every account's report (`BackendUsageService.read(sessionID: nil)`, the pool Hoot's Limits tab reads too).
    public typealias Plans = @Sendable () async throws -> BackendUsageReport
    private final class Tracked: @unchecked Sendable {
        weak var chat: BackendHootChatStore?
        let account: Account
        init(chat: BackendHootChatStore, account: @escaping Account) { self.chat = chat; self.account = account }
    }
    private var tracked: [String: Tracked] = [:]
    private var plans: Plans?
    private var changed: (@Sendable (String) async -> Void)?
    private let now: @Sendable () -> Double

    public init(now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) { self.now = now }

    /// Follows one Hoot conversation (the chat at assembly, a task's when its Hoot is made). Held weakly.
    public func track(_ id: String, chat: BackendHootChatStore, account: @escaping Account) async {
        tracked[id] = Tracked(chat: chat, account: account)
        await chat.setContextObserver { [weak self] in Task { await self?.moved(id) } }
    }
    public func bindPlans(_ plans: @escaping Plans) { self.plans = plans }
    /// Post-24: a refresh tap starts Claude's own usage check for Hoot's account when its record is over an hour old
    /// (BackendUsageService.refreshAccount); without it a refresh only re-reads the record. It answers with what the
    /// check did, in a sentence (for the Mac's Limits tab), or nil.
    public typealias Check = @Sendable (BackendUsageAccount) async throws -> String?
    private var check: Check?
    public func bindCheck(_ check: @escaping Check) { self.check = check }
    /// The relay's push (`BackendRemoteServeUsagePush.transcriptChanged`); nil stops it.
    public func setChangeHandler(_ handler: (@Sendable (String) async -> Void)?) { changed = handler }
    /// The chat, then each task whose Hoot is running now.
    public func ids() -> [String] {
        tracked = tracked.filter { $0.value.chat != nil }
        return [Self.chatID] + tracked.keys.filter { $0 != Self.chatID }.sorted()
    }
    private func moved(_ id: String) async { await changed?(id) }

    public func reading(id: String, want: String, force: Bool = false) async throws -> NativeRPCValue {
        switch want {
        case "context": return await context(id: id)
        case "plan": return try await plan(id: id).wireValue
        case "refresh":
            let started = now()
            let report = try await refreshPlan(id: id).report
            return Self.refreshAnswer(report, elapsed: now() - started)
        default: throw NativeRPCError.invalidArguments("Unknown remote usage reading")
        }
    }

    /// The ring's refresh and the Mac's Limits tab ("Read limits", #26): the same check, then the plan read again.
    public func refreshPlan(id: String) async throws -> (report: BackendUsageReport, detail: String?) {
        var detail: String?
        if let check, let entry = tracked[id], entry.chat != nil, let account = await entry.account() {
            do { detail = try await check(account) } catch { detail = error.localizedDescription }
        }
        return (try await plan(id: id), detail)
    }

    public func context(id: String) async -> NativeRPCValue {
        guard let chat = tracked[id]?.chat else {
            return Self.blank(nil, "not-reported", id == Self.chatID ? "Hoot's chat is not open on this Mac yet." : "That Hoot task is not running now, so it has no context reading.", now: now())
        }
        return Self.contextReading(await chat.contextFacts(), now: now())
    }

    public func plan(id: String) async throws -> BackendUsageReport {
        let at = now()
        guard let entry = tracked[id], entry.chat != nil else {
            return .init(sessionID: id, account: nil, readings: [], reason: id == Self.chatID ? "Hoot's chat is not open on this Mac yet." : "That Hoot task is not running now.", assembledAt: at)
        }
        guard let account = await entry.account() else {
            return .init(sessionID: id, account: nil, readings: [], reason: "Hoot has no account chosen yet, so there are no plan limits to show.", assembledAt: at)
        }
        if account.provider == "gemini" || account.id.map(BackendAPIAccountRecord.isAPIAccountID) == true || plans == nil {
            return Self.planReport(all: nil, account: account, id: id, now: at)
        }
        return Self.planReport(all: try await plans?(), account: account, id: id, now: at)
    }

    // MARK: The readings (pure, so the shapes are tested without a chat)

    static func blank(_ provider: String?, _ state: String, _ detail: String, now: Double) -> NativeRPCValue {
        BackendUsageIO.object([("provider", BackendUsageIO.string(provider)), ("state", .string(state)), ("tokens", .null), ("window", .null), ("percent", .null),
            ("windowBasis", .null), ("model", .null), ("modelLabel", .null), ("source", .null), ("reportedAt", .number(0)), ("observedAt", .number(now)), ("detail", .string(detail))])
    }
    /// Hoot's context as a session's context reading. Claude: the tokens its last step reported, over the window its
    /// turn result reported (before the first result: the model's known window, `windowBasis: model`). Codex: its own
    /// token-usage numbers and window. Gemini reports neither, so it says so.
    public static func contextReading(_ facts: BackendHootContextFacts, now: Double,
                                      modelLabel: (String) -> String = BackendCompositionSuppliers.modelLabel) -> NativeRPCValue {
        let provider = facts.provider
        guard ["claude", "codex"].contains(provider) else {
            return blank(provider, "not-reported", provider == "gemini"
                ? "Gemini does not report how full its context window is, so there is no figure for Hoot while it runs on Gemini."
                : "Hoot's AI does not report how full its context window is, so there is nothing to read.", now: now)
        }
        guard let tokens = facts.tokens, tokens > 0 else {
            return blank(provider, "nothing-yet", facts.alive
                ? "Hoot has not answered in this conversation yet. The figure is what its AI reports after each step, so it appears with Hoot's next reply."
                : "Hoot is not running right now. The figure is what its AI reports after each step, so it appears once Hoot answers again.", now: now)
        }
        let used = Double(tokens)
        var window: Double? = facts.window.flatMap { $0 > 0 ? Double($0) : nil }
        var basis: String? = window == nil ? nil : "reported"
        if window == nil, provider == "claude", let model = facts.model, !model.isEmpty {
            let table = BackendCostMath.contextWindow(model), effective = BackendCostMath.effectiveWindow(model: model, observed: used)
            window = effective; basis = effective > table ? "observed" : "model"
        }
        let percent = window.map { used / $0 * 100 }
        func grouped(_ value: Double) -> String {
            let format = NumberFormatter(); format.locale = Locale(identifier: "en_US"); format.numberStyle = .decimal; format.maximumFractionDigits = 0
            return format.string(from: NSNumber(value: value)) ?? String(Int(value))
        }
        let detail: String
        if let window, let percent { detail = "\(grouped(used)) of \(grouped(window)) tokens — \(Int(percent.rounded()))% of Hoot's context window." }
        else { detail = "\(grouped(used)) tokens in Hoot's context. Codex has not said how large its window is yet, so there is no share to show." }
        return BackendUsageIO.object([("provider", .string(provider)), ("state", .string("ok")), ("tokens", .number(used)), ("window", BackendUsageIO.number(window)),
            ("percent", BackendUsageIO.number(percent)), ("windowBasis", BackendUsageIO.string(basis)),
            ("model", BackendUsageIO.string(facts.model)), ("modelLabel", BackendUsageIO.string(facts.model.map(modelLabel))),
            ("source", BackendUsageIO.object([("sessionId", BackendUsageIO.string(facts.conversation)), ("chosen", .string("reported")), ("rivals", .number(0))])),
            ("reportedAt", .number(facts.reportedAt ?? 0)), ("observedAt", .number(now)), ("detail", .string(detail))])
    }
    /// Hoot's account's windows out of every account's report: never another account's (as Hoot's Limits tab).
    public static func planReport(all: BackendUsageReport?, account: BackendUsageAccount, id: String, now: Double) -> BackendUsageReport {
        if account.provider == "gemini" {
            return .init(sessionID: id, account: account, readings: [], reason: "Gemini does not report plan limits to this app, so Hoot's weekly limit is not shown while it runs on Gemini.", assembledAt: now)
        }
        if account.id.map(BackendAPIAccountRecord.isAPIAccountID) == true {
            return .init(sessionID: id, account: account, readings: [], reason: "Hoot's account uses API billing. That has no weekly or 5-hour plan limits; API spend and credits are not shown here.", assembledAt: now)
        }
        guard let all else {
            return .init(sessionID: id, account: account, readings: [], reason: "Usage is not ready on this Mac yet.", assembledAt: now)
        }
        let readings = all.readings.filter { $0.account.key == account.key }
        return .init(sessionID: id, account: account, readings: readings, reason: account.provider == "codex"
            ? "Codex has not recorded a rate limit under Hoot's account yet; it records one when a turn completes."
            : "No plan usage has been reported for Hoot's account in the last hour. Claude Code records it as it works.", assembledAt: now)
    }
    /// A press on Hoot's ring reads the account's recorded limits again. No probe process is started for Hoot.
    static func refreshAnswer(_ report: BackendUsageReport, elapsed: Double) -> NativeRPCValue {
        let found = !report.readings.isEmpty
        return BackendUsageIO.object([("ok", .bool(found)), ("outcome", .string(found ? "cached" : "unreadable")),
            ("detail", .string(found ? "Read again from what Hoot's AI last recorded for its account." : report.reason ?? "No plan usage has been reported for Hoot's account.")),
            ("elapsedMs", .number(max(0, elapsed))), ("spawned", .bool(false)), ("report", report.wireValue)])
    }
}
