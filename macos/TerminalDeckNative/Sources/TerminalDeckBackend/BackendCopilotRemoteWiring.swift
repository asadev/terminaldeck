import Foundation
import Darwin
import TerminalDeckNativeCore

/// remote/copilot-wiring.ts and copilot-consent.ts: only enumerated fields
/// cross to phones. Arguments are reserved for a question's actual approvers.
public enum BackendCopilotRemoteWiring {
    public static func actionRow(_ row: NativeRPCValue) -> NativeRPCValue {
        .object([.init("id", row["id"]), .init("at", row["at"]), .init("tool", row["tool"]), .init("tier", row["tier"]),
            .init("outcome", row["outcome"]), .init("detail", row["detail"]),
            .init("refusal", row["confirmed"]["reason"].isNullish ? .null : row["confirmed"]["reason"]),
            .init("deviceId", row["caller"]["deviceId"].isNullish ? .null : row["caller"]["deviceId"])])
    }
    public static func sessions(_ sessions: [BackendSessionMeta], status: (String) -> String) -> [NativeRPCValue] {
        sessions.filter { $0.origin == .copilot }.map { session in
            .object([.init("id", .string(session.id)), .init("title", .string(session.title)), .init("cwd", .string(session.cwd)),
                .init("provider", .string(session.provider)), .init("status", .string(status(session.id))), .init("startedAt", .number(session.createdAt)),
                .init("originRunId", session.originRunId.map(NativeRPCValue.string) ?? .null)])
        }
    }
    public static func tail(_ rows: [NativeRPCValue], limit: Double, before: String? = nil) -> (rows: [NativeRPCValue], more: Bool) {
        let count = Int(limit.isFinite ? min(max(limit.rounded(.towardZero), 1), 200) : 200)
        let end = before.flatMap { cursor in rows.firstIndex { $0["id"].string == cursor } } ?? rows.count
        let start = max(end - count, 0)
        return (rows[start..<end].map(actionRow), start > 0)
    }
    private static func phoneSummary(_ request: BackendDeckCoreSecurityConsentRequest) -> String {
        request.askedBy.map { "From “\($0)”: \(request.summary)" } ?? request.summary
    }
    public static func pendingRow(_ request: BackendDeckCoreSecurityConsentRequest, mine: Bool) -> NativeRPCValue {
        .object([.init("id", .string(request.id)), .init("tool", .string(request.tool)), .init("summary", .string(phoneSummary(request))),
            .init("requestedAt", .number(request.requestedAt)), .init("expiresAt", .number(request.expiresAt)), .init("mine", .bool(mine))])
    }
    public static func consentQuestion(_ request: BackendDeckCoreSecurityConsentRequest) -> NativeRPCValue {
        .object([.init("id", .string(request.id)), .init("tool", .string(request.tool)), .init("tier", .string(request.tier.rawValue)),
            .init("summary", .string(phoneSummary(request))), .init("args", request.arguments),
            .init("origin", .string(request.origin.hasPrefix("key:") ? request.label ?? request.origin : request.origin)),
            .init("requestedAt", .number(request.requestedAt)), .init("expiresAt", .number(request.expiresAt))])
    }
    public static func chatMessage(_ message: NativeRPCValue) -> NativeRPCValue {
        let text = message["text"].string ?? ""
        let over = text.utf16.count > BackendCopilotRemoteSurface.maximumMessageUnits
        let clipped = over ? String(decoding: Array(text.utf16.prefix(BackendCopilotRemoteSurface.maximumMessageUnits)), as: UTF16.self) : text
        var fields: [NativeRPCValue.Field] = [.init("id", message["id"]), .init("role", .string(["you", "user"].contains(message["role"].string ?? "") ? "you" : "agent")),
            .init("text", .string(clipped)), .init("at", message["at"])]
        if over || message["truncated"].bool == true { fields.append(.init("truncated", .bool(true))) }
        return .object(fields)
    }

