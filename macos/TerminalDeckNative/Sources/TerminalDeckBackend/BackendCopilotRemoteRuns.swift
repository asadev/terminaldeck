import Foundation
import CryptoKit
import Security
import TerminalDeckNativeCore

/// remote/copilot-runs.ts. One process/conversation/token per authenticated
/// device. Prose and parsed transcript messages are its only keyboard surface.
public actor BackendCopilotRemoteRuns {
    public typealias Sink = @Sendable (BackendRemoteServerMessage) async -> Void
    private struct Run: Sendable {
        let sessionID: String
        let registration: BackendMCPRegistration
        let config: URL
        let token: String
        let cancellation: BackendMCPCancellation
        var unchat: @Sendable () -> Void
        var expiresAt: Double?
        var ready = false
        var queuedChat: [BackendCopilotRemoteChatUpdate] = []
    }
    private struct Watcher: Sendable { let deviceID: String; let sink: Sink }
    private struct Pending: Sendable {
        let epoch: Int
        let registration: BackendMCPRegistration
        let cancellation: BackendMCPCancellation
        let config: URL
        let token: String
    }
    private let deps: BackendCopilotRemoteRunDependencies
    private var runs: [String: Run] = [:]
    private var watchers: [UUID: Watcher] = [:]
    private var starting: [String: Task<BackendCopilotRemoteOutcome, Never>] = [:]
    private var pendingRuns: [String: Pending] = [:]
    private var epochs: [String: Int] = [:]
    private var stopping = false
    public init(dependencies: BackendCopilotRemoteRunDependencies) { deps = dependencies }

    public func granted(_ deviceID: String) async -> BackendCopilotRemoteGrant { await deps.access.granted(deviceID) }
    public func linked(_ deviceID: String) async -> Bool { await deps.access.linked(deviceID) }
    public func open(_ deviceID: String) async -> BackendCopilotRemoteOutcome {
        await linked(deviceID) ? .success : .unauthorized("This device does not have Hoot.")
    }
    public func closed(_ deviceID: String) async {
        if let consent = await deps.consent() { try? await consent.callerGone("device:" + deviceID) }
    }
    public func state(_ deviceID: String) async throws -> NativeRPCValue {
        await reap()
        let desk = try await deps.desk(), cost = try await deps.cost()
        let endpoint = try await deps.endpoint(), grant = await granted(deviceID)
        let count = await questions().count
        let available = desk.available && endpoint != nil
        let reason = endpoint == nil ? "Hoot’s tools are not running on this machine." : desk.reason
        return .object([.init("desk", .string(desk.status)), .init("run", runs[deviceID].map { .string($0.sessionID) } ?? .null),
            .init("profile", desk.profile.map(NativeRPCValue.string) ?? .null), .init("signedIn", desk.signedIn.map(NativeRPCValue.bool) ?? .null),
            .init("tools", .number(Double(cost.tools))), .init("turnTokens", .number(Double(cost.turnTokens))), .init("pending", .number(Double(count))),
            .init("grant", grant.wireValue), .init("available", .bool(available)), .init("reason", available ? .null : reason.map(NativeRPCValue.string) ?? .null),
            .init("interactive", .bool(desk.interactive))])
    }
    public func sessions() async throws -> [NativeRPCValue] { try await deps.sessions() }
    public func setInteractive(_ on: Bool) async throws { try await deps.setInteractive(on) }
    public func log(limit: Double? = nil, before: String? = nil) async throws -> (rows: [NativeRPCValue], more: Bool) {
        let want = limit ?? Double(BackendCopilotRemoteSurface.maximumLogRows)
        let clamped = want.isFinite ? min(max(want.rounded(.towardZero), 1), 200) : 200
        return try await deps.log(Int(clamped), before)
    }
    private func questions() async -> [BackendDeckCoreSecurityConsentRequest] {
        guard let broker = await deps.consent() else { return [] }
        return await broker.list()
    }
    public func pending(_ deviceID: String) async -> [NativeRPCValue] {
        let canAnswerKeys = await granted(deviceID).alter
        return await questions().map { question in
            BackendCopilotRemoteWiring.pendingRow(question, mine: question.origin == "device:" + deviceID || (canAnswerKeys && Self.isKey(question.origin)))
        }
    }
    public func answer(_ deviceID: String, id: String, approved: Bool) async -> Bool {
        guard let broker = await deps.consent() else { return false }
        // Broker owns question ownership and first-answer-wins semantics.
        return await broker.respond(id: id, approved: approved, by: "device:" + deviceID)
    }
    public func watch(_ deviceID: String, sink: @escaping Sink) async -> UUID {
        let id = UUID(); watchers[id] = Watcher(deviceID: deviceID, sink: sink)
        if let run = runs[deviceID] {
            runs[deviceID]?.expiresAt = nil
            if let frame = try? BackendRemoteServerMessage(.copilotChat, fields: [.init("run", .string(run.sessionID)), .init("messages", .array([])), .init("reset", .bool(true))]) { await sink(frame) }
        }
        return id
    }
    public func unwatch(_ watcherID: UUID) {
        guard let watcher = watchers.removeValue(forKey: watcherID), !watching(watcher.deviceID),
              runs[watcher.deviceID] != nil, runs[watcher.deviceID]?.expiresAt == nil else { return }
        runs[watcher.deviceID]?.expiresAt = deps.now() + deps.graceMilliseconds
    }
    private func watching(_ deviceID: String) -> Bool { watchers.values.contains { $0.deviceID == deviceID } }

    public func start(_ deviceID: String) async -> BackendCopilotRemoteOutcome {
        await reap()
        guard !stopping else { return .unavailable("Hoot could not be started just now.") }
        guard await linked(deviceID) else { return .unauthorized("This device does not have Hoot.") }
        if runs[deviceID] != nil { runs[deviceID]?.expiresAt = nil; return .success }
        if let task = starting[deviceID] { return await task.value }
        let epoch = epochs[deviceID, default: 0]
        let task = Task { await self.performStart(deviceID, epoch: epoch) }
        starting[deviceID] = task
        let result = await task.value
        if epochs[deviceID, default: 0] == epoch { starting[deviceID] = nil }
        return result
    }
    private func performStart(_ deviceID: String, epoch: Int) async -> BackendCopilotRemoteOutcome {
        let endpoint: BackendMCPEndpointDescription
        let root: URL
        do {
            guard let value = try await deps.endpoint() else { return .unavailable("Hoot’s tools are not running on this machine, so there is nothing to start.") }
            endpoint = value
            let desk = try await deps.desk()
            guard desk.available else { return .unavailable(desk.reason ?? "Hoot cannot start on this machine just now.") }
            root = URL(fileURLWithPath: try await deps.root(), isDirectory: true)
            guard root.path.hasPrefix("/") else { return .unavailable("Hoot could not be started just now.") }
        } catch { return .unavailable("Hoot could not be started just now.") }
        let config = root.appendingPathComponent(BackendCopilotRemoteSurface.runConfigName(deviceID))
        guard validStart(deviceID, epoch: epoch) else { return .unavailable("Hoot could not be started just now.") }
        let token: String
        do { token = try Self.token(); try Self.writeConfig(directory: root, config: config, url: endpoint.url, token: token) }
        catch { return .unavailable("Hoot’s tools could not be handed to this device securely.") }
        let cancellation = BackendMCPCancellation()
        let registration: BackendMCPRegistration
        do {
            let access = deps.access
            registration = try await deps.callers.register(token: token, endpointURL: endpoint.url, attended: true, caller: { await access.caller(deviceID) }, cancellation: cancellation)
        } catch { Self.remove(config, token: token); cancellation.cancel(); return .unavailable("Hoot’s tools could not be handed to this device securely.") }
        guard validStart(deviceID, epoch: epoch) else {
            await deps.callers.revoke(registration); cancellation.cancel(); Self.remove(config, token: token)
            return .unavailable("Hoot could not be started just now.")
        }
        pendingRuns[deviceID] = Pending(epoch: epoch, registration: registration, cancellation: cancellation, config: config, token: token)
        var sessionID: String?
        do {
            guard validStart(deviceID, epoch: epoch), await linked(deviceID) else { throw BackendSessionFailure.closed }
            let session = try await deps.spawn(.init(cwd: root.path, mcpConfig: config.path, deviceID: deviceID))
            sessionID = session
            deps.hidden.hide(session)
            guard validStart(deviceID, epoch: epoch), await linked(deviceID) else { throw BackendSessionFailure.closed }
            runs[deviceID] = Run(sessionID: session, registration: registration, config: config, token: token, cancellation: cancellation,
                unchat: {}, expiresAt: watching(deviceID) ? nil : deps.now() + deps.graceMilliseconds)
            if pendingRuns[deviceID]?.epoch == epoch { pendingRuns[deviceID] = nil }
            let unchat = try await deps.chat(session) { [weak self] update in await self?.pushChat(deviceID, sessionID: session, update: update) }
            guard runs[deviceID]?.sessionID == session, validStart(deviceID, epoch: epoch) else { unchat(); throw BackendSessionFailure.closed }
            runs[deviceID]?.unchat = unchat
            await sendChat(deviceID, sessionID: session, update: .init(messages: [], reset: true))
            let queued = runs[deviceID]?.queuedChat ?? []
            runs[deviceID]?.ready = true; runs[deviceID]?.queuedChat.removeAll()
            for update in queued { await pushChat(deviceID, sessionID: session, update: update) }
            await pushState(deviceID)
            return .success
        } catch {
            if pendingRuns[deviceID]?.epoch == epoch { pendingRuns[deviceID] = nil }
            if let sessionID, runs[deviceID]?.sessionID == sessionID { _ = await end(deviceID) }
            else {
                await deps.callers.revoke(registration); cancellation.cancel()
                if let sessionID {
                    do { try await deps.stop(sessionID); deps.hidden.release(sessionID) }
                    catch { /* Keep a possibly-live PTY hidden if stopping failed. */ }
                }
                Self.remove(config, token: token)
            }
            return .unavailable("Hoot could not be started just now.")
        }
    }
    private func validStart(_ deviceID: String, epoch: Int) -> Bool { !stopping && !Task.isCancelled && epochs[deviceID, default: 0] == epoch }
    public func say(_ deviceID: String, text: String) async -> BackendCopilotRemoteOutcome {
        await reap()
        if runs[deviceID] == nil { let result = await start(deviceID); if !result.ok { return result } }
        guard let run = runs[deviceID] else { return .unavailable("That run is no longer there.") }
        runs[deviceID]?.expiresAt = watching(deviceID) ? nil : deps.now() + deps.graceMilliseconds
        do { try await deps.say(run.sessionID, text); return .success }
        catch { return .unavailable("Hoot did not take that message.") }
    }
    public func cancel(_ deviceID: String) async -> BackendCopilotRemoteOutcome {
        await reap()
        guard let run = runs[deviceID] else { return .unavailable("There is no run to interrupt.") }
        do { try await deps.interrupt(run.sessionID); return .success }
        catch { return .unavailable("Hoot did not take the interrupt.") }
    }
    public func stop(_ deviceID: String) async -> BackendCopilotRemoteOutcome {
        await invalidateStart(deviceID)
        guard await end(deviceID) else { return .unavailable("There is no run to stop.") }
        await pushState(deviceID); return .success
    }
    public func revoked(_ deviceID: String) async {
        await closed(deviceID)
        guard !(await granted(deviceID).act) else { return }
        await invalidateStart(deviceID)
        if await end(deviceID) { await pushState(deviceID) }
    }
    public func stopAll() async {
        stopping = true
        for id in Array(starting.keys) { await invalidateStart(id) }
        for id in Array(runs.keys) { _ = await end(id) }
    }
    private func invalidateStart(_ deviceID: String) async {
        epochs[deviceID, default: 0] += 1; starting.removeValue(forKey: deviceID)?.cancel()
        if let pending = pendingRuns.removeValue(forKey: deviceID) {
            await deps.callers.revoke(pending.registration); pending.cancellation.cancel()
            Self.remove(pending.config, token: pending.token)
        }
    }
    private func end(_ deviceID: String) async -> Bool {
        guard let run = runs.removeValue(forKey: deviceID) else { return false }
        run.unchat()
        await deps.callers.revoke(run.registration)
        run.cancellation.cancel()
        do { try await deps.stop(run.sessionID); deps.hidden.release(run.sessionID) }
        catch { /* Stop failure must never expose a process that still accepts keys. */ }
        Self.remove(run.config, token: run.token); return true
    }
    public func reap() async {
        let at = deps.now()
        for (id, run) in Array(runs) {
            let alive = await deps.isAlive(run.sessionID)
            if run.expiresAt.map({ $0 <= at }) == true || !alive {
                if runs[id]?.sessionID == run.sessionID { _ = await end(id) }
            }
        }
    }
    public nonisolated func isRunSession(_ sessionID: String) -> Bool { deps.hidden.listed(sessionID) }
    private func pushChat(_ deviceID: String, sessionID: String, update: BackendCopilotRemoteChatUpdate) async {
        guard let run = runs[deviceID], run.sessionID == sessionID else { return }
        guard run.ready else { runs[deviceID]?.queuedChat.append(update); return }
        await sendChat(deviceID, sessionID: sessionID, update: update)
    }
    private func sendChat(_ deviceID: String, sessionID: String, update: BackendCopilotRemoteChatUpdate) async {
        guard runs[deviceID]?.sessionID == sessionID else { return }
        var fields: [NativeRPCValue.Field] = [.init("run", .string(sessionID)), .init("messages", .array(update.messages.map(BackendCopilotRemoteWiring.chatMessage)))]
        if update.reset { fields.append(.init("reset", .bool(true))) }
        guard let frame = try? BackendRemoteServerMessage(.copilotChat, fields: fields) else { return }
        await broadcast(frame, deviceID: deviceID)
    }
    private func pushState(_ deviceID: String) async {
        do { await broadcast(try .init(.copilotState, fields: [.init("state", try await state(deviceID))]), deviceID: deviceID) }
        catch { if let frame = try? BackendRemoteServerMessage.error(code: "unavailable", message: "Hoot’s state could not be read just now.") { await broadcast(frame, deviceID: deviceID) } }
    }
    private func pushPending() async {
        for (id, watcher) in watchers {
            guard await granted(watcher.deviceID).read, watchers[id] != nil,
                  let frame = try? BackendRemoteServerMessage(.copilotPending, fields: [.init("questions", .array(await pending(watcher.deviceID)))]) else { continue }
            await watcher.sink(frame)
        }
    }
    public func ask(_ request: BackendDeckCoreSecurityConsentRequest) async -> Bool {
        await pushPending()
        let key = Self.isKey(request.origin)
        guard key || (request.origin.hasPrefix("device:") && request.origin.count > 7),
              let frame = try? BackendRemoteServerMessage(.copilotAsk, fields: [.init("question", BackendCopilotRemoteWiring.consentQuestion(request))]) else { return false }
        let owner = String(request.origin.dropFirst(7))
        var delivered = false
        for (id, watcher) in watchers {
            guard key || watcher.deviceID == owner, await granted(watcher.deviceID).alter, watchers[id] != nil else { continue }
            await watcher.sink(frame); delivered = true
        }
        return delivered
    }
    public func settled(_ id: String, outcome: BackendDeckCoreSecurityConsentOutcome) async {
        let row = NativeRPCValue.object([.init("id", .string(id)), .init("granted", .bool(outcome.granted)), .init("by", outcome.by.map(NativeRPCValue.string) ?? .null),
            .init("reason", outcome.granted ? .null : outcome.reason.map { .string($0.rawValue) } ?? .null)])
        if let frame = try? BackendRemoteServerMessage(.copilotSettled, fields: [.init("settled", row)]) { await broadcast(frame) }
        await pushPending()
    }
    public func publishTool(_ row: NativeRPCValue) async throws {
        await broadcast(try .init(.copilotTool, fields: [.init("row", BackendCopilotRemoteWiring.actionRow(row))]))
    }
    public func publishSessions() async throws {
        await broadcast(try .init(.copilotSessions, fields: [.init("sessions", .array(try await deps.sessions()))]))
    }
    public func publishDeskState() async { for id in Set(watchers.values.map(\.deviceID)) { await pushState(id) } }
    private func broadcast(_ frame: BackendRemoteServerMessage, deviceID: String? = nil) async {
        for (id, watcher) in watchers {
            guard deviceID == nil || watcher.deviceID == deviceID, await granted(watcher.deviceID).read, watchers[id] != nil else { continue }
            await watcher.sink(frame)
        }
    }
    private static func isKey(_ origin: String) -> Bool { origin.hasPrefix("key:") && origin.count > 4 }
    private static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw BackendSessionFailure.closed }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    public nonisolated static func writeConfig(directory: URL, config: URL, url: URL, token: String) throws {
        let value = NativeRPCValue.object([.init("mcpServers", .object([.init("deck-control", .object([.init("type", .string("http")), .init("url", .string(url.absoluteString)),
            .init("headers", .object([.init("Authorization", .string("Bearer " + token))]))]))]))])
        var bytes = try value.encodedJSON(pretty: true)
        if bytes.last != 10 { bytes.append(10) }
        try BackendRemoteServeSecretFile.write(directory: directory, file: config, contents: bytes)
    }
    private static func remove(_ file: URL, token: String) {
        // A slow cancelled start can outlive a replacement run at the same
        // source-compatible filename. Remove only the config that holds ours.
        guard let data = try? Data(contentsOf: file), let value = try? NativeRPCValue.parseJSON(data),
              value["mcpServers"]["deck-control"]["headers"]["Authorization"].string == "Bearer " + token else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
