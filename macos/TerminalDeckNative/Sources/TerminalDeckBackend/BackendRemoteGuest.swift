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
    /// m5-direct-only: the direct link's path ("host", "internet", "turn") once this Mac moved onto it; empty on the relay.
    public var linkPath: String = ""
    public var value: NativeRPCValue { .object([.init("id", .string(id)), .init("state", .string(phase.rawValue)), .init("reason", reason.map(NativeRPCValue.string) ?? .null),
        .init("sessions", .array(sessions)), .init("folders", folders.map { .array($0.map(NativeRPCValue.string)) } ?? .null),
        .init("capabilities", .array(capabilities.sorted().map(NativeRPCValue.string))), .init("ports", .array(ports)), .init("hoot", copilot),
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
    // MARK: The direct link (contract §11, the phones' client side)
    enum LinkStage: Equatable { case none, awaiting, answering, moved }
    private(set) var stage = LinkStage.none
    private var link: (any BackendLinkAnswerConnection)?
    /// The host said `link.only`: nothing app-level comes on the relay, nothing is held for its marker.
    private var hostOnly = false
    private var hostMoved = false
    private var held: [String] = []
    private var waiting: [String] = []
    private var waitingBytes = 0
    private var ownCandidates: [String]? = []
    private var linkPath = ""
    private var linkTimer: Task<Void, Never>?
    private var pongDue: Task<Void, Never>?
    private var hostName = "that computer"
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
    public func state() -> BackendMachineLinkState {
        var state = BackendMachineLinkState(id: id, phase: phase, reason: reason, sessions: sessions, folders: folders, capabilities: capabilities,
            ports: ports, copilot: copilot, hostPlatform: platform, hostVersion: version, hostKind: hostKind, retryAt: retryAt)
        state.linkPath = stage == .moved ? linkPath : ""
        return state
    }
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
            } catch { await self?.relayEnded(epoch, reason: error.localizedDescription) }
        }
    }
    private func sendHello(_ epoch: UUID) async throws {
        guard epoch == generation, let channel else { return }
        var caps = declaredCapabilities
        if windowCall == nil { caps.remove("windows") } else { caps.insert("windows") }
        if receivedHolds == nil { caps.remove("hostwindows") } else { caps.insert("hostwindows") }
        // §11: the direct link, as a phone asks for it (only with a sealed channel to bind it to, and WebRTC here).
        if Self.answerer != nil, await channel.binding != nil { caps.formUnion([BackendRemoteHost.linkCapability, BackendRemoteHost.linkOnlyCapability]) }
        try await channel.send(.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(secrets.credential)),
            .init("device", .object([.init("name", .string(name)), .init("platform", .string("darwin"))])), .init("capabilities", .array(caps.sorted().map(NativeRPCValue.string)))]))
    }
    /// Tests: one host frame as if it arrived on the current link.
    func feedForTest(_ text: String) async throws { stopped = false; try await frame(text, epoch: generation) }
    private func frame(_ text: String, epoch: UUID, viaLink: Bool = false) async throws {
        guard epoch == generation, !stopped else { return }
        // The link's own frames (contract §2, §5): on the relay; from a link-only host late candidates also on the link.
        if text.hasPrefix(#"{"t":"link."#), let value = try? NativeRPCValue.parseJSON(Data(text.utf8)) {
            if viaLink, !(hostOnly && value["t"].string == "link.peer") { return }
            if value["t"].string == "link.moved" { hostMovedArrived(epoch); return }
            if value["t"].string == "link.peer" { await signal(value, epoch: epoch) }
            return
        }
        // §11.1: once on link-only terms the relay carries only the hello's answers; an older host's own relay messages
        // count until its marker.
        if !viaLink, stage != .none, hostOnly || hostMoved,
           !["welcome", "error", "device.access", "enrolled"].contains(BackendRemoteLinkPath.type(of: text).map(String.init) ?? "") { return }
        let value = try BackendRemoteGuestFrames.parse(text, most: viaLink ? 4 * 1024 * 1024 : nil), type = value["t"].string!
        for (key, request) in pending where request.tags.contains(type) && value[request.field].string == key {
            pending.removeValue(forKey: key)?.timeout.cancel(); request.continuation.resume(returning: value); break
        }
        switch type {
        case "welcome":
            phase = .online; reason = nil; retryAt = nil; everWelcomed = true; connectedAt = Date().timeIntervalSince1970 * 1000
            sessions = value["sessions"].elements ?? []; folders = value["folders"].elements?.compactMap(\.string)
            capabilities = Set(value["capabilities"].elements?.compactMap(\.string) ?? [])
            copilot = value["hoot"] == .missing ? .null : value["hoot"]
            platform = value["hostPlatform"].string ?? ""; version = value["appVersion"].string ?? ""; hostKind = value["hostKind"].string
            hostName = value["hostName"].string.flatMap { $0.isEmpty ? nil : $0 } ?? (hostKind == "headless" ? "your server" : "that computer")
            if hostKind == "headless", !capabilities.contains(BackendRemoteHost.linkCapability), !capabilities.contains(BackendRemoteHost.linkOnlyCapability) {
                await drop("Update the host on your server to connect directly.", reconnect: false)
                return
            }
            let binding = await channel?.binding
            if hostKind == "headless", Self.answerer == nil || binding == nil {
                await drop(Self.unreachable(hostName), reconnect: false)
                return
            }
            // A host that offers the link (§1): everything from here on waits for it; one that does not (older than
            // 0.20.3) keeps today's relay connection (§11.5). Servers always require the link.
            if stage == .none, capabilities.contains(BackendRemoteHost.linkCapability) || capabilities.contains(BackendRemoteHost.linkOnlyCapability), Self.answerer != nil, binding != nil {
                stage = .awaiting
                hostOnly = capabilities.contains(BackendRemoteHost.linkOnlyCapability)
                linkTimer?.cancel()
                if capabilities.contains(BackendRemoteHost.linkCapability) {
                    linkTimer = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(Self.offerWaitMs))
                        await self?.linkDeadline(epoch, stage: .awaiting)
                    }
                }
            }
            await onWelcome(platform)
            try await announceWindows(); try await announceSessions()
            for (id, size) in attachments { _ = try? await attach(id, cols: size.cols, rows: size.rows) }
            // A beat every 10 s, the link given up after 30 s without an answer (Macky study, learning 9).
            heartbeat?.cancel(); heartbeat = Task { [weak self] in
                while !Task.isCancelled { try? await Task.sleep(for: .seconds(10)); guard !Task.isCancelled else { return }; await self?.beat(epoch) }
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
        case "hoot.grant": copilot = value["link"]; await announce()
        case "pong": pongDue?.cancel(); pongDue = nil
        case "window.call":
            let id = value["id"].string!
            guard windowTasks[id] == nil, windowTasks.count < 8 else { try await refuseWindow(value["id"], message: "Too many browser calls are already pending."); return }
            windowTasks[id] = Task { [weak self] in await self?.serveWindow(value, epoch: epoch); await self?.finishedWindow(id, epoch: epoch) }
        case "window.holds": await receivedHolds?(value["sessions"].elements?.compactMap(\.string) ?? [], value["held"].elements ?? [])
        case "window.result": await receivedResult?(value["id"].string!, value["ok"].bool!, value["body"].string!)
        case "error":
            let message = value["message"].string ?? "The remote host refused the request."
            // Only a refusal of the link itself (no rid: the hello, a revoked device) ends it. A refusal that answers one
            // request (it carries that request's rid: "this Mac needs Full control to click") fails that request only;
            // dropping the link for it made the viewer ask again on reconnect, forever (Reviewer, 31 Oct).
            if value["rid"] == .missing, ["unauthorized", "unauthenticated"].contains(value["code"].string ?? "") {
                phase = value["code"].string == "unauthorized" && !everWelcomed ? .awaitingApproval : .error
                reason = message; await announce()
                await drop(message, reconnect: true, preservePhase: true)
            }
            // #58: an error fails only the request it names. An uncorrelated one (a stale input to a
            // session that just closed) fails nothing that is still waiting.
            if let key = Self.requestNamed(by: value, in: pending.mapValues(\.field)) {
                fail(key, error: NativeRPCError(code: value["code"].string ?? "remote", message: message))
            }
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
        try await deliver(BackendRemoteProtocol.serialize(message), channel: channel)
    }

    /// One message out (§11.2): on the relay only without a link; waiting for the link while it opens; on `td.ctl` after.
    private func deliver(_ text: String, channel: BackendRemoteGuestChannel) async throws {
        switch stage {
        case .none:
            try await channel.sendText(text)
        case .awaiting, .answering:
            waitingBytes += text.utf8.count
            guard waitingBytes <= Self.mostWaitingBytes else {
                await linkUnreachable(generation, why: "too much waited for the link")
                throw NativeRPCError(code: "machine-offline", message: Self.unreachable(hostName))
            }
            waiting.append(text)
        case .moved:
            guard let link, link.send(Data(text.utf8), lane: .control) else {
                await linkFailed(generation, why: "a message could not go on the direct link")
                throw NativeRPCError(code: "machine-offline", message: "The direct link to \(hostName) ended.")
            }
        }
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
    /// The waiting request a host frame names by its own correlation field (`rid`, or `id` for tunnels).
    static func requestNamed(by frame: NativeRPCValue, in pending: [String: String]) -> String? {
        pending.first { key, field in frame[field].string == key }?.key
    }
    private func expire(_ id: String) { fail(id, error: NativeRPCError(code: "machine-timeout", message: "That machine did not answer the request in time")) }
    private func fail(_ id: String, error: Error) { guard let value = pending.removeValue(forKey: id) else { return }; value.timeout.cancel(); value.continuation.resume(throwing: error) }
    /// The heartbeat: on the link a `ping` on `td.ctl` that must be answered within 10 s (§11.4); while the link opens,
    /// nothing; without a link, today's relay ping.
    private func beat(_ epoch: UUID) async {
        guard epoch == generation else { return }
        switch stage {
        case .awaiting, .answering: return
        case .moved:
            guard pongDue == nil else { return }
            guard let link, link.send(Data(#"{"t":"ping"}"#.utf8), lane: .control) else { await linkFailed(epoch, why: "the ping could not go"); return }
            pongDue = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10)); guard !Task.isCancelled else { return }
                await self?.linkFailed(epoch, why: "\(await self?.hostName ?? "That computer") stopped answering on the direct link.")
            }
        case .none: await ping(epoch)
        }
    }

    /// The relay socket ended. With a link that is up nothing changes (§11.4: Cloudflare resets idle-looking sockets every
    /// 1–3 min); otherwise this is the connection ending.
    private func relayEnded(_ epoch: UUID, reason: String) async {
        guard epoch == generation, !stopped else { return }
        if stage == .moved, link?.isOpen == true {
            BackendRemoteRelayClient.note("machines: the relay to \(hostName) closed; the direct link carries on")
            return
        }
        await lost(epoch, reason: reason)
    }

    private func ping(_ epoch: UUID) async {
        guard epoch == generation, let channel else { return }
        let timeout = Task { [weak self] in try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled else { return }; await self?.lost(epoch, reason: "That machine stopped answering heartbeat pings.") }
        defer { timeout.cancel() }
        do { try await channel.ping() } catch { await lost(epoch, reason: error.localizedDescription) }
    }
    private func lost(_ epoch: UUID, reason: String) async { if epoch == generation && !stopped { await drop(reason, reconnect: true) } }
    private func drop(_ message: String, reconnect: Bool, preservePhase: Bool = false) async {
        generation = UUID(); receiver?.cancel(); receiver = nil; heartbeat?.cancel(); heartbeat = nil
        // The link belongs to this sealed connection and goes with it.
        linkTimer?.cancel(); linkTimer = nil; pongDue?.cancel(); pongDue = nil
        let ending = link; link = nil; ending?.close()
        stage = .none; hostOnly = false; hostMoved = false; held = []; waiting = []; waitingBytes = 0; ownCandidates = []; linkPath = ""
        for task in windowTasks.values { task.cancel() }; windowTasks = [:]
        await channel?.close(); channel = nil
        for request in pending.values { request.timeout.cancel(); request.continuation.resume(throwing: NativeRPCError(code: "machine-offline", message: message)) }; pending = [:]
        if !preservePhase { phase = stopped ? .offline : .error }
        if connectedAt != 0 && Date().timeIntervalSince1970 * 1000 - connectedAt >= 60000 { attempts = 0 }; connectedAt = 0
        reason = stopped ? nil : message; sessions = []; ports = []; copilot = .null
        if !stopped && reconnect {
            // Never more than 30 s between tries (learning 10).
            let ceiling = phase == .awaitingApproval ? 2000 : min(30000, 1000 * (1 << min(attempts, 5)))
            let delay = Int.random(in: (ceiling / 2)...ceiling); attempts += 1
            retryAt = Date().timeIntervalSince1970 * 1000 + Double(delay)
            retry?.cancel(); retry = Task { [weak self] in try? await Task.sleep(for: .milliseconds(delay)); guard !Task.isCancelled else { return }; await self?.beginDial() }
        } else { retryAt = nil }
        await announce()
    }
    private func announce() async { await onState(state()) }
    /// The network came back or the Mac woke: a link that is waiting to retry dials now, with a fresh backoff.
    /// Never a second dial: `beginDial` sets `channel` before it suspends, and a retry task that already woke runs
    /// `beginDial` on this actor afterwards, where the same `channel == nil` guard stops it.
    public func nudge() {
        guard !stopped, channel == nil else { return }
        attempts = 0
        retry?.cancel(); retry = nil
        beginDial()
    }
    private func finishedWindow(_ id: String, epoch: UUID) { if epoch == generation { windowTasks[id] = nil } }
    public func sendCopilot(type: String, fields: [NativeRPCValue.Field]) async throws {
        guard copilot["granted"].bool == true else { throw NativeRPCError(code: "copilot-denied", message: "Someone on that machine must grant access to its assistant first") }
        if copilot["open"].bool != true { try await send(type: "hoot.hello", fields: [], capability: "hoot"); copilot = copilot.setting("open", .bool(true)); await announce() }
        try await send(type: type, fields: fields, capability: "hoot")
    }
}