    /// Index.ts assembly expressed against the existing native owners. The
    /// unresolved callbacks are authoritative app settings/desk/account reads,
    /// rather than substitutes for session input, spawn, tokens, log or chat.
    public static func dependencies(trust: BackendRemoteTrustStore, server: BackendDeckCoreSecurityServer,
                                    consent: @escaping @Sendable () async -> BackendDeckCoreSecurityConsentBroker?,
                                    spawner: BackendCopilotRemoteSpawner, manager: BackendPTYManager,
                                    actionLog: BackendDeckCoreSecurityActionLog,
                                    root: @escaping @Sendable () async throws -> String,
                                    desk: @escaping @Sendable () async throws -> BackendCopilotRemoteDesk,
                                    cost: @escaping @Sendable () async throws -> (tools: Int, turnTokens: Int),
                                    interactive: @escaping @Sendable (Bool) async throws -> Void,
                                    status: @escaping @Sendable (String) async -> String,
                                    transcriptScope: @escaping @Sendable (String) async throws -> NativeTranscriptScope,
                                    hidden: BackendRemoteServeSessionHidden = .shared) -> BackendCopilotRemoteRunDependencies {
        let registry = BackendCopilotRemoteSecurityRegistry(endpoint: { await server.currentEndpoint() })
        return .init(access: .init(trust: trust), consent: consent, callers: registry, endpoint: {
            guard let endpoint = await server.currentEndpoint() else { return nil }
            return try .init(url: endpoint.url, implementation: .native)
        }, root: root, spawn: { try await spawner.spawn($0) },
        isAlive: { id in manager.list().contains { $0.id == id && $0.exitCode == nil } },
        stop: { manager.kill($0) }, say: { id, text in
            try BackendCopilotRemoteSurface.typeAndSubmit(text, write: { try manager.write(id, data: $0) })
        }, interrupt: { try manager.write($0, data: "\u{3}") }, desk: desk, cost: cost, setInteractive: interactive,
        sessions: {
            var statuses: [String: String] = [:]
            let sessions = manager.list()
            for session in sessions where session.origin == .copilot { statuses[session.id] = await status(session.id) }
            return Self.sessions(sessions) { statuses[$0] ?? "unknown" }
        }, log: { limit, before in Self.tail(await actionLog.tail(2000), limit: Double(limit), before: before) },
        chat: { sessionID, callback in
            guard let session = manager.list().first(where: { $0.id == sessionID }) else { throw BackendSessionFailure.missingSession }
            let watcher = BackendCopilotRemoteChatWatcher(cwd: session.cwd, agentSessionID: session.agentSessionId,
                scope: try await transcriptScope(sessionID), update: callback)
            try await watcher.start()
            return { Task { await watcher.stop() } }
        }, hidden: hidden)
    }
}

/// Use deck-core's actual serving table, with its live identity callback and
/// cancellation. The endpoint is looked up anew for each run; a restart cannot
/// silently register a token in an old, non-serving table.
public actor BackendCopilotRemoteSecurityRegistry: BackendCopilotRemoteCallerRegistry {
    private struct Entry: Sendable {
        let table: BackendDeckCoreSecurityCallerTable
        let cancellation: BackendMCPCancellation
    }
    private let endpoint: @Sendable () async -> BackendDeckCoreSecurityEndpoint?
    private var entries: [UUID: Entry] = [:]
    public init(endpoint: @escaping @Sendable () async -> BackendDeckCoreSecurityEndpoint?) { self.endpoint = endpoint }
    public func register(token: String, endpointURL: URL, attended: Bool, caller: @escaping @Sendable () async -> BackendDeckCoreSecurityCaller,
                         cancellation: BackendMCPCancellation) async throws -> BackendMCPRegistration {
        guard let endpoint = await endpoint(), endpoint.url == endpointURL, !cancellation.isCancelled else {
            throw BackendSessionFailure.missingCapability("Hoot’s actual deck-control endpoint")
        }
        let id = try await endpoint.callers.set(token: token, grant: .init(attended: attended, cancellation: cancellation, caller: caller))
        entries[id] = Entry(table: endpoint.callers, cancellation: cancellation)
        let current = await self.endpoint()
        guard !cancellation.isCancelled, current?.url == endpointURL, current?.callers === endpoint.callers else {
            await revoke(.init(id: id)); throw BackendSessionFailure.closed
        }
        return .init(id: id)
    }
    public func revoke(_ registration: BackendMCPRegistration) async {
        guard let entry = entries.removeValue(forKey: registration.id) else { return }
        // Delete from the serving table first; its revoke aborts current calls.
        _ = await entry.table.revoke(registration.id)
        entry.cancellation.cancel()
    }
}

