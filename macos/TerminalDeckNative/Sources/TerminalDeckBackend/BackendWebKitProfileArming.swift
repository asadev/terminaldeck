import Foundation
import TerminalDeckNativeCore

public enum BackendWebKitProfileArmingBaton: String, Sendable { case unclaimed, agent, human }

/// Only the source's resource-kind rules are accepted. A WebKit block list
/// cannot synthesize response bytes or distinguish fetch from XHR faithfully.
public struct BackendWebKitProfileArmingRulePlan: Sendable {
    public let rules: NativeRPCValue
    public let blockedKinds: [String]
    public let origin: String?
    public let encodedRules: String
    public var needsInstallation: Bool { !blockedKinds.isEmpty }
    public var wireValue: NativeRPCValue { .object([
        .init("rules", rules), .init("blockedKinds", .array(blockedKinds.map(NativeRPCValue.string))),
        .init("origin", origin.map(NativeRPCValue.string) ?? .null), .init("contentRuleList", .bool(needsInstallation)),
        .init("requestInterception", .bool(false)), .init("fulfillment", .bool(false)), .init("counts", .null)
    ]) }
    public static func make(rules raw: NativeRPCValue, pageURL: URL) throws -> Self {
        let resourceTypes = ["image": "image", "media": "media", "font": "font", "stylesheet": "style-sheet", "script": "script"]
        let kinds = ["image", "media", "font", "stylesheet", "script", "xhr", "fetch"]
        _ = try raw.requireObject("profile request rules")
        var normalized = NativeRPCValue.object([]), blocked: [String] = []
        for field in raw.fields ?? [] {
            let kind = field.key.lowercased()
            guard kinds.contains(kind) else { throw BackendBrowserScrapingError.invalid("Unknown request kind: \(field.key).") }
            if field.value.isNullish { continue }
            let action = field.value.string?.lowercased() == "cheap" ? "fulfill" : field.value.string?.lowercased()
            guard let action, ["allow", "block", "fulfill"].contains(action) else {
                throw BackendBrowserScrapingError.invalid("\(field.key) must be allow, block or fulfill.")
            }
            guard action != "fulfill" else {
                throw BackendBrowserScrapingError.unsupported("WebKit cannot fulfill \(kind) with replacement response bytes. The requested policy was not installed.")
            }
            if action == "block", resourceTypes[kind] == nil {
                throw BackendBrowserScrapingError.unsupported("WebKit cannot faithfully distinguish and block the source's \(kind) kind. No broader raw-resource rule was substituted.")
            }
            normalized = normalized.setting(kind, .string(action))
        }
        normalized = .object(kinds.compactMap { normalized.has($0) ? .init($0, normalized[$0]) : nil })
        blocked = kinds.filter { normalized[$0].string == "block" }
        guard !blocked.isEmpty else { return Self(rules: normalized, blockedKinds: [], origin: BackendBrowserOrigin.exact(pageURL.absoluteString), encodedRules: "[]") }
        guard let origin = BackendBrowserOrigin.exact(pageURL.absoluteString), let host = pageURL.host,
              let scheme = pageURL.scheme?.lowercased() else {
            throw BackendBrowserScrapingError.unsupported("Request blocking is supported only on an exact HTTP(S) top-page origin.")
        }
        let safeHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let prefix = "^" + NSRegularExpression.escapedPattern(for: scheme + "://" + safeHost)
        let port = pageURL.port ?? (scheme == "https" ? 443 : 80)
        let defaults = scheme == "https" ? 443 : 80
        let topURLs = port == defaults ? [prefix + "/", prefix + ":\(port)/"] : [prefix + ":\(port)/"]
        let value = NativeRPCValue.array(blocked.map { kind in
            .object([
                .init("trigger", .object([
                    .init("url-filter", .string("^https?://")),
                    .init("resource-type", .array([.string(resourceTypes[kind]!)])),
                    .init("if-top-url", .array(topURLs.map(NativeRPCValue.string)))
                ])), .init("action", .object([.init("type", .string("block"))]))
            ])
        })
        return Self(rules: normalized, blockedKinds: blocked, origin: origin, encodedRules: value.compact)
    }
}

