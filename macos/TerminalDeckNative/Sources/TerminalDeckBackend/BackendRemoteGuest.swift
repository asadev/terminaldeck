import Foundation
import TerminalDeckNativeCore

public enum BackendMachineConnectionPhase: String, Sendable { case offline, connecting, awaitingApproval = "awaiting-approval", online, error }
public struct BackendMachineLinkState: Sendable {
    public let id: String
    public let phase: BackendMachineConnectionPhase
    public let reason: String?
    public let sessions: [NativeRPCValue]
    public let folders: [String]?
    public let capabilities: Set<String>
    public let ports: [NativeRPCValue]
    public let copilot: NativeRPCValue
    public let hostPlatform: String
    public let hostVersion: String
    public let hostKind: String?
    public let retryAt: Double?
    public var value: NativeRPCValue { .object([.init("id", .string(id)), .init("state", .string(phase.rawValue)), .init("reason", reason.map(NativeRPCValue.string) ?? .null),
        .init("sessions", .array(sessions)), .init("folders", folders.map { .array($0.map(NativeRPCValue.string)) } ?? .null),
        .init("capabilities", .array(capabilities.sorted().map(NativeRPCValue.string))), .init("ports", .array(ports)), .init("copilot", copilot),
        .init("hostPlatform", .string(hostPlatform)), .init("hostVersion", .string(hostVersion)), .init("hostKind", hostKind.map(NativeRPCValue.string) ?? .null), .init("retryAt", retryAt.map(NativeRPCValue.number) ?? .null)]) }
}

