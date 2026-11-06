import Foundation
import TerminalDeckNativeCore

public struct BackendDeckCoreSecurityBudget: Sendable {
    public let limit: Int
    public let windowMilliseconds: Double
    public init(limit: Int, windowMilliseconds: Double) { self.limit = limit; self.windowMilliseconds = windowMilliseconds }
}
public struct BackendDeckCoreSecurityBudgets: Sendable {
    public let all: BackendDeckCoreSecurityBudget
    public let changes: BackendDeckCoreSecurityBudget
    public let sessionStarts: BackendDeckCoreSecurityBudget
    public let deviceInput: BackendDeckCoreSecurityBudget
    public let browserSteps: BackendDeckCoreSecurityBudget
    public init(all: BackendDeckCoreSecurityBudget = .init(limit: 240, windowMilliseconds: 60_000),
                changes: BackendDeckCoreSecurityBudget = .init(limit: 30, windowMilliseconds: 300_000),
                sessionStarts: BackendDeckCoreSecurityBudget = .init(limit: 5, windowMilliseconds: 600_000),
                deviceInput: BackendDeckCoreSecurityBudget = .init(limit: 300, windowMilliseconds: 300_000),
                browserSteps: BackendDeckCoreSecurityBudget = .init(limit: 300, windowMilliseconds: 300_000)) {
        self.all = all; self.changes = changes; self.sessionStarts = sessionStarts; self.deviceInput = deviceInput; self.browserSteps = browserSteps
    }
}
public struct BackendDeckCoreSecurityCallResult: Sendable {
    public let ok: Bool
    public let value: NativeRPCValue
    public let error: String?
    public let refusal: BackendDeckCoreSecurityRefusalReason?
    public let row: NativeRPCValue
    public var reply: BackendMCPToolReply { ok ? .value(value) : .failure(error ?? "the call failed") }
}
private final class BackendDeckCoreSecurityStarted: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: String] = [:]
    func starter(_ id: String) -> String? { lock.withLock { entries[id] } }
    func note(_ id: String, starter: String) { lock.withLock { entries[id] = starter } }
    func copilotSessions() -> [String] { lock.withLock { entries.filter { $0.value == "copilot" }.map(\.key) } }
}