/// Real OS event watch, with the source's 2-second discovery fallback only
/// while a brand-new transcript directory/file does not exist. It ceases once
/// the exact named file is attached. No terminal bytes ever leave this reader.
public actor BackendCopilotRemoteChatWatcher {
    private let cwd: String
    private let sessionID: String?
    private let scope: NativeTranscriptScope
    private let update: @Sendable (BackendCopilotRemoteChatUpdate) async -> Void
    private var reader: NativeChatTranscriptReader?
    private var watches: [BackendCopilotRemoteFileWatch] = []
    private var fileWatch: BackendCopilotRemoteFileWatch?
    private var discovery: Task<Void, Never>?
    private var stopped = false
    private var attaching = false
    private var reading = false
    private var again = false
    public init(cwd: String, agentSessionID: String? = nil, scope: NativeTranscriptScope,
                update: @escaping @Sendable (BackendCopilotRemoteChatUpdate) async -> Void) {
        self.cwd = cwd; sessionID = agentSessionID; self.scope = scope; self.update = update
    }
    public func start() async throws {
        guard !stopped, watches.isEmpty, discovery == nil else { return }
        let directories = try NativeTranscriptPaths.projectDirectories(cwd, scope: scope)
        for directory in directories {
            if let watch = BackendCopilotRemoteFileWatch(path: directory, changed: { [weak self] in Task { await self?.attach() } }) { watches.append(watch) }
        }
        discovery = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }; await self.attach()
            }
        }
        await attach()
    }
    public func stop() {
        stopped = true; discovery?.cancel(); discovery = nil
        fileWatch?.close(); fileWatch = nil
        for watch in watches { watch.close() }; watches.removeAll(); reader = nil
    }
    private func attach() async {
        guard !stopped, reader == nil, !attaching else { return }
        attaching = true; defer { attaching = false }
        do {
            let path: String?
            if let sessionID {
                path = try NativeTranscriptPaths.projectDirectories(cwd, scope: scope).lazy.map {
                    URL(fileURLWithPath: $0).appendingPathComponent(sessionID + ".jsonl").path
                }.first { FileManager.default.fileExists(atPath: $0) }
            } else { path = try NativeTranscriptPaths.newest(cwd, scope: scope)?.path }
            guard !stopped, let path else { return }
            let checked = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
            // Install the watch before reading, avoiding a missed append between them.
            guard let watch = BackendCopilotRemoteFileWatch(path: checked, changed: { [weak self] in Task { await self?.drain() } }) else { return }
            fileWatch = watch
            reader = NativeChatTranscriptReader(path: checked, sessionID: sessionID, allowedRoots: try NativeTranscriptPaths.approvedRoots(scope))
            discovery?.cancel(); discovery = nil
            await drain()
        } catch { /* Local filesystem errors do not put a home path on the wire. */ }
    }
    private func drain() async {
        guard !stopped else { return }
        if reading { again = true; return }
        reading = true; defer { reading = false; again = false }
        do {
            repeat {
                again = false
                guard !stopped, let reader else { return }
                let chunk = try await reader.readAll()
                guard !stopped else { return }
                if !chunk.messages.isEmpty || chunk.reset {
                    let messages = chunk.messages.map { message in
                        NativeRPCValue.object([.init("id", .string(message.id)), .init("role", .string(message.role.rawValue)),
                            .init("text", .string(message.text)), .init("at", .number(message.at))])
                    }
                    await update(.init(messages: messages, reset: chunk.reset))
                }
            } while again
        } catch { /* Keep the run alive; transcript failure is a quiet chat, not PTY input. */ }
    }
}
private final class BackendCopilotRemoteFileWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var source: (any DispatchSourceFileSystemObject)?
    init?(path: String, changed: @escaping @Sendable () -> Void) {
        let fd = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: .global(qos: .utility))
        self.source = source; source.setEventHandler(handler: changed)
        source.setCancelHandler { Darwin.close(fd) }; source.resume()
    }
    func close() { lock.lock(); let old = source; source = nil; lock.unlock(); old?.cancel() }
    deinit { close() }
}