public struct BackendWebKitProfileArmingDecision: Sendable {
    public let plan: BackendWebKitProfileArmingRulePlan
    public let capture: Bool
    public let camera: Bool
    public let coveragePattern: String
    public let limits: NativeRPCValue
    public var wanted: Bool { plan.needsInstallation || capture || camera }
    public var fingerprint: String { NativeRPCValue.object([
        .init("rules", plan.rules), .init("capture", .bool(capture)), .init("camera", .bool(camera)),
        .init("coverage", .string(coveragePattern)), .init("limits", limits)
    ]).compact }
    public static func make(settings: NativeRPCValue, pageURL: URL) throws -> Self {
        let plan = try BackendWebKitProfileArmingRulePlan.make(rules: settings["requests"].isNullish ? .object([]) : settings["requests"], pageURL: pageURL)
        let capture = settings["capture"]["on"].bool == true
        let otherwiseArmed = capture || plan.needsInstallation
        let camera = otherwiseArmed ? settings["checks"]["screenshotOnBlock"].bool != false : settings["checks"]["screenshotOnBlock"].bool == true
        let coverage = capture && settings["checks"]["coverage"]["on"].bool == true ? settings["checks"]["coverage"]["pattern"].string ?? "" : ""
        var limits = NativeRPCValue.object([.init("bodyKinds", .array([.string("xhr"), .string("fetch")]))])
        if let mb = settings["capture"]["keepMB"].number { limits = limits.setting("maxTotalBytes", .number(mb * 1_024 * 1_024)) }
        return Self(plan: plan, capture: capture, camera: camera, coveragePattern: coverage, limits: limits)
    }
}

public struct BackendWebKitProfileArmingHooks: Sendable {
    public let authorize: BackendBrowserScrapingAuthorize
    public let baton: @Sendable (BackendBrowserCaptureTarget) async throws -> BackendWebKitProfileArmingBaton
    /// Map an app-owned target to the existing real network target resolver.
    /// For pre-navigation arming the runtime must retain the approved pending
    /// navigation URL; arbitrary tools cannot manufacture that target binding.
    public let networkArguments: @Sendable (BackendBrowserCaptureTarget) async throws -> NativeRPCValue
    public let applyRules: @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget, BackendWebKitProfileArmingRulePlan) async throws -> Void
    /// Removes only this lifecycle owner's rule list; cleanup cannot be gated
    /// on a fresh consent that would leave a revoked blocking policy installed.
    public let removeRules: @Sendable (String) async throws -> Void
    public let recordBlock: @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget, URL, Int?, NativeRPCValue) async throws -> NativeRPCValue?
    public let safeText: @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget, Int) async throws -> String
    public let changed: @Sendable (String, NativeRPCValue) async -> Void
    public init(authorize: @escaping BackendBrowserScrapingAuthorize,
                baton: @escaping @Sendable (BackendBrowserCaptureTarget) async throws -> BackendWebKitProfileArmingBaton,
                networkArguments: @escaping @Sendable (BackendBrowserCaptureTarget) async throws -> NativeRPCValue,
                applyRules: @escaping @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget, BackendWebKitProfileArmingRulePlan) async throws -> Void,
                removeRules: @escaping @Sendable (String) async throws -> Void,
                recordBlock: @escaping @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget, URL, Int?, NativeRPCValue) async throws -> NativeRPCValue?,
                safeText: @escaping @Sendable (BackendBrowserScrapingCaller, BackendBrowserCaptureTarget, Int) async throws -> String,
                changed: @escaping @Sendable (String, NativeRPCValue) async -> Void) {
        self.authorize = authorize; self.baton = baton; self.networkArguments = networkArguments
        self.applyRules = applyRules; self.removeRules = removeRules; self.recordBlock = recordBlock; self.safeText = safeText; self.changed = changed
    }
}

