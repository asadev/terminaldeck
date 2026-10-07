import Foundation
import TerminalDeckNativeCore

public actor BackendAlertsService {
    public static let channels: Set<String> = ["alerts:project"]
    private let cost: BackendCostService, lifecycle: BackendSessionLifecycleCoordinator
    private let projects: BackendProjectService, git: BackendGitService, providers: BackendNativeProviders
    private let defaultProvider: @Sendable (String) async -> String?
    private var statusTimes: [String: (BackendSessionStatus, Double)] = [:]
    private var observer: UUID?
    public init(cost: BackendCostService, lifecycle: BackendSessionLifecycleCoordinator, projects: BackendProjectService,
                git: BackendGitService, providers: BackendNativeProviders, defaultProvider: @escaping @Sendable (String) async -> String?) {
        self.cost = cost; self.lifecycle = lifecycle; self.projects = projects; self.git = git; self.providers = providers; self.defaultProvider = defaultProvider
    }
    public func start() async {
        guard observer == nil else { return }
        // We know when status was first observed, not how long it predated
        // subscription. Under-age it rather than inventing an earlier start.
        for metadata in await lifecycle.metadata() { statusTimes[metadata.session.id] = (metadata.status, BackendUsageIO.now()) }
        observer = await lifecycle.observe { [weak self] event in await self?.note(event) }
    }
    private func note(_ event: BackendSessionEvent) async {
        switch event {
        case .status(let id, let status): if statusTimes[id]?.0 != status { statusTimes[id] = (status, BackendUsageIO.now()) }
        case .removed(let id, _): statusTimes[id] = nil
        case .data(let id, _): let status = await lifecycle.status(sessionID: id); if statusTimes[id]?.0 != status { statusTimes[id] = (status, BackendUsageIO.now()) }
        case .exit(let id, _): statusTimes[id] = (.exited, BackendUsageIO.now())
        }
    }
    /// The lifecycle's accepted hook/status receipt can arrive without another
    /// PTY byte. Wire its event fanout here; raw unvalidated hooks are not inputs.
    public func noteStatusReceipt(sessionID: String, status: BackendSessionStatus, at: Double) {
        guard at.isFinite, at > 0 else { return }
        if statusTimes[sessionID]?.0 != status { statusTimes[sessionID] = (status, at) }
    }
    public func stop() async { if let observer { await lifecycle.removeObserver(observer) }; observer = nil; statusTimes.removeAll() }
    private struct Row: Sendable {
        let id: String, path: String, started: Double, last: Double, requests: Int, tokens: Double, prefix: Double, context: NativeRPCValue
        let appID: String?, status: BackendSessionStatus?, statusSince: Double?, progress: NativeRPCValue?
    }
    public func project(_ project: String, context: NativeRPCContext, cancellation: BackendMCPCancellation? = nil) async throws -> NativeRPCValue {
        _ = try await projects.requireKnown(project); _ = try await projects.files.authority.authorize(project, context: context, intent: .read)
        let now = BackendUsageIO.now(), deadline = now + 15_000
        let live = await lifecycle.metadata().filter { NativeTranscriptPaths.canonical($0.session.cwd) == NativeTranscriptPaths.canonical(project) && $0.session.exitCode == nil }
        let files = try await cost.files(project: project, context: context), scope = try await cost.scope(project: project, context: context)
        var rows: [Row] = [], coverage: [String] = [], trails = 0, bytes = 0
        for file in files.filter({ $0.modifiedAt >= now - 90 * 86_400_000 }).prefix(40) {
            if BackendUsageIO.now() >= deadline { coverage.append("The transcript gather deadline ended."); break }
            if cancellation?.isCancelled == true { throw CancellationError() }; try Task.checkCancellation()
            do {
                let transcript = try await BackendCostTranscript.read(path: file.path, scope: scope, cancellation: cancellation, deadline: deadline); bytes += transcript.readBytes
                guard bytes <= 512 * 1024 * 1024 else { coverage.append("The transcript gather byte budget ended."); break }
                var progress: NativeRPCValue?
                if trails < 3, transcript.lastActivityAt >= now - 1_800_000 { progress = BackendInsightsProgress.assess(transcript); trails += 1 }
                rows.append(Row(id: transcript.sessionID, path: file.path, started: transcript.startedAt, last: transcript.lastActivityAt, requests: transcript.requestCount, tokens: transcript.usage.total, prefix: transcript.prefix, context: transcript.context, appID: live.count == 1 ? live[0].session.id : nil, status: nil, statusSince: nil, progress: progress))
                if transcript.truncated { coverage.append("A transcript exceeded its read budget.") }
            } catch is CancellationError { throw CancellationError() }
            catch { coverage.append("A transcript could not be read: " + error.localizedDescription) }
        }
        // Live app UUIDs and CLI transcript IDs are distinct namespaces.
        // Status rows are never joined by folder or guessed conversation ID.
        for metadata in live { rows.append(Row(id: metadata.session.id, path: "", started: metadata.session.createdAt, last: statusTimes[metadata.session.id]?.1 ?? now, requests: 0, tokens: 0, prefix: 0, context: .null, appID: metadata.session.id, status: metadata.status, statusSince: statusTimes[metadata.session.id]?.1, progress: nil)) }
        var alerts: [NativeRPCValue] = []
        func alert(_ id: String, _ kind: String, _ severity: String, _ title: String, _ detail: String, _ at: Double, session: String? = nil, action: String, label: String, target: String) -> NativeRPCValue {
            BackendUsageIO.object([("id", .string(id)), ("kind", .string(kind)), ("severity", .string(severity)), ("title", .string(title)), ("detail", .string(detail)), ("sessionId", BackendUsageIO.string(session)), ("at", .number(at)), ("action", BackendUsageIO.object([("kind", .string(action)), ("label", .string(label)), ("target", .string(target))]))])
        }
        let active = rows.filter { $0.requests > 0 }
        if let newest = active.max(by: { $0.last < $1.last }) {
            let percent = newest.context["percent"].number ?? 0, window = newest.context["window"].number ?? 0
            if percent >= 70 { alerts.append(alert("context-bloat:\(newest.id)", "context-bloat", percent >= 90 ? "critical" : "warning", "Context \(Int(percent.rounded()))% full", "The latest main-thread request is holding \(BackendCostMath.format(newest.context["tokens"].number ?? 0)) of a \(BackendCostMath.format(window)) context window.", newest.last, session: newest.id, action: "compact-session", label: "Compact this session", target: newest.id)) }
            if window > 0, newest.prefix / window >= 0.15 { alerts.append(alert("pre-context-bloat:\(newest.id)", "pre-context-bloat", newest.prefix / window >= 0.3 ? "critical" : "warning", "Every request starts heavy", "The first request already occupied \(Int((newest.prefix / window * 100).rounded()))% of the context window.", newest.last, session: newest.id, action: "open-inspector", label: "Open the inspector", target: newest.path)) }
        }
        for row in rows where row.status == .input {
            guard let since = row.statusSince, since > 0, now - since >= 600_000 else { continue }
            let minutes = Int((now - since) / 60_000)
            alerts.append(alert("session-blocked:\(row.id)", "session-blocked", now - since >= 2_700_000 ? "critical" : "warning", "Waiting on you for \(minutes)m", "This live session is waiting for input. It needs an answer before it can continue.", since, session: row.id, action: "focus-session", label: "Go to the session", target: row.id))
        }
        var loopAlerts: [NativeRPCValue] = []
        for row in active where row.progress?["verdict"].string == "looping" {
            let findings = row.progress?["findings"].elements ?? [], maximum = findings.compactMap { $0["count"].number }.max() ?? 0, tool = findings.compactMap { $0["tool"].string }.first
            loopAlerts.append(alert("loop:\(row.id)", "loop", maximum >= 20 ? "critical" : "warning", tool.map { "A session is stuck on \($0)" } ?? "A session is repeating itself and writing nothing", findings.compactMap { $0["detail"].string }.joined(separator: " ") + " This is read from tool names and outcomes only; inspect it before stopping it.", row.last, session: row.appID, action: "open-inspector", label: "See what it is doing", target: row.path))
        }
        let rank: [String: Int] = ["critical": 0, "warning": 1, "info": 2]
        func ordered(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool { let x = rank[a["severity"].string ?? "info"] ?? 2, y = rank[b["severity"].string ?? "info"] ?? 2; return x == y ? (a["at"].number ?? 0) > (b["at"].number ?? 0) : x < y }
        if let loop = loopAlerts.sorted(by: ordered).first { alerts.append(loop) }
        let counted = active.filter { $0.tokens > 0 }.sorted { $0.tokens < $1.tokens }
        if counted.count >= 5, let worst = counted.last {
            let mid = counted.count / 2, median = counted.count % 2 == 1 ? counted[mid].tokens : (counted[mid - 1].tokens + counted[mid].tokens) / 2
            if median > 0, worst.tokens / median >= 3, worst.tokens >= 1_000_000 {
                let ratio = worst.tokens / median
                alerts.append(alert("heavy-session:\(worst.id)", "heavy-session", ratio >= 6 && worst.tokens >= 5_000_000 ? "warning" : "info", String(format: "One session used %.1fx the usual tokens", ratio), "It moved \(BackendCostMath.format(worst.tokens)) tokens against a median of \(BackendCostMath.format(median)) across \(counted.count) sessions.", worst.last, session: worst.id, action: "open-inspector", label: "See where it went", target: worst.path))
            }
        }
        var wanted = Set(live.map { $0.observedAgentProvider ?? $0.session.provider }); if let preferred = await defaultProvider(project) { wanted.insert(preferred) }
        do {
            let path = try await providers.loginPath()
            for provider in wanted.sorted() where ["claude", "codex", "gemini"].contains(provider) {
                let binary = await providers.resolveBinary(provider, path: path)
                if binary.runnable == nil && binary.onPath == nil { alerts.append(alert("provider-missing:\(provider)", "provider-missing", "critical", "\(BackendAccountProfile.providerLabel(provider)) is not installed", "\(provider) is not on the login shell's PATH, so sessions cannot start with it.", now, action: "install-provider", label: "Set up \(BackendAccountProfile.providerLabel(provider))", target: provider)) }
            }
        } catch { coverage.append("Provider availability could not be read: " + error.localizedDescription) }
        do {
            let status = try await git.status(cwd: project, context: context)
            if status["repo"].bool == true {
                let paths = Set(["staged", "unstaged", "untracked", "conflicted"].flatMap { status[$0].elements ?? [] }.compactMap { $0["path"].string })
                var newest: Double?
                // A deletion has no mtime; source cannot establish its age.
                // Over 400 paths is unknown, never measured from a partial set.
                if paths.count <= 400 { for path in paths {
                    let url = try await projects.files.authority.resolve(root: status["root"].string ?? project, relative: path, context: context, intent: .read, mustExist: false).path
                    if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { newest = max(newest ?? 0, date.timeIntervalSince1970 * 1000) }
                } }
                if let newest, !paths.isEmpty { let streak = active.filter { $0.started > newest }.count
                    if streak >= 3 { alerts.append(alert("dirty-tree", "dirty-tree", streak >= 8 ? "warning" : "info", "\(paths.count) files uncommitted across \(streak) sessions", "Several sessions started on top of uncommitted work. Commit or stash before the next one.", newest, action: "open-git", label: "Open the git panel", target: project)) }
                }
            } else if status["reason"].string != "not-a-repo" { coverage.append("Git status is unavailable: " + (status["message"].string ?? "the status request failed")) }
        } catch { coverage.append("Git status is unavailable: " + error.localizedDescription) }
        alerts.sort(by: ordered)
        var counts: [String: Double] = ["critical": 0, "warning": 0, "info": 0]; for row in alerts { counts[row["severity"].string ?? "info", default: 0] += 1 }
        return BackendUsageIO.object([("projectPath", .string(project)), ("alerts", .array(alerts)), ("counts", .object(counts.keys.sorted().map { .init($0, .number(counts[$0]!)) })), ("worst", alerts.first?["severity"] ?? .null), ("scannedAt", .number(now)), ("coverage", .array(coverage.map(NativeRPCValue.string)))])
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard channel == "alerts:project" else { throw BackendSessionFailure.unsupported("The native alerts channel is not registered.") }
        return try await project((args.first ?? .missing).requireString("project path", nonempty: true), context: context)
    }
}