// MARK: - The direct link (the phones' client side of stream-step2-contract.md §2-§7, §11)

extension BackendRemoteGuest {
    /// The host's signalling: its offer (checked against this sealed channel), its candidates, or the end.
    fileprivate func signal(_ value: NativeRPCValue, epoch: UUID) async {
        guard epoch == generation else { return }
        switch value["op"].string {
        case "offer":
            guard stage == .awaiting, let channel, let binding = await channel.binding, let answerer = Self.answerer else { return }
            guard let sdp = value["sdp"].string, sdp.utf8.count <= 32_000, let fp = value["fp"].string, let bind = value["bind"].string,
                  BackendLinkBinding.fingerprint(in: sdp) == fp,
                  BackendLinkBinding.check(bind, binding: binding, role: "host", fingerprint: fp) else {
                try? await channel.sendText(#"{"t":"link.peer","op":"end"}"#)
                await linkUnreachable(epoch, why: "the offer did not match this pairing")
                return
            }
            let servers = (value["ice"].elements ?? []).prefix(8).compactMap { row -> BackendPhonePeerServer? in
                let urls = (row["urls"].elements?.compactMap(\.string) ?? row["urls"].string.map { [$0] } ?? [])
                    .filter { ($0.hasPrefix("stun:") || $0.hasPrefix("turn:") || $0.hasPrefix("turns:")) && $0.utf8.count <= 512 }
                return urls.isEmpty ? nil : BackendPhonePeerServer(urls: urls, username: row["username"].string, credential: row["credential"].string)
            }
            let policy = ["all", "nohost", "relay"].contains(value["policy"].string ?? "") ? value["policy"].string! : "all"
            let events = BackendLinkEvents(
                candidate: { [weak self] sdp, mid, index in Task { await self?.ownCandidate(sdp, mid: mid, index: index, epoch: epoch) } },
                open: { [weak self] path in Task { await self?.linkOpened(path, epoch: epoch) } },
                closed: { [weak self] why in Task { await self?.linkClosedByPeer(why, epoch: epoch) } },
                message: { [weak self] data, lane in
                    let text = String(decoding: data, as: UTF8.self)
                    Task { await self?.linkMessage(text, lane: lane, epoch: epoch) }
                })
            let made: any BackendLinkAnswerConnection
            do { made = try answerer.answer(servers: Array(servers), policy: policy, events: events) }
            catch { await linkUnreachable(epoch, why: "this Mac could not start a direct link"); return }
            link = made
            stage = .answering
            linkTimer?.cancel()
            linkTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Self.linkDeadlineMs))
                await self?.linkDeadline(epoch, stage: .answering)
            }
            do {
                let answer = try await made.answer(offer: sdp)
                guard epoch == generation, stage == .answering, let mine = BackendLinkBinding.fingerprint(in: answer) else { return }
                let bound = BackendLinkBinding.make(binding: binding, role: "client", fingerprint: mine)
                let text = String(decoding: try NativeRPCValue.object([.init("t", .string("link.peer")), .init("op", .string("answer")),
                    .init("sdp", .string(answer)), .init("fp", .string(mine)), .init("bind", .string(bound))]).encodedJSON(), as: UTF8.self)
                try await channel.sendText(text)
                let early = ownCandidates ?? []
                ownCandidates = nil
                for line in early { try? await channel.sendText(line) }
            } catch {
                await linkUnreachable(epoch, why: "this Mac could not answer the offer")
            }
        case "cand":
            guard let line = value["c"].string, line.utf8.count <= 2_000, BackendLinkCandidate.usable(line) else { return }
            link?.add(candidate: line, mid: value["mid"].string, index: Int32(min(64, max(0, value["idx"].number ?? 0))))
        case "end":
            if stage == .moved { await linkFailed(epoch, why: "\(hostName) ended the direct link") }
            else if stage != .none { await linkUnreachable(epoch, why: "\(hostName) ended the direct link") }
        default:
            break
        }
    }

    private func ownCandidate(_ sdp: String, mid: String?, index: Int32, epoch: UUID) async {
        guard epoch == generation, stage == .answering || stage == .moved, let channel else { return }
        var fields: [NativeRPCValue.Field] = [.init("t", .string("link.peer")), .init("op", .string("cand")), .init("c", .string(sdp)), .init("idx", .number(Double(index)))]
        if let mid { fields.append(.init("mid", .string(mid))) }
        guard let text = try? String(decoding: NativeRPCValue.object(fields).encodedJSON(), as: UTF8.self) else { return }
        if ownCandidates != nil { ownCandidates?.append(text); return }
        // After the move to a link-only host: on the link too (the relay may be gone, §11.4).
        if stage == .moved, hostOnly { _ = link?.send(Data(text.utf8), lane: .control) }
        try? await channel.sendText(text)
    }

    /// Every channel is open: the marker as this side's last relay message, then everything that waited, on `td.ctl`.
    private func linkOpened(_ path: String, epoch: UUID) async {
        guard epoch == generation, stage == .answering, let link else { return }
        try? await channel?.sendText(BackendRemoteLinkPath.movedText)
        stage = .moved
        linkPath = path
        linkTimer?.cancel(); linkTimer = nil
        let queued = waiting
        waiting = []; waitingBytes = 0
        for text in queued where !link.send(Data(text.utf8), lane: .control) {
            await linkFailed(epoch, why: "a waiting message could not go on the direct link")
            return
        }
        BackendRemoteRelayClient.note("machines: link up \(path) to \(hostName)\(hostOnly ? ", link only" : "")")
        await announce()
    }

    /// One message off the link: video at once; `td.ctl` after the host's marker (an older host), at once (link only).
    private func linkMessage(_ text: String, lane: BackendLinkLane, epoch: UUID) async {
        guard epoch == generation, stage == .answering || stage == .moved else { return }
        if lane != .control {
            guard text.hasPrefix(#"{"t":"sims.video""#) else { return }
            try? await frame(text, epoch: epoch, viaLink: true)
            return
        }
        if !hostOnly, !hostMoved { held.append(text); return }
        try? await frame(text, epoch: epoch, viaLink: true)
    }

    fileprivate func hostMovedArrived(_ epoch: UUID) {
        guard epoch == generation, !hostMoved else { return }
        hostMoved = true
        let waiting = held
        held = []
        Task { for text in waiting { try? await self.frame(text, epoch: epoch, viaLink: true) } }
    }

    fileprivate func linkDeadline(_ epoch: UUID, stage expected: LinkStage) async {
        guard epoch == generation, stage == expected else { return }
        await linkUnreachable(epoch, why: expected == .awaiting ? "no offer came" : "no direct path opened")
    }

    private func linkClosedByPeer(_ why: String, epoch: UUID) async {
        guard epoch == generation else { return }
        if stage == .moved { await linkFailed(epoch, why: why) } else if stage == .answering { await linkUnreachable(epoch, why: why) }
    }

    /// No link before the move (§11.3): the plain truth, and the normal retries (never a relay fallback).
    func linkUnreachable(_ epoch: UUID, why: String) async {
        guard epoch == generation, !stopped else { return }
        BackendRemoteRelayClient.note("machines: no direct link to \(hostName) (\(why))")
        try? await channel?.sendText(#"{"t":"link.peer","op":"end"}"#)
        await drop(Self.unreachable(hostName), reconnect: true)
    }

    /// The link failed after the move (§7 fail-stop): the connection starts again from the hello.
    func linkFailed(_ epoch: UUID, why: String) async {
        guard epoch == generation, !stopped else { return }
        BackendRemoteRelayClient.note("machines: the direct link to \(hostName) ended (\(why))")
        await drop("The direct link to \(hostName) ended.", reconnect: true)
    }
}
