import Foundation
import TerminalDeckNativeCore

public struct BackendRemoteHostWire: Sendable {
    public let address: String
    public let peerPublicKey: Data?
    public let send: @Sendable (String) async throws -> Void
    public let close: @Sendable (Int, String) async -> Void
    public init(address: String, peerPublicKey: Data? = nil, send: @escaping @Sendable (String) async throws -> Void, close: @escaping @Sendable (Int, String) async -> Void) {
        self.address = address; self.peerPublicKey = peerPublicKey; self.send = send; self.close = close
    }
}
public struct BackendRemoteHostContext: Sendable {
    public let connectionID: UUID
    public let deviceID: String
    public let kind: BackendRemoteDeviceKind
    public let address: String
    public let peerPublicKey: Data?
    public let claimedCapabilities: Set<String>
    public let reach: BackendRemoteDeviceReach
    public var rpcContext: NativeRPCContext { .init(caller: .pairedDevice, ownerID: deviceID, capabilities: ["filesystem.read", "git.read", "state.read"]) }
}
public struct BackendRemoteCreateRequest: Sendable {
    public let deviceID: String
    public let cwd: String
    public let provider: String?
    public let cols: Int
    public let rows: Int
}
public struct BackendRemoteHostFeature: Sendable {
    public enum Policy: Equatable, Sendable { case grantedDevice, ownerOnly, windowGrant }
    public let capability: String
    public let messageTypes: Set<String>
    public let policy: Policy
    public let sessionField: String?
    public let handle: @Sendable (BackendRemoteClientMessage, BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage]
    public init(capability: String, messageTypes: Set<String>, policy: Policy = .ownerOnly, sessionField: String? = nil,
                handle: @escaping @Sendable (BackendRemoteClientMessage, BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage]) {
        self.capability = capability; self.messageTypes = messageTypes; self.policy = policy; self.sessionField = sessionField; self.handle = handle
    }
}
public struct BackendRemoteHostOperations: Sendable {
    public var create: (@Sendable (BackendRemoteCreateRequest, BackendRemoteHostContext) async throws -> BackendSessionMeta)?
    public var close: (@Sendable (String) async throws -> Bool)?
    public var rename: (@Sendable (String, String) async throws -> Bool)?
    public var proveSystemLogin: (@Sendable (String, String, String) async throws -> Bool)?
    public init(create: (@Sendable (BackendRemoteCreateRequest, BackendRemoteHostContext) async throws -> BackendSessionMeta)? = nil,
                close: (@Sendable (String) async throws -> Bool)? = nil, rename: (@Sendable (String, String) async throws -> Bool)? = nil,
                proveSystemLogin: (@Sendable (String, String, String) async throws -> Bool)? = nil) {
        self.create = create; self.close = close; self.rename = rename; self.proveSystemLogin = proveSystemLogin
    }
}
public struct BackendRemoteHostConnection: Sendable {
    public let id: UUID
    public let deviceID: String
    public let name: String
    public let platform: String
    public let address: String
    public let attached: [String]
}