/// Every source path (local, session, paired device, key and routine) enters this gate.
public actor BackendDeckCoreSecurityControl {
    private struct Window {
        let budget: BackendDeckCoreSecurityBudget
        var hits: [Double] = []
        mutating func take(_ now: Double) -> Bool {
            hits.removeAll { $0 <= now - budget.windowMilliseconds }
            guard hits.count < budget.limit else { return false }; hits.append(now); return true
        }
        func idle(_ now: Double) -> Bool { hits.allSatisfy { $0 <= now - budget.windowMilliseconds } }
    }
    private struct Windows {
        var all: Window; var changes: Window; var starts: Window; var devices: Window; var browser: Window
        init(_ budgets: BackendDeckCoreSecurityBudgets) {
            all = Window(budget: budgets.all); changes = Window(budget: budgets.changes)
            starts = Window(budget: budgets.sessionStarts); devices = Window(budget: budgets.deviceInput); browser = Window(budget: budgets.browserSteps)
        }
        func idle(_ now: Double) -> Bool { all.idle(now) && changes.idle(now) && starts.idle(now) && devices.idle(now) && browser.idle(now) }
    }
    private let log: BackendDeckCoreSecurityActionLog
    private let consent: BackendDeckCoreSecurityConsentBroker
    private let budgets: BackendDeckCoreSecurityBudgets
    private let now: @Sendable () -> Double
    private let driving: @Sendable () async -> Bool
    private let liveTools: @Sendable () throws -> [BackendDeckCoreSecurityToolPolicy]
    private let onRow: (@Sendable (NativeRPCValue) async throws -> Void)?
    private let checkArguments: @Sendable (BackendMCPTool, NativeRPCValue) throws -> Void
    private let started = BackendDeckCoreSecurityStarted()
    /// #74: every caller keeps its own allowance (each key, each agent session, each paired device, Hoot and the
    /// window), so a busy agent never spends another's; the limits per caller are unchanged. Session starts cost
    /// money and a session can start others, so callers without a key still share one start allowance.
    private var callerWindows: [String: Windows] = [:]
    private var sharedStarts: Window
    private var catalogue: [BackendDeckCoreSecurityToolPolicy] = []
    private var specs: [String: BackendDeckCoreSecurityToolPolicy] = [:]
    /// The in-flight call a domain handler may enter once (prepared effect).
    private struct Effect: Sendable {
        let tool: BackendMCPTool
        let arguments: NativeRPCValue
        let redacted: NativeRPCValue?
        let scrubbed: NativeRPCValue
        let caller: BackendDeckCoreSecurityCaller
        let attended: Bool
        let cancellation: BackendMCPCancellation
        let lease: BackendDeckCoreSecurityEffectLease
        let spendsDeviceInput: Bool
        let toolUseStamp: String?
        /// The tier the call's own gate already covered (budget and consent).
        let coveredTier: BackendMCPTier
        var tier: BackendMCPTier
        var confirmation: BackendDeckCoreSecurityConfirmation
        var summary: String
        var entered = false
        var proof: BackendDeckCoreSecurityEffectProof?
        var recorded: NativeRPCValue?
        var refusal: BackendDeckCoreSecurityRefusal?
        var reason: String? = nil
    }
    private var effects: [String: Effect] = [:]
    public typealias ToolUseInspector = @Sendable (BackendDeckCoreSecurityCallContext, String, NativeRPCValue, String?) async throws -> String
    private var toolUseInspector: ToolUseInspector?
    public func setToolUseInspector(_ inspector: @escaping ToolUseInspector) { toolUseInspector = inspector }
    /// Production calls this before attaching restored helper relays. Session tools stay
    /// closed until the saved-agent/task policy inspector replaces this bootstrap guard.
    public func holdSessionToolsUntilRestrictionsReady() {
        toolUseInspector = { context, _, _, _ in
            guard context.caller.kind != .session else {
                throw BackendDeckCoreSecurityRefusal(.notGranted, "Saved-agent session tool rules are still loading. Retry when startup finishes.")
            }
            return "independent:" + context.caller.kind.rawValue + ":" + (context.caller.keyID ?? "")
        }
    }
    private var profileConsentInspector: BackendTAGProfileConsent.Inspector?
    public func setProfileConsentInspector(_ inspector: @escaping BackendTAGProfileConsent.Inspector) { profileConsentInspector = inspector }
    private func profileBatch(tool: String, arguments: NativeRPCValue, context: BackendDeckCoreSecurityCallContext) async throws -> BackendTAGProfileConsentBatch? {
        guard let basic = BackendTAGProfileConsent.batch(tool: tool, arguments: arguments, caller: context.caller) else { return nil }
        if let inspector = profileConsentInspector {
            return BackendTAGProfileConsent.batch(tool: tool, arguments: arguments, caller: context.caller, items: try await inspector(tool, arguments, context))
        }
        if ["tasks.agents_import", "tasks_agents_import"].contains(tool) {
            throw BackendSessionFailure.missingCapability("the authorized agent import preview before consent")
        }
        return basic
    }
    public init(log: BackendDeckCoreSecurityActionLog, consent: BackendDeckCoreSecurityConsentBroker,
                policies: [BackendDeckCoreSecurityToolPolicy] = [], budgets: BackendDeckCoreSecurityBudgets = .init(),
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                driving: @escaping @Sendable () async -> Bool = { false },
                liveTools: @escaping @Sendable () throws -> [BackendDeckCoreSecurityToolPolicy] = { [] },
                onRow: (@Sendable (NativeRPCValue) async throws -> Void)? = nil,
                checkArguments: @escaping @Sendable (BackendMCPTool, NativeRPCValue) throws -> Void = { tool, args in try BackendDeckCoreCatalogueSchema.check(tool: tool, arguments: args) }) throws {
        self.log = log; self.consent = consent; self.budgets = budgets; self.now = now
        self.driving = driving; self.liveTools = liveTools; self.onRow = onRow; self.checkArguments = checkArguments
        sharedStarts = Window(budget: budgets.sessionStarts)
        var names: [String: BackendDeckCoreSecurityToolPolicy] = [:]
        for policy in policies {
            guard names[policy.tool.id] == nil && names[policy.tool.wireName] == nil else { throw NativeRPCError.invalidArguments("deck-control: two tools are called \(policy.tool.id)") }
            names[policy.tool.id] = policy; names[policy.tool.wireName] = policy
        }
        for policy in policies { for alias in policy.aliases {
            guard names[alias] == nil else { throw NativeRPCError.invalidArguments("deck-control: the old name \(alias) is taken") }; names[alias] = policy
        } }
        catalogue = policies; specs = names
    }
    public func register(_ policies: [BackendDeckCoreSecurityToolPolicy]) throws {
        var names = specs
        for policy in policies {
            guard names[policy.tool.id] == nil && names[policy.tool.wireName] == nil else { throw NativeRPCError.invalidArguments("deck-control: two tools are called \(policy.tool.id)") }
            names[policy.tool.id] = policy; names[policy.tool.wireName] = policy
        }
        for policy in policies { for alias in policy.aliases {
            guard names[alias] == nil else { throw NativeRPCError.invalidArguments("deck-control: the old name \(alias) is taken") }; names[alias] = policy
        } }
        specs = names; catalogue += policies
    }
    public func tools() -> [BackendDeckCoreSecurityToolPolicy] { catalogue + live() }
    private func live() -> [BackendDeckCoreSecurityToolPolicy] {
        guard let offered = try? liveTools() else { return [] }; var taken: Set<String> = []
        return offered.filter { policy in
            guard specs[policy.tool.id] == nil && specs[policy.tool.wireName] == nil && !taken.contains(policy.tool.id) && !taken.contains(policy.tool.wireName) else { return false }
            taken.insert(policy.tool.id); taken.insert(policy.tool.wireName); return true
        }
    }
    public func policy(named name: String) -> BackendDeckCoreSecurityToolPolicy? { specs[name] ?? live().first { $0.tool.id == name || $0.tool.wireName == name } }
    public func starterOf(sessionID: String) -> String? { started.starter(sessionID) }
    public func copilotSessions() -> [String] { started.copilotSessions() }
    public func unattendedCall(name: String, arguments: NativeRPCValue, cancellation: BackendMCPCancellation = .init()) async -> BackendDeckCoreSecurityCallResult {
        await call(name: name, arguments: arguments, options: .init(attended: false, cancellation: cancellation))
    }
    public func call(name: String, arguments raw: NativeRPCValue, options: BackendDeckCoreSecurityCallOptions = .init()) async -> BackendDeckCoreSecurityCallResult {
        let at = now(); let id = UUID().uuidString.lowercased(); let caller = options.caller
        // Distinct identity per call, even when a routine shares its shutdown
        // signal across simultaneous operations. The native handler-context
        // authority can therefore resolve two real calls independently.
        let cancellation = BackendMCPCancellation()
        let parentObserver = options.cancellation.observe { cancellation.cancel() }
        defer { options.cancellation.removeObserver(parentObserver) }
        let args = raw.fields == nil ? NativeRPCValue.object([]) : raw
        var scrubbed = BackendDeckCoreSecurityActionLog.scrubArguments(args)
        func record(tool: String, tier: BackendMCPTier, baseTier: BackendMCPTier? = nil, summary: String,
                    outcome: BackendDeckCoreSecurityActionOutcome, confirmed: BackendDeckCoreSecurityConfirmation,
                    result: NativeRPCValue? = nil, error: String? = nil, refusal: BackendDeckCoreSecurityRefusalReason? = nil,
                    value: NativeRPCValue = .null) async -> BackendDeckCoreSecurityCallResult {
            let prefix = caller.kind == .key ? "From “\(caller.keyName ?? "an AI app")”: " : ""
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            // The sentence and the tool's own summary quote what was typed, so
            // they are hidden like the arguments (#27, #28).
            let detail = BackendDeckCoreSecurityActionLog.hideSecrets(Self.detailFor(summary: prefix + summary, outcome: outcome, confirmed: confirmed, error: error))
            let row = NativeRPCValue.object([.init("at", .string(formatter.string(from: Date(timeIntervalSince1970: at / 1000)))),
                .init("action", .string("tool." + tool)), .init("detail", .string(detail)),
                .init("sessionId", args["sessionId"].string.map(NativeRPCValue.string) ?? .missing), .init("id", .string(id)), .init("tool", .string(tool)),
                .init("tier", .string(tier.rawValue)), .init("baseTier", baseTier.map { .string($0.rawValue) } ?? .missing), .init("args", scrubbed),
                .init("outcome", .string(outcome.rawValue)), .init("confirmed", confirmed.wireValue), .init("caller", caller.wireValue),
                .init("ms", .number(now() - at)), .init("result", result.map { BackendDeckCoreSecurityActionLog.scrubResult($0) } ?? .null), .init("error", error.map(NativeRPCValue.string) ?? .null)])
            let written = await log.record(row)
            if let onRow { try? await onRow(written) }
            return .init(ok: outcome == .ok, value: value, error: error, refusal: refusal, row: written)
        }
        let policy = policy(named: name)
        if policy?.tool.id == "tools.run" {
            do {
                let target = try BackendDeckCoreCatalogueRunTarget.parse(args)
                if let inner = self.policy(named: target.name), inner.tool.id != "tools.run", inner.visible(to: options.granted, caller: caller) {
                    return await call(name: inner.tool.id, arguments: target.arguments, options: options.with(reason: args["reason"].string))
                }
                scrubbed = .object([.init("name", .string(target.name))])
                let problem = self.policy(named: target.name)?.tool.id == "tools.run" ? "tools_run runs other tools; name the tool you want to run instead" : (caller.kind == .session && target.name.hasPrefix("sessions") ? BackendSessionDirectory.toolRefusal : "no tool called \(target.name)")
                return await record(tool: "tools.run", tier: .read, summary: "Run \(target.name)", outcome: .error, confirmed: .init(required: false), error: problem)
            } catch {
                scrubbed = .object([])
                return await record(tool: "tools.run", tier: .read, summary: "Run a tool", outcome: .error, confirmed: .init(required: false), error: error.localizedDescription)
            }
        }
        guard let policy else { return await record(tool: name, tier: .read, summary: "Call \(name)", outcome: .error, confirmed: .init(required: false), error: "there is no tool called \(name)") }
        let native = BackendMCPCallContext(sessionID: caller.sessionID ?? "", machineID: caller.machineID ?? "", projectRoot: caller.projectRoot,
            attended: options.attended, allowedTools: options.granted ?? Set(tools().flatMap { [$0.tool.id, $0.tool.wireName] }), allowedTiers: caller.tiers, cancellation: cancellation)
        let started = self.started; let starter = caller.starter
        let context = BackendDeckCoreSecurityCallContext(native: native, caller: caller, callID: id, attended: options.attended,
            granted: options.granted, sessionLimits: options.sessionLimits, now: now,
            startedByCopilot: { started.starter($0) == starter }, noteStarted: { started.note($0, starter: starter) }, relaySessionProof: options.relaySessionProof)
        if let proof = options.relaySessionProof {
            do { try proof.claim(callID: id, caller: caller, native: native, granted: options.granted, tool: policy.tool.id, arguments: args) }
            catch {
                return await record(tool: policy.tool.id, tier: policy.tool.tier, summary: "Verify helper session", outcome: .refused,
                    confirmed: .init(required: false), error: "The authenticated helper session cannot authorize this tool call.", refusal: .notGranted)
            }
            guard toolUseInspector != nil else {
                return await record(tool: policy.tool.id, tier: policy.tool.tier, summary: "Load helper session rules", outcome: .refused,
                    confirmed: .init(required: false), error: "Saved-agent session tool rules are not ready.", refusal: .notGranted)
            }
        }
        if let redact = policy.redactArgs, let redacted = try? redact(args) { scrubbed = BackendDeckCoreSecurityActionLog.scrubArguments(redacted) }
        let summary = (try? policy.summary(args, context)) ?? "Run \(policy.tool.id)"
        var tier = policy.tool.tier; var mustAnswer = false
        if let must = policy.ownerMustAnswer { do { mustAnswer = try must(args) } catch { mustAnswer = true } }
        if BackendTAGProfileConsent.honorsStandingKey(tool: policy.tool.id, arguments: args, caller: caller) { mustAnswer = false }
        if Self.hootModeDecides(tool: policy.tool.id, caller: caller) { mustAnswer = false }
        if mustAnswer { tier = .alter }
        if let escalate = policy.escalate { do { if let higher = try escalate(args, context), Self.rank(higher) > Self.rank(tier) { tier = higher } } catch { tier = .alter } }
        let baseTier: BackendMCPTier? = tier == policy.tool.tier ? nil : policy.tool.tier
        func stopped(_ reason: BackendDeckCoreSecurityRefusalReason, _ message: String, required: Bool? = nil) async -> BackendDeckCoreSecurityCallResult {
            await record(tool: policy.tool.id, tier: tier, baseTier: baseTier, summary: summary, outcome: .refused,
                confirmed: .init(required: required ?? (tier == .alter), reason: reason), error: message, refusal: reason)
        }
        if !caller.tiers.contains(tier) { return await stopped(.notGranted, Self.notGranted(caller: caller, tool: policy.tool.id, tier: tier), required: false) }
        if Self.refusedWhileDriving(policy.tool.id) {
            if await driving() { return await stopped(.whileDriving, Self.refusalSentence(.whileDriving, tool: policy.tool.id)) }
        }
        // Visibility is checked by the transport before logging, and again for direct in-process keys.
        if !policy.visible(to: options.granted, caller: caller) { return await record(tool: policy.tool.id, tier: .read, summary: "Call \(name)", outcome: .error, confirmed: .init(required: false), error: caller.kind == .session && policy.tool.id.hasPrefix("sessions.") ? BackendSessionDirectory.toolRefusal : "no tool called \(name)") }
        let windowKey = windowFor(caller, at: at)
        var window = callerWindows[windowKey] ?? Windows(budgets)
        func storeWindows(_ value: Windows) { callerWindows[windowKey] = value }
        let allTaken = window.all.take(at); storeWindows(window)
        if !allTaken { return await stopped(.rateLimited, "too many tool calls in the last minute; slow down and try again") }
        var toolUseStamp: String?
        do {
            try checkArguments(policy.tool, args); try policy.precheck?(args, context)
            toolUseStamp = try await toolUseInspector?(context, policy.tool.id, args, nil)
            try await policy.precheckAsync?(args, context)
        }
        catch let refusal as BackendDeckCoreSecurityRefusal { return await stopped(refusal.reason, refusal.message) }
        catch { return await record(tool: policy.tool.id, tier: tier, baseTier: baseTier, summary: summary, outcome: .error, confirmed: .init(required: tier == .alter), error: error.localizedDescription) }
        if tier == .alter && !options.attended { return await stopped(.unattended, Self.refusalSentence(.unattended, tool: policy.tool.id)) }
        if tier != .read {
            if policy.tool.id == "browser.step" {
                let taken = window.browser.take(at); storeWindows(window)
                if !taken { return await stopped(.rateLimited, "too many browser steps in the last five minutes; pause before carrying on") }
            } else if policy.spendsDeviceInput {
                let taken = window.devices.take(at); storeWindows(window)
                if !taken { return await stopped(.rateLimited, "too many taps, swipes and keystrokes on a device in the last few minutes; pause, look at the screen with devices.tree, then carry on") }
            } else {
                let taken = window.changes.take(at); storeWindows(window)
                if !taken { return await stopped(.rateLimited, "too many changes in the last few minutes; ask the person to act instead") }
            }
        }
        if ["sessions.start", "sessions.start_agent"].contains(policy.tool.id)
            || policy.tool.id == "sessions.conversations" && ["start", "resume"].contains(args["do"].string ?? "") {
            let taken: Bool
            if caller.kind == .key { taken = window.starts.take(at); storeWindows(window) } else { taken = sharedStarts.take(at) }
            if !taken { return await stopped(.rateLimited, "too many sessions started recently; each one costs money, so this is capped") } }
        var confirmation = BackendDeckCoreSecurityConfirmation(required: false)
        if tier == .alter {
            // No card: the calling AI's own permission setting decided asking before it called (see `standing`).
            confirmation = Self.standing(caller, at: now())
        }
        if cancellation.isCancelled { return await stopped(.callerGone, Self.refusalSentence(.callerGone, tool: policy.tool.id, keyed: caller.kind == .key)) }
        // A domain handler that only knows its effective tier/prompt after its own
        // async prechecks enters THIS call once (prepareEffect/recordEffect); the
        // one row below then carries the effective tier, consent and summary.
        do {
            let checkedStamp = try await toolUseInspector?(context, policy.tool.id, args, toolUseStamp)
            guard checkedStamp == toolUseStamp else { throw BackendDeckCoreSecurityRefusal(.notGranted, "This tool request’s verified agent binding changed.") }
        }
        catch { return await stopped(.notGranted, "This agent’s current Deck tool rules refuse this operation.", required: false) }
        if cancellation.isCancelled { return await stopped(.callerGone, Self.refusalSentence(.callerGone, tool: policy.tool.id)) }
        let lease = BackendDeckCoreSecurityEffectLease(cancellation: cancellation)
        effects[id] = Effect(tool: policy.tool, arguments: args, redacted: policy.redactArgs.flatMap { try? $0(args) }, scrubbed: scrubbed,
            caller: caller, attended: options.attended, cancellation: cancellation, lease: lease, spendsDeviceInput: policy.spendsDeviceInput, toolUseStamp: toolUseStamp,
            coveredTier: tier, tier: tier, confirmation: confirmation, summary: summary,
            reason: options.reason ?? args["reason"].string)
        defer { lease.end(); effects[id] = nil }
        func settled() -> (tier: BackendMCPTier, base: BackendMCPTier?, summary: String, confirmed: BackendDeckCoreSecurityConfirmation, effect: Effect?) {
            let effect = effects[id], final = effect?.tier ?? tier
            return (final, final == policy.tool.tier ? nil : policy.tool.tier, effect?.summary ?? summary, effect?.confirmation ?? confirmation, effect)
        }
        do {
            let operation = Task { try await policy.run(args, context) }
            let observer = cancellation.observe { operation.cancel() }
            defer { cancellation.removeObserver(observer) }
            let output = try await operation.value
            let end = settled()
            if let refused = end.effect?.refusal {
                return await record(tool: policy.tool.id, tier: end.tier, baseTier: end.base, summary: end.summary, outcome: .refused, confirmed: end.confirmed, error: refused.message, refusal: refused.reason)
            }
            return await record(tool: policy.tool.id, tier: end.tier, baseTier: end.base, summary: end.summary, outcome: .ok, confirmed: end.confirmed, result: end.effect?.recorded ?? output.summary, value: output.value)
        } catch let refusal as BackendDeckCoreSecurityRefusal {
            let end = settled(), refused = end.effect?.refusal ?? refusal
            return await record(tool: policy.tool.id, tier: end.tier, baseTier: end.base, summary: end.summary, outcome: .refused, confirmed: end.confirmed, error: refused.message, refusal: refused.reason)
        } catch {
            let end = settled()
            if cancellation.isCancelled {
                return await record(tool: policy.tool.id, tier: end.tier, baseTier: end.base, summary: end.summary, outcome: .refused,
                    confirmed: .init(required: end.tier == .alter, reason: .callerGone), error: Self.refusalSentence(.callerGone, tool: policy.tool.id, keyed: caller.kind == .key), refusal: .callerGone)
            }
            if let refused = end.effect?.refusal {
                return await record(tool: policy.tool.id, tier: end.tier, baseTier: end.base, summary: end.summary, outcome: .refused, confirmed: end.confirmed, error: refused.message, refusal: refused.reason)
            }
            return await record(tool: policy.tool.id, tier: end.tier, baseTier: end.base, summary: end.summary, outcome: .error, confirmed: end.confirmed, error: error.localizedDescription)
        }
    }

    /// The allowance a caller spends from: its key, its session (on its machine), its paired device, or the
    /// local caller (Hoot's session or the window). Allowances nobody used for a whole window are dropped.
    private func windowFor(_ caller: BackendDeckCoreSecurityCaller, at: Double) -> String {
        if callerWindows.count > 64 { callerWindows = callerWindows.filter { !$0.value.idle(at) } }
        switch caller.kind {
        case .key: return "key:" + (caller.keyID ?? "")
        case .session: return "session:" + (caller.machineID ?? "") + "/" + (caller.sessionID ?? "")
        case .remote: return "device:" + (caller.deviceID ?? "")
        case .local: return "local:" + (caller.sessionID ?? "")
        }
    }

    // MARK: Prepared effect (delegated effective policy gate)

    /// Enter the running call `context.callID` once with the effective tier a
    /// domain handler computed after its async prechecks. Binds this call's
    /// tool and arguments (redaction markers like "[redacted]" may stand for a
    /// value), takes only the budget/consent the call has not covered yet, and
    /// expires with that call's cancellation. A refusal is recorded in the
    /// call's one row; nothing here writes a second row or runs a nested call.
    public func prepareEffect(context: BackendDeckCoreSecurityCallContext, tool: String, arguments: NativeRPCValue,
                              tier requested: BackendMCPTier, sentence: String, ownerMustAnswer: Bool) async throws -> BackendDeckCoreSecurityEffectProof {
        let callID = context.callID
        guard var effect = effects[callID], !effect.cancellation.isCancelled, !context.cancellation.isCancelled else {
            throw BackendSessionFailure.missingCapability("a current deck-control call for this operation")
        }
        guard Self.sameCaller(effect.caller, context.caller), context.attended == effect.attended,
              tool == effect.tool.id || tool == effect.tool.wireName,
              Self.argumentsBound(arguments, to: effect.arguments) || effect.redacted.map({ Self.argumentsBound(arguments, to: $0) }) == true else {
            throw NativeRPCError(code: "access-denied", message: "This effect does not match the deck-control call it claims.")
        }
        var tier = effect.tier
        if Self.rank(requested) > Self.rank(tier) { tier = requested }
        let mustAnswer = ownerMustAnswer && !BackendTAGProfileConsent.honorsStandingKey(tool: effect.tool.id, arguments: arguments, caller: effect.caller)
            && !Self.hootModeDecides(tool: effect.tool.id, caller: effect.caller)
        if mustAnswer { tier = .alter }
        // Read paths recheck access around suspended work. Those checks do not
        // consume the single mutation entry, and each still verifies live rules.
        guard !effect.entered else {
            throw NativeRPCError(code: "access-denied", message: "This deck-control call's effect was already entered; it is entered exactly once.")
        }
        if tier != .read { effect.entered = true; effects[callID] = effect }
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = trimmed.isEmpty ? effect.summary : trimmed
        let caller = effect.caller
        func refuse(_ reason: BackendDeckCoreSecurityRefusalReason, _ message: String,
                    confirmed: BackendDeckCoreSecurityConfirmation? = nil) -> BackendDeckCoreSecurityRefusal {
            let refusal = BackendDeckCoreSecurityRefusal(reason, message)
            if var current = effects[callID] {
                current.tier = tier; current.summary = summary
                current.confirmation = confirmed ?? .init(required: tier == .alter, reason: reason)
                current.refusal = refusal; effects[callID] = current
            }
            return refusal
        }
        if !caller.tiers.contains(tier) {
            throw refuse(.notGranted, Self.notGranted(caller: caller, tool: effect.tool.id, tier: tier), confirmed: .init(required: false, reason: .notGranted))
        }
        if tier == .alter && !effect.attended { throw refuse(.unattended, Self.refusalSentence(.unattended, tool: effect.tool.id)) }
        if tier != .read && effect.coveredTier == .read {
            let at = now()
            let windowKey = windowFor(caller, at: at)
            var window = callerWindows[windowKey] ?? Windows(budgets)
            let browserStep = effect.tool.id == "browser.step"
            let taken = browserStep ? window.browser.take(at) : effect.spendsDeviceInput ? window.devices.take(at) : window.changes.take(at)
            callerWindows[windowKey] = window
            if !taken {
                throw refuse(.rateLimited, browserStep ? "too many browser steps in the last five minutes; pause before carrying on" : effect.spendsDeviceInput
                    ? "too many taps, swipes and keystrokes on a device in the last few minutes; pause, look at the screen with devices.tree, then carry on"
                    : "too many changes in the last few minutes; ask the person to act instead")
            }
        }
        var confirmation = effect.confirmation
        let covered = confirmation.required && confirmation.granted
        if tier == .alter && !covered {
            // No card (Asad, 11 Oct): the calling AI's own permission setting decided asking (see `standing`).
            confirmation = Self.standing(caller, at: now())
        }
        if effect.cancellation.isCancelled || context.cancellation.isCancelled {
            throw refuse(.callerGone, Self.refusalSentence(.callerGone, tool: effect.tool.id, keyed: caller.kind == .key),
                confirmed: .init(required: confirmation.required, granted: false, by: confirmation.by, at: confirmation.at, reason: .callerGone))
        }
        do {
            let stamp = try await toolUseInspector?(context, effect.tool.id, effect.arguments, effect.toolUseStamp)
            guard stamp == effect.toolUseStamp else { throw BackendDeckCoreSecurityRefusal(.notGranted, "This tool request’s verified agent binding changed.") }
        } catch { throw refuse(.notGranted, "This agent’s current Deck tool rules refuse this effect.") }
        guard !effect.cancellation.isCancelled, !context.cancellation.isCancelled else { throw refuse(.callerGone, "This tool request is no longer current.") }
        guard var current = effects[callID] else { throw BackendSessionFailure.missingCapability("a current deck-control call for this operation") }
        if tier == .read, current.entered {
            throw NativeRPCError(code: "access-denied", message: "This deck-control call has already entered a change.")
        }
        let proof = BackendDeckCoreSecurityEffectProof(id: UUID(), callID: callID, tool: effect.tool.id, tier: tier,
            arguments: arguments, lease: effect.lease)
        current.tier = tier; current.summary = summary; current.confirmation = confirmation; current.proof = proof
        effects[callID] = current
        return proof
    }

    /// The key already passed the change gate and may have applied narrowing.
    /// Widening is a separate exact owner decision in this SAME call, never a
    /// standing/key-kind grant and never a second mutation-budget charge.
    public func approveProfileWidening(context: BackendDeckCoreSecurityCallContext,
                                       arguments: NativeRPCValue, summary: String) async throws {
        let callID = context.callID
        let profileSave = ["tasks.agents", "tasks_agents"].contains(effects[callID]?.tool.id ?? "") &&
            ["save", "save-many"].contains(arguments["do"].string ?? "")
        let publicFields = Set(BackendAGOPTProfileFields.profile.keys).union(BackendAGOPTProfileFields.efficiency.keys).union(["mcp_servers"])
        let currentTool = effects[callID]?.tool.id ?? ""
        let field = arguments["field"].string ?? ""
        let budgetFields: Set<String> = ["monthly_token_budget", "monthly_budget_usd", "warn_percent", "on_exhaustion", "per_task_token_budget"]
        let settingsField = (currentTool == "agents.settings_set" && publicFields.contains(field) ||
            currentTool == "agents.budget_set" && budgetFields.contains(field)) &&
            arguments["id"].string?.isEmpty == false &&
            arguments.has("value")
        guard let effect = effects[callID], effect.entered, effect.proof?.tier == .alter,
              profileSave || settingsField,
              Self.sameCaller(effect.caller, context.caller), effect.caller.kind == .key,
              effect.caller.tasks, let keyID = effect.caller.keyID,
              effect.caller.tiers.contains(.alter), effect.attended,
              arguments == effect.arguments,
              !effect.cancellation.isCancelled, !context.cancellation.isCancelled else {
            throw NativeRPCError(code: "access-denied", message: "This widening request has no current permitted profile-change call.")
        }
        func refuse(_ reason: BackendDeckCoreSecurityRefusalReason, _ message: String) -> BackendDeckCoreSecurityRefusal {
            if var current = effects[callID] {
                current.tier = .alter; current.summary = summary
                current.confirmation = .init(required: true, reason: reason)
                current.refusal = BackendDeckCoreSecurityRefusal(reason, message); effects[callID] = current
            }
            return BackendDeckCoreSecurityRefusal(reason, message)
        }
        // No card (Asad, 11 Oct): the widening a key's own AI asked for runs as a standing approval and is recorded.
        _ = keyID
        guard var current = effects[callID] else { throw refuse(.callerGone, "The profile-change call ended.") }
        current.tier = .alter; current.summary = summary
        current.confirmation = Self.standing(effect.caller, at: now())
        effects[callID] = current
    }

    /// Record the result summary of the effect accepted for `context.callID`
    /// into that call's one row. Exactly once, same tool and arguments.
    public func recordEffect(context: BackendDeckCoreSecurityCallContext, tool: String, arguments: NativeRPCValue, summary: NativeRPCValue) throws {
        guard let proof = effects[context.callID]?.proof else {
            throw BackendSessionFailure.missingCapability("an accepted effect for this deck-control call")
        }
        try recordEffect(proof: proof, context: context, tool: tool, arguments: arguments, summary: summary)
    }
    public func recordEffect(proof: BackendDeckCoreSecurityEffectProof, context: BackendDeckCoreSecurityCallContext,
                             tool: String, arguments: NativeRPCValue, summary: NativeRPCValue) throws {
        guard proof.callID == context.callID, var effect = effects[proof.callID], effect.proof?.id == proof.id,
              !proof.isExpired, !context.cancellation.isCancelled, effect.refusal == nil else {
            throw BackendSessionFailure.missingCapability("a current accepted effect for this deck-control call")
        }
        guard Self.sameCaller(effect.caller, context.caller), tool == proof.tool || tool == effect.tool.wireName, arguments == proof.arguments else {
            throw NativeRPCError(code: "access-denied", message: "This result does not belong to the accepted effect.")
        }
        guard effect.recorded == nil else {
            throw NativeRPCError(code: "access-denied", message: "This deck-control call's result was already recorded.")
        }
        effect.recorded = summary; effects[proof.callID] = effect
    }

    /// The concrete `BackendCompositionCoreGate` over this one control.
    public nonisolated func compositionGate() -> BackendCompositionCoreGate {
        BackendCompositionCoreGate(authorize: { [self] context, tool, arguments, tier, sentence, ownerMustAnswer in
            _ = try await self.prepareEffect(context: context, tool: tool, arguments: arguments, tier: tier, sentence: sentence, ownerMustAnswer: ownerMustAnswer)
        }, record: { [self] context, tool, arguments, summary in
            try await self.recordEffect(context: context, tool: tool, arguments: arguments, summary: summary)
        })
    }

    nonisolated static func sameCaller(_ a: BackendDeckCoreSecurityCaller, _ b: BackendDeckCoreSecurityCaller) -> Bool {
        a.kind == b.kind && a.deviceID == b.deviceID && a.keyID == b.keyID && a.sessionID == b.sessionID &&
        a.machineID == b.machineID && a.projectRoot == b.projectRoot && a.taskProject == b.taskProject && a.tiers == b.tiers
    }
    /// Every value equals the call's own argument, except a redaction marker
    /// string ("[…]") which may stand for any value (or an absent one).
    public nonisolated static func argumentsBound(_ given: NativeRPCValue, to raw: NativeRPCValue, depth: Int = 0) -> Bool {
        if given == raw { return true }
        guard depth < 32 else { return false }
        if let text = given.string, text.count >= 2, text.hasPrefix("["), text.hasSuffix("]") { return true }
        if let givenFields = given.fields, let rawFields = raw.fields {
            let keys = Set(givenFields.map(\.key)).union(rawFields.map(\.key))
            return keys.allSatisfy { argumentsBound(given[$0], to: raw[$0], depth: depth + 1) }
        }
        if let givenItems = given.elements, let rawItems = raw.elements, givenItems.count == rawItems.count {
            return zip(givenItems, rawItems).allSatisfy { argumentsBound($0, to: $1, depth: depth + 1) }
        }
        return false
    }
    /// Asad, 11 Oct ("full capabilities… only his own settings guarded"): Hoot's phone and simulator actions and
    /// stopping or resuming an agent are not raised to a change by the Bypass the person chose (their tier stays).
    nonisolated static func hootModeDecides(tool: String, caller: BackendDeckCoreSecurityCaller) -> Bool {
        caller.kind == .local && caller.askFirst == false && (tool.hasPrefix("devices.") || ["agents.stop", "agents.resume"].contains(tool))
    }
    /// Asad, 11 Oct: "app itself will not ask any permissions at all it all depends on ai model settings directly" (and
    /// "any kind of restrictions we designed for reasons they will stay"). The app never shows an approval card for a
    /// tool call: whether anything is asked is the calling AI's own permission setting (Claude's mode through its own
    /// prompt, Codex's approval policy, Gemini's setting, an outside AI app's own prompts). A call the caller may make
    /// runs and is recorded as a standing approval. Every refusal stays: grants and tiers, folders, Hoot's own settings,
    /// while driving, unattended changes, the rate guards, and the profile checks that refuse.
    nonisolated static func standing(_ caller: BackendDeckCoreSecurityCaller, at: Double) -> BackendDeckCoreSecurityConfirmation {
        let by: String
        if caller.kind == .key, let key = caller.keyID { by = "standing:key:" + key }
        else if caller.kind == .local && caller.askFirst == false { by = "standing:hoot-bypass" }
        else { by = "standing:ai-setting" }
        return .init(required: true, granted: true, by: by, at: at)
    }
    private nonisolated static func rank(_ tier: BackendMCPTier) -> Int { tier == .alter ? 2 : tier == .act ? 1 : 0 }
    public nonisolated static let notWhileDriving = ["sessions.send", "sessions.start", "readiness.ask_ai", "sessions.stop", "sessions.keys", "sessions.rename", "sessions.account", "sessions.held", "settings.write", "settings.reset", "agents.set_control", "accounts.sign_in", "updates.install", "tour.play", "ui.do", "hoot.run", "machines.session", "servers.shell", "routines."]
    public nonisolated static func refusedWhileDriving(_ id: String) -> Bool { notWhileDriving.contains { $0.hasSuffix(".") ? id.hasPrefix($0) : id == $0 } }
    public nonisolated static func detailFor(summary: String, outcome: BackendDeckCoreSecurityActionOutcome, confirmed: BackendDeckCoreSecurityConfirmation, error: String?) -> String {
        if outcome == .ok {
            if !confirmed.granted { return summary + " — done" }
            if confirmed.by?.hasPrefix("standing:") == true { return summary + " — done without asking here; the AI's own permission setting decides asking" }
            return summary + (confirmed.by?.hasPrefix("device:") == true ? " — allowed on a connected device" : " — allowed by the person")
        }
        if outcome == .refused { return summary + " — refused" + (confirmed.reason.map { " (\($0.rawValue))" } ?? "") }
        return summary + " — failed" + (error.map { ": " + $0 } ?? "")
    }
    public nonisolated static func notGranted(caller: BackendDeckCoreSecurityCaller, tool: String, tier: BackendMCPTier) -> String {
        if caller.kind == .key {
            if caller.tiers.isEmpty { return "\(tool) was refused: the access key this app is using has been revoked. Nothing was changed, and retrying will not help." }
            let level = caller.tiers.contains(.alter) ? "Full control" : caller.tiers.contains(.act) ? "Work" : "Look only"
            let needs = tier == .alter ? "Full control" : tier == .act ? "Work or Full control" : "any level"
            return "\(tool) needs a key set to \(needs), and the key this app is using is set to \(level). Nothing was changed. Only the owner can change what a key allows, in Settings on their Mac, so do not retry: answer with what you can do, and say what you would need."
        }
        let allowed: [BackendMCPTier] = [.read, .act, .alter]
        let has = caller.tiers.isEmpty ? "It has not been given any access to Hoot’s tools at all." : "It has \(allowed.filter { caller.tiers.contains($0) }.map(\.rawValue).joined(separator: " and ")) access only."
        return "\(tool) needs \(tier.rawValue) access and this device does not have it. \(has) Nothing was changed. This cannot be granted from here — it is a switch on the desktop, in Settings, so do not retry: answer with what you can already see, and say what you would need permission for."
    }
    public nonisolated static func refusalSentence(_ reason: BackendDeckCoreSecurityRefusalReason, tool: String, keyed: Bool = false) -> String {
        if keyed {
            switch reason {
            case .timeout: return "\(tool) needs the owner to approve it, and nobody answered within 45 seconds — not at their Mac and not on their phone. Nothing was changed. Do not retry in a loop: tell them what you wanted to do and why, so they can approve it when they are there, or do it themselves."
            case .noApprover: return "\(tool) needs the owner to approve it, and there is nowhere to ask them right now: the app’s window is not open on their Mac and no phone of theirs is connected. Nothing was changed. Tell them what you wanted to do."
            case .approverGone: return "\(tool) needs the owner's approval, and the window asking them closed before they answered. Nothing was changed."
            case .declined: return "\(tool) was turned down by the owner. Nothing was changed. Do not try it again unless they ask you to."
            case .callerGone: return "\(tool) was cancelled: the connection dropped while the owner was being asked. Nothing was changed."
            default: break
            }
        }
        switch reason {
        case .declined: return "\(tool) was not approved. Do not try it again unless you are asked to."
        case .timeout: return "\(tool) needs the person at the keyboard to confirm it, and nobody answered. Tell them what you were trying to do and let them decide."
        case .noApprover: return "\(tool) needs the person at the keyboard to confirm it, and there is no window open to ask. Nothing was changed."
        case .approverGone: return "\(tool) needs a confirmation, and the window closed before it was answered. Nothing was changed."
        case .shuttingDown: return "\(tool) was not run: the app is closing."
        case .callerGone: return "\(tool) was cancelled: the connection dropped while the confirmation was still on screen. Nothing was changed."
        case .tooManyPending: return "\(tool) was refused because too many confirmations are already waiting. Finish those first."
        case .rateLimited: return "\(tool) was refused: too many calls too quickly."
        case .notPermitted: return "\(tool) is not permitted with those arguments."
        case .notGranted: return "\(tool) is not something this device has been given permission to do. Nothing was changed, and asking again will not help."
        case .unattended: return "\(tool) needs a person to confirm it, and this run is a routine with nobody at the machine, so it cannot be confirmed at all. Do not retry it and do not look for another way to do it. Say in your report what you would have done and why, and leave the decision to them."
        case .whileDriving: return "\(tool) cannot run while a tour is playing on their screen. Things are moving that they did not do, so anything you changed now is a change they could not attribute to you or to the tour. Nothing was changed. Wait until the tour ends and ask again then — say what you are waiting to do, if it matters."
        }
    }
}
