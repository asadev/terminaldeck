import Foundation
import TerminalDeckNativeCore

/// Report/refresh ownership only. PTY screens and attribution come from the
/// sole lifecycle actor; credentials remain in the account broker.
public actor BackendUsageService {
    public static let channels: Set<String> = ["usage:read", "usage:watch", "usage:refresh", "usage:context", "plan:watch"]
    public static let sendChannels: Set<String> = ["usage:unwatch", "plan:unwatch"]
    private let accounts: BackendAccountLaunchAdapter, lifecycle: BackendSessionLifecycleCoordinator
    private let store: NativeStateStore, cost: BackendCostService, probe: BackendUsageProbe
    private let modelLabel: @Sendable (String) -> String
    private let push: @Sendable (String, String, NativeRPCValue) async -> Void
    private var pool: [String: BackendUsageReading] = [:]
    private struct Plan: Sendable { let parsed: BackendUsagePlanParser.Parsed; let firstSeen: Double; var captured: Double }
    private var plans: [String: Plan] = [:], subscriptions: [String: Set<String>] = [:], planSubscriptions: [String: Set<String>] = [:]
    private var billing: [String: String] = [:]
    /// The TS plan-limit tracker (plan-limit.ts): answers wherever the TS tracker answered. `plans`/`billing` above stay the account-based state.
    public let planLimits = BackendPlanLimits()
    private var switchedScreens: [String: String] = [:]
    private var inFlight: [String: Task<BackendUsageProbe.Outcome, Never>] = [:]
    private var watchers: [String: BackendUsageFileWatch] = [:]
    private var seededAt: [String: Double] = [:]
    /// TS usage-ipc.ts `lastProbeAt`: when a probe last finished for a login (by config directory), whatever it found.
    private var lastProbeAt: [String: Double] = [:]
    private var pendingBroadcast: Task<Void, Never>?
    private var observer: UUID?, stopped = false
    /// TS usage-ipc `options.probe`: the one probe call, the real BackendUsageProbe unless a test supplies one.
    private let runProbe: @Sendable (BackendUsageAccount, BackendMCPCancellation?) async -> BackendUsageProbe.Outcome
    /// A session as this service reads it. Production reads the lifecycle; a test may supply sessions.
    public typealias SessionLookup = @Sendable (String) async -> (meta: BackendSessionMeta, observedProvider: String?, account: BackendAccountSessionReading, screen: String?)?
    private let sessionLookup: SessionLookup?
    public init(accounts: BackendAccountLaunchAdapter, lifecycle: BackendSessionLifecycleCoordinator, store: NativeStateStore,
                cost: BackendCostService, providers: BackendNativeProviders, modelLabel: @escaping @Sendable (String) -> String,
                push: @escaping @Sendable (String, String, NativeRPCValue) async -> Void,
                probe override: (@Sendable (BackendUsageAccount, BackendMCPCancellation?) async -> BackendUsageProbe.Outcome)? = nil,
                sessionLookup: SessionLookup? = nil) {
        self.accounts = accounts; self.lifecycle = lifecycle; self.store = store; self.cost = cost
        let real = BackendUsageProbe(accounts: accounts, providers: providers)
        probe = real; runProbe = override ?? { await real.run(account: $0, cancellation: $1) }
        self.sessionLookup = sessionLookup
        self.modelLabel = modelLabel; self.push = push
    }
    private func sessionMeta(_ id: String) async -> (session: BackendSessionMeta, observed: String?)? {
        if let sessionLookup { return await sessionLookup(id).map { ($0.meta, $0.observedProvider) } }
        return await lifecycle.metadata().first(where: { $0.session.id == id }).map { ($0.session, $0.observedAgentProvider) }
    }
    private func sessionAttribution(_ id: String) async -> BackendAccountSessionReading? {
        if let sessionLookup { return await sessionLookup(id)?.account }
        return await lifecycle.sessionAccount(sessionID: id)
    }
    private func sessionScreen(_ id: String) async -> String? {
        if let sessionLookup { return await sessionLookup(id)?.screen }
        return lifecycle.manager.screen(id)
    }
    /// Explicit app startup after the whole native state/session cutover.
    public func start() async { guard observer == nil else { return }; stopped = false; observer = await lifecycle.observe { [weak self] event in await self?.note(event) } }
    public func account(sessionID: String?, provider: String? = nil) async throws -> BackendUsageAccount? {
        if let sessionID {
            guard let meta = await sessionMeta(sessionID) else { return nil }
            let actualProvider = provider ?? meta.observed ?? meta.session.provider
            guard ["claude", "codex", "gemini"].contains(actualProvider) else { return nil }
            guard let attribution = await sessionAttribution(sessionID) else { return nil }
            guard attribution.provider == actualProvider, let directory = attribution.configDir else { return BackendUsageAccount(provider: actualProvider, id: nil, name: nil, configDirectory: nil) }
            return BackendUsageAccount(provider: actualProvider, id: attribution.profileId, name: attribution.profileName, configDirectory: directory)
        }
        let actualProvider = provider ?? "claude"
        guard let profile = try await accounts.profiles.find(BackendAccountProfile.systemID(actualProvider)) else { return nil }
        return BackendUsageAccount(provider: actualProvider, id: profile.id, name: profile.name, configDirectory: profile.configDir)
    }
    private func merge(_ readings: [BackendUsageReading]) {
        for reading in readings { if pool[reading.id] == nil || pool[reading.id]!.reportedAt <= reading.reportedAt { pool[reading.id] = reading } }
    }
    private func cachedClaude(_ account: BackendUsageAccount) async throws -> [BackendUsageReading] {
        guard let id = account.id, let profile = try await accounts.profiles.find(id), profile.provider == "claude" else { return [] }
        let configuration = accounts.profiles.configuration
        let path = profile.system && configuration.inheritedEnvironment["CLAUDE_CONFIG_DIR"] == nil ? configuration.homeDirectory.appendingPathComponent(".claude.json") : URL(fileURLWithPath: profile.configDir).appendingPathComponent(".claude.json")
        guard let data = try BackendAccountFiles.boundedRead(path, maximum: 4 * 1024 * 1024) else { return [] }
        let raw = try NativeRPCValue.parseJSON(data), cache = raw["cachedUsageUtilization"]
        guard let fetchedAt = cache["fetchedAtMs"].number, BackendUsageIO.now() - fetchedAt <= 3_600_000 else { return [] }
        if let original = raw["oauthAccount"]["accountUuid"].string, let cached = cache["accountUuid"].string, original != cached { return [] }
        let organization = raw["oauthAccount"]["organizationType"].string?.replacingOccurrences(of: "^claude_", with: "", options: .regularExpression)
        return BackendUsagePlanParser.utilization(cache["utilization"], subscription: organization).map { $0.reading(account: account, observedAt: BackendUsageIO.now(), reportedAt: fetchedAt, source: "claude-usage-api", apiReset: true) }
    }
    private func seed(_ account: BackendUsageAccount) async throws {
        guard account.configDirectory != nil else { return }
        if let checked = seededAt[account.key], BackendUsageIO.now() - checked < 30_000 { return }
        if account.provider == "claude" { merge(try await cachedClaude(account)) }
        else if account.provider == "codex" { merge(try await BackendUsageCodex.read(account: account)) }
        seededAt[account.key] = BackendUsageIO.now()
    }
    public func read(sessionID: String?) async throws -> BackendUsageReport {
        let now = BackendUsageIO.now()
        if let sessionID {
            guard let account = try await account(sessionID: sessionID) else { return BackendUsageReport(sessionID: sessionID, account: nil, readings: [], reason: "That session has no established agent account on this computer.", assembledAt: now) }
            var readFailure: String?
            do { try await seed(account) } catch { readFailure = error.localizedDescription }
            await captureScreen(sessionID)
            let readings = pool.values.filter { $0.account.key == account.key && account.configDirectory != nil }.sorted(by: Self.order)
            return BackendUsageReport(sessionID: sessionID, account: account, readings: readings, reason: readFailure ?? (account.configDirectory == nil ? "The running agent's login has not been established, so another account's limits are not shown." : account.provider == "codex" ? "Codex has not recorded a rate limit under this account yet; it records one when a turn completes." : "No subscription usage has been reported under this account yet."), assembledAt: now)
        }
        let profiles = try await accounts.profiles.list().filter { ["claude", "codex"].contains($0.provider) }
        guard profiles.count <= 64 else { throw NativeRPCError.malformed("The account usage read exceeds this build's 64-account budget.") }
        let valid = Set(profiles.map { "\($0.provider)/\($0.id)" }); pool = pool.filter { valid.contains($0.value.account.key) }
        var failed: [String] = []
        for profile in profiles {
            do { try await seed(BackendUsageAccount(provider: profile.provider, id: profile.id, name: profile.name, configDirectory: profile.configDir)) } catch { failed.append(profile.name + ": " + error.localizedDescription) }
        }
        return BackendUsageReport(sessionID: nil, account: nil, readings: pool.values.sorted(by: Self.order), reason: failed.isEmpty ? "No account has reported a subscription usage reading yet." : failed.joined(separator: "; "), assembledAt: now)
    }
    private static func order(_ left: BackendUsageReading, _ right: BackendUsageReading) -> Bool {
        func minutes(_ value: BackendUsageReading) -> Double { value.windowMinutes ?? (value.window == .fiveHour ? 300 : value.window == .weekly ? 10_080 : value.window == .monthly ? 43_200 : Double.greatestFiniteMagnitude) }
        return minutes(left) == minutes(right) ? left.id < right.id : minutes(left) < minutes(right)
    }
    private func captureScreen(_ sessionID: String) async {
        guard let account = try? await account(sessionID: sessionID, provider: "claude"), account.configDirectory != nil,
              let screen = await sessionScreen(sessionID) else { return }
        if switchedScreens[sessionID] == screen { return }; switchedScreens[sessionID] = nil
        if let observedBilling = BackendUsagePlanParser.billing(screen: screen) { billing[account.key] = observedBilling }
        guard let parsed = BackendUsagePlanParser.parse(screen: screen) else { return }
        let now = BackendUsageIO.now(), previous = plans[sessionID]
        let identical = previous?.parsed.limits == parsed.limits && previous?.parsed.source == parsed.source && previous?.parsed.message == parsed.message
        let plan = Plan(parsed: parsed, firstSeen: identical ? previous!.firstSeen : now, captured: now); plans[sessionID] = plan
        merge(parsed.limits.map { $0.reading(account: account, observedAt: now, reportedAt: plan.firstSeen, source: parsed.source == "warning" ? "claude-warning" : "claude-usage-panel") })
    }
    public func plan(sessionID: String) async -> NativeRPCValue {
        await captureScreen(sessionID)   // keeps the account-based usage readings fed, as before
        return await planLimits.snapshot(sessionID).wireValue
    }
    private func planChanged() { scheduleBroadcast() }
    public func refresh(sessionID: String, force: Bool, cancellation: BackendMCPCancellation? = nil) async throws -> BackendUsageProbe.Outcome {
        let start = BackendUsageIO.now()
        func answer(_ kind: String, _ detail: String) -> BackendUsageProbe.Outcome { .init(kind: kind, detail: detail, readings: [], spawned: false, elapsedMilliseconds: BackendUsageIO.now() - start) }
        guard let account = try await account(sessionID: sessionID, provider: "claude"), let directory = account.configDirectory else { return answer("unwatched", "That session's Claude login has not been established here.") }
        guard let meta = await sessionMeta(sessionID), ["claude", "shell"].contains(meta.observed ?? meta.session.provider) else { return answer("unwatched", "This session runs another agent, so its login has no Claude limits to read.") }
        seededAt[account.key] = nil
        do { try await seed(account) } catch { /* A corrupt CLI cache is not an account identity and cannot prohibit a fresh control-protocol request. */ }
        let newest = pool.values.filter { $0.account.key == account.key }.map(\.reportedAt).max() ?? 0
        if !force, newest > 0, start - newest < 300_000 { return answer("cached", "Claude Code fetched this less than five minutes ago; its newest figure is already available.") }
        if !force, await store.getAccountLimit(directory)["answer"].string == "no-limits" { return answer("settled", "This login has no subscription limits, so there is nothing to read.") }
        await captureScreen(sessionID)
        let announcedAPI = await planLimits.billing(sessionID) == "api"
        if !force, billing[account.key] == "api" || announcedAPI {
            _ = try await store.setAccountLimit(directory, patch: BackendUsageIO.object([("billing", .string("api")), ("answer", .string("no-limits"))]))
            return answer("no-limits", "This login is billed through the Claude API, which has no subscription limits to read.")
        }
        // TS usage-ipc.ts:870: a probe finished for this login moments ago and produced no figure; a press goes past.
        if BackendUsageProbeFloor.recentlyRead(lastProbeAt: lastProbeAt[directory], now: BackendUsageIO.now(), force: force) {
            return answer("unreadable", BackendUsageProbeFloor.recentlyReadSentence)
        }
        if let existing = inFlight[account.key] { return await existing.value }
        let work = Task { await runProbe(account, cancellation) }; inFlight[account.key] = work
        let result = await work.value; inFlight[account.key] = nil
        lastProbeAt[directory] = BackendUsageIO.now()
        if !stopped {
            merge(result.readings)
            // TS usage-ipc.ts:888-913: a reading proves the login has windows, so anything remembered to the
            // contrary is dropped; `no-limits` is the one answer written down; anything else is left as it is.
            switch BackendUsageProbeFloor.memory(after: result.kind) {
            case .forget: try await store.forgetAccountLimit(directory)
            case .writeNoLimits: _ = try await store.setAccountLimit(directory, patch: BackendUsageIO.object([("answer", .string("no-limits"))]))
            case .keep: break
            }
            await broadcast()
        }
        return result
    }
    private func note(_ event: BackendSessionEvent) async {
        switch event {
        case .data(let id, let text):
            await planLimits.noteOutput(id, text)
            if subscriptions[id] != nil || planSubscriptions[id] != nil { await captureScreen(id); scheduleBroadcast() }
        case .status(let id, _): if subscriptions[id] != nil { scheduleBroadcast() }
        case .removed(let id, _): plans[id] = nil; await planLimits.drop(id); scheduleBroadcast()
        case .exit: scheduleBroadcast()
        }
    }
    private func scheduleBroadcast() {
        guard pendingBroadcast == nil else { return }
        pendingBroadcast = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)); try Task.checkCancellation(); await self?.broadcast() } catch {}
            await self?.broadcastFinished()
        }
    }
    private func broadcastFinished() { pendingBroadcast = nil }
    private func dataChanged(_ accountKey: String) async {
        seededAt[accountKey] = nil
        for sessionID in subscriptions.keys {
            if let account = try? await account(sessionID: sessionID), account.key == accountKey, let watch = watchers[accountKey] {
                do { try watch.install(paths: await usageWatchPaths(account)); break } catch { watchers[accountKey]?.stop(); watchers[accountKey] = nil }
            }
        }
        scheduleBroadcast()
    }
    private func usageWatchPaths(_ account: BackendUsageAccount) throws -> [String] {
        guard let home = account.configDirectory else { return [] }
        var paths = [home]
        if account.provider == "codex" {
            paths += [URL(fileURLWithPath: home).appendingPathComponent("sessions").path, URL(fileURLWithPath: home).appendingPathComponent("archived_sessions").path]
            for file in try BackendUsageCodex.candidates(home: home).prefix(3) {
                paths.append(file.path); var parent = URL(fileURLWithPath: file.path).deletingLastPathComponent()
                while NativeTranscriptPaths.isDescendant(parent.path, of: home), parent.path != home { paths.append(parent.path); parent.deleteLastPathComponent() }
            }
        } else {
            let config = accounts.profiles.configuration
            let file = account.id == "system" && config.inheritedEnvironment["CLAUDE_CONFIG_DIR"] == nil ? config.homeDirectory.appendingPathComponent(".claude.json") : URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
            paths += [file.path, file.deletingLastPathComponent().path]
        }
        return paths
    }
    private func broadcast() async {
        for (session, owners) in subscriptions {
            let value: NativeRPCValue
            do { value = try await read(sessionID: session).wireValue } catch { value = BackendUsageIO.object([("sessionId", .string(session)), ("readings", .array([])), ("reason", .string(error.localizedDescription)), ("assembledAt", .number(BackendUsageIO.now()))]) }
            for owner in owners { await push(owner, "usage:update", value) }
        }
        for (session, owners) in planSubscriptions { let value = await plan(sessionID: session); for owner in owners { await push(owner, "plan:update", value) } }
    }
    public func watch(sessionID: String, ownerID: String, planOnly: Bool = false) async throws -> NativeRPCValue {
        if planOnly {
            planSubscriptions[sessionID, default: []].insert(ownerID)
            let held = try await planLimits.watch(sessionID, key: ownerID) { [weak self] _ in Task { await self?.planChanged() } }
            return held.wireValue
        }
        subscriptions[sessionID, default: []].insert(ownerID)
        if let account = try await account(sessionID: sessionID), let home = account.configDirectory, ["codex", "claude"].contains(account.provider), watchers[account.key] == nil {
            let key = account.key, watch = BackendUsageFileWatch { [weak self] in Task { await self?.dataChanged(key) } }
            let paths = try usageWatchPaths(account)
            do { guard try watch.install(paths: paths) > 0 else { throw NativeRPCError(code: "missing-capability", message: "No existing account usage directory can be monitored.") }; watchers[account.key] = watch }
            catch { unwatch(sessionID: sessionID, ownerID: ownerID); throw error }
        }
        return try await read(sessionID: sessionID).wireValue
    }
    public func unwatch(sessionID: String, ownerID: String, planOnly: Bool = false) {
        if planOnly {
            planSubscriptions[sessionID]?.remove(ownerID); if planSubscriptions[sessionID]?.isEmpty == true { planSubscriptions[sessionID] = nil }
            let limits = planLimits; Task { await limits.unwatch(sessionID, key: ownerID) }
        }
        else { subscriptions[sessionID]?.remove(ownerID); if subscriptions[sessionID]?.isEmpty == true { subscriptions[sessionID] = nil } }
        if subscriptions.isEmpty { watchers.values.forEach { $0.stop() }; watchers.removeAll() }
    }
    public func disconnect(ownerID: String) { for session in Array(subscriptions.keys) { unwatch(sessionID: session, ownerID: ownerID) }; for session in Array(planSubscriptions.keys) { unwatch(sessionID: session, ownerID: ownerID, planOnly: true) } }
    /// Call from the existing lifecycle accountChanged receipt. Old unchanged
    /// panel text must not be re-attributed to the newly served login.
    public func accountChanged(sessionID: String) async { plans[sessionID] = nil; switchedScreens[sessionID] = lifecycle.manager.screen(sessionID); await broadcast() }
    public func noteStatusReceipt() { scheduleBroadcast() }
    public func stop() async { stopped = true; pendingBroadcast?.cancel(); pendingBroadcast = nil; if let observer { await lifecycle.removeObserver(observer) }; observer = nil; inFlight.values.forEach { $0.cancel() }; inFlight.removeAll(); watchers.values.forEach { $0.stop() }; watchers.removeAll(); subscriptions.removeAll(); planSubscriptions.removeAll() }
    public func contextWindow(sessionID: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        let observed = BackendUsageIO.now()
        func blank(_ provider: String?, _ state: String, _ detail: String) -> NativeRPCValue { BackendUsageIO.object([("provider", BackendUsageIO.string(provider)), ("state", .string(state)), ("tokens", .null), ("window", .null), ("percent", .null), ("windowBasis", .null), ("model", .null), ("modelLabel", .null), ("source", .null), ("reportedAt", .number(0)), ("observedAt", .number(observed)), ("detail", .string(detail))]) }
        guard let metadata = await lifecycle.metadata().first(where: { $0.session.id == sessionID }) else { return blank(nil, "not-reported", "That session is not running here, so its folder and transcript are unknown.") }
        let provider = metadata.observedAgentProvider ?? metadata.session.provider, cwd = metadata.session.cwd
        guard ["claude", "codex"].contains(provider) else {
            return blank(provider, "not-reported", provider == "gemini"
                ? "Gemini does not record how full its context window is. Its session files hold the conversation and no token counts at all, so there is nothing here to read — this is not a reading that is late, it is one Gemini never writes."
                : provider == "shell" ? "This tab is a plain shell, so there is no model and no context window to measure."
                : "This agent does not write down how full its context window is, so there is nothing to read.")
        }
        let namedID = metadata.observedCLIConversationID ?? metadata.session.agentSessionId
        var candidates: [(path: String, id: String, modified: Double)] = [], roots: [String] = []
        if provider == "claude" {
            let scope = try await cost.scope(project: cwd, context: context); roots = try NativeTranscriptPaths.approvedRoots(scope)
            let files = try await cost.files(project: cwd, context: context)
            candidates = files.filter { namedID == nil || $0.sessionID == namedID }.map { ($0.path, $0.sessionID, $0.modifiedAt) }
        } else {
            guard let account = try await account(sessionID: sessionID, provider: provider), let home = account.configDirectory else { return blank(provider, "nothing-yet", "This app does not know which Codex account this session runs as, so it cannot find the rollout that would carry the figure.") }
            // Account attribution is necessary but filesystem grants are still
            // checked by the same caller-bound transcript scope.
            try await cost.authorizeDataDirectory(home, context: context)
            roots = [home]
            candidates = try BackendUsageCodex.projectCandidates(home: home, cwd: cwd, conversationID: namedID).map { ($0.path, $0.conversationID ?? URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent, $0.modifiedAt) }
        }
        return try Self.contextReading(provider: provider, cwd: cwd, namedID: namedID, candidates: candidates, roots: roots, modelLabel: modelLabel, now: observed)
    }
    /// The transcript-reading half of `contextWindow`, free of any session, lifecycle or cost fixture
    /// (context-window.ts `readContextWindow`): newest conversation across the candidates, bounded tail reads.
    public static let contextRivalWindowMilliseconds = 10.0 * 60 * 1000
    public static func contextReading(provider: String, cwd: String, namedID: String?,
                                      candidates given: [(path: String, id: String, modified: Double)], roots: [String],
                                      modelLabel: @Sendable (String) -> String, now observed: Double) throws -> NativeRPCValue {
        let steps = [256 * 1024, 1024 * 1024, 8 * 1024 * 1024], rival = contextRivalWindowMilliseconds
        func blank(_ state: String, _ detail: String) -> NativeRPCValue { BackendUsageIO.object([("provider", BackendUsageIO.string(provider)), ("state", .string(state)), ("tokens", .null), ("window", .null), ("percent", .null), ("windowBasis", .null), ("model", .null), ("modelLabel", .null), ("source", .null), ("reportedAt", .number(0)), ("observedAt", .number(observed)), ("detail", .string(detail))]) }
        func grouped(_ value: Double) -> String { let f = NumberFormatter(); f.locale = Locale(identifier: "en_US"); f.numberStyle = .decimal; f.maximumFractionDigits = 0; return f.string(from: NSNumber(value: value)) ?? String(Int(value)) }
        func tailOf(_ path: String, _ amount: Int) throws -> (String, Double)? {
            do { return try BackendUsageIO.tail(path: path, roots: roots, bytes: amount) }
            catch let error as NativeRPCError where error.code == "access-denied" { throw error }
            catch { return nil }
        }
        func sizeOf(_ path: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil }
        let candidates = given.enumerated().sorted { $0.element.modified == $1.element.modified ? $0.offset < $1.offset : $0.element.modified > $1.element.modified }.map(\.element)
        if provider == "codex" {
            for candidate in candidates {
                guard let size = sizeOf(candidate.path), size > 0 else { continue }
                var found: (tokens: Double, window: Double?, at: Double)?
                scan: for amount in steps {
                    guard let tail = try tailOf(candidate.path, amount) else { break }
                    for line in tail.0.components(separatedBy: "\n").reversed() {
                        if let parsed = Self.parseCodexContextLine(line, tail.1) { found = parsed; break scan }
                    }
                    if min(amount, size) >= size { break }
                }
                guard let found else { continue }
                let rivals = candidates.filter { $0.path != candidate.path && abs($0.modified - candidate.modified) <= rival }.count
                let percent = found.window.flatMap { $0 > 0 ? found.tokens / $0 * 100 : nil }
                var detail: String
                if let window = found.window, let percent { detail = "\(grouped(found.tokens)) of \(grouped(window)) tokens — \(Int(percent.rounded()))% of the context window Codex reports for this model." }
                else { detail = "\(grouped(found.tokens)) tokens in context. Codex did not record how large its window is on this turn, so there is no share to show." }
                if rivals > 0 {
                    detail += " Read from the most recent rollout Codex filed for this folder, and \(rivals == 1 ? "one other Codex conversation" : "\(rivals) other Codex conversations") here \(rivals == 1 ? "was" : "were") active at the same time — Codex cannot be told which conversation to open, so if you have more than one session here this may be the other one's."
                }
                return BackendUsageIO.object([("provider", .string("codex")), ("state", .string("ok")), ("tokens", .number(found.tokens)), ("window", BackendUsageIO.number(found.window)), ("percent", BackendUsageIO.number(percent)),
                    ("windowBasis", found.window == nil ? .null : .string("reported")), ("model", .null), ("modelLabel", .null),
                    ("source", BackendUsageIO.object([("path", .string(candidate.path)), ("sessionId", .string(candidate.id)), ("chosen", .string(rivals > 0 ? "inferred" : "named")), ("rivals", .number(Double(rivals)))])),
                    ("reportedAt", .number(found.at)), ("observedAt", .number(observed)), ("detail", .string(detail))])
            }
            return blank("nothing-yet", "Codex has not completed a turn in this folder yet. It records the size of its context at the end of each turn, so the figure appears after the first reply.")
        }
        let named = namedID != nil
        // One transcript line: the prompt that turn put in the context. Interrupts (`<synthetic>`), sub-agents and lines with no usage are not it.
        func promptOnLine(_ line: String) -> (tokens: Double, model: String, at: Double)? {
            guard line.contains("usage"), let raw = try? NativeRPCValue.parseJSON(Data(line.utf8)), raw["type"].string == "assistant", raw["isSidechain"].bool != true,
                  raw["message"]["usage"].fields != nil, let model = raw["message"]["model"].string else { return nil }
            let id = BackendCostMath.normalizeModel(model)
            guard !id.isEmpty, id != "<synthetic>" else { return nil }
            return ((BackendCostTokens.parse(raw["message"]["usage"]) ?? BackendCostTokens()).prompt, model, BackendUsageIO.timestamp(raw["timestamp"]))
        }
        func readClaude(_ path: String) throws -> (latest: (tokens: Double, model: String, at: Double)?, high: Double, bytes: Int) {
            guard let size = sizeOf(path), size > 0 else { return (nil, 0, 0) }
            var spent = 0
            for amount in steps {
                guard let tail = try tailOf(path, amount) else { return (nil, 0, spent) }
                spent += tail.0.utf8.count
                let lines = tail.0.components(separatedBy: "\n")
                if let latest = lines.reversed().lazy.compactMap(promptOnLine).first {
                    return (latest, max(latest.tokens, lines.compactMap(promptOnLine).map(\.tokens).max() ?? 0), spent)
                }
                if min(amount, size) >= size { break }
            }
            return (nil, 0, spent)
        }
        let liveAfter = (candidates.first?.modified ?? 0) - rival
        var best: (candidate: (path: String, id: String, modified: Double), latest: (tokens: Double, model: String, at: Double), high: Double)?, budget = 16 * 1024 * 1024
        for candidate in candidates {
            if budget <= 0 { break }
            if best != nil && candidate.modified < liveAfter { break }
            try Task.checkCancellation()
            let read = try readClaude(candidate.path); budget -= read.bytes
            guard let latest = read.latest else { continue }
            if best == nil || latest.at > best!.latest.at { best = (candidate, latest, read.high) }
        }
        guard let best else {
            return blank("nothing-yet", named
                ? "This session has not written a reply yet. The figure is read from its own transcript — this app named the conversation when it started it — so it says nothing about any other session open in this folder."
                : "Claude Code has not written a reply in this folder yet. The figure appears as soon as it answers once — it comes from the transcript it writes as it goes, not from anything this app has to ask for.")
        }
        let table = BackendCostMath.contextWindow(best.latest.model), window = BackendCostMath.effectiveWindow(model: best.latest.model, observed: best.high)
        let rivals = named ? 0 : candidates.filter { $0.path != best.candidate.path && abs($0.modified - best.candidate.modified) <= rival }.count
        let head = (window > 0 ? "\(grouped(best.latest.tokens)) of \(grouped(window)) tokens — \(Int((best.latest.tokens / window * 100).rounded()))% of the context window" : "\(grouped(best.latest.tokens)) of \(grouped(window)) tokens")
        let detail = named || rivals == 0 ? head + "." : head + ". Read from the most recently updated transcript in this folder, and \(rivals == 1 ? "one other conversation" : "\(rivals) other conversations") here \(rivals == 1 ? "was" : "were") active at the same time — if you have more than one session open here, this may be the other one's."
        return BackendUsageIO.object([("provider", .string(provider)), ("state", .string("ok")), ("tokens", .number(best.latest.tokens)), ("window", .number(window)),
            ("percent", window > 0 ? .number(best.latest.tokens / window * 100) : .null), ("windowBasis", .string(window > table ? "observed" : "model")),
            ("model", .string(best.latest.model)), ("modelLabel", .string(modelLabel(best.latest.model))),
            ("source", BackendUsageIO.object([("path", .string(best.candidate.path)), ("sessionId", .string(best.candidate.id)), ("chosen", .string(named ? "named" : "inferred")), ("rivals", .number(Double(rivals)))])),
            ("reportedAt", .number(best.latest.at)), ("observedAt", .number(observed)), ("detail", .string(detail))])
    }
    /// One Codex rollout line: a `token_count` event's last input tokens, the window it reported and when.
    /// `fallbackAt` stands in for a line with no usable timestamp. Nil for any other line.
    static func parseCodexContextLine(_ line: String, _ fallbackAt: Double) -> (tokens: Double, window: Double?, at: Double)? {
        guard line.contains("\"token_count\""), let raw = try? NativeRPCValue.parseJSON(Data(line.utf8)),
              raw["payload"]["type"].string == "token_count", let tokens = raw["payload"]["info"]["last_token_usage"]["input_tokens"].number, tokens.isFinite else { return nil }
        let stamp = BackendUsageIO.timestamp(raw["timestamp"])
        return (tokens, raw["payload"]["info"]["model_context_window"].number.flatMap { $0.isFinite ? $0 : nil }, stamp > 0 ? stamp : fallbackAt)
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], ownerID: String, context: NativeRPCContext,
                       authorizeRefresh: @Sendable (NativeRPCContext) throws -> Void) async throws -> NativeRPCValue {
        let first = args.first ?? .missing
        switch channel {
        case "usage:read": return try await read(sessionID: first.string).wireValue
        case "usage:watch": return try await watch(sessionID: first.requireString("session id", nonempty: true), ownerID: ownerID)
        case "plan:watch": return try await watch(sessionID: first.requireString("session id", nonempty: true), ownerID: ownerID, planOnly: true)
        case "usage:refresh": try authorizeRefresh(context); return try await refresh(sessionID: first.requireString("session id", nonempty: true), force: args.count > 1 && args[1].bool == true).wireValue
        case "usage:context": return try await contextWindow(sessionID: first.requireString("session id", nonempty: true), context: context)
        default: throw BackendSessionFailure.unsupported("The native usage channel is not registered.")
        }
    }
}

/// TS usage-ipc.ts PROBE_FLOOR_MS (:682) and what a finished probe does to the login's memory (:888-913).
public enum BackendUsageProbeFloor {
    public static let milliseconds: Double = 60_000
    public static let recentlyReadSentence = "This login was read a moment ago and had nothing to report."
    /// `!force && Date.now() - (lastProbeAt.get(configDir) ?? 0) < PROBE_FLOOR_MS`
    public static func recentlyRead(lastProbeAt: Double?, now: Double, force: Bool) -> Bool { !force && now - (lastProbeAt ?? 0) < milliseconds }
    public enum Memory: Equatable, Sendable { case forget, writeNoLimits, keep }
    /// `ok` -> `accounts.forget(configDir)`; `no-limits` -> `accounts.write(configDir, { answer: 'no-limits' })`;
    /// everything else (`signed-out` deliberately included) leaves the memory alone.
    public static func memory(after outcome: String) -> Memory { outcome == "ok" ? .forget : outcome == "no-limits" ? .writeNoLimits : .keep }
}