/// Actual session endpoint. Optional domain operations are not advertised until
/// supplied; an absent operation always gives unavailable, never an empty win.
public actor BackendRemoteHost {
    public let trust: BackendRemoteTrustStore
    public let manager: BackendPTYManager
    private let state: NativeStateStore
    private let home: String
    private let privateRoots: [String]
    private let name: String
    private let appVersion: String
    private let operations: BackendRemoteHostOperations
    private let ptySource: (any BackendRemoteServePTYSource)?
    private let sleep: @Sendable (Int) async throws -> Void
    private let clock: @Sendable () -> Double
    private var features: [String: BackendRemoteHostFeature] = [:]
    private struct FeatureLease: Sendable { let ownerID: String; let tags: Set<String>; let closeHook: UUID }
    private var featureLeases: [UUID: FeatureLease] = [:]
    private var live: [UUID: Connection] = [:]
    private var status: [String: BackendSessionStatus] = [:]
    private var started = false
    public var onConnections: (@Sendable ([BackendRemoteHostConnection]) -> Void)?
    private var pairingSpent: (@Sendable () async -> Void)?
    private var deviceDisconnected: (@Sendable (String) async -> Void)?
    private struct ServeLease: Sendable {
        let id: UUID
        let ownerID: String
        let tags: Set<String>
        let suppliers: BackendRemoteServeRegistration.Suppliers
        let hooks: BackendRemoteServeRegistration.Hooks
        let pty: NativeRPCSubscription
        let events: Task<Void, Never>
    }
    private var serveLease: ServeLease?
    private var serveUninstalling = false
    private var processedPTYSequence: UInt64 = 0
    private var ptyWaiters: [UUID: (UInt64, CheckedContinuation<Void, Never>)] = [:]
    private var connectionClosedHandlers: [UUID: @Sendable (UUID) async -> Void] = [:]
    private var connectionRowsProviders: [UUID: @Sendable (UUID) async throws -> [NativeRPCValue.Field]] = [:]
    private struct Attachment: Sendable { let sequence: UInt64; let ready: Bool }
    private struct Connection: Sendable {
        let wire: BackendRemoteHostWire
        let writer: BackendRemoteServeWireWriter
        let connectedAt: Double
        var device: BackendRemoteDevice?
        var platform = ""
        var capabilities: Set<String> = []
        var attached: Set<String> = []
        var attachmentBoundaries: [String: Attachment] = [:]
        var pendingAttachmentEvents: [String: [BackendRemoteServePTYEvent]] = [:]
        var ownSessions: [NativeRPCValue] = []
        var timer: Task<Void, Never>?
    }
    public init(trust: BackendRemoteTrustStore, manager: BackendPTYManager, state: NativeStateStore, home: String,
                hostName: String, appVersion: String, privateRoots: [String], operations: BackendRemoteHostOperations = .init(),
                ptySource: (any BackendRemoteServePTYSource)? = nil,
                sleep: @escaping @Sendable (Int) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) },
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.trust = trust; self.manager = manager; self.state = state; self.home = home; name = hostName
        self.appVersion = appVersion; self.privateRoots = privateRoots; self.operations = operations
        if let ptySource { self.ptySource = ptySource } else { self.ptySource = manager }
        self.sleep = sleep
        self.clock = clock
    }
    public func setConnectionsHandler(_ handler: (@Sendable ([BackendRemoteHostConnection]) -> Void)?) { onConnections = handler }
    public func setPairingSpentHandler(_ handler: (@Sendable () async -> Void)?) { pairingSpent = handler }
    public func setDeviceDisconnectedHandler(_ handler: (@Sendable (String) async -> Void)?) { deviceDisconnected = handler }
    public func register(_ feature: BackendRemoteHostFeature) throws {
        guard BackendRemoteProtocol.capabilities.contains(feature.capability), !feature.messageTypes.isEmpty else { throw NativeRPCError.invalidArguments("The remote feature has no known capability or messages") }
        for type in feature.messageTypes {
            guard features[type] == nil, !Self.baseline.contains(type) else { throw NativeRPCError.invalidArguments("A remote handler already owns \(type)") }
        }
        for type in feature.messageTypes { features[type] = feature }
    }
    /// Additive atomic join for machines/panels/uploads/tunnels. Its cleanup
    /// never removes remote-serve or another area's handlers/callbacks.
    public func installFeatures(ownerID: String, features additions: [BackendRemoteHostFeature],
                                connectionClosed: @escaping @Sendable (UUID) async -> Void) throws -> NativeRPCSubscription {
        guard !ownerID.isEmpty, live.isEmpty, !serveUninstalling,
              !featureLeases.values.contains(where: { $0.ownerID == ownerID }) else {
            throw NativeRPCError(code: "composition-conflict", message: "The remote feature area already has an owner or live peers.")
        }
        var tags = Set<String>()
        for feature in additions {
            guard BackendRemoteProtocol.capabilities.contains(feature.capability), !feature.messageTypes.isEmpty else { throw NativeRPCError.malformed("Unknown remote feature capability") }
            for tag in feature.messageTypes {
                guard tags.insert(tag).inserted, features[tag] == nil, !Self.baseline.contains(tag) else { throw NativeRPCError.malformed("A remote handler already owns \(tag)") }
            }
        }
        let id = UUID(), hook = UUID()
        for feature in additions { for tag in feature.messageTypes { features[tag] = feature } }
        connectionClosedHandlers[hook] = connectionClosed
        featureLeases[id] = .init(ownerID: ownerID, tags: tags, closeHook: hook)
        return NativeRPCSubscription(id: id) { [weak self] in await self?.removeFeatureLease(id) }
    }
    private func removeFeatureLease(_ id: UUID) {
        guard let lease = featureLeases.removeValue(forKey: id) else { return }
        for tag in lease.tags { features[tag] = nil }; connectionClosedHandlers[lease.closeHook] = nil
    }
    /// Never accepts kind/grants/capabilities copied from an old request. The
    /// connection UUID is resolved against the live authenticated owner again.
    public func refreshedContext(_ previous: BackendRemoteHostContext) async throws -> BackendRemoteHostContext {
        guard let current = try await context(previous.connectionID), current.deviceID == previous.deviceID else {
            throw NativeRPCError(code: "unauthorized", message: "This device is no longer approved.")
        }
        return current
    }
    /// Validate everything before publishing any feature/supplier ownership.
    public func installRemoteServe(ownerID: String, features additions: [BackendRemoteHostFeature],
                                   suppliers: BackendRemoteServeRegistration.Suppliers,
                                   hooks: BackendRemoteServeRegistration.Hooks) async throws -> NativeRPCSubscription {
        guard serveLease == nil, !serveUninstalling, live.isEmpty, !ownerID.isEmpty else {
            throw NativeRPCError(code: "composition-conflict", message: "The remote-serve host area already has an owner or live peers.")
        }
        guard let ptySource else { throw NativeRPCError(code: "unavailable", message: "The atomic native PTY replay source is unavailable.") }
        var tags = Set<String>()
        for feature in additions {
            guard BackendRemoteProtocol.capabilities.contains(feature.capability), !feature.messageTypes.isEmpty else { throw NativeRPCError.malformed("Unknown remote feature capability") }
            for tag in feature.messageTypes {
                guard tags.insert(tag).inserted, features[tag] == nil, !Self.baseline.contains(tag) else { throw NativeRPCError.malformed("A remote handler already owns \(tag)") }
            }
        }
        let id = UUID()
        let stream = AsyncStream<BackendRemoteServePTYEvent>.makeStream(bufferingPolicy: .bufferingNewest(2048))
        let observation = ptySource.observe { [weak self] event in
            if case .dropped = stream.continuation.yield(event) {
                Task { await self?.remoteServeOverflow(id) }
            }
        }
        let task = Task { [weak self] in
            for await event in stream.stream {
                guard !Task.isCancelled else { break }; await self?.sequencedEvent(event, leaseID: id)
            }
        }
        for feature in additions { for tag in feature.messageTypes { features[tag] = feature } }
        processedPTYSequence = ptySource.currentSequence()
        serveLease = .init(id: id, ownerID: ownerID, tags: tags, suppliers: suppliers, hooks: hooks, pty: observation, events: task)
        return NativeRPCSubscription(id: id) { [weak self] in
            stream.continuation.finish(); await self?.uninstallRemoteServe(id)
        }
    }
    private func uninstallRemoteServe(_ id: UUID) async {
        guard let lease = serveLease, lease.id == id else { return }
        guard !serveUninstalling else { return }; serveUninstalling = true
        defer { serveUninstalling = false }
        // Keep hooks visible through actual peer teardown; remove the lease
        // only after last-device and each-connection callbacks have drained.
        let waiters = ptyWaiters.values; ptyWaiters = [:]; for waiter in waiters { waiter.1.resume() }
        for tag in lease.tags { features[tag] = nil }
        lease.events.cancel(); await lease.pty.cancelAndWait()
        for connection in Array(live.keys) { await disconnect(connection, code: 1001, reason: "The host stopped.") }
        if serveLease?.id == id { serveLease = nil }
    }
    private func remoteServeOverflow(_ id: UUID) async {
        guard serveLease?.id == id else { return }
        for connection in Array(live.keys) { await disconnect(connection, code: 1011, reason: "Session output could not be delivered.") }
    }
    public func addConnectionClosedHandler(_ handler: @escaping @Sendable (UUID) async -> Void) -> NativeRPCSubscription {
        let id = UUID(); connectionClosedHandlers[id] = handler
        return NativeRPCSubscription(id: id) { [weak self] in await self?.removeConnectionClosedHandler(id) }
    }
    private func removeConnectionClosedHandler(_ id: UUID) { connectionClosedHandlers[id] = nil }
    public func addConnectionRowsProvider(_ provider: @escaping @Sendable (UUID) async throws -> [NativeRPCValue.Field]) -> NativeRPCSubscription {
        let id = UUID(); connectionRowsProviders[id] = provider
        return NativeRPCSubscription(id: id) { [weak self] in await self?.removeConnectionRowsProvider(id) }
    }
    private func removeConnectionRowsProvider(_ id: UUID) { connectionRowsProviders[id] = nil }
    public func remoteServeConnectedDeviceIDs() -> Set<String> { Set(live.values.compactMap { $0.device?.id }) }
    /// TS remote ipc `remote:connection:disconnect`: close one live connection from the desktop.
    public func dropConnection(_ id: UUID) async -> Bool {
        guard live[id] != nil else { return false }
        await disconnect(id, code: 1001, reason: "disconnected from the desktop"); return true
    }
    public func remoteServeConnectionRows() async -> [NativeRPCValue] {
        var result: [NativeRPCValue] = []
        let rows = live.filter { $0.value.device != nil }.sorted { $0.value.connectedAt < $1.value.connectedAt }
        for (id, row) in rows {
            guard let device = row.device, live[id]?.device?.id == device.id else { continue }
            var value = NativeRPCValue.object([.init("id", .string(id.uuidString.lowercased())), .init("deviceId", .string(device.id)),
                .init("deviceName", .string(device.name)), .init("platform", .string(row.platform)), .init("address", .string(row.wire.address)),
                .init("connectedAt", .number(row.connectedAt)), .init("sessionIds", .array(row.attached.sorted().map(NativeRPCValue.string))),
                .init("sessions", .array(row.ownSessions)), .init("tunnels", .array([]))])
            for provider in Array(connectionRowsProviders.values) {
                if let fields = try? await provider(id) { for field in fields where ["tunnels"].contains(field.key) { value = value.setting(field.key, field.value) } }
            }
            if live[id]?.device?.id == device.id { result.append(value) }
        }; return result
    }
    public func remoteServeDropDevice(_ id: String) async {
        for connection in live.keys.filter({ live[$0]?.device?.id == id }) { await disconnect(connection, code: 1008, reason: "This device is no longer approved.") }
    }
    public func remoteServeFoldersChanged(_ id: String) async {
        for connection in live.keys.filter({ live[$0]?.device?.id == id }) {
            guard let context = try? await context(connection) else { continue }
            try? await send(connection, .init(.folders, fields: [.init("folders", .array(context.reach.folders.map(NativeRPCValue.string)))]))
        }
        await refreshGrants()
    }
    public func remoteServeAskWindows(deviceID: String, message: BackendRemoteServerMessage) async throws -> Int {
        var delivered = 0
        for id in live.keys.filter({ live[$0]?.device?.id == deviceID }) {
            guard let context = try await context(id), context.claimedCapabilities.contains("windows") else { continue }
            try await sendToConnection(id, message: message); delivered += 1
        }; return delivered
    }
    public func remoteServeReachesWindows(_ deviceID: String) async -> Bool {
        for id in live.keys.filter({ live[$0]?.device?.id == deviceID }) {
            if let context = try? await context(id), context.claimedCapabilities.contains("windows") { return true }
        }; return false
    }
    public func remoteServePushToOwnDevices(message: BackendRemoteServerMessage, claiming capability: String) async throws {
        var failure: (any Error)?
        for id in Array(live.keys) {
            guard let context = try await context(id), context.kind == .mine, context.claimedCapabilities.contains(capability) else { continue }
            do { try await sendToConnection(id, message: message) }
            catch { failure = error; await disconnect(id, code: 1011, reason: "Remote output could not be delivered.") }
        }
        if let failure { throw failure }
    }
    public func sendToConnection(_ id: UUID, message: BackendRemoteServerMessage) async throws {
        guard let context = try await context(id) else { throw NativeRPCError(code: "unavailable", message: "The remote connection is closed or unauthenticated.") }
        if let lease = serveLease { try await lease.suppliers.requireReady() }
        guard live[id]?.device?.id == context.deviceID else { throw NativeRPCError(code: "unavailable", message: "The remote connection is closed.") }
        try await send(id, message)
    }
    public func start() async throws {
        guard !started else { return }
        try await trust.open()
        if serveLease != nil { try await trust.remoteServeReloadDomainGrants() }
        await trust.setChangeHandler { [weak self] in Task { await self?.refreshGrants() } }
        started = true
    }
    public func stop() async {
        started = false
        for id in Array(live.keys) { await disconnect(id, code: 1001, reason: "The host stopped.") }
        await trust.setChangeHandler(nil)
        await trust.close()
    }
    private var sessionSource: [BackendSessionMeta] { ptySource?.list() ?? manager.list() }
    private func waitForPTYBoundary() async {
        guard serveLease != nil, !serveUninstalling, let ptySource else { return }
        let target = ptySource.currentSequence()
        guard processedPTYSequence < target || live.values.contains(where: { $0.attachmentBoundaries.values.contains { !$0.ready } }) else { return }
        await withCheckedContinuation { ptyWaiters[UUID()] = (target, $0) }
    }
    private func signalPTYWaiters() {
        guard !live.values.contains(where: { $0.attachmentBoundaries.values.contains { !$0.ready } }) else { return }
        for id in ptyWaiters.filter({ $0.value.0 <= processedPTYSequence }).map(\.key) { ptyWaiters.removeValue(forKey: id)?.1.resume() }
    }
    private func sequencedEvent(_ item: BackendRemoteServePTYEvent, leaseID: UUID) async {
        guard serveLease?.id == leaseID else { return }
        defer {
            processedPTYSequence = max(processedPTYSequence, item.sequence)
            signalPTYWaiters()
        }
        if case .status(let id, let current) = item.event { status[id] = current }
        let session: String
        switch item.event { case .data(let id, _), .exit(let id, _), .status(let id, _), .removed(let id, _): session = id }
        for id in Array(live.keys) {
            guard let boundary = live[id]?.attachmentBoundaries[session], item.sequence > boundary.sequence else { continue }
            if !boundary.ready {
                let pending = live[id]?.pendingAttachmentEvents[session] ?? []
                guard pending.count < 2048 else { await disconnect(id, code: 1013, reason: "output backed up"); continue }
                live[id]?.pendingAttachmentEvents[session] = pending + [item]; continue
            }
            await deliverSessionEvent(item.event, connectionID: id)
        }
        if case .exit = item.event { status[session] = nil; try? await broadcastSessions() }
        if case .removed = item.event { status[session] = nil; try? await broadcastSessions() }
    }
    private func deliverSessionEvent(_ event: BackendSessionEvent, connectionID: UUID) async {
        let session: String
        switch event { case .data(let id, _), .exit(let id, _), .status(let id, _), .removed(let id, _): session = id }
        guard live[connectionID]?.attached.contains(session) == true else { return }
        do {
            if case .removed = event {
                live[connectionID]?.attached.remove(session); live[connectionID]?.attachmentBoundaries[session] = nil
                try await send(connectionID, .init(.detached, fields: [.init("id", .string(session))])); return
            }
            guard let context = try await context(connectionID), try await visible(session, context: context) else {
                live[connectionID]?.attached.remove(session); live[connectionID]?.attachmentBoundaries[session] = nil; return
            }
            switch event {
            case .data(_, let text): for chunk in BackendRemoteProtocol.chunkOutput(text) { try await send(connectionID, .init(.output, fields: [.init("id", .string(session)), .init("data", .string(chunk))])) }
            case .status(_, let value): try await send(connectionID, .init(.status, fields: [.init("id", .string(session)), .init("status", .string(value.rawValue))]))
            case .exit(_, let code):
                try await send(connectionID, .init(.exit, fields: [.init("id", .string(session)), .init("exitCode", .number(Double(code)))]))
                live[connectionID]?.attached.remove(session); live[connectionID]?.attachmentBoundaries[session] = nil
            case .removed: break
            }
        } catch { await disconnect(connectionID, code: 1011, reason: "Session output could not be delivered.") }
    }
    public func accept(_ wire: BackendRemoteHostWire) async -> UUID? {
        guard started, live.count < 64 else { await wire.close(1013, "This host has too many connections."); return nil }
        let id = UUID()
        live[id] = Connection(wire: wire, writer: BackendRemoteServeWireWriter(write: wire.send), connectedAt: clock())
        live[id]?.timer = Task { [weak self] in
            try? await self?.sleep(10_000)
            guard !Task.isCancelled else { return }
            await self?.expireHello(id)
        }
        return id
    }
    public func connections() -> [BackendRemoteHostConnection] {
        live.compactMap { id, row in row.device.map { .init(id: id, deviceID: $0.id, name: $0.name, platform: row.platform,
            address: row.wire.address, attached: row.attached.sorted()) } }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    public func receive(_ id: UUID, text: String) async {
        guard live[id] != nil else { return }
        switch BackendRemoteProtocol.parseClientMessage(text) {
        case .refused(let failure): await refuse(id, code: failure.code, message: failure.reason, close: failure.code == "too-large" ? 1009 : 1002)
        case .message(let message):
            do { try await dispatch(id, message) }
            catch let failure as BackendRemoteTrustFailure {
                let reason: String
                switch failure { case .denied(let text), .storage(let text): reason = text; case .closed: reason = "Remote access is not running." }
                await refuse(id, code: "unauthorized", message: reason)
            } catch let error as NativeRPCError {
                await refuse(id, code: BackendRemoteProtocol.errorCodes.contains(error.code) ? error.code : "unavailable", message: error.message)
            } catch { await refuse(id, code: "unavailable", message: error.localizedDescription) }
        }
    }
    public func closed(_ id: UUID) async {
        await finishConnection(id, closeWire: nil)
    }
    private func expireHello(_ id: UUID) async { if live[id]?.device == nil { await disconnect(id, code: 1008, reason: "Say hello before opening a session.") } }
    private func dispatch(_ id: UUID, _ message: BackendRemoteClientMessage) async throws {
        if message.type == "hello" { try await hello(id, message); return }
        if message.type == "enroll" { try await enroll(id, message); return }
        if message.type == "ping" { try await send(id, .init(.pong, fields: [])); return }
        guard let context = try await context(id) else { await refuse(id, code: "unauthenticated", message: "Say hello before opening a session.", close: 1008); return }
        switch message.type {
        case "list": try await sendSessions(id, context: context)
        case "attach":
            let sessionID = message["id"].string!
            guard try await visible(sessionID, context: context) else { await unknown(id, sessionID); return }
            guard let ptySource, serveLease != nil else { await unavailable(id, "The atomic native PTY replay source is unavailable."); return }
            if let cols = message["cols"].number, let rows = message["rows"].number { try ptySource.resize(sessionID, cols: Int(cols), rows: Int(rows)) }
            // No await from the owner-queue snapshot to installing this peer's
            // watermark. Earlier queued events are excluded from its replay.
            guard let snapshot = ptySource.snapshot(sessionID), live[id] != nil else { await unknown(id, sessionID); return }
            live[id]?.attached.insert(sessionID)
            live[id]?.attachmentBoundaries[sessionID] = .init(sequence: snapshot.sequence, ready: false)
            live[id]?.pendingAttachmentEvents[sessionID] = []
            do {
                try await send(id, .init(.attached, fields: [.init("id", .string(sessionID))]))
                for chunk in BackendRemoteProtocol.chunkOutput(snapshot.replay) { try await send(id, .init(.output, fields: [.init("id", .string(sessionID)), .init("data", .string(chunk))])) }
                let current = snapshot.status
                try await send(id, .init(.status, fields: [.init("id", .string(sessionID)), .init("status", .string(current.rawValue))]))
            } catch {
                // A failed replay must not leave a not-ready attachment that
                // holds the lifecycle's exit/grant-pruning barrier forever.
                await disconnect(id, code: 1011, reason: "Session output could not be delivered.")
                throw error
            }
            // Keep the gate closed while draining: a new event cannot overtake
            // an older queued byte during an awaited transport write.
            while live[id]?.attached.contains(sessionID) == true {
                guard let next = live[id]?.pendingAttachmentEvents[sessionID]?.first else { break }
                live[id]?.pendingAttachmentEvents[sessionID]?.removeFirst()
                await deliverSessionEvent(next.event, connectionID: id)
            }
            live[id]?.pendingAttachmentEvents[sessionID] = nil
            if live[id]?.attached.contains(sessionID) == true { live[id]?.attachmentBoundaries[sessionID] = .init(sequence: snapshot.sequence, ready: true) }
            signalPTYWaiters()
            announce()
        case "detach":
            let session = message["id"].string!
            live[id]?.attached.remove(session)
            live[id]?.attachmentBoundaries[session] = nil; live[id]?.pendingAttachmentEvents[session] = nil
            signalPTYWaiters()
            try await send(id, .init(.detached, fields: [.init("id", .string(session))])); announce()
        case "input", "resize":
            let session = message["id"].string!
            guard live[id]?.attached.contains(session) == true else { await unknown(id, session); return }
            guard try await visible(session, context: context) else { await refuse(id, code: "unauthorized", message: BackendRemoteServeSessionPolicy.unsharedMessage); return }
            if let ptySource {
                if message.type == "input" { try ptySource.write(session, data: message["data"].string!) }
                else { try ptySource.resize(session, cols: Int(message["cols"].number!), rows: Int(message["rows"].number!)) }
            } else if message.type == "input" { try manager.write(session, data: message["data"].string!) }
            else { try manager.resize(session, cols: Int(message["cols"].number!), rows: Int(message["rows"].number!)) }
        case "create":
            if let lease = serveLease {
                try await lease.suppliers.requireReady()
                guard let creator = lease.suppliers.create else { await unavailable(id, "This host cannot start a session."); return }
                let outcome = await creator.create(.init(message: message, deviceID: context.deviceID))
                if let session = outcome.session {
                    guard live[id]?.device?.id == context.deviceID, await trust.isApproved(context.deviceID), await trust.canReachFolder(context.deviceID, folder: session.cwd) else {
                        ptySource?.kill(session.id); return
                    }
                }
                try await send(id, outcome.message()); try await broadcastSessions(); return
            }
            guard let create = operations.create else { await unavailable(id, "This host cannot start a session."); return }
            let request: BackendRemoteCreateRequest
            switch BackendRemoteServeSessionCreate.plan(.init(message: message, deviceID: context.deviceID), offered: context.reach.folders, unrestricted: context.reach.unrestricted) {
            case .failure(let error): await refuse(id, code: error.code, message: error.message); return
            case .success(let planned): request = planned
            }
            let session = try await create(request, context)
            guard live[id]?.device?.id == context.deviceID, await trust.isApproved(context.deviceID), await trust.canReachFolder(context.deviceID, folder: session.cwd) else {
                manager.kill(session.id)
                throw BackendRemoteTrustFailure.denied("This device is no longer approved for that folder.")
            }
            _ = try? await trust.remoteServeIncludeStartedSession(context.deviceID, sessionID: session.id)
            try await send(id, BackendRemoteServeSessionCreate.Outcome.created(session).message())
            try await broadcastSessions()
        case "close", "rename":
            let session = message["id"].string!
            guard try await visible(session, context: context) else { await unknown(id, session); return }
            if message.type == "close" {
                guard let close = operations.close else { await unavailable(id, "This host cannot close a session."); return }
                guard try await close(session) else { await unknown(id, session); return }
                try await send(id, .init(.closed, fields: [.init("id", .string(session))]))
            } else {
                guard let rename = operations.rename else { await unavailable(id, "This host cannot rename a session."); return }
                guard try await rename(session, message["title"].string!) else { await unknown(id, session); return }
            }
            try await broadcastSessions()
        default:
            if let lease = serveLease {
                try await lease.suppliers.requireReady()
                if message.type.hasPrefix("credential.") { try await lease.suppliers.legacyCredential(message, context); return }
            }
            guard let feature = features[message.type] else {
                if let refusal = try BackendRemoteServeHostRefusals.missing(message.type) { try await send(id, refusal) }
                else { await unavailable(id, "This host does not serve \(message.type).") }; return
            }
            if feature.policy == .ownerOnly && context.kind != .mine || feature.policy == .windowGrant && !context.reach.drivesWindows {
                if let refusal = try BackendRemoteServeHostRefusals.guest(message.type) { try await send(id, refusal) }
                else { await refuse(id, code: "unauthorized", message: "This device was not granted that operation.") }; return
            }
            if let field = feature.sessionField, let session = message[field].string, !(try await visible(session, context: context)) { await unknown(id, session); return }
            if message.type == "window.holds" { await serveLease?.hooks.windowHolds(message, context.deviceID) }
            if message.type == "sessions.mine" { live[id]?.ownSessions = message["sessions"].elements ?? []; announce() }
            for answer in try await feature.handle(message, context) { try await send(id, answer) }
        }
    }
    private func hello(_ id: UUID, _ message: BackendRemoteClientMessage) async throws {
        guard let row = live[id], row.device == nil else { throw BackendRemoteTrustFailure.denied("This connection already said hello.") }
        guard message["protocol"].number == 1 else { await refuse(id, code: "version", message: "This client and host speak different protocol versions. Update whichever is older.", close: 1008); return }
        let token = message["token"].string!, name = message["device"]["name"].string!
        if !token.contains(".") {
            let paired = try await trust.redeem(token, name: name, address: row.wire.address, publicKey: row.wire.peerPublicKey)
            await pairingSpent?()
            try await send(id, .init(.welcome, fields: [.init("protocol", .number(1)), .init("deviceId", .string(paired.device.id)), .init("deviceName", .string(paired.device.name)),
                .init("token", .string(paired.credential)), .init("sessions", .array([])), .init("capabilities", .array([]))]))
            await refuse(id, code: "unauthorized", message: "Paired. Approve this device in the app on this Mac, then reconnect.", close: 1008)
            return
        }
        let device = try await trust.verify(token, address: row.wire.address, peerKey: row.wire.peerPublicKey)
        guard live[id] != nil else { return }
        live[id]?.device = device; live[id]?.platform = message["device"]["platform"].string ?? "unknown"
        live[id]?.capabilities = Set(message["capabilities"].elements?.compactMap(\.string) ?? [])
        live[id]?.timer?.cancel(); live[id]?.timer = nil
        guard let context = try await context(id) else { return }
        var fields: [NativeRPCValue.Field] = [.init("protocol", .number(1)), .init("deviceId", .string(device.id)), .init("deviceName", .string(device.name)),
            .init("token", .null), .init("sessions", .array(try await sessions(context))), .init("capabilities", .array(capabilities(context).map(NativeRPCValue.string))),
            .init("hostPlatform", .string("darwin")), .init("hostName", .string(self.name)), .init("appVersion", .string(appVersion)), .init("hostKind", .string("desktop"))]
        if serveLease?.suppliers.create != nil || serveLease == nil && operations.create != nil { fields.append(.init("folders", .array(context.reach.folders.map(NativeRPCValue.string)))) }
        try await send(id, .init(.welcome, fields: fields)); announce()
    }
    private func enroll(_ id: UUID, _ message: BackendRemoteClientMessage) async throws {
        guard let row = live[id], row.device == nil else { throw BackendRemoteTrustFailure.denied("This connection already authenticated.") }
        if let lease = serveLease {
            try await lease.suppliers.requireReady()
            guard let enrollment = lease.suppliers.enrollment else { await unavailable(id, "Sign-in is not switched on for this machine. Pair it with a code instead."); return }
            guard message["protocol"].number == 1, let key = row.wire.peerPublicKey else { throw NativeRPCError(code: "unauthorized", message: BackendRemoteServeEnrollment.refused) }
            let issued = try await enrollment.signIn(username: message["username"].string!, secret: message["secret"].string!, method: message["method"].string!,
                deviceName: message["device"]["name"].string!, address: row.wire.address, peerPublicKey: key)
            guard live[id]?.device == nil, live[id] != nil else { return }
            try await send(id, .init(.enrolled, fields: [.init("deviceId", .string(issued.device.id)), .init("deviceName", .string(issued.device.name)), .init("credential", .string(issued.credential))]))
            return
        }
        guard let verifier = operations.proveSystemLogin else { await unavailable(id, "Sign-in is not switched on for this machine. Pair it with a code instead."); return }
        guard message["protocol"].number == 1, let key = row.wire.peerPublicKey, await trust.enrollmentAllowed(address: row.wire.address) else {
            throw BackendRemoteTrustFailure.denied("Sign-in could not be accepted.")
        }
        let allowed = try await verifier(message["username"].string!, message["secret"].string!, message["method"].string!)
        guard allowed, live[id] != nil else { await trust.noteEnrollmentFailure(address: row.wire.address); throw BackendRemoteTrustFailure.denied("Sign-in could not be accepted.") }
        let issued = try await trust.enrollVerifiedDevice(name: message["device"]["name"].string!, address: row.wire.address, publicKey: key)
        try await send(id, .init(.enrolled, fields: [.init("deviceId", .string(issued.device.id)), .init("deviceName", .string(issued.device.name)), .init("credential", .string(issued.credential))]))
        // Credential delivery does not authenticate the socket. Ordinary hello
        // must prove the new credential and its sealed public-key binding.
    }
    private func capabilities(_ context: BackendRemoteHostContext) -> [String] {
        var enabled: Set<String> = []
        if serveLease?.suppliers.create != nil || serveLease == nil && operations.create != nil { enabled.insert("create") }
        if operations.close != nil { enabled.insert("close") }
        if operations.rename != nil { enabled.insert("rename") }
        var supplied: [String: Set<String>] = [:]
        for feature in features.values where feature.policy != .ownerOnly || context.kind == .mine {
            if feature.capability == "credential" { continue }
            if feature.capability == "account", context.reach.accounts?.isEmpty == true { continue }
            if feature.capability == "logins", context.kind != .mine { continue }
            // hostwindows describes this host's implemented verbs. The current
            // window permission is checked at dispatch, not advertisement.
            if feature.capability == "hostwindows" || feature.policy != .windowGrant || context.reach.drivesWindows {
                supplied[feature.capability, default: []].formUnion(feature.messageTypes)
            }
        }
        for (capability, types) in supplied {
            if let required = Self.requiredFeatureMessages[capability], required.isSubset(of: types) { enabled.insert(capability) }
        }
        return BackendRemoteProtocol.advertisedCapabilities(implemented: enabled)
    }
    private func context(_ id: UUID) async throws -> BackendRemoteHostContext? {
        guard let row = live[id], let device = row.device else { return nil }
        guard await trust.isApproved(device.id) else { await disconnect(id, code: 1008, reason: "This device is no longer approved."); return nil }
        let sessionRows = sessionSource
        let hidden: @Sendable (String) -> Bool
        if let supplied = serveLease?.suppliers.isHidden { hidden = supplied }
        else { hidden = { @Sendable (id: String) -> Bool in BackendRemoteServeSessionHidden.shared.contains(id) } }
        // host-core.ts hides by register + desk-Hoot identity, never by origin:
        // sessions Hoot or a routine started for the person stay ordinary work.
        let rawOffered = await state.getProjects().compactMap { $0["path"].string } + sessionRows.filter { !hidden($0.id) }.map(\.cwd)
        let offered = BackendRemoteServeSessionPolicy.offeredFolders(rawOffered, sessions: sessionRows, hidden: hidden)
        let reach = await trust.reach(device.id, offered: offered, home: home)
        let effective: BackendRemoteDeviceReach
        if let lease = serveLease {
            let drives = try await lease.suppliers.drivesWindows(device.id)
            effective = .init(kind: reach.kind, unrestricted: reach.unrestricted, folders: reach.folders, accounts: reach.accounts, drivesWindows: drives)
        } else { effective = reach }
        return .init(connectionID: id, deviceID: device.id, kind: reach.kind, address: row.wire.address,
            peerPublicKey: row.wire.peerPublicKey, claimedCapabilities: row.capabilities, reach: effective)
    }
    private func visible(_ sessionID: String, context: BackendRemoteHostContext) async throws -> Bool {
        if let lease = serveLease {
            guard let session = sessionSource.first(where: { $0.id == sessionID }), !lease.suppliers.isHidden(session.id) else { return false }
            return await lease.suppliers.sessionVisible(context.deviceID, sessionID)
        }
        guard let meta = sessionSource.first(where: { $0.id == sessionID }), !BackendRemoteServeSessionHidden.shared.contains(sessionID),
              !privateRoots.contains(where: { BackendRemoteTrustStore.within($0, meta.cwd) }),
              await trust.sessionShared(context.deviceID, session: sessionID) else { return false }
        return await trust.canReachFolder(context.deviceID, folder: meta.cwd)
    }
    private func sessions(_ context: BackendRemoteHostContext) async throws -> [NativeRPCValue] {
        var result: [NativeRPCValue] = []
        for session in sessionSource where try await visible(session.id, context: context) { result.append(sessionValue(session)) }
        return result
    }
    private func sessionValue(_ meta: BackendSessionMeta) -> NativeRPCValue {
        let state = meta.exitCode == nil ? status[meta.id] ?? ptySource?.snapshot(meta.id)?.status ?? manager.screen(meta.id).map { BackendSessionClassifier.classify(viewport: $0) } ?? .idle : .exited
        return .object([.init("id", .string(meta.id)), .init("title", .string(meta.title)), .init("cwd", .string(meta.cwd)), .init("provider", .string(meta.provider)),
            .init("status", .string(state.rawValue)), .init("exitCode", meta.exitCode.map { .number(Double($0)) } ?? .null)])
    }
    public func noteSessionEvent(_ event: BackendSessionEvent) async {
        if serveLease != nil {
            // The queue-owned sequenced path is the only terminal fanout.
            // Lifecycle waits for it before pruning exit/removal grants.
            await waitForPTYBoundary(); return
        }
        if case .status(let session, let current) = event { status[session] = current }
        for id in Array(live.keys) {
            guard let context = try? await context(id) else { continue }
            let session: String
            switch event { case .data(let id, _), .exit(let id, _), .status(let id, _), .removed(let id, _): session = id }
            guard live[id]?.attached.contains(session) == true else { continue }
            if case .removed = event { live[id]?.attached.remove(session); try? await send(id, .init(.detached, fields: [.init("id", .string(session))])); continue }
            guard (try? await visible(session, context: context)) == true else { live[id]?.attached.remove(session); continue }
            do {
                switch event {
                case .data(_, let text): for chunk in BackendRemoteProtocol.chunkOutput(text) { try await send(id, .init(.output, fields: [.init("id", .string(session)), .init("data", .string(chunk))])) }
                case .status(_, let current): try await send(id, .init(.status, fields: [.init("id", .string(session)), .init("status", .string(current.rawValue))]))
                case .exit(_, let code): try await send(id, .init(.exit, fields: [.init("id", .string(session)), .init("exitCode", .number(Double(code)))]))
                case .removed: break
                }
            } catch { await disconnect(id, code: 1011, reason: "Session output could not be delivered.") }
        }
        if case .exit = event { try? await broadcastSessions() }
        if case .removed = event { try? await broadcastSessions() }
    }
    public func sessionsChanged() async { try? await broadcastSessions() }
    public func refreshGrants() async {
        for id in Array(live.keys) {
            guard let context = try? await context(id) else { continue }
            for session in live[id]?.attached ?? [] where (try? await visible(session, context: context)) != true {
                live[id]?.attached.remove(session); try? await send(id, .init(.detached, fields: [.init("id", .string(session))]))
            }
            try? await sendSessions(id, context: context)
            if serveLease?.suppliers.create != nil || serveLease == nil && operations.create != nil { try? await send(id, .init(.folders, fields: [.init("folders", .array(context.reach.folders.map(NativeRPCValue.string)))])) }
        }
        announce()
    }
    private func broadcastSessions() async throws { for id in Array(live.keys) { if let context = try await context(id) { try await sendSessions(id, context: context) } } }
    private func sendSessions(_ id: UUID, context: BackendRemoteHostContext) async throws { try await send(id, .init(.sessions, fields: [.init("sessions", .array(try await sessions(context)))])) }
    private func send(_ id: UUID, _ message: BackendRemoteServerMessage) async throws {
        guard let writer = live[id]?.writer else { throw NativeRPCError(code: "unavailable", message: "The remote connection is closed.") }
        try await writer.send(BackendRemoteProtocol.serialize(message))
    }
    private func unknown(_ id: UUID, _ session: String) async { await refuse(id, code: "unknown-session", message: BackendRemoteServeSessionPolicy.noSuchSession(session)) }
    private func unavailable(_ id: UUID, _ message: String) async { await refuse(id, code: "unavailable", message: message) }
    private func refuse(_ id: UUID, code: String, message: String, close: Int? = nil) async {
        try? await send(id, .error(code: code, message: message))
        if let close { await disconnect(id, code: close, reason: message) }
    }
    private func disconnect(_ id: UUID, code: Int, reason: String) async {
        await finishConnection(id, closeWire: (code, reason))
    }
    private func finishConnection(_ id: UUID, closeWire: (Int, String)?) async {
        guard let row = live.removeValue(forKey: id) else { return }
        signalPTYWaiters()
        row.timer?.cancel(); await row.writer.close()
        // Remove first: transport close may synchronously notify closed again.
        for callback in Array(connectionClosedHandlers.values) { await callback(id) }
        if let device = row.device, !live.values.contains(where: { $0.device?.id == device.id }) {
            await deviceDisconnected?(device.id); await serveLease?.hooks.lastDeviceDisconnected(device.id)
        }
        if let closeWire { await row.wire.close(closeWire.0, closeWire.1) }
        announce()
    }
    private func announce() {
        onConnections?(connections())
        if let hooks = serveLease?.hooks { Task { await hooks.connectionsChanged() } }
    }
    private static let baseline: Set<String> = ["hello", "enroll", "ping", "list", "attach", "detach", "input", "resize", "create", "close", "rename"]
    private static let requiredFeatureMessages: [String: Set<String>] = [
        "localhost": ["ports", "tunnel.open", "tunnel.close", "net.open", "net.data", "net.ack", "net.close"],
        "upload": ["upload.begin", "upload.data", "upload.end", "upload.cancel"], "credential": ["credential.ack", "credential.answer", "credential.deny"],
        "github": ["github.read", "github.connect", "github.cancel", "github.disconnect"], "host.control": ["host.status", "host.restart", "host.stop"],
        "devserver": ["dev.status", "dev.start"], "routines": ["routines", "routine.text", "routine.run", "routine.resume", "routine.delete", "routine.pause"],
        "copilot": ["copilot.hello", "copilot.attach", "copilot.detach", "copilot.state", "copilot.sessions", "copilot.pending", "copilot.start", "copilot.cancel", "copilot.stop", "copilot.bye", "copilot.answer", "copilot.say", "copilot.log", "copilot.interactive"],
        "copilot.files": ["copilot.files", "copilot.file.read", "copilot.file.write", "copilot.file.reset", "copilot.memory.delete"], "web": ["web.open"],
        "controls": ["controls.read", "controls.apply"], "usage": ["usage.read"], "send": ["session.send"], "account": ["account.read", "account.switch"],
        "logins": ["logins.read", "logins.signin", "logins.signout"], "devices": ["devices.list", "devices.revoke"], "settings": ["settings.read", "settings.apply"],
        "windows": ["window.result"], "hostwindows": ["window.call", "window.holds", "sessions.mine"],
        "watch": ["browser.watch", "browser.unwatch", "browser.frame.ack", "browser.input", "browser.surfaces", "browser.handover.take", "browser.handover.done"],
        "folders.pick": ["folders.browse"], "files": ["files.list", "files.read"], "git": ["git.status", "git.diff"], "panels": ["panel.read", "panel.act"],
        "browser.profiles": ["browser.profiles", "browser.profile.use", "browser.profile.clear"],
        "browser.control": ["browser.windows", "browser.window.open", "browser.window.go", "browser.window.act", "browser.window.size", "browser.window.bind", "browser.window.shot", "browser.window.steps", "browser.window.pick"],
    ]
}
