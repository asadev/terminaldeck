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
    private struct Watching: Sendable { let project: String; let signature: String; let context: NativeRPCContext; let watch: BackendUsageFileWatch; var owners: [String: NativeRPCContext] }
    private var watching: [String: Watching] = [:]
    private var refreshes: [String: Task<Void, Never>] = [:]
    public init(projects: BackendProjectService, scopeProvider: @escaping BackendCostScopeProvider,
                push: @escaping @Sendable (String, String, NativeRPCValue) async -> Void) { self.projects = projects; self.scopeProvider = scopeProvider; self.push = push }
    public func scope(project: String?, context: NativeRPCContext) async throws -> NativeTranscriptScope { try await scopeProvider(project, context) }
    public func authorizeDataDirectory(_ path: String, context: NativeRPCContext) async throws { _ = try await projects.files.authority.authorize(path, context: context, intent: .read) }
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
                ownerGroups.append(try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []).sorted { $0.lastPathComponent < $1.lastPathComponent })
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
        if requireKnown { _ = try await projects.requireKnown(project) }
        _ = try await projects.files.authority.authorize(project, context: context, intent: .read)
        let scope = try await scopeProvider(project, context)
        var found: [NativeTranscriptFile] = []
        for directory in try NativeTranscriptPaths.projectDirectories(project, scope: scope) {
            for file in try NativeTranscriptPaths.listTranscripts(directory, scope: scope) {
                if try await BackendCompositionAuthorityTranscripts.belongs(file.path, scope: scope) { found.append(file) }
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
        let all = try await files(project: project, context: context), scope = try await scopeProvider(project, context), cutoff = BackendUsageIO.now() - 90 * 86_400_000
        let candidates = Array(all.filter { $0.modifiedAt >= cutoff }.prefix(400))
        var opened: [BackendCostTranscript] = [], carrying = 0, read = 0, bytes = 0
        for file in candidates {
            if carrying >= 40 { break }; try Task.checkCancellation()
            if cancellation?.isCancelled == true { throw CancellationError() }
            let transcript = try await BackendCostTranscript.read(path: file.path, scope: scope, cancellation: cancellation)
            try BackendCompositionAuthorityTranscripts.assertCwd(transcript.cwd, scope: scope)
            bytes += transcript.readBytes
            guard bytes <= 512 * 1024 * 1024 else { throw NativeRPCError.malformed("The project transcript scan exceeded its total byte budget.") }
            read += 1; if transcript.requestCount > 0 { carrying += 1 }; opened.append(transcript)
        }
        var seen = Set<String>(), usage = BackendCostTokens(), byModel: [String: BackendCostTokens] = [:], requests = 0
        for transcript in opened { for request in transcript.requests {
            if let key = request.key, !seen.insert(key).inserted { continue }
            requests += 1; usage.add(request.usage)
            if request.model != "<synthetic>" { byModel[request.model, default: BackendCostTokens()].add(request.usage) }
        } }
        let sessions = opened.filter { $0.requestCount > 0 }.sorted { $0.lastActivityAt > $1.lastActivityAt }
        let directories = try NativeTranscriptPaths.projectDirectories(project, scope: scope)
        return BackendUsageIO.object([("cwd", .string(project)), ("transcriptDir", .string(directories.first ?? URL(fileURLWithPath: scope.configDirectory).appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(project)).path)),
            ("sessions", .array(sessions.map(\.summary))), ("usage", usage.wireValue), ("usageByModel", .object(byModel.keys.sorted().map { .init($0, byModel[$0]!.wireValue) })),
            ("requests", .number(Double(requests))), ("activeSessionId", BackendUsageIO.string(sessions.first?.sessionID)), ("scanning", .bool(false)),
            ("truncated", .bool(all.count > read || opened.contains(where: \.truncated))), ("watching", .bool(watching)), ("updatedAt", .number(BackendUsageIO.now()))])
    }
    private func watchPaths(project: String, context: NativeRPCContext) async throws -> [String] {
        let scope = try await scopeProvider(project, context), directories = try NativeTranscriptPaths.projectDirectories(project, scope: scope)
        var paths = directories + directories.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        paths.append(scope.configDirectory)
        paths += try await files(project: project, context: context).prefix(24).map(\.path)
        return paths
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
    private func changed(_ project: String) {
        guard refreshes[project] == nil, let entry = watching[project] else { return }
        refreshes[project] = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.project(entry.project, context: entry.context, watching: true)
                try entry.watch.install(paths: await self.watchPaths(project: entry.project, context: entry.context))
                await self.deliver(project, value: summary)
            } catch { await self.deliver(project, value: BackendUsageIO.object([("cwd", .string(entry.project)), ("error", .string(error.localizedDescription))])) }
            await self.finished(project)
        }
    }
    private func finished(_ project: String) { refreshes[project] = nil }
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
        for key in Array(watching.keys) {
            guard var entry = watching[key], entry.project == project else { continue }; entry.owners[ownerID] = nil
            if entry.owners.isEmpty { entry.watch.stop(); refreshes[key]?.cancel(); refreshes[key] = nil; watching[key] = nil } else { watching[key] = entry }
        }
    }
    public func disconnect(ownerID: String) { for project in Set(watching.values.map(\.project)) { unwatch(project: project, ownerID: ownerID) } }
    public func stop() { refreshes.values.forEach { $0.cancel() }; refreshes.removeAll(); watching.values.forEach { $0.watch.stop() }; watching.removeAll() }
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
