import Foundation
import TerminalDeckNativeCore

public typealias BackendCostScopeProvider = @Sendable (_ project: String?, _ context: NativeRPCContext) async throws -> NativeTranscriptScope

/// One metrics catalogue and one watcher per project, shared by owner IDs.
/// The scope provider must derive account/device home access from trusted app
/// grants; the renderer never supplies an arbitrary configuration directory.
public actor BackendCostService {
    public static let channels: Set<String> = ["cost:project", "cost:session", "cost:sessions", "cost:watch", "cost:unwatch", "cost:format"]
    private let scopeProvider: BackendCostScopeProvider
    private let projects: BackendProjectService
    private let push: @Sendable (String, String, NativeRPCValue) async -> Void
    private let maximumCompletions: Int
    private let periodCalendar: @Sendable () -> Calendar
    private let periodNow: @Sendable () -> Date
    private struct Watching: Sendable { let project: String; let signature: String; let context: NativeRPCContext; let watch: BackendUsageFileWatch; var owners: [String: NativeRPCContext] }
    private var watching: [String: Watching] = [:]
    private var refreshes: [String: Task<Void, Never>] = [:]
    /// 18 Oct (#652): projects that changed while their refresh was already running: one more refresh follows.
    private var changedDuringRefresh = Set<String>()
    /// #26 (2 Nov, #25 CPU check): every transcript write re-added the whole project's cost and re-sent it to the
    /// Overview, all the time while agents worked. Now at most one recompute per `refreshSpacing` per project
    /// (trailing: the last write in a burst is always counted), and the Overview is sent a summary only when what it
    /// shows changed.
    private let refreshSpacing: TimeInterval
    private var lastRefreshAt: [String: Double] = [:]
    private var lastDelivered: [String: NativeRPCValue] = [:]
    /// Recomputes started by transcript changes (for tests and the report).
    private(set) var watchRecomputes = 0
    private let transcriptCache = BackendFIXESUsageCache()
    private var completions: [String: Task<Void, Never>] = [:]
    private var completionIDs: [String: UUID] = [:]
    private struct ProjectScan {
        let signature: String
        var cursor = 0
        var carrying = 0
        var skipped = 0
        var retainedBytes = 0
        var keyBytes = 0
        var modelBytes = 0
        var budgetReached = false
        var truncated = false
        var seen = Set<String>()
        var usage = BackendCostTokens()
        var byModel: [String: BackendCostTokens] = [:]
        var requests = 0
        var sessions: [NativeRPCValue] = []
        var memberships: [String] = []
        var value: NativeRPCValue?
        var finished = false
        var periodMinutes: [Int: PeriodMinute] = [:]
        var periodBytes = 0
        var unknownTimes = 0
        var periodTruncated = false
        var periodIdentity = ""
    }
    private struct PeriodMinute {
        var usage = BackendCostTokens()
        var requests = 0
        var byModel: [String: BackendCostTokens] = [:]
    }
    private struct PeriodWindow {
        let todayStart: Double
        let weekStart: Double
        let end: Double
        let timeZone: String
        let identity: String
        let approximate: Bool
    }
    private var projectScans: [String: ProjectScan] = [:]
    /// 18 Oct (#669): when each scan was last asked for, so the one left unused longest is the one let go.
    private var scanUse: [String: UInt64] = [:]
    private var scanTick: UInt64 = 0
    public init(projects: BackendProjectService, scopeProvider: @escaping BackendCostScopeProvider,
                maximumCompletions: Int = 12,
                periodCalendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent },
                periodNow: @escaping @Sendable () -> Date = { Date() },
                refreshSpacing: TimeInterval = 5,
                push: @escaping @Sendable (String, String, NativeRPCValue) async -> Void) {
        self.projects = projects; self.scopeProvider = scopeProvider; self.push = push; self.refreshSpacing = max(0, refreshSpacing)
        self.maximumCompletions = min(12, max(0, maximumCompletions))
        self.periodCalendar = periodCalendar; self.periodNow = periodNow
    }
    public func scope(project: String?, context: NativeRPCContext) async throws -> NativeTranscriptScope { try await scopeProvider(project, context) }
    public func authorizeDataDirectory(_ path: String, context: NativeRPCContext) async throws { _ = try await projects.files.authority.authorize(path, context: context, intent: .read) }
    /// One running session's own transcripts, scoped to that session's folder rather than to an open project (27 Oct
    /// walk, i; Asad's item 8: everything works with no project). Usage on a chat in a plain folder was refused
    /// "That folder is not an open project". Never wider than the caller's grant: a caller limited to some folders
    /// reads only a session inside them, and the folder still passes the caller's file authority.
    public static func sessionScope(_ granted: NativeTranscriptScope, folder: String) throws -> NativeTranscriptScope {
        if let permitted = granted.projectFolders, !permitted.contains(where: { BackendRemoteTrustStore.within($0, folder) }) {
            throw NativeRPCError(code: "access-denied", message: "That session's folder is outside this caller's grant.")
        }
        var scope = granted; scope.projectFolders = [folder]; return scope
    }
    /// `named`: the conversation the session is in. Then only that transcript is found and checked (28 Oct, CPU: the
    /// usage bar asked about once a second per shown session, and every call listed and proved every transcript in
    /// the folder, 41 to 100 of them, to keep one).
    public func sessionTranscripts(folder: String, context: NativeRPCContext, named: String? = nil) async throws -> (scope: NativeTranscriptScope, files: [NativeTranscriptFile]) {
        let scope = try Self.sessionScope(try await scopeProvider(nil, context), folder: folder)
        _ = try await projects.files.authority.authorize(folder, context: context, intent: .read)
        var found: [NativeTranscriptFile] = [], seen = Set<String>()
        for directory in try NativeTranscriptPaths.projectDirectories(folder, scope: scope) {
            let files = try named.map { id in try NativeTranscriptPaths.transcript(named: id, in: directory, scope: scope).map { [$0] } ?? [] }
                ?? NativeTranscriptPaths.listTranscripts(directory, scope: scope)
            for file in files where seen.insert(file.path).inserted {
                if try await BackendCompositionAuthorityTranscripts.belongs(file.path, scope: scope) { found.append(file) }
            }
        }
        return (scope, found.sorted { $0.modifiedAt == $1.modifiedAt ? $0.path < $1.path : $0.modifiedAt > $1.modifiedAt })
    }
    /// Every historical project directory in the caller's approved stores,
    /// including projects no longer open in the sidebar.
    public func allFiles(context: NativeRPCContext, cancellation: BackendMCPCancellation? = nil, deadline: Double? = nil) async throws -> [NativeTranscriptFile] {
        let scope = try await scopeProvider(nil, context)
        var found: [NativeTranscriptFile] = [], seen = Set<String>(), visited = 0
        let groups: [[URL]]
        if let permitted = scope.projectFolders {
            var scoped: [URL] = [], seenDirectories = Set<String>()
            for project in permitted {
                for directory in try NativeTranscriptPaths.projectDirectories(project, scope: scope) where seenDirectories.insert(directory).inserted {
                    guard FileManager.default.fileExists(atPath: directory) else { continue }
                    _ = try await projects.files.authority.authorize(directory, context: context, intent: .read)
                    scoped.append(URL(fileURLWithPath: directory))
                }
            }
            groups = [scoped]
        } else {
            var ownerGroups: [[URL]] = []
            for root in try NativeTranscriptPaths.approvedRoots(scope) {
                if !FileManager.default.fileExists(atPath: root) { continue }
                _ = try await projects.files.authority.authorize(root, context: context, intent: .read)
                // A root that cannot be listed (a folder link looping into itself) is skipped, not fatal.
                ownerGroups.append(((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent })
            }
            groups = ownerGroups
        }
        for directories in groups {
            guard directories.count <= scope.maximumDirectoryEntries else { throw NativeRPCError.malformed("The historical project directory exceeded its entry budget.") }
            for directory in directories {
                try Task.checkCancellation(); if cancellation?.isCancelled == true { throw CancellationError() }; if let deadline, BackendUsageIO.now() >= deadline { return found.sorted { $0.modifiedAt > $1.modifiedAt } }
                let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true else { continue }
                for file in try NativeTranscriptPaths.listTranscripts(directory.path, scope: scope) {
                    visited += 1; guard visited <= 100_000 else { throw NativeRPCError.malformed("The historical transcript catalogue exceeded its scan budget.") }
                    if seen.insert(file.path).inserted, try await BackendCompositionAuthorityTranscripts.belongs(file.path, scope: scope, cancellation: cancellation) { found.append(file) }
                }
                await Task.yield()
            }
        }
        return found.sorted { $0.modifiedAt > $1.modifiedAt }
    }
    public func files(project: String, context: NativeRPCContext, requireKnown: Bool = true) async throws -> [NativeTranscriptFile] {
        let scope = try await scopeProvider(project, context)
        var found: [NativeTranscriptFile] = []
        for file in try await catalogue(project: project, context: context, requireKnown: requireKnown) {
            if try await BackendCompositionAuthorityTranscripts.belongs(file.path, scope: scope) { found.append(file) }
        }
        return found
    }
    private func catalogue(project: String, context: NativeRPCContext, requireKnown: Bool = true) async throws -> [NativeTranscriptFile] {
        if requireKnown { _ = try await projects.requireKnown(project) }
        _ = try await projects.files.authority.authorize(project, context: context, intent: .read)
        let scope = try await scopeProvider(project, context)
        var found: [NativeTranscriptFile] = []
        for directory in try NativeTranscriptPaths.projectDirectories(project, scope: scope) {
            for file in try NativeTranscriptPaths.listTranscripts(directory, scope: scope) {
                found.append(file)
            }
        }
        var seen = Set<String>(); return found.filter { seen.insert($0.path).inserted }.sorted { $0.modifiedAt == $1.modifiedAt ? $0.path < $1.path : $0.modifiedAt > $1.modifiedAt }
    }
    public func session(path: String, context: NativeRPCContext, cancellation: BackendMCPCancellation? = nil) async throws -> BackendCostTranscript {
        let scope = try await scopeProvider(nil, context)
        guard try await BackendCompositionAuthorityTranscripts.belongs(path, scope: scope, cancellation: cancellation) else { throw NativeRPCError(code: "access-denied", message: "This transcript belongs to a different granted project") }
        let result = try await BackendCostTranscript.read(path: path, scope: scope, cancellation: cancellation)
        try BackendCompositionAuthorityTranscripts.assertCwd(result.cwd, scope: scope)
        return result
    }
    public func project(_ project: String, context: NativeRPCContext, cancellation: BackendMCPCancellation? = nil, watching: Bool = false) async throws -> NativeRPCValue {
        var value = try await projectStep(project, context: context, cancellation: cancellation, watching: watching)
        if value["scanning"].bool == true, !(await completeProject(project, context: context)) {
            value = value.merging(BackendUsageIO.object([("scanning", .bool(false)), ("truncated", .bool(true)), ("canRetry", .bool(true)),
                ("scanNote", .string("Showing the records read so far. Other Usage reads are finishing; choose Try Again to continue."))]))
            await push(context.ownerID, "cost:update", value)
        }
        return value
    }
    private func projectStep(_ project: String, context: NativeRPCContext, cancellation: BackendMCPCancellation? = nil, watching: Bool = false) async throws -> NativeRPCValue {
        _ = try await projects.requireKnown(project)
        _ = try await projects.files.authority.authorize(project, context: context, intent: .read)
        let scope = try await scopeProvider(project, context)
        let deadline = BackendFIXESUsageCache.budgetNow() + 250
        let catalogue = try await transcriptCache.catalogue(project: project, scope: scope, deadline: deadline)
        let all = catalogue.files, cutoff = BackendUsageIO.now() - 90 * 86_400_000
        let candidates = Array(all.filter { $0.modifiedAt >= cutoff }.prefix(400))
        let roots = try NativeTranscriptPaths.approvedRoots(scope).sorted().joined(separator: "\n")
        let key = context.ownerID + "\n" + NativeTranscriptPaths.resolved(project) + "\n" + roots + "\n" + (scope.projectFolders ?? []).sorted().joined(separator: "\n")
        let signature = candidates.map { [$0.path, String($0.bytes), String($0.modifiedAt), $0.identity].joined(separator: ":") }.joined(separator: "\n")
        scanTick &+= 1; scanUse[key] = scanTick
        var scan = projectScans[key].flatMap { $0.signature == signature ? $0 : nil } ?? ProjectScan(signature: signature)
        for cwd in scan.memberships { try BackendCompositionAuthorityTranscripts.assertCwd(cwd, scope: scope) }
        if scan.finished, let value = scan.value {
            let window = periodsWindow()
            let periods = scan.periodIdentity != window.identity
                ? periodValues(scan, window: window, scanning: catalogue.scanning, truncated: value["truncated"].bool == true || catalogue.limited)
                : periodStatus(value["periods"], scanning: catalogue.scanning, truncated: value["truncated"].bool == true || catalogue.limited, scan: scan)
            let result = value.merging(BackendUsageIO.object([("periods", periods), ("scanning", .bool(catalogue.scanning)), ("scanBytesRead", .number(0)),
                ("truncated", .bool(value["truncated"].bool == true || catalogue.limited)),
                ("scanProgress", .number(Double(catalogue.progress + scan.cursor))), ("watching", .bool(watching))]))
            if scan.periodIdentity != window.identity {
                scan.periodIdentity = window.identity; scan.value = result; projectScans[key] = scan
            }
            return result
        }
        var bytes = 0, active: BackendCostTranscript?
        while scan.cursor < candidates.count, scan.carrying < 40, !scan.budgetReached {
            try Task.checkCancellation()
            if cancellation?.isCancelled == true { throw CancellationError() }
            if BackendFIXESUsageCache.budgetNow() >= deadline { break }
            let file = candidates[scan.cursor]
            do {
                let result = try await transcriptCache.read(path: file.path, scope: scope, cwd: project,
                    deadline: deadline, cancellation: cancellation)
                bytes += result.bytesRead
                if result.scanning { active = result.transcript; break }
                merge(result.transcript, into: &scan)
                scan.retainedBytes += result.transcript.readBytes
                scan.truncated = scan.truncated || result.limited || result.transcript.truncated
                if scan.retainedBytes >= 512 * 1024 * 1024 { scan.budgetReached = true }
                scan.cursor += 1
            } catch is CancellationError { throw CancellationError() }
            catch { scan.skipped += 1; scan.cursor += 1 }
        }
        var shown = scan
        if let active { merge(active, into: &shown) }
        let scanning = catalogue.scanning || (!scan.budgetReached && scan.carrying < 40 && scan.cursor < candidates.count)
        let directories = try NativeTranscriptPaths.projectDirectories(project, scope: scope)
        let sessions = shown.sessions.sorted { ($0["lastActivityAt"].number ?? 0) > ($1["lastActivityAt"].number ?? 0) }
        let truncated = catalogue.limited || shown.budgetReached || shown.truncated || all.count > scan.cursor || scan.skipped > 0
        let window = periodsWindow()
        let value = BackendUsageIO.object([("cwd", .string(project)), ("transcriptDir", .string(directories.first ?? URL(fileURLWithPath: scope.configDirectory).appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(project)).path)),
            ("sessions", .array(sessions)), ("usage", shown.usage.wireValue), ("usageByModel", .object(shown.byModel.keys.sorted().map { .init($0, shown.byModel[$0]!.wireValue) })),
            ("requests", .number(Double(shown.requests))), ("activeSessionId", BackendUsageIO.string(sessions.first?["sessionId"].string)), ("scanning", .bool(scanning)),
            ("truncated", .bool(truncated)), ("watching", .bool(watching)),
            ("periods", periodValues(shown, window: window, scanning: scanning, truncated: truncated)),
            ("scanBytesRead", .number(Double(bytes))), ("scanProgress", .number(Double(catalogue.progress + scan.cursor))),
            ("skippedTranscripts", .number(Double(scan.skipped))), ("updatedAt", .number(BackendUsageIO.now()))])
        scan.value = value; scan.finished = !scanning; scan.periodIdentity = window.identity
        if scan.finished { scan.seen.removeAll(); scan.keyBytes = 0 }
        projectScans[key] = scan
        for old in Self.evicted(Array(projectScans.keys), keeping: key, used: scanUse, limit: 12) { projectScans[old] = nil; scanUse[old] = nil }
        if scanUse.count > 48 { scanUse = scanUse.filter { projectScans[$0.key] != nil } }
        return value
    }
    /// The scans to let go once more than `limit` are kept: the least recently asked for, never the current one.
    static func evicted(_ keys: [String], keeping current: String, used: [String: UInt64], limit: Int) -> [String] {
        guard keys.count > limit else { return [] }
        return Array(keys.filter { $0 != current }.sorted { (used[$0] ?? 0) < (used[$1] ?? 0) }.prefix(keys.count - limit))
    }
    private func merge(_ transcript: BackendCostTranscript, into scan: inout ProjectScan) {
        for request in transcript.requests {
            if let key = request.key {
                if scan.seen.contains(key) { continue }
                if scan.seen.count >= 250_000 || scan.keyBytes + key.utf8.count > 16 * 1024 * 1024 {
                    scan.budgetReached = true; break
                }
                scan.seen.insert(key); scan.keyBytes += key.utf8.count
            }
            if request.model != "<synthetic>", scan.byModel[request.model] == nil {
                if scan.byModel.count >= 1_024 || scan.modelBytes + request.model.utf8.count > 2 * 1024 * 1024 {
                    scan.budgetReached = true; break
                }
                scan.modelBytes += request.model.utf8.count
            }
            scan.requests += 1; scan.usage.add(request.usage)
            foldPeriod(request, into: &scan)
            if request.model != "<synthetic>" { scan.byModel[request.model, default: BackendCostTokens()].add(request.usage) }
        }
        if transcript.requestCount > 0 {
            scan.carrying += 1
            let summary = overviewSummary(transcript); scan.sessions.append(summary)
            scan.truncated = scan.truncated || summary["truncated"].bool == true
        }
        if !transcript.cwd.isEmpty { scan.memberships.append(transcript.cwd) }
        scan.truncated = scan.truncated || transcript.truncated
    }
    private func periodsWindow() -> PeriodWindow {
        let calendar = periodCalendar(), now = periodNow(), start = calendar.startOfDay(for: now)
        let next = calendar.date(byAdding: .day, value: 1, to: start)
        let week = calendar.date(byAdding: .day, value: -6, to: start)
        let a = start.timeIntervalSince1970 * 1000
        let b = (week ?? start.addingTimeInterval(-6 * 86_400)).timeIntervalSince1970 * 1000
        let end = (next ?? start.addingTimeInterval(86_400)).timeIntervalSince1970 * 1000
        let zone = calendar.timeZone.identifier
        return PeriodWindow(todayStart: a, weekStart: b, end: end, timeZone: zone,
            identity: String(describing: calendar.identifier) + ":" + zone + ":" + String(a) + ":" + String(b) + ":" + String(end),
            approximate: next == nil || week == nil)
    }
    /// Keep only compact UTC-minute totals for recent periods. Midnight and
    /// timezone changes re-fold these totals, never start another file scan.
    private func foldPeriod(_ request: BackendCostRequest, into scan: inout ProjectScan) {
        guard request.at > 0 else { scan.unknownTimes += 1; return }
        let now = periodNow().timeIntervalSince1970 * 1000
        guard request.at >= now - 10 * 86_400_000, request.at <= now + 2 * 86_400_000 else { return }
        let minute = Int(floor(request.at / 60_000))
        var bucket = scan.periodMinutes[minute] ?? PeriodMinute()
        var added = scan.periodMinutes[minute] == nil ? 512 : 0
        if request.model != "<synthetic>", bucket.byModel[request.model] == nil { added += 128 + request.model.utf8.count }
        guard scan.periodBytes + added <= 16 * 1024 * 1024, scan.periodMinutes.count < 20_000 || scan.periodMinutes[minute] != nil else {
            scan.periodTruncated = true; return
        }
        bucket.requests += 1; bucket.usage.add(request.usage)
        if request.model != "<synthetic>" { bucket.byModel[request.model, default: BackendCostTokens()].add(request.usage) }
        scan.periodMinutes[minute] = bucket; scan.periodBytes += added
    }
    private func periodValues(_ scan: ProjectScan, window: PeriodWindow, scanning: Bool, truncated: Bool) -> NativeRPCValue {
        func value(start: Double) -> NativeRPCValue {
            var usage = BackendCostTokens(), requests = 0, byModel: [String: BackendCostTokens] = [:]
            var bars = [Double](repeating: 0, count: 12)
            for (minute, bucket) in scan.periodMinutes {
                let at = Double(minute) * 60_000
                guard at >= start, at < window.end else { continue }
                requests += bucket.requests; usage.add(bucket.usage)
                for (model, tokens) in bucket.byModel { byModel[model, default: BackendCostTokens()].add(tokens) }
                let index = min(11, max(0, Int((at - start) / max(1, window.end - start) * 12)))
                bars[index] += bucket.usage.total
            }
            let maximum = bars.max() ?? 0
            if maximum > 0 { bars = bars.map { $0 / maximum } }
            let partial = scanning || truncated || scan.periodTruncated || scan.unknownTimes > 0 || window.approximate
            return BackendUsageIO.object([("usage", usage.wireValue), ("requests", .number(Double(requests))),
                ("usageByModel", .object(byModel.keys.sorted().map { .init($0, byModel[$0]!.wireValue) })),
                ("bars", .array(bars.map(NativeRPCValue.number))), ("startAt", .number(start)), ("endAt", .number(window.end)),
                ("timeZone", .string(window.timeZone)), ("scanning", .bool(scanning)), ("truncated", .bool(truncated || scan.periodTruncated)),
                ("partial", .bool(partial)), ("unknownTimestamps", .number(Double(scan.unknownTimes)))])
        }
        return BackendUsageIO.object([("today", value(start: window.todayStart)), ("week", value(start: window.weekStart))])
    }
    private func periodStatus(_ periods: NativeRPCValue, scanning: Bool, truncated: Bool, scan: ProjectScan) -> NativeRPCValue {
        .object(["today", "week"].map { key in
            let value = periods[key]
            let partial = scanning || truncated || scan.periodTruncated || scan.unknownTimes > 0
            return .init(key, value.merging(BackendUsageIO.object([("scanning", .bool(scanning)),
                ("truncated", .bool(truncated || scan.periodTruncated)), ("partial", .bool(partial))])))
        })
    }
    /// Context and tokens remain exact for the records read. Bound the model
    /// labels in retained card summaries; full session/insights reads retain
    /// their existing parser and schema without this Overview metadata cap.
    private func overviewSummary(_ transcript: BackendCostTranscript) -> NativeRPCValue {
        var models: [String: BackendCostTokens] = [:], omitted = false
        for request in transcript.requests where request.model != "<synthetic>" {
            if models[request.model] == nil, models.count >= 32 { omitted = true; continue }
            models[request.model, default: BackendCostTokens()].add(request.usage)
        }
        let names = models.keys.sorted {
            models[$0]!.total == models[$1]!.total ? $0 < $1 : models[$0]!.total > models[$1]!.total
        }
        return BackendUsageIO.object([("sessionId", .string(transcript.sessionID)), ("transcriptPath", .string(transcript.path)),
            ("cwd", .string(transcript.cwd)), ("models", .array(names.map(NativeRPCValue.string))),
            ("requests", .number(Double(transcript.requestCount))), ("usage", transcript.usage.wireValue),
            ("usageByModel", .object(names.map { .init($0, models[$0]!.wireValue) })),
            ("context", transcript.context), ("warnings", .array(transcript.warnings)), ("preContextTokens", .number(transcript.prefix)),
            ("compactions", .number(Double(transcript.compactions.count))),
            ("sidechainRequests", .number(Double(transcript.requests.reduce(0) { $0 + ($1.sidechain ? 1 : 0) }))),
            ("startedAt", .number(transcript.startedAt)), ("lastActivityAt", .number(transcript.lastActivityAt)),
            ("truncated", .bool(transcript.truncated || omitted)), ("bytesRead", .number(Double(transcript.readBytes)))])
    }
    /// One finite completion per caller/project. No timer or idle polling.
    /// Each step repeats the current scope and filesystem grant checks.
    private func completeProject(_ project: String, context: NativeRPCContext) async -> Bool {
        let key = context.ownerID + "\n" + NativeTranscriptPaths.resolved(project)
        if completions[key] != nil { return true }
        guard completions.count < maximumCompletions else { return false }
        let id = UUID(); completionIDs[key] = id
        completions[key] = Task { [weak self] in
            guard let self else { return }
            do {
                var value: NativeRPCValue, previous: NativeRPCValue?, unchanged = 0
                let limit = BackendFIXESUsageCache.budgetNow() + 60_000
                var publishedAt = 0.0
                repeat {
                    try Task.checkCancellation()
                    value = try await self.projectStep(project, context: context, watching: true)
                    let progress = BackendUsageIO.object([("requests", value["requests"]), ("bytes", value["scanBytesRead"]),
                        ("position", value["scanProgress"]), ("sessions", value["sessions"]), ("skipped", value["skippedTranscripts"])])
                    unchanged = value["scanBytesRead"].number == 0 && progress == previous ? unchanged + 1 : 0
                    previous = progress
                    if unchanged >= 32 || BackendFIXESUsageCache.budgetNow() >= limit {
                        value = value.merging(BackendUsageIO.object([("scanning", .bool(false)), ("truncated", .bool(true)),
                            ("canRetry", .bool(true)),
                            ("scanNote", .string("Showing the records read so far. Open Usage again to continue."))]))
                    }
                    if value["scanning"].bool == false || BackendFIXESUsageCache.budgetNow() - publishedAt >= 250 {
                        await self.push(context.ownerID, "cost:update", value); publishedAt = BackendFIXESUsageCache.budgetNow()
                    }
                    await Task.yield()
                } while value["scanning"].bool == true
            } catch is CancellationError { }
            catch {
                await self.push(context.ownerID, "cost:update", BackendUsageIO.object([
                    ("cwd", .string(project)), ("error", .string(error.localizedDescription))]))
            }
            await self.completedProject(key, id: id)
        }
        return true
    }
    private func completedProject(_ key: String, id: UUID) {
        guard completionIDs[key] == id else { return }
        completions[key] = nil; completionIDs[key] = nil
    }
    private func watchPaths(project: String, context: NativeRPCContext) async throws -> [String] {
        let scope = try await scopeProvider(project, context), directories = try NativeTranscriptPaths.projectDirectories(project, scope: scope)
        var paths = directories + directories.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        paths.append(scope.configDirectory)
        paths += try await transcriptCache.catalogue(project: project, scope: scope, deadline: BackendFIXESUsageCache.budgetNow() + 100).files.prefix(24).map(\.path)
        // A folder link that points back into itself ("Too many levels of symbolic links", 11 Oct) is never
        // followed: a path that does not resolve to a real place is left out instead of failing the whole watch.
        return paths.filter { path in path.withCString { realpath($0, nil) }.map { free($0); return true } ?? false }
    }
    public func watch(project: String, ownerID: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        let project = NativeTranscriptPaths.resolved(project), scope = try await scopeProvider(project, context)
        let signature = try NativeTranscriptPaths.approvedRoots(scope).sorted().joined(separator: "\n")
        let key = project + "\n" + signature
        _ = try await projects.files.authority.authorize(project, context: context, intent: .read)
        if var entry = watching[key] { entry.owners[ownerID] = context; watching[key] = entry }
        else {
            guard watching.count < 12 else { throw NativeRPCError.malformed("Too many projects are watching transcripts at once.") }
            let watch = BackendUsageFileWatch { [weak self] in Task { await self?.changed(key) } }
            guard try watch.install(paths: await watchPaths(project: project, context: context)) > 0 else { throw NativeRPCError(code: "missing-capability", message: "No existing transcript directory can be monitored for this project.") }
            watching[key] = Watching(project: project, signature: signature, context: context, watch: watch, owners: [ownerID: context])
        }
        do { return try await self.project(project, context: context, watching: true) }
        catch { unwatch(project: project, ownerID: ownerID); throw error }
    }
    /// How long a change waits before its recompute: none when the last one is `spacing` old, else the rest.
    static func refreshWait(lastAt: Double?, now: Double, spacing: TimeInterval) -> TimeInterval {
        guard let lastAt else { return 0 }
        return max(0, lastAt + spacing - now)
    }
    /// What the Overview shows, without the fields that move on every scan.
    static func shownSummary(_ value: NativeRPCValue) -> NativeRPCValue {
        guard let fields = value.fields else { return value }
        return .object(fields.filter { !["updatedAt", "scanBytesRead", "scanProgress"].contains($0.key) })
    }
    private func changed(_ project: String) {
        guard watching[project] != nil else { return }
        guard refreshes[project] == nil else { changedDuringRefresh.insert(project); return }
        let wait = Self.refreshWait(lastAt: lastRefreshAt[project], now: Date().timeIntervalSince1970, spacing: refreshSpacing)
        refreshes[project] = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, !Task.isCancelled else { return }
            await self.recompute(project)
        }
    }
    private func recompute(_ project: String) async {
        guard let entry = watching[project] else { refreshes[project] = nil; return }
        changedDuringRefresh.remove(project) // writes during the wait are part of this recompute
        lastRefreshAt[project] = Date().timeIntervalSince1970; watchRecomputes += 1
        do {
            let summary = try await self.project(entry.project, context: entry.context, watching: true)
            try entry.watch.install(paths: await self.watchPaths(project: entry.project, context: entry.context))
            let shown = Self.shownSummary(summary)
            if lastDelivered[project] != shown { lastDelivered[project] = shown; await self.deliver(project, value: summary) }
        } catch { await self.deliver(project, value: BackendUsageIO.object([("cwd", .string(entry.project)), ("error", .string(error.localizedDescription))])) }
        finished(project)
    }
    private func finished(_ project: String) {
        refreshes[project] = nil
        if changedDuringRefresh.remove(project) != nil { changed(project) }
    }
    private func deliver(_ key: String, value: NativeRPCValue) async {
        guard let entry = watching[key] else { return }
        for (owner, context) in entry.owners {
            do {
                _ = try await projects.files.authority.authorize(entry.project, context: context, intent: .read)
                let scope = try await scopeProvider(entry.project, context), signature = try NativeTranscriptPaths.approvedRoots(scope).sorted().joined(separator: "\n")
                guard signature == entry.signature else { throw NativeRPCError(code: "access-denied", message: "This caller's transcript scope changed; subscribe again with its current grant.") }
                await push(owner, "cost:update", value)
            } catch { await push(owner, "cost:update", BackendUsageIO.object([("cwd", .string(entry.project)), ("error", .string(error.localizedDescription))])); unwatch(project: entry.project, ownerID: owner) }
        }
    }
    /// Call after a new confined/account home is created; no second PTY owner.
    public func refreshWatchers() { for project in watching.keys { changed(project) } }
    public func unwatch(project: String, ownerID: String) {
        let project = NativeTranscriptPaths.resolved(project)
        let completion = ownerID + "\n" + project
        completions[completion]?.cancel(); completions[completion] = nil; completionIDs[completion] = nil
        for key in Array(watching.keys) {
            guard var entry = watching[key], entry.project == project else { continue }; entry.owners[ownerID] = nil
            if entry.owners.isEmpty {
                entry.watch.stop(); refreshes[key]?.cancel(); refreshes[key] = nil; changedDuringRefresh.remove(key); watching[key] = nil
                lastRefreshAt[key] = nil; lastDelivered[key] = nil
            } else { watching[key] = entry }
        }
    }
    public func disconnect(ownerID: String) {
        for key in Array(projectScans.keys) where key.hasPrefix(ownerID + "\n") { projectScans[key] = nil; scanUse[key] = nil }
        for key in Array(completions.keys) where key.hasPrefix(ownerID + "\n") {
            completions[key]?.cancel(); completions[key] = nil; completionIDs[key] = nil
        }
        for project in Set(watching.values.map(\.project)) { unwatch(project: project, ownerID: ownerID) }
    }
    public func stop() async {
        completions.values.forEach { $0.cancel() }; completions.removeAll(); completionIDs.removeAll()
        refreshes.values.forEach { $0.cancel() }; refreshes.removeAll(); changedDuringRefresh.removeAll()
        watching.values.forEach { $0.watch.stop() }; watching.removeAll()
        projectScans.removeAll(); scanUse.removeAll()
        await transcriptCache.removeAll()
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], ownerID: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        let first = args.first ?? .missing
        switch channel {
        case "cost:project": return try await project(first.requireString("project", nonempty: true), context: context)
        case "cost:session": return try await session(path: first.requireString("transcript path", nonempty: true), context: context).summary
        case "cost:sessions": return .array(try await files(project: first.requireString("project", nonempty: true), context: context).map { try NativeRPCValue.fromFoundation($0.wireValue) })
        case "cost:watch": return try await watch(project: first.requireString("project", nonempty: true), ownerID: ownerID, context: context)
        case "cost:unwatch": unwatch(project: try first.requireString("project", nonempty: true), ownerID: ownerID); return .null
        case "cost:format": return BackendUsageIO.object([("tokens", .string(BackendCostMath.format(first["tokens"].number ?? 0)))])
        default: throw BackendSessionFailure.unsupported("The native token/context channel is not registered.")
        }
    }
}
