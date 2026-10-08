import Foundation
import TerminalDeckNativeCore

private final class BackendCopilotSessionIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    func set(_ value: String?) { lock.withLock { id = value } }
    func contains(_ value: String) -> Bool { lock.withLock { id != nil && id == value } }
}

public enum BackendCopilotSessionStatus: String, Sendable { case stopped, starting, running }
public struct BackendCopilotSessionSignIn: Sendable {
    public let state: String
    public let account: String?
    public let plan: String?
    public let profileId: String
    public let profileName: String
    public let checkedAt: Double
    public var wireValue: NativeRPCValue {
        BackendCopilotInspect.object([("state", .string(state)), ("account", BackendCopilotInspect.optional(account)), ("plan", BackendCopilotInspect.optional(plan)),
            ("profileId", .string(profileId)), ("profileName", .string(profileName)), ("checkedAt", .number(checkedAt))])
    }
}
public struct BackendCopilotSessionRecords: Sendable {
    public let kind: String
    public let enforced: Bool
    public let reason: String?
    public let paths: [String]
    public var wireValue: NativeRPCValue { BackendCopilotInspect.object([("kind", .string(kind)), ("enforced", .bool(enforced)), ("reason", BackendCopilotInspect.optional(reason)), ("paths", .array(paths.map(NativeRPCValue.string)))]) }
}
public struct BackendCopilotSessionState: Sendable {
    public let status: BackendCopilotSessionStatus
    public let sessionId: String?
    public let paths: BackendCopilotPaths
    public let folder: BackendCopilotFolderReport
    public let home: String
    public let startedAt: Double?
    public let problem: String?
    public let records: BackendCopilotSessionRecords
    public let profile: BackendAccountIdentity?
    public let instructionsAreDefault: Bool
    public let instructions: BackendCopilotInstructionsState
    public let startupFiles: [BackendCopilotStartupFile]
    public let layerFiles: [BackendCopilotStartupFile]
    public var wireValue: NativeRPCValue {
        let identity = profile.map { BackendCopilotInspect.object([("id", .string($0.id)), ("name", .string($0.name))]) } ?? .null
        return BackendCopilotInspect.object([("status", .string(status.rawValue)), ("sessionId", BackendCopilotInspect.optional(sessionId)), ("paths", paths.wireValue),
            ("folder", folder.wireValue), ("home", .string(home)), ("startedAt", startedAt.map(NativeRPCValue.number) ?? .null), ("problem", BackendCopilotInspect.optional(problem)),
            ("records", records.wireValue), ("profile", identity), ("instructionsAreDefault", .bool(instructionsAreDefault)), ("instructions", .string(instructions.rawValue)),
            ("startupFiles", .array(startupFiles.map(\.wireValue))), ("layerFiles", .array(layerFiles.map(\.wireValue)))])
    }
}
public struct BackendCopilotSessionFence: Sendable {
    /// Existing BackendMacConfinement.recordsFenceID, never renderer input.
    public let id: String
    public let kind: String
    public init(id: String = BackendMacConfinement.recordsFenceID, kind: String = "seatbelt") { self.id = id; self.kind = kind }
}
public struct BackendCopilotSessionFenceMeasurement: Sendable {
    public let fence: BackendCopilotSessionFence?
    public let reason: String?
    public init(fence: BackendCopilotSessionFence?, reason: String?) { self.fence = fence; self.reason = reason }
}
/// A fenced launch whose records proof failed again at spawn time. Source
/// measures once and wraps the spawn; the native launcher re-proves, so this
/// second failure gets the same visible fail-open result, never a Hoot outage.
public struct BackendCopilotSessionFenceLost: Error, LocalizedError, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}
/// The existing macOS confinement owner must expose its one canonical resolver
/// and its per-start proof. Missing proof is a visible, fail-open records result.
public protocol BackendCopilotSessionRecordsProviding: Sendable {
    func paths(userData: String) async throws -> BackendCopilotLayerRecords
    func measure(userData: String) async -> BackendCopilotSessionFenceMeasurement
}
public struct BackendCopilotSessionUnavailableRecords: BackendCopilotSessionRecordsProviding {
    public init() {}
    public func paths(userData: String) async throws -> BackendCopilotLayerRecords {
        throw NativeRPCError(code: "unavailable", message: "Hoot's canonical records fence resolver is unavailable.")
    }
    public func measure(userData: String) async -> BackendCopilotSessionFenceMeasurement {
        .init(fence: nil, reason: "This app’s own routines and action log could not be held against Hoot on this machine: the native records fence proof is unavailable.")
    }
}
/// Reuse the app's profile, sign-in and launcher graph. Local Hoot passes no
/// guest Git environment and no paired-device confinement, exactly as TS does.
public protocol BackendCopilotSessionDriving: Sendable {
    func hasClaude() async throws -> Bool
    func resolveProfile(projectPath: String) async throws -> BackendAccountProfile
    func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?)
    func start(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta
    func isAlive(_ sessionID: String) async -> Bool
    func stop(_ sessionID: String) async throws
}
public struct BackendCopilotSessionUnavailableDriver: BackendCopilotSessionDriving {
    public init() {}
    private func unavailable() -> NativeRPCError { .init(code: "unavailable", message: "Hoot's native session/profile driver is unavailable.") }
    public func hasClaude() async throws -> Bool { throw unavailable() }
    public func resolveProfile(projectPath: String) async throws -> BackendAccountProfile { throw unavailable() }
    public func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?) { throw unavailable() }
    public func start(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta { throw unavailable() }
    public func isAlive(_ sessionID: String) async -> Bool { false }
    public func stop(_ sessionID: String) async throws { throw unavailable() }
}
public struct BackendCopilotSessionTools: Sendable {
    public let configPath: String
    public let tools: [BackendCopilotLayerTool]
    public let leaseID: UUID
    public init(configPath: String, tools: [BackendCopilotLayerTool], leaseID: UUID) { self.configPath = configPath; self.tools = tools; self.leaseID = leaseID }
}
public protocol BackendCopilotSessionToolProviding: Sendable {
    /// Nil is an actually absent server, never a guessed/stale config path.
    func prepare() async throws -> BackendCopilotSessionTools?
    func bind(_ tools: BackendCopilotSessionTools, sessionID: String) async throws
    func abandon(_ tools: BackendCopilotSessionTools) async
    func release(sessionID: String) async
}
public struct BackendCopilotSessionDependencies: Sendable {
    public let userData: String
    public let storageDir: String
    public let chosenFolder: @Sendable () async throws -> NativeRPCValue
    public let driver: any BackendCopilotSessionDriving
    public let records: any BackendCopilotSessionRecordsProviding
    public let tools: (any BackendCopilotSessionToolProviding)?
    public let chat: BackendHootChatStore?
    public let cols: Int
    public let rows: Int
    public init(userData: String, storageDir: String? = nil,
                chosenFolder: @escaping @Sendable () async throws -> NativeRPCValue = { .null },
                driver: any BackendCopilotSessionDriving, records: any BackendCopilotSessionRecordsProviding,
                tools: (any BackendCopilotSessionToolProviding)? = nil, chat: BackendHootChatStore? = nil, cols: Int = 120, rows: Int = 30) {
        self.userData = userData; self.storageDir = storageDir ?? URL(fileURLWithPath: userData).appendingPathComponent("remote").path
        self.chosenFolder = chosenFolder; self.driver = driver; self.records = records; self.tools = tools; self.chat = chat; self.cols = cols; self.rows = rows
    }
}