/// Remote sessions stay remote: this actor never invents local PTYs or writes a
/// second session ledger. Only real host pushes update its remote view.
public actor BackendRemoteGuest {
    public typealias WindowCall = @Sendable (String, String, String) async throws -> (ok: Bool, body: String)
    public nonisolated let id: String
    private let secrets: BackendMachineSecrets
    private let name: String
    private let declaredCapabilities: Set<String>
    private let onState: @Sendable (BackendMachineLinkState) async -> Void
    private let onOutput: @Sendable (String, String, Bool) async -> Void
    private let onFrame: @Sendable (NativeRPCValue) async -> Void
    private let onWelcome: @Sendable (String) async -> Void
    private let windowsAllowed: @Sendable () async throws -> Bool
    private let windowCall: WindowCall?
    private let windowsHeld: (@Sendable () async -> [NativeRPCValue])?
    private let ownSessions: (@Sendable () async -> [NativeRPCValue])?
    private let receivedHolds: (@Sendable ([String], [NativeRPCValue]) async -> Void)?
    private let receivedResult: (@Sendable (String, Bool, String) async -> Void)?
    private var channel: BackendRemoteGuestChannel?
    private var receiver: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var stopped = true
    private var generation = UUID()
    private var attempts = 0
    private var everWelcomed = false
    private var connectedAt: Double = 0
    private var windowTasks: [String: Task<Void, Never>] = [:]
    private var phase: BackendMachineConnectionPhase = .offline
    private var reason: String?
    private var sessions: [NativeRPCValue] = []
    private var folders: [String]?
    private var capabilities: Set<String> = []
    private var ports: [NativeRPCValue] = []
    private var copilot: NativeRPCValue = .null
    private var platform = "", version = ""
    private var hostKind: String?
    private var retryAt: Double?
    private var attachments: [String: (cols: Int, rows: Int)] = [:]
    private var replaying: Set<String> = []
    private struct Pending {
        let tags: Set<String>
        let field: String
        let continuation: CheckedContinuation<NativeRPCValue, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]
    public init(id: String, secrets: BackendMachineSecrets, localName: String, declaredCapabilities: Set<String> = [],
                onState: @escaping @Sendable (BackendMachineLinkState) async -> Void,
                onOutput: @escaping @Sendable (String, String, Bool) async -> Void,
                onWelcome: @escaping @Sendable (String) async -> Void,
                onFrame: @escaping @Sendable (NativeRPCValue) async -> Void = { _ in },
                windowsAllowed: @escaping @Sendable () async throws -> Bool = { false }, windowCall: WindowCall? = nil,
                windowsHeld: (@Sendable () async -> [NativeRPCValue])? = nil, ownSessions: (@Sendable () async -> [NativeRPCValue])? = nil,
                receivedHolds: (@Sendable ([String], [NativeRPCValue]) async -> Void)? = nil,
                receivedResult: (@Sendable (String, Bool, String) async -> Void)? = nil) {
        self.id = id; self.secrets = secrets; name = localName; self.declaredCapabilities = declaredCapabilities
        self.onState = onState; self.onOutput = onOutput; self.onWelcome = onWelcome; self.onFrame = onFrame
        self.windowsAllowed = windowsAllowed; self.windowCall = windowCall
        self.windowsHeld = windowsHeld; self.ownSessions = ownSessions; self.receivedHolds = receivedHolds; self.receivedResult = receivedResult
    }
    public func state() -> BackendMachineLinkState { .init(id: id, phase: phase, reason: reason, sessions: sessions, folders: folders, capabilities: capabilities,
        ports: ports, copilot: copilot, hostPlatform: platform, hostVersion: version, hostKind: hostKind, retryAt: retryAt) }
    public func connect() { guard stopped else { return }; stopped = false; beginDial() }
    public func disconnect() async { stopped = true; retry?.cancel(); retry = nil; await drop("Disconnected.", reconnect: false) }
    private func beginDial() {
        guard !stopped, channel == nil else { return }
        generation = UUID(); let epoch = generation
        phase = .connecting; reason = nil; retryAt = nil
        let channel = BackendRemoteGuestChannel(relayURL: secrets.relayURL, hostID: secrets.hostID, hostKey: secrets.hostPublicKey, identity: secrets.guestIdentity)
        self.channel = channel
        receiver = Task { [weak self] in
            await self?.announce()
            do {
                try await channel.open()
                try await self?.sendHello(epoch)
                let first = try await channel.receive(timeoutMilliseconds: 15000)
                try await self?.frame(first, epoch: epoch)
                while !Task.isCancelled { let text = try await channel.receive(); try await self?.frame(text, epoch: epoch) }
            } catch { await self?.lost(epoch, reason: error.localizedDescription) }
        }
    }
    private func sendHello(_ epoch: UUID) async throws {
        guard epoch == generation, let channel else { return }
        var caps = declaredCapabilities
        if windowCall == nil { caps.remove("windows") } else { caps.insert("windows") }
        if receivedHolds == nil { caps.remove("hostwindows") } else { caps.insert("hostwindows") }
        try await channel.send(.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(secrets.credential)),
            .init("device", .object([.init("name", .string(name)), .init("platform", .string("darwin"))])), .init("capabilities", .array(caps.sorted().map(NativeRPCValue.string)))]))
    }
    private func frame(_ text: String, epoch: UUID) async throws {
        guard epoch == generation, !stopped else { return }
        let value = try BackendRemoteGuestFrames.parse(text), type = value["t"].string!
        for (key, request) in pending where request.tags.contains(type) && value[request.field].string == key {
            pending.removeValue(forKey: key)?.timeout.cancel(); request.continuation.resume(returning: value); break
        }
        switch type {
        case "welcome":
            phase = .online; reason = nil; retryAt = nil; everWelcomed = true; connectedAt = Date().timeIntervalSince1970 * 1000
            sessions = value["sessions"].elements ?? []; folders = value["folders"].elements?.compactMap(\.string)
            capabilities = Set(value["capabilities"].elements?.compactMap(\.string) ?? [])
            copilot = value["copilot"] == .missing ? .null : value["copilot"]
            platform = value["hostPlatform"].string ?? ""; version = value["appVersion"].string ?? ""; hostKind = value["hostKind"].string
            await onWelcome(platform)
            try await announceWindows(); try await announceSessions()
            for (id, size) in attachments { _ = try? await attach(id, cols: size.cols, rows: size.rows) }
            heartbeat?.cancel(); heartbeat = Task { [weak self] in
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(20)); guard !Task.isCancelled else { return }; await self?.ping(epoch) }
            }
            await announce()
        case "sessions": sessions = value["sessions"].elements ?? []; await announce()
        case "created": if let row = BackendRemoteProtocol.remoteSession(value["session"]) { sessions.removeAll { $0["id"] == row["id"] }; sessions.append(row); await announce() }
        case "closed": sessions.removeAll { $0["id"] == value["id"] }; attachments[value["id"].string ?? ""] = nil; await announce()
        case "output": await onOutput(value["id"].string!, value["data"].string!, replaying.contains(value["id"].string!))
        case "status", "exit":
            let session = value["id"].string!; replaying.remove(session)
            if let index = sessions.firstIndex(where: { $0["id"].string == session }) {
                sessions[index] = sessions[index].setting("status", type == "exit" ? .string("exited") : value["status"])
                if type == "exit" { sessions[index] = sessions[index].setting("exitCode", value["exitCode"]) }
                await announce()
            }
        case "folders": folders = value["folders"].elements?.compactMap(\.string); await announce()
        case "ports": ports = value["ports"].elements ?? []; await announce()
        case "copilot.grant": copilot = value["link"]; await announce()
        case "window.call":
            let id = value["id"].string!
            guard windowTasks[id] == nil, windowTasks.count < 8 else { try await refuseWindow(value["id"], message: "Too many browser calls are already pending."); return }
            windowTasks[id] = Task { [weak self] in await self?.serveWindow(value, epoch: epoch); await self?.finishedWindow(id, epoch: epoch) }
        case "window.holds": await receivedHolds?(value["sessions"].elements?.compactMap(\.string) ?? [], value["held"].elements ?? [])
        case "window.result": await receivedResult?(value["id"].string!, value["ok"].bool!, value["body"].string!)
        case "error":
            let message = value["message"].string ?? "The remote host refused the request."
            if ["unauthorized", "unauthenticated"].contains(value["code"].string ?? "") {
                phase = value["code"].string == "unauthorized" && !everWelcomed ? .awaitingApproval : .error
                reason = message; await announce()
                await drop(message, reconnect: true, preservePhase: true)
            }
            for request in pending.values { request.timeout.cancel(); request.continuation.resume(throwing: NativeRPCError(code: value["code"].string ?? "remote", message: message)) }; pending = [:]
        default: break
        }
        await onFrame(value)
    }
    public func send(type: String, fields: [NativeRPCValue.Field], capability: String? = nil) async throws {
        guard phase == .online, let channel else { throw NativeRPCError(code: "machine-offline", message: "That machine is not online") }
        if let capability, !capabilities.contains(capability) { throw NativeRPCError(code: "machine-capability", message: "That machine does not serve \(capability)") }
        guard !fields.contains(where: { $0.key == "t" }) else { throw NativeRPCError.invalidArguments("Remote request fields cannot replace the message tag") }
        let value = NativeRPCValue.object([.init("t", .string(type))] + fields)
        guard case .message(let message) = BackendRemoteProtocol.parseClientMessage(value) else { throw NativeRPCError.invalidArguments("The remote request is malformed") }
        try await channel.sendText(BackendRemoteProtocol.serialize(message))
    }
    public func announceWindows() async throws {
        guard capabilities.contains("windows"), let windowsHeld else { return }
        let held = await windowsHeld()
        var fields: [NativeRPCValue.Field] = [.init("sessions", .array(held.compactMap { $0["session"].string }.map(NativeRPCValue.string)))]
        if !held.isEmpty { fields.append(.init("held", .array(held))) }
        try await send(type: "window.holds", fields: fields, capability: "windows")
    }
    public func announceSessions() async throws {
        guard capabilities.contains("hostwindows"), let ownSessions else { return }
        try await send(type: "sessions.mine", fields: [.init("sessions", .array(await ownSessions()))], capability: "hostwindows")
    }
    public func askWindow(id: String, sessionID: String, tool: String, arguments: String) async throws {
        try await send(type: "window.call", fields: [.init("id", .string(id)), .init("session", .string(sessionID)), .init("tool", .string(tool)), .init("args", .string(arguments))], capability: "hostwindows")
    }
    private func serveWindow(_ value: NativeRPCValue, epoch: UUID) async {
        guard epoch == generation else { return }
        let permitted = (try? await windowsAllowed()) == true
        guard permitted, let windowCall else { try? await refuseWindow(value["id"], message: "This machine was not granted browser control here."); return }
        do {
            let answer = try await windowCall(value["session"].string!, value["tool"].string!, value["args"].string!)
            guard epoch == generation else { return }
            try await send(type: "window.result", fields: [.init("id", value["id"]), .init("ok", .bool(answer.ok)), .init("body", .string(answer.body))])
        } catch { try? await refuseWindow(value["id"], message: error.localizedDescription) }
    }
    public func request(type: String, fields: [NativeRPCValue.Field], capability: String, replies: Set<String>,
                        correlation: String = "rid", requestID: String = UUID().uuidString.lowercased(), timeoutMilliseconds: Int = 30000) async throws -> NativeRPCValue {
        try Task.checkCancellation()
        guard pending.count < 64, pending[requestID] == nil else { throw NativeRPCError(code: "machine-pending", message: "Too many remote requests are pending") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in try? await Task.sleep(for: .milliseconds(timeoutMilliseconds)); guard !Task.isCancelled else { return }; await self?.expire(requestID) }
                pending[requestID] = Pending(tags: replies, field: correlation, continuation: continuation, timeout: timeout)
                Task { [weak self] in
                    do { try await self?.send(type: type, fields: fields + [.init(correlation, .string(requestID))], capability: capability) }
                    catch { await self?.fail(requestID, error: error) }
                }
            }
        } onCancel: { Task { await self.fail(requestID, error: CancellationError()) } }
    }
    public func attach(_ session: String, cols: Int, rows: Int) async throws -> Bool {
        guard sessions.contains(where: { $0["id"].string == session }) else { throw NativeRPCError(code: "unknown-session", message: "That remote session is not in the host's list") }
        attachments[session] = (cols, rows); replaying.insert(session)
        try await send(type: "attach", fields: [.init("id", .string(session)), .init("cols", .number(Double(cols))), .init("rows", .number(Double(rows)))]); return true
    }
    public func detach(_ session: String) async throws { attachments[session] = nil; replaying.remove(session); try await send(type: "detach", fields: [.init("id", .string(session))]) }
    public func input(_ session: String, data: String) async throws {
        guard attachments[session] != nil, data.utf8.count <= 1048576 else { throw NativeRPCError.invalidArguments("The remote session is not attached or the paste is too large") }
        for chunk in BackendRemoteProtocol.chunkInput(data) { try await send(type: "input", fields: [.init("id", .string(session)), .init("data", .string(chunk))]) }
    }
    public func resize(_ session: String, cols: Int, rows: Int) async throws { try await send(type: "resize", fields: [.init("id", .string(session)), .init("cols", .number(Double(cols))), .init("rows", .number(Double(rows)))]) }
    private func refuseWindow(_ id: NativeRPCValue, message: String) async throws { try await send(type: "window.result", fields: [.init("id", id), .init("ok", .bool(false)), .init("body", .string(NativeRPCValue.object([.init("message", .string(message))]).compact))]) }
    private func expire(_ id: String) { fail(id, error: NativeRPCError(code: "machine-timeout", message: "That machine did not answer the request in time")) }
    private func fail(_ id: String, error: Error) { guard let value = pending.removeValue(forKey: id) else { return }; value.timeout.cancel(); value.continuation.resume(throwing: error) }
    private func ping(_ epoch: UUID) async {
        guard epoch == generation, let channel else { return }
        let timeout = Task { [weak self] in try? await Task.sleep(for: .seconds(20)); guard !Task.isCancelled else { return }; await self?.lost(epoch, reason: "That machine stopped answering heartbeat pings.") }
        defer { timeout.cancel() }
        do { try await channel.ping() } catch { await lost(epoch, reason: error.localizedDescription) }
    }
    private func lost(_ epoch: UUID, reason: String) async { if epoch == generation && !stopped { await drop(reason, reconnect: true) } }
    private func drop(_ message: String, reconnect: Bool, preservePhase: Bool = false) async {
        generation = UUID(); receiver?.cancel(); receiver = nil; heartbeat?.cancel(); heartbeat = nil
        for task in windowTasks.values { task.cancel() }; windowTasks = [:]
        await channel?.close(); channel = nil
        for request in pending.values { request.timeout.cancel(); request.continuation.resume(throwing: NativeRPCError(code: "machine-offline", message: message)) }; pending = [:]
        if !preservePhase { phase = stopped ? .offline : .error }
        if connectedAt != 0 && Date().timeIntervalSince1970 * 1000 - connectedAt >= 60000 { attempts = 0 }; connectedAt = 0
        reason = stopped ? nil : message; sessions = []; ports = []; copilot = .null
        if !stopped && reconnect {
            let ceiling = phase == .awaitingApproval ? 2000 : min(60000, 1000 * (1 << min(attempts, 6)))
            let delay = Int.random(in: (ceiling / 2)...ceiling); attempts += 1
            retryAt = Date().timeIntervalSince1970 * 1000 + Double(delay)
            retry?.cancel(); retry = Task { [weak self] in try? await Task.sleep(for: .milliseconds(delay)); guard !Task.isCancelled else { return }; await self?.beginDial() }
        } else { retryAt = nil }
        await announce()
    }
    private func announce() async { await onState(state()) }
    private func finishedWindow(_ id: String, epoch: UUID) { if epoch == generation { windowTasks[id] = nil } }
    public func sendCopilot(type: String, fields: [NativeRPCValue.Field]) async throws {
        guard copilot["granted"].bool == true else { throw NativeRPCError(code: "copilot-denied", message: "Someone on that machine must grant access to its assistant first") }
        if copilot["open"].bool != true { try await send(type: "copilot.hello", fields: [], capability: "copilot"); copilot = copilot.setting("open", .bool(true)); await announce() }
        try await send(type: type, fields: fields, capability: "copilot")
    }
}