/// Event-driven replacement for browser-profile-arm. One serialized lifecycle
/// per live tab; nothing runs for default settings, and nothing owns a debugger.
public actor BackendWebKitProfileArming {
    public struct Token: Sendable { public let tabID: String; fileprivate let generation: UUID }
    private struct Entry: Sendable {
        let generation: UUID
        let caller: BackendBrowserScrapingCaller
        var target: BackendBrowserCaptureTarget
        var held = false
        var closing = false
        var configuration = ""
        var ruleOrigin: String?
        var ruleList = false
        var runID: String?
        var camera = false
        var coveragePattern = ""
        var entriesAtPage = 0.0
        var state = "idle"
        var error = ""
        var args = NativeRPCValue.object([])
    }
    private let store: BackendBrowserScrapingStore
    private let network: BackendBrowserNetworkCapture
    private let assets: BackendBrowserScrapingAssets
    private let hooks: BackendWebKitProfileArmingHooks
    private var entries: [String: Entry] = [:]
    private var queues: [String: (id: UUID, task: Task<NativeRPCValue, any Error>)] = [:]
    public init(store: BackendBrowserScrapingStore, network: BackendBrowserNetworkCapture,
                assets: BackendBrowserScrapingAssets, hooks: BackendWebKitProfileArmingHooks) {
        self.store = store; self.network = network; self.assets = assets; self.hooks = hooks
    }

    public func watch(target: BackendBrowserCaptureTarget, caller: BackendBrowserScrapingCaller) async throws -> Token {
        guard caller.sessionID == nil, !caller.remote, caller.rpc?.caller == .nativeApp || caller.rpc?.caller == .internalEngine else {
            throw BackendBrowserScrapingError.denied("Standing profile arming is owned by the native app, not a session or device tool argument.")
        }
        _ = try BackendBrowserScrapingPaths.component(target.profileID)
        try await authorize(caller, "watch", target)
        guard entries[target.tabID] == nil else { throw NativeRPCError(code: "profile-already-watched", message: "This live tab already has a profile arming lifecycle.") }
        let token = Token(tabID: target.tabID, generation: UUID())
        entries[target.tabID] = Entry(generation: token.generation, caller: caller, target: target)
        // Watching is a lifecycle registration. An invalid saved policy is
        // reported as failed arming while its token remains closable/reusable.
        _ = try? await enqueue(token) { try await self.reconcile(token) }
        return token
    }

    /// Called and awaited before an approved navigation is allowed to proceed.
    public func navigationStarted(_ token: Token, url: URL) async throws -> NativeRPCValue {
        try await enqueue(token) {
            try await self.updateTarget(token, url: url, title: nil)
            return try await self.reconcile(token)
        }
    }
    public func navigationCommitted(_ token: Token, url: URL, title: String) async throws -> NativeRPCValue {
        try await enqueue(token) {
            try await self.updateTarget(token, url: url, title: title)
            if let held = await self.entry(token), held.runID != nil {
                let status = try await self.network.invoke(held.args.setting("action", .string("status")), caller: held.caller)
                await self.baseline(token, count: status["captured"]["entries"].number ?? 0)
            }
            return try await self.reconcile(token)
        }
    }

    public func navigationFinished(_ token: Token, requestedURL: URL, httpStatus: Int?, failure: NativeRPCValue = .null) async throws -> NativeRPCValue {
        try await enqueue(token) {
            let state = try await self.reconcile(token)
            guard let entry = await self.entry(token), !entry.held, !entry.closing else { return state }
            if entry.camera {
                try await self.authorize(entry.caller, "camera", entry.target)
                _ = try await self.hooks.recordBlock(entry.caller, entry.target, requestedURL, httpStatus, failure)
            }
            if let run = entry.runID, !entry.coveragePattern.isEmpty {
                try await self.authorize(entry.caller, "coverage", entry.target)
                let text = try await self.hooks.safeText(entry.caller, entry.target, 4_000)
                guard text.count <= 4_000 else { throw BackendBrowserScrapingError.invalid("The privacy-safe page text exceeds its requested bound.") }
                // Source person arming records nothing when a page states no
                // unambiguous total; do not fill the log with unknown checks.
                guard let stated = try await self.statedTotal(text, pattern: entry.coveragePattern) else { return state }
                let snapshot = try await self.network.invoke(entry.args.setting("action", .string("status")), caller: entry.caller)
                let observed = max(0, (snapshot["captured"]["entries"].number ?? 0) - entry.entriesAtPage)
                _ = try await self.assets.coverage(.object([
                    .init("profileId", .string(entry.target.profileID)), .init("runId", .string(run)), .init("op", .string("check")),
                    .init("text", .string(text)), .init("pattern", .string(entry.coveragePattern)), .init("captured", .number(observed)),
                    .init("stated", .number(stated)),
                    .init("what", .string("WebKit resource timing metadata observed for this page (not items or complete traffic)")),
                    .init("pageUrl", .string(entry.target.pageURL.absoluteString))
                ]), caller: entry.caller)
            }
            return try await self.report(token)
        }
    }

    public func settingsChanged(profileID: String) async {
        let targets = entries.filter { $0.value.target.profileID == profileID && !$0.value.closing }
            .map { Token(tabID: $0.key, generation: $0.value.generation) }
        for token in targets { _ = try? await enqueue(token) { try await self.reconcile(token) } }
    }

    /// The drive must await this barrier BEFORE claiming/driving the page.
    /// Mark held before awaiting any queued work, so a suspended start cannot
    /// install a new observer/rule list behind the agent's claim.
    public func yieldToDrive(_ token: Token) async throws -> NativeRPCValue {
        guard var held = entry(token) else { throw missing() }
        try await authorize(held.caller, "yield", held.target)
        held.held = true; entries[token.tabID] = held
        return try await enqueue(token) { try await self.disarm(token, state: "yielded", why: "The agent claimed this page.", reason: .humanTakeover) }
    }
    public func freedByDrive(_ token: Token) async throws -> NativeRPCValue {
        try await enqueue(token) {
            guard let held = await self.entry(token) else { throw await self.missing() }
            guard try await self.hooks.baton(held.target) == .unclaimed else {
                throw BackendBrowserScrapingError.denied("The real browser baton has not been released.")
            }
            await self.setHeld(token, false)
            return try await self.reconcile(token)
        }
    }
    public func close(_ token: Token) async throws {
        guard var held = entry(token) else { return }
        held.closing = true; held.held = true; entries[token.tabID] = held
        _ = try await enqueue(token) { try await self.disarm(token, state: "closed", why: "The tab closed.", reason: .tabClosed) }
        entries[token.tabID] = nil
    }
    public func status(_ token: Token) async throws -> NativeRPCValue {
        guard let held = entry(token) else { throw missing() }
        try await authorize(held.caller, "status", held.target)
        return try await report(token)
    }

    private func enqueue(_ token: Token, _ operation: @escaping @Sendable () async throws -> NativeRPCValue) async throws -> NativeRPCValue {
        guard entry(token) != nil else { throw missing() }
        let previous = queues[token.tabID]?.task
        let id = UUID()
        let task = Task {
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                await self.failed(token, error: error)
                throw error
            }
        }
        queues[token.tabID] = (id, task)
        defer { if queues[token.tabID]?.id == id { queues[token.tabID] = nil } }
        // A lifecycle operation completes its cleanup even if an event caller
        // goes away. The app explicitly closes/disarms its retained token.
        return try await task.value
    }
    private func entry(_ token: Token) -> Entry? {
        guard let value = entries[token.tabID], value.generation == token.generation else { return nil }; return value
    }
    private func setHeld(_ token: Token, _ held: Bool) { if entry(token) != nil { entries[token.tabID]!.held = held } }
    private func baseline(_ token: Token, count: Double) { if entry(token) != nil { entries[token.tabID]!.entriesAtPage = max(0, count) } }
    private func updateTarget(_ token: Token, url: URL, title: String?) async throws {
        guard let held = entry(token) else { throw missing() }
        let next = BackendBrowserCaptureTarget(tabID: held.target.tabID, profileID: held.target.profileID, pageURL: url, title: title ?? held.target.title)
        try await authorize(held.caller, "navigation", next)
        guard entry(token) != nil else { throw missing() }
        entries[token.tabID]!.target = next
    }
    private func reconcile(_ token: Token) async throws -> NativeRPCValue {
        guard let held = entry(token) else { throw missing() }
        if held.held || held.closing { return try await report(token) }
        do {
            try await authorize(held.caller, "reconcile", held.target)
            let baton = try await hooks.baton(held.target)
            if baton != .unclaimed { setHeld(token, true); return try await disarm(token, state: "yielded", why: "The real baton is claimed.", reason: .humanTakeover) }
            let settings = try await store.config(held.target.profileID)
            // Non-HTTP pages have no resource metadata or HTTP content rules.
            guard BackendBrowserOrigin.exact(held.target.pageURL.absoluteString) != nil else {
                return try await disarm(token, state: "idle", why: "This page has no HTTP(S) origin.")
            }
            let decision = try BackendWebKitProfileArmingDecision.make(settings: settings, pageURL: held.target.pageURL)
            guard decision.wanted else { return try await disarm(token, state: "idle", why: "The profile's settings are at defaults.") }
            if entry(token)?.configuration != decision.fingerprint { _ = try await disarm(token, state: "arming", why: "The profile configuration changed.") }
            guard let current = entry(token), !current.held, !current.closing else { return try await report(token) }
            if current.ruleOrigin != decision.plan.origin || current.ruleList != decision.plan.needsInstallation {
                try await authorize(held.caller, "rules", held.target, args: decision.plan.wireValue)
                try await hooks.applyRules(held.caller, held.target, decision.plan)
                guard entry(token)?.held == false, entry(token)?.closing == false else {
                    try await hooks.removeRules(token.tabID); return try await report(token)
                }
                entries[token.tabID]!.ruleList = decision.plan.needsInstallation; entries[token.tabID]!.ruleOrigin = decision.plan.origin
            }
            if decision.capture, entry(token)?.runID == nil {
                try await authorize(held.caller, "capture", held.target)
                let runID = "browse-" + UUID().uuidString.lowercased()
                let args = try await hooks.networkArguments(held.target)
                    .setting("action", .string("start")).setting("capture", .bool(true)).setting("rules", .object([]))
                    .setting("limits", decision.limits).setting("runId", .string(runID))
                _ = try await network.invoke(args, caller: held.caller)
                entries[token.tabID]!.runID = runID; entries[token.tabID]!.args = args
                if entry(token)?.held != false || entry(token)?.closing != false { return try await disarm(token, state: "yielded", why: "The page was claimed while arming.", reason: .humanTakeover) }
            }
            guard entry(token) != nil else { throw missing() }
            entries[token.tabID]!.configuration = decision.fingerprint; entries[token.tabID]!.camera = decision.camera
            entries[token.tabID]!.coveragePattern = decision.coveragePattern; entries[token.tabID]!.state = "armed"; entries[token.tabID]!.error = ""
            return try await report(token)
        } catch {
            // Unsupported policies/removed grants leave no silently partial
            // request policy behind. Close this lifecycle's own observations.
            let reason: BackendBrowserNetworkCapture.CleanupReason = (error as? NativeRPCError)?.code == "access-denied" ? .grantsRevoked : .profileChanged
            _ = try? await disarm(token, state: "failed", why: error.localizedDescription, reason: reason)
            throw error
        }
    }
    private func disarm(_ token: Token, state: String, why: String, reason: BackendBrowserNetworkCapture.CleanupReason = .profileChanged) async throws -> NativeRPCValue {
        guard let held = entry(token) else { throw missing() }
        var failure: (any Error)?
        if held.runID != nil {
            do {
                _ = try await network.cleanup(tabID: token.tabID, profileID: held.target.profileID, ownerHolder: held.caller.holder, reason: reason)
                if entry(token) != nil { entries[token.tabID]!.runID = nil }
            } catch let error as NativeRPCError where error.code == "not-armed" {
                // The same retained lifecycle may have been retired already by
                // app-wide disconnect cleanup; no live run is left to claim.
                if entry(token) != nil { entries[token.tabID]!.runID = nil }
            } catch { failure = error }
        }
        do { try await hooks.removeRules(token.tabID) } catch { if failure == nil { failure = error } }
        if entry(token) != nil {
            entries[token.tabID]!.ruleList = false; entries[token.tabID]!.ruleOrigin = nil
            entries[token.tabID]!.camera = false; entries[token.tabID]!.coveragePattern = ""; entries[token.tabID]!.configuration = ""
            entries[token.tabID]!.state = failure == nil ? state : "failed"; entries[token.tabID]!.error = failure?.localizedDescription ?? (state == "failed" ? why : "")
        }
        if let failure { throw failure }
        return try await report(token)
    }
    private func failed(_ token: Token, error: any Error) async {
        guard entry(token) != nil else { return }
        entries[token.tabID]!.state = "failed"; entries[token.tabID]!.error = error.localizedDescription
        _ = try? await report(token)
    }
    private func report(_ token: Token) async throws -> NativeRPCValue {
        guard let value = entry(token) else { throw missing() }
        let status = NativeRPCValue.object([
            .init("tabId", .string(value.target.tabID)), .init("profileId", .string(value.target.profileID)), .init("state", .string(value.state)),
            .init("personArmHolds", .bool(!value.held && (value.ruleList || value.runID != nil))), .init("heldByDrive", .bool(value.held)),
            .init("contentRuleList", .bool(value.ruleList)), .init("metadataCapture", .bool(value.runID != nil)), .init("camera", .bool(value.camera)),
            .init("runId", value.runID.map(NativeRPCValue.string) ?? .null), .init("message", .string(value.error)),
            .init("allTraffic", .bool(false)), .init("allResponseBodies", .bool(false)), .init("interceptionCounts", .null)
        ])
        await hooks.changed(token.tabID, status); return status
    }
    private func authorize(_ caller: BackendBrowserScrapingCaller, _ operation: String, _ target: BackendBrowserCaptureTarget, args: NativeRPCValue = .object([])) async throws {
        try Task.checkCancellation(); try await hooks.authorize(caller, "browser.profile-arm." + operation, target.profileID, target.pageURL, args); try Task.checkCancellation()
    }
    private func missing() -> NativeRPCError { .init(code: "profile-tab-closed", message: "This profile arming token no longer names a live tab.") }
    private func statedTotal(_ text: String, pattern: String) throws -> Double? {
        guard pattern.count <= 512 else { throw BackendBrowserScrapingError.invalid("Coverage pattern exceeds 512 characters.") }
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count <= 1_000 else { throw BackendBrowserScrapingError.invalid("Coverage pattern matched more than 1000 totals.") }
        let numbers = Set(matches.compactMap { match -> Double? in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return Double(text[range].filter(\.isNumber))
        })
        return numbers.count == 1 ? numbers.first : nil
    }
}