/// The one desk Hoot. Construct one actor for the assembled app, never one per
/// window. A Task latch survives actor reentrancy across every startup await.
public actor BackendCopilotSessionRuntime {
    public static let homeKey = "copilot"
    public static let signInTTLMilliseconds: Double = 60_000
    public static let channels = ["copilot:ensure", "copilot:state", "copilot:files", "copilot:stop", "copilot:signin", "copilot:read-instructions", "copilot:read-contract", "copilot:read-composed", "copilot:write-instructions", "copilot:read-folder-instructions", "copilot:write-folder-instructions", "copilot:reset-instructions"] + BackendHootChatChannels.invokes
    public nonisolated let structuredChat: BackendHootChatStore?
    private struct Live: Sendable {
        let sessionID: String
        let startedAt: Double
        let root: String
        let fenced: Bool
        let profile: BackendAccountIdentity
    }
    private let deps: BackendCopilotSessionDependencies
    private nonisolated let identity = BackendCopilotSessionIdentity()
    private var live: Live? { didSet { identity.set(live?.sessionID) } }
    private var starting: Task<BackendCopilotSessionState, Error>?
    private var problem: String?
    private var fenceProblem: String?
    private var signInCache: BackendCopilotSessionSignIn?
    private var closing = false
    /// The records supplier this one runtime actually measures with (join
    /// evidence for request 8; never re-supplied separately).
    public nonisolated let installedRecords: any BackendCopilotSessionRecordsProviding
    public init(dependencies: BackendCopilotSessionDependencies) { deps = dependencies; installedRecords = dependencies.records; structuredChat = dependencies.chat }
    public static func legacyHome(storageDir: String) -> String { URL(fileURLWithPath: storageDir).appendingPathComponent("device-home").appendingPathComponent(homeKey).path }
    /// Register this at transcript-reader boot, even after the old jail is gone.
    public static func homeScope(userData: String, storageDir: String? = nil) -> NativeTranscriptHomeScope {
        let storage = storageDir ?? URL(fileURLWithPath: userData).appendingPathComponent("remote").path
        return .init(home: legacyHome(storageDir: storage), folder: BackendCopilotPaths(userData: userData).root)
    }
    /// Cheap ID-only answer for remote fanout list/attach/input/resize fences.
    /// It intentionally still names a dead ID until state is recomputed.
    public nonisolated func isCopilotSession(_ id: String) -> Bool { identity.contains(id) }
    private func resolve() async throws -> (paths: BackendCopilotPaths, folder: BackendCopilotFolderReport) {
        let folder = BackendCopilotFolder.report(stored: try await deps.chosenFolder(), userData: deps.userData, runningIn: live?.root)
        return (BackendCopilotPaths(userData: deps.userData, home: folder.home), folder)
    }
    public func layerPaths() async throws -> BackendCopilotPaths { try await resolve().paths }
    public func state() async throws -> BackendCopilotSessionState {
        let resolved = try await resolve()
        let paths = resolved.paths
        let report = BackendCopilotHome.report(paths)
        let observed = live
        let alive = if let observed { await deps.driver.isAlive(observed.sessionID) } else { false }
        if let observed, !alive, live?.sessionID == observed.sessionID {
            live = nil
            await deps.tools?.release(sessionID: observed.sessionID)
        }
        let canonical = try await deps.records.paths(userData: deps.userData)
        let current = live
        let running = alive && current?.sessionID == observed?.sessionID && current != nil
        let status: BackendCopilotSessionStatus = running ? .running : problem != nil ? .stopped : starting != nil ? .starting : .stopped
        let folder = BackendCopilotFolderReport(home: resolved.folder.home, chosen: resolved.folder.chosen,
            isDefault: resolved.folder.isDefault, problem: resolved.folder.problem, runningIn: running ? current?.root : nil,
            restartNeeded: running && current?.root != resolved.folder.home)
        return .init(status: status, sessionId: running ? current?.sessionID : nil, paths: paths, folder: folder,
            home: Self.legacyHome(storageDir: deps.storageDir), startedAt: running ? current?.startedAt : nil, problem: problem,
            records: .init(kind: "seatbelt", enforced: running && current?.fenced == true, reason: fenceProblem, paths: canonical.list),
            profile: running ? current?.profile : nil, instructionsAreDefault: report.instructionsAreDefault, instructions: report.instructions,
            startupFiles: report.startupFiles, layerFiles: report.layerFiles)
    }
    public func ensure() async throws -> BackendCopilotSessionState {
        guard !closing else { throw NativeRPCError(code: "unavailable", message: "Hoot is shutting down.") }
        if let starting { return try await starting.value }
        // Install the latch BEFORE asking liveness. Another window may enter
        // while isAlive awaits; it must await this same attempt.
        let attempt = Task { try await self.startOrRead() }
        starting = attempt
        defer { starting = nil }
        return try await attempt.value
    }
    private func startOrRead() async throws -> BackendCopilotSessionState {
        if let existing = live, await deps.driver.isAlive(existing.sessionID) { return try await state() }
        if let existing = live { live = nil; await deps.tools?.release(sessionID: existing.sessionID) }
        return try await start()
    }
    private func start() async throws -> BackendCopilotSessionState {
        let resolved = try await resolve()
        let paths = resolved.paths
        let folder = resolved.folder
        problem = nil
        if let reason = folder.problem {
            BackendCopilotHome.appendAction(paths, .init(action: "folder.unusable", detail: "\(folder.chosen ?? "the chosen folder") — \(reason) Starting in \(paths.root) instead."))
        }
        let scaffold = BackendCopilotHome.scaffold(paths)
        if let error = scaffold.error { return try await refuse("Hoot's folder could not be created: \(error)") }
        if !scaffold.created.isEmpty { BackendCopilotHome.appendAction(paths, .init(action: "home.created", detail: scaffold.created.joined(separator: ", "))) }
        var prepared: BackendCopilotSessionTools?
        do {
            let selectedProvider = structuredChat?.provider.rawValue ?? "claude"
            guard try await deps.driver.hasClaude() else { return try await refuse("Hoot's \(selectedProvider) CLI is not installed on this machine.") }
            var measured = await deps.records.measure(userData: deps.userData)
            fenceProblem = measured.reason
            let profile = try await deps.driver.resolveProfile(projectPath: paths.root)
            prepared = try await deps.tools?.prepare()
            if let receiver = deps.driver as? any BackendHootChatToolRequirementsReceiving { await receiver.toolRequirements(prepared) }
            let canonical = try await deps.records.paths(userData: deps.userData)
            let layer = BackendCopilotLayer.write(paths.layer, input: .init(root: paths.root, actionsLog: paths.actions,
                chosenFolder: !paths.ownFolder, userData: deps.userData, tools: prepared?.tools ?? [], toolsAttached: prepared != nil, records: canonical))
            guard let composed = layer.composed else {
                if let prepared { await deps.tools?.abandon(prepared) }
                return try await refuse("Hoot's instructions could not be prepared: \(layer.error ?? "unavailable")")
            }
            var input = BackendCreateSessionInput(cwd: paths.root, cols: deps.cols, rows: deps.rows, provider: selectedProvider)
            input.resume = false; input.profileId = profile.id
            let mcp = prepared.map { ["--mcp-config", $0.configPath, "--strict-mcp-config"] } ?? []
            let launchArguments = mcp + BackendCopilotLayer.args(composed: composed)
            let meta: BackendSessionMeta
            do { meta = try await deps.driver.start(input, fence: measured.fence, extraArguments: launchArguments) }
            catch let lost as BackendCopilotSessionFenceLost where measured.fence != nil {
                // Request 8 correction: the records fence fails open, visibly.
                measured = .init(fence: nil, reason: "This app’s own routines and action log could not be held against Hoot on this machine: " + lost.reason)
                fenceProblem = measured.reason
                meta = try await deps.driver.start(input, fence: nil, extraArguments: launchArguments)
            }
            guard meta.provider == selectedProvider else {
                try await deps.driver.stop(meta.id)
                if let prepared { await deps.tools?.abandon(prepared) }
                return try await refuse("Hoot started as a \(meta.provider) session rather than an agent.")
            }
            if let prepared {
                do { try await deps.tools?.bind(prepared, sessionID: meta.id) }
                catch {
                    try await deps.driver.stop(meta.id)
                    await deps.tools?.abandon(prepared)
                    return try await refuse(error.localizedDescription)
                }
            }
            live = .init(sessionID: meta.id, startedAt: meta.createdAt, root: paths.root, fenced: measured.fence != nil, profile: profile.identity)
            let folderNote = paths.ownFolder ? "" : " (your folder — nothing of this app’s was written into it)"
            let recordsNote = if let fence = measured.fence { ", as \(profile.name), routines and this log held against it (\(fence.kind))" }
                else { ", as \(profile.name), routines and this log NOT held against it" + (measured.reason.map { " — " + $0 } ?? "") }
            let toolNote = prepared.map { ", with this app’s tools from \($0.configPath)" } ?? ", with none of this app’s tools — no deck-control server is running"
            BackendCopilotHome.appendAction(paths, .init(action: "session.started", detail: "cwd \(paths.root)\(folderNote)\(recordsNote)\(toolNote)", sessionId: meta.id))
            return try await state()
        } catch {
            if let prepared { await deps.tools?.abandon(prepared) }
            return try await refuse(error.localizedDescription)
        }
    }
    private func refuse(_ reason: String) async throws -> BackendCopilotSessionState {
        problem = reason
        BackendCopilotHome.appendAction(try await layerPaths(), .init(action: "session.refused", detail: reason))
        return try await state()
    }
    /// Graph shutdown: refuse new starts, await the one pending launch latch
    /// (its outcome is irrelevant), then stop the same desk Hoot. After this
    /// returns no desk assistant can still spawn from this runtime.
    public func quiesceAndStop() async throws -> BackendCopilotSessionState {
        closing = true
        if let starting { _ = try? await starting.value }
        return try await stop()
    }
    public var isClosing: Bool { closing }
    public func stop() async throws -> BackendCopilotSessionState {
        if let starting {
            starting.cancel()
            _ = try? await starting.value
        }
        let paths = try await layerPaths()
        if let existing = live {
            try await deps.driver.stop(existing.sessionID)
            BackendCopilotHome.appendAction(paths, .init(action: "session.stopped", sessionId: existing.sessionID))
            if live?.sessionID == existing.sessionID { live = nil }
            await deps.tools?.release(sessionID: existing.sessionID)
        }
        return try await state()
    }
    public func readSignIn(now: Double = Date().timeIntervalSince1970 * 1000) async throws -> BackendCopilotSessionSignIn {
        let profile = try await deps.driver.resolveProfile(projectPath: try await layerPaths().root)
        if let cached = signInCache, cached.profileId == profile.id, now - cached.checkedAt < Self.signInTTLMilliseconds { return cached }
        let answer = try await deps.driver.signIn(profile: profile)
        let result = BackendCopilotSessionSignIn(state: answer.state == "unsupported" ? "unknown" : answer.state, account: answer.account, plan: answer.plan,
            profileId: profile.id, profileName: profile.name, checkedAt: now)
        signInCache = result; return result
    }
    public func invoke(_ channel: String, arguments: [NativeRPCValue]) async throws -> NativeRPCValue {
        let channel = RNMHootChannelCompatibility.incomingChannel(channel)
        if BackendHootChatChannels.invokes.contains(channel) {
            guard let chat = structuredChat else { throw NativeRPCError(code: "unavailable", message: "Hoot's structured chat is unavailable.") }
            switch BackendHootChatChannels.canonical(channel) {
            case "hoot:chat:read":
                guard arguments.count <= 2 else { throw NativeRPCError.invalidArguments("Expected cursor and limit.") }
                let cursor = try BackendHootChatChannels.integer(arguments.first ?? .null, maximum: Int.max - 1)
                let limit = try BackendHootChatChannels.integer(arguments.count > 1 ? arguments[1] : .null, maximum: 500) ?? 200
                return await chat.snapshot(after: cursor, limit: limit)
            case "hoot:chat:say":
                guard (1...2).contains(arguments.count) else { throw NativeRPCError.invalidArguments("Expected message and optional attachments.") }
                let text = try arguments[0].requireString("message")
                let attachments = arguments.count == 2 ? try arguments[1].requireArray("attachments") : []
                let state = try await ensure()
                guard state.status == .running else { throw NativeRPCError(code: "unavailable", message: state.problem ?? "Hoot could not start.") }
                return try await chat.say(text, attachments: attachments)
            case "hoot:chat:stop":
                guard arguments.isEmpty else { throw NativeRPCError.invalidArguments("Expected no stop arguments.") }
                _ = try await stop(); return await chat.snapshot()
            case "hoot:chat:answer":
                guard (2...3).contains(arguments.count), let approved = arguments[1].bool else { throw NativeRPCError.invalidArguments("Expected request ID, approve/deny and optional structured answers.") }
                try await chat.answer(id: try arguments[0].requireString("requestId", nonempty: true), allowed: approved,
                    answers: arguments.count == 3 ? try arguments[2].requireObject("answers") : .object([]))
                return await chat.snapshot()
            default: throw NativeRPCError.invalidArguments("Unknown Hoot chat channel.")
            }
        }
        switch channel {
        case "copilot:ensure": return try await ensure().wireValue
        case "copilot:state": return try await state().wireValue
        case "copilot:files": return .array(try await state().startupFiles.map(\.wireValue))
        case "copilot:stop": return try await stop().wireValue
        case "copilot:signin": return try await readSignIn().wireValue
        case "copilot:read-instructions": return BackendCopilotHome.readInstructions(try await layerPaths()).wireValue
        case "copilot:read-contract": return BackendCopilotLayer.readFile(try await layerPaths().layer.contract).wireValue
        case "copilot:read-composed": return BackendCopilotLayer.readComposed(try await layerPaths().layer).wireValue
        case "copilot:read-folder-instructions": return BackendCopilotHome.readFolderInstructions(try await layerPaths()).wireValue
        case "copilot:write-instructions":
            let paths = try await layerPaths()
            let result = BackendCopilotHome.writeInstructions(paths, text: arguments.first ?? .missing)
            if result.saved, let backup = result.backup {
                BackendCopilotHome.appendAction(paths, .init(action: "instructions.edited", detail: "you edited its instructions from Settings; the previous file is at \(backup)"))
            }
            return result.wireValue.setting("state", try await state().wireValue)
        case "copilot:write-folder-instructions":
            let paths = try await layerPaths()
            let result = BackendCopilotHome.writeFolderInstructions(paths, text: arguments.first ?? .missing)
            if result.saved {
                let detail = result.created ? "you created the folder’s own instructions from Settings at \(paths.root)" : result.backup.map { "you edited the folder’s own instructions from Settings; the previous file is at \($0)" } ?? "you saved the folder’s own instructions from Settings; nothing changed"
                BackendCopilotHome.appendAction(paths, .init(action: "folder-instructions.edited", detail: detail))
            }
            return result.wireValue.setting("state", try await state().wireValue)
        case "copilot:reset-instructions":
            let paths = try await layerPaths()
            let result = BackendCopilotHome.resetInstructions(paths)
            if result.error == nil {
                BackendCopilotHome.appendAction(paths, .init(action: "instructions.reset", detail: result.backup.map { "restored the instructions this build ships; the previous file is at \($0)" } ?? "restored the instructions this build ships"))
            }
            return result.wireValue.setting("state", try await state().wireValue)
        default: throw NativeRPCError(code: "unavailable", message: "Unknown Hoot session channel.")
        }
    }
    public func register(registry: NativeChannelRegistry, ownerID: String) async throws {
        for channel in Self.channels {
            try await registry.register(channel, ownerID: ownerID) { [self] context, args in
                guard context.caller == .nativeApp || context.caller == .internalEngine else {
                    throw NativeRPCError(code: "access-denied", message: "Hoot's desk session is available on this computer only.")
                }
                return try await invoke(channel, arguments: args)
            }
        }
    }
}
