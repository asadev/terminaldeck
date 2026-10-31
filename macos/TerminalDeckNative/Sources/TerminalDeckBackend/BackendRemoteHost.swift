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
    public var phoneAccess: BackendINT2PhoneAccessLevel? = nil
    public var rpcContext: NativeRPCContext { .init(caller: .pairedDevice, ownerID: deviceID, capabilities: ["filesystem.read", "git.read", "state.read"]) }
}
public struct BackendRemoteCreateRequest: Sendable {
    public let deviceID: String
    public let cwd: String
    public let provider: String?
    public let cols: Int
    public let rows: Int
    /// The phone's New session choices (iOS batch 1): what the Mac's own New session dialog offers. Shapes only;
    /// the launch path checks each against this Mac's AIs, accounts and agents.
    public var choices = BackendRemoteStartChoices()
}
/// What a phone may choose when it starts a session or a chat, as the Mac's New session dialog offers it: the
/// agent (seat) it runs as, the model, the effort, the permission mode (the chat box's four words), the account,
/// and Chat or Terminal. Every field is optional: an absent one is the Mac's own default.
public struct BackendRemoteStartChoices: Sendable, Equatable {
    public var agent: String?
    public var model: String?
    public var effort: String?
    public var permissionMode: String?
    public var account: String?
    /// `create` only: false asks for a terminal even where the person's remembered choice is Chat.
    public var chat: Bool?
    public init(agent: String? = nil, model: String? = nil, effort: String? = nil, permissionMode: String? = nil,
                account: String? = nil, chat: Bool? = nil) {
        self.agent = agent; self.model = model; self.effort = effort; self.permissionMode = permissionMode
        self.account = account; self.chat = chat
    }
    public init(message: BackendRemoteClientMessage) {
        self.init(agent: message["agent"].string, model: message["model"].string, effort: message["effort"].string,
                  permissionMode: message["permissionMode"].string, account: message["account"].string, chat: message["chat"].bool)
    }
    public var isEmpty: Bool { self == .init() }
    /// The permission words a phone may send: the chat box's own (ask, plan, changes, bypass).
    public static let permissionModes = BackendHOOTSIMPermissionMode.allCases.map(\.rawValue)
}
public struct BackendRemoteHostFeature: Sendable {
    public enum Policy: Equatable, Sendable { case grantedDevice, ownerOnly, windowGrant }
    public let capability: String
    public let messageTypes: Set<String>
    public let policy: Policy
    public let sessionField: String?
    public let additionalAdvertisedCapabilities: Set<String>
    public let handle: @Sendable (BackendRemoteClientMessage, BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage]
    public init(capability: String, messageTypes: Set<String>, policy: Policy = .ownerOnly, sessionField: String? = nil,
                additionalAdvertisedCapabilities: Set<String> = [],
                handle: @escaping @Sendable (BackendRemoteClientMessage, BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage]) {
        self.capability = capability; self.messageTypes = messageTypes; self.policy = policy; self.sessionField = sessionField; self.handle = handle
        self.additionalAdvertisedCapabilities = additionalAdvertisedCapabilities
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
    /// #58: the request being answered. An error frame sent back on its connection carries its
    /// `rid`, so the guest fails that request alone rather than everything it is waiting for.
    struct Answering: Sendable { let connection: UUID; let rid: String }
    @TaskLocal static var answering: Answering?
    /// 29 Oct: the frame being answered, by its place in its connection's arrival order (`take`).
    struct Ticket: Sendable { let connection: UUID; let number: Int }
    @TaskLocal static var ticket: Ticket?

    /// 29 Oct 2026 (the phones' opening screen: the session list, pictures, each project's Tasks and the browser tabs
    /// were answered one after another, ~0.6 s on every launch): the reads a phone sends together are answered at the
    /// same time. Only these, which change nothing; every other frame waits for everything before it and holds back
    /// everything after it, exactly as before (a write after a read in the same chat, an attach and then its output).
    /// Not file, folder or git reads (Reviewer, 29 Oct): every reply carries its path, but older phones apply a file
    /// listing, a file page and a git state as "the newest wins", so two of them must keep their order.
    public static let readsAlongside: Set<String> = ["list", "ping", "panel.read", "pictures", "picture", "browser.windows",
        "usage.read", "account.read", "logins.read", "settings.read", "host.status", "devices.list", "github.read",
        // 31 Oct: the phone's device list, a picture's ack and a still for Annotate (BackendPhoneDevices).
        "sims.list", "sims.ack", "sims.shot"]
    /// At most this many reads of one connection run at once; one more waits for them, as a write does.
    public static let mostReadsAlongside = 8
    /// One connection's frames in arrival order: the reads running alongside each other, the last frame that runs
    /// alone, and the refusals without a rid that wait until every earlier frame has finished (a phone matches such a
    /// refusal to its oldest waiting read, so it must not overtake an earlier answer).
    struct Pipeline: Sendable {
        var next = 0
        var reads: [Int: Task<Void, Never>] = [:]
        var alone: Task<Void, Never>?
        var finished: Set<Int> = []
        /// Every frame numbered below this has finished.
        var settled = 0
        var held: [Int: [String]] = [:]
    }
    static func stamped(_ message: BackendRemoteServerMessage, to connection: UUID) -> BackendRemoteServerMessage {
        guard message.kind == .error, let answering, answering.connection == connection, message.value["rid"] == .missing,
              let fields = message.value.fields?.filter({ $0.key != "t" }) else { return message }
        return (try? BackendRemoteServerMessage(.error, fields: fields + [.init("rid", .string(answering.rid))])) ?? message
    }
    public let trust: BackendRemoteTrustStore
    public let manager: BackendPTYManager
    /// Hellos per device or pairing address, limited before the credential check (BackendRemoteReconnectThrottle).
    private var reconnects = BackendRemoteReconnectThrottle()
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
    /// 27 Oct: sessions some remote viewer has given a size to, so a viewer leaving is told to the session too.
    private var sizedSessions: Set<String> = []
    private var claims: UInt64 = 0
    private var sizeWatch: NativeRPCSubscription?
    /// What a phone says it can do: show a session it does not size as a picture of the owner's screen, and
    /// follow `size` frames (27 Oct; the Mac advertises the same word back).
    public static let pictureCapability = "terminal.picture"
    /// 28 Oct: what a phone says when it follows the session to the device where it was chosen last: it opens a
    /// session with its size (taking it), sends `take` for "Move back here", reports its size with `resize` without
    /// taking it, and shows "Open on <name>" while another device has it (`size` frames, with the owner's `name`).
    public static let handoffCapability = "terminal.handoff"
    /// 28 Oct: when each session last printed (host clock), for `settle`.
    private var lastOutput: [String: Double] = [:]
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
    private var outputCheckEpoch: UInt64 = 0
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
        /// PHONE2: when this connection last typed into each session (host clock, ms).
        var lastInput: [String: Double] = [:]
        /// #192: when each attached session's output was last cleared for this connection (host clock, ms).
        var outputChecked: [String: Double] = [:]
        /// 27 Oct: the size this connection asked for each attached session (attach and resize), when it asked
        /// (`claimOrder`, for "the latest ask"), and the last `size` frame it was sent per session.
        var viewSizes: [String: BackendTerminalSize] = [:]
        var claimOrder: [String: UInt64] = [:]
        var sentSize: [String: NativeRPCValue] = [:]
        /// 29 Oct: this connection's frames, answered alongside each other where they may be (`take`).
        var pipeline = Pipeline()
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
        guard BackendRemoteProtocol.capabilities.contains(feature.capability),
              feature.additionalAdvertisedCapabilities.isSubset(of: BackendRemoteProtocol.capabilities),
              !feature.messageTypes.isEmpty else { throw NativeRPCError.invalidArguments("The remote feature has no known capability or messages") }
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
            guard BackendRemoteProtocol.capabilities.contains(feature.capability),
                  feature.additionalAdvertisedCapabilities.isSubset(of: BackendRemoteProtocol.capabilities),
                  !feature.messageTypes.isEmpty else { throw NativeRPCError.malformed("Unknown remote feature capability") }
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
    public func panelSessionIDs(_ previous: BackendRemoteHostContext) async throws -> Set<String> {
        let current = try await refreshedContext(previous)
        try await trust.requirePhoneAccess(current.deviceID, message: "list")
        return Set(try await sessions(current).compactMap { $0["id"].string })
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
            guard BackendRemoteProtocol.capabilities.contains(feature.capability),
                  feature.additionalAdvertisedCapabilities.isSubset(of: BackendRemoteProtocol.capabilities),
                  !feature.messageTypes.isEmpty else { throw NativeRPCError.malformed("Unknown remote feature capability") }
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
        await phoneAccessChanged(id)
        for connection in live.keys.filter({ live[$0]?.device?.id == id }) { await disconnect(connection, code: 1008, reason: "This device is no longer approved.") }
    }
    public func remoteServeFoldersChanged(_ id: String) async {
        for connection in live.keys.filter({ live[$0]?.device?.id == id }) {
            guard let context = try? await context(connection) else { continue }
            try? await send(connection, .init(.folders, fields: [.init("folders", .array(context.reach.folders.map(NativeRPCValue.string)))]))
        }
        await refreshGrants()
    }
    public func phoneAccessChanged(_ deviceID: String) async {
        forgetOutputChecks(device: deviceID)
        for id in Array(live.keys) where live[id]?.device?.id == deviceID {
            try? await sendPhoneAccess(id, deviceID: deviceID)
            guard await trust.phoneAccess(deviceID) == nil else { continue }
            live[id]?.attached.removeAll(); live[id]?.attachmentBoundaries.removeAll()
            live[id]?.pendingAttachmentEvents.removeAll()
        }
        announce()
    }
    private func sendPhoneAccess(_ id: UUID, deviceID: String) async throws {
        guard live[id]?.capabilities.contains("device.access") == true else { return }
        let level = await trust.phoneAccess(deviceID)
        try await send(id, .init(.deviceAccess, fields: [.init("level", level.map { .string($0.wireLevel) } ?? .null)]))
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
        if case .data(let id, _) = item.event { lastOutput[id] = clock() }
        if case .removed(let id, _) = item.event { lastOutput[id] = nil }
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
            guard try await outputAllowed(session, connectionID: connectionID, recheck: !event.isOutput) else {
                live[connectionID]?.attached.remove(session); live[connectionID]?.attachmentBoundaries[session] = nil; return
            }
            switch event {
            case .data(_, let text): for chunk in BackendRemoteProtocol.chunkOutput(text) { try await send(connectionID, .init(.output, fields: [.init("id", .string(session)), .init("data", .string(chunk))])) }
            case .status(_, let value): try await send(connectionID, .init(.status, fields: statusFields(session, value)))
            case .exit(_, let code):
                try await send(connectionID, .init(.exit, fields: [.init("id", .string(session)), .init("exitCode", .number(Double(code)))]))
                live[connectionID]?.attached.remove(session); live[connectionID]?.attachmentBoundaries[session] = nil
            case .removed: break
            }
        } catch { await disconnect(connectionID, code: 1011, reason: "Session output could not be delivered.") }
    }
    /// The session as it is now, then its live output: `attached`, who has its size (`size`), its screen as history
    /// (flagged `replay`), its `status`. For an attach, and again for a device that takes the session back (`take`):
    /// a device's terminal starts clean from `attached` each time.
    private func deliverSession(_ id: UUID, _ sessionID: String, from ptySource: any BackendRemoteServePTYSource) async throws {
        // No await from the owner-queue snapshot to installing this peer's
        // watermark. Earlier queued events are excluded from its replay.
        guard let snapshot = ptySource.snapshot(sessionID), live[id] != nil else {
            live[id]?.viewSizes[sessionID] = nil; _ = try? pushViewerSizes(sessionID)
            await unknown(id, sessionID); return
        }
        live[id]?.attached.insert(sessionID); live[id]?.outputChecked[sessionID] = nil
        live[id]?.attachmentBoundaries[sessionID] = .init(sequence: snapshot.sequence, ready: false)
        live[id]?.pendingAttachmentEvents[sessionID] = []
        do {
            try await send(id, .init(.attached, fields: [.init("id", .string(sessionID))]))
            // Before the snapshot: who has the size (a phone that shows pictures sizes its picture first).
            try await sendSize(id, sessionID)
            // Flagged as history (27 Oct): the phone's first unflagged frame, or the `status` below, ends its hold.
            for frame in try Self.historyFrames(sessionID, snapshot.replay) { try await send(id, frame) }
            let current = snapshot.status
            try await send(id, .init(.status, fields: statusFields(sessionID, current)))
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
    }
    /// 28 Oct: after a device took the session at a new size, wait for the program to finish redrawing before its
    /// screen is read for that device: until its output has been quiet for 120 ms, never longer than 600 ms.
    private func settle(_ session: String) async {
        let settle = TerminalSettle(start: clock())
        while let wake = settle.next(now: clock(), lastOutput: lastOutput[session]) {
            try? await self.sleep(max(1, Int((wake - clock()).rounded(.up))))
        }
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
    /// One frame, answered: `take` and then its answer.
    public func receive(_ id: UUID, text: String) async {
        await take(id, text: text)?.answered.value
    }
    /// The next frame of a connection, taken in arrival order. It returns once the frame is scheduled: a read in
    /// `readsAlongside` runs alongside the reads before it (`alongside`, and the caller may read the next frame at
    /// once); any other frame runs after everything before it, and the caller waits for `answered`, as it always did.
    @discardableResult
    public func take(_ id: UUID, text: String) -> (answered: Task<Void, Never>, alongside: Bool)? {
        guard var row = live[id] else { return nil }
        let parsed = BackendRemoteProtocol.parseClientMessage(text)
        var alongside = false
        if case .message(let message) = parsed { alongside = Self.readsAlongside.contains(message.type) }
        if row.pipeline.reads.count >= Self.mostReadsAlongside { alongside = false }
        let number = row.pipeline.next
        row.pipeline.next += 1
        let earlier = (alongside ? [] : Array(row.pipeline.reads.values)) + [row.pipeline.alone].compactMap { $0 }
        let task = Task { [weak self] in
            for frame in earlier { await frame.value }
            guard let self, !Task.isCancelled else { return }
            await Self.$ticket.withValue(Ticket(connection: id, number: number)) { await self.answer(id, parsed) }
            await self.finished(id, number)
        }
        if alongside { row.pipeline.reads[number] = task } else { row.pipeline.alone = task; row.pipeline.reads = [:] }
        live[id] = row
        return (task, alongside)
    }
    /// A frame is answered: refusals without a rid that waited for it (and for every frame before theirs) go out now.
    private func finished(_ id: UUID, _ number: Int) async {
        guard var row = live[id] else { return }
        row.pipeline.reads[number] = nil
        row.pipeline.finished.insert(number)
        var release: [String] = []
        while row.pipeline.finished.remove(row.pipeline.settled) != nil {
            row.pipeline.settled += 1
            release += row.pipeline.held.removeValue(forKey: row.pipeline.settled) ?? []
        }
        live[id] = row
        for text in release { try? await row.writer.send(text) }
    }
    private func answer(_ id: UUID, _ parsed: BackendRemoteClientParse) async {
        guard live[id] != nil else { return }
        switch parsed {
        case .refused(let failure): await refuse(id, code: failure.code, message: failure.reason, close: failure.code == "too-large" ? 1009 : 1002)
        case .message(let message):
            await Self.$answering.withValue(message["rid"].string.map { Answering(connection: id, rid: $0) }) {
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
        do { try await trust.requirePhoneAccess(context.deviceID, message: message.type, panel: message["panel"].string) }
        catch { await refuse(id, code: "unauthorized", message: "This device's current host access does not permit that action."); return }
        switch message.type {
        case "list": try await sendSessions(id, context: context)
        case "attach":
            let sessionID = message["id"].string!
            guard try await visible(sessionID, context: context) else { await unknown(id, sessionID); return }
            guard let ptySource, serveLease != nil else { await unavailable(id, "The atomic native PTY replay source is unavailable."); return }
            // Opening the session on this device chooses it (Asad, 28 Oct: "As soon as I click on the session in my
            // phone's side panel, it automatically comes to my phone"): with a size in the attach, the device owns the
            // session's size from now on, and the screen it is sent below is the program's redraw at that size.
            // `keep`: a phone coming back after its link dropped, to a session it had; it takes it back only if nobody
            // chose it since. A phone that shows pictures (27 Oct) attaches without a size and never takes it.
            watchSizes()
            if let cols = message["cols"].number, let rows = message["rows"].number {
                let size = BackendTerminalSize(cols: Int(cols), rows: Int(rows))
                claim(id, sessionID, size)
                if try pushViewerSizes(sessionID, joining: id, user: id, keep: message["keep"].bool == true) {
                    await settle(sessionID)
                    // Another device leaving meanwhile forgets the sizes of sessions not yet attached: asked again.
                    claim(id, sessionID, size)
                }
            }
            try await deliverSession(id, sessionID, from: ptySource)
        case "detach":
            let session = message["id"].string!
            live[id]?.attached.remove(session)
            live[id]?.attachmentBoundaries[session] = nil; live[id]?.pendingAttachmentEvents[session] = nil
            signalPTYWaiters()
            try await send(id, .init(.detached, fields: [.init("id", .string(session))])); announce()
        case "take":
            // "Move back here" on a device that was showing the session when another one took it (28 Oct): it owns
            // the size again, and is sent the session afresh once the program has redrawn for it.
            let session = message["id"].string!
            guard live[id]?.attached.contains(session) == true else { await unknown(id, session); return }
            guard try await visible(session, context: context) else { await unknown(id, session); return }
            guard let ptySource, serveLease != nil else { await unavailable(id, "The atomic native PTY replay source is unavailable."); return }
            claim(id, session, .init(cols: Int(message["cols"].number!), rows: Int(message["rows"].number!)))
            if try pushViewerSizes(session, user: id) { await settle(session) }
            try await deliverSession(id, session, from: ptySource)
        case "input", "resize":
            let session = message["id"].string!
            guard live[id]?.attached.contains(session) == true else { await unknown(id, session); return }
            guard try await visible(session, context: context) else { await refuse(id, code: "unauthorized", message: BackendRemoteServeSessionPolicy.unsharedMessage); return }
            try await trust.requirePhoneAccess(context.deviceID, message: message.type)
            if message.type == "input" { live[id]?.lastInput[session] = clock() } // PHONE2
            if message.type == "resize" {
                claim(id, session, .init(cols: Int(message["cols"].number!), rows: Int(message["rows"].number!)))
                // A phone that knows the 28 Oct rule only reports its size (turning, its keyboard): it sizes the
                // program while it owns it. An older viewer meant every resize as asking for the size, as before.
                try pushViewerSizes(session, user: live[id]?.capabilities.contains(Self.handoffCapability) == true ? nil : id)
            } else if let ptySource { try ptySource.write(session, data: message["data"].string!) }
            else { try manager.write(session, data: message["data"].string!) }
        case "create":
            // A login or a permission mode chosen for a new session is Full control, as answering an approval is.
            if !BackendPhoneChats.mayChooseLoginAndMode(BackendRemoteStartChoices(message: message), context) {
                await refuse(id, code: "unauthorized", message: BackendPhoneChats.fullControlNeeded); return
            }
            if let lease = serveLease {
                try await lease.suppliers.requireReady()
                guard let creator = lease.suppliers.create else { await unavailable(id, "This host cannot start a session."); return }
                let outcome = await creator.create(.init(message: message, deviceID: context.deviceID))
                if let session = outcome.session {
                    guard live[id]?.device?.id == context.deviceID, await trust.isApproved(context.deviceID), await trust.canReachFolder(context.deviceID, folder: session.cwd),
                          (try? await trust.requirePhoneAccess(context.deviceID, message: "create")) != nil else {
                        // #486: the device hears why, as on the path below, instead of waiting for its own timeout.
                        ptySource?.kill(session.id)
                        throw BackendRemoteTrustFailure.denied("This device is no longer approved for that folder.")
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
            guard live[id]?.device?.id == context.deviceID, await trust.isApproved(context.deviceID), await trust.canReachFolder(context.deviceID, folder: session.cwd),
                  (try? await trust.requirePhoneAccess(context.deviceID, message: "create")) != nil else {
                manager.kill(session.id)
                throw BackendRemoteTrustFailure.denied("This device is no longer approved for that folder.")
            }
            _ = try? await trust.remoteServeIncludeStartedSession(context.deviceID, sessionID: session.id)
            try await send(id, BackendRemoteServeSessionCreate.Outcome.created(session).message())
            try await broadcastSessions()
        case "close", "rename":
            let session = message["id"].string!
            guard try await visible(session, context: context) else { await unknown(id, session); return }
            try await trust.requirePhoneAccess(context.deviceID, message: message.type)
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
            try await trust.requirePhoneAccess(context.deviceID, message: message.type, panel: message["panel"].string)
            for answer in try await feature.handle(message, context) { try await send(id, answer) }
        }
    }
    private func hello(_ id: UUID, _ message: BackendRemoteClientMessage) async throws {
        guard let row = live[id], row.device == nil else { throw BackendRemoteTrustFailure.denied("This connection already said hello.") }
        guard message["protocol"].number == 1 else { await refuse(id, code: "version", message: "This client and host speak different protocol versions. Update whichever is older.", close: 1008); return }
        let token = message["token"].string!, name = message["device"]["name"].string!
        // Before any scrypt: a device (or pairing address) reconnecting too often is told to slow down and waits.
        if let wait = reconnects.admit(BackendRemoteReconnectThrottle.key(token: token, address: row.wire.address), now: Date().timeIntervalSince1970) {
            await refuse(id, code: "unavailable", message: BackendRemoteReconnectThrottle.slowDown(wait), close: 1013)
            return
        }
        if !token.contains(".") {
            let paired = try await trust.redeem(token, name: name, address: row.wire.address, publicKey: row.wire.peerPublicKey,
                                                platform: message["device"]["platform"].string)
            await pairingSpent?()
            try await send(id, .init(.welcome, fields: [.init("protocol", .number(1)), .init("deviceId", .string(paired.device.id)), .init("deviceName", .string(paired.device.name)),
                .init("token", .string(paired.credential)), .init("sessions", .array([])), .init("capabilities", .array([]))]))
            await refuse(id, code: "unauthorized", message: "Paired. Approve this device in the app on this Mac, then reconnect.", close: 1008)
            return
        }
        let device = try await trust.verify(token, address: row.wire.address, peerKey: row.wire.peerPublicKey)
        guard live[id] != nil else { return }
        live[id]?.device = device; live[id]?.platform = message["device"]["platform"].string ?? "unknown"
        await trust.notePlatform(device.id, message["device"]["platform"].string)
        live[id]?.capabilities = Set(message["capabilities"].elements?.compactMap(\.string) ?? [])
        live[id]?.timer?.cancel(); live[id]?.timer = nil
        guard let context = try await context(id) else { return }
        var fields: [NativeRPCValue.Field] = [.init("protocol", .number(1)), .init("deviceId", .string(device.id)), .init("deviceName", .string(device.name)),
            .init("token", .null), .init("sessions", .array(context.phoneAccess == nil || context.phoneAccess == .hoot ? [] : try await sessions(context))), .init("capabilities", .array(capabilities(context).map(NativeRPCValue.string))),
            .init("hostPlatform", .string("darwin")), .init("hostName", .string(self.name)), .init("appVersion", .string(appVersion)), .init("hostKind", .string("desktop"))]
        if serveLease?.suppliers.create != nil || serveLease == nil && operations.create != nil { fields.append(.init("folders", .array(context.reach.folders.map(NativeRPCValue.string)))) }
        if let link = await Self.hootWelcomeLink(context, served: features["hoot.hello"] != nil, trust: trust) { fields.append(.init("hoot", link)) } // PHONE2
        try await send(id, .init(.welcome, fields: fields)); announce()
        try await sendPhoneAccess(id, deviceID: device.id)
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
        guard context.phoneAccess != nil else { return context.claimedCapabilities.contains("device.access") ? ["device.access"] : [] }
        // Hoot only: the phone is offered Hoot and its access frame, nothing else.
        if context.phoneAccess == .hoot {
            var hoot: Set<String> = context.claimedCapabilities.contains("device.access") ? ["device.access"] : []
            if context.kind == .mine, let feature = features["hoot.hello"] {
                hoot.insert(feature.capability)
                hoot.formUnion(feature.additionalAdvertisedCapabilities.intersection(context.claimedCapabilities))
            }
            return BackendRemoteProtocol.advertisedCapabilities(implemented: hoot)
        }
        var enabled: Set<String> = []
        if context.claimedCapabilities.contains("device.access") { enabled.insert("device.access") }
        if context.claimedCapabilities.contains(Self.pictureCapability) { enabled.insert(Self.pictureCapability) }
        if context.claimedCapabilities.contains(Self.handoffCapability) { enabled.insert(Self.handoffCapability) }
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
                enabled.formUnion(feature.additionalAdvertisedCapabilities.intersection(context.claimedCapabilities))
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
            peerPublicKey: row.wire.peerPublicKey, claimedCapabilities: row.capabilities, reach: effective,
            phoneAccess: await trust.phoneAccess(device.id))
    }
    /// #192: a session's output is checked once per connection, then again only after grants,
    /// folders, sessions or phone access change, or a few seconds on; never per output piece.
    private func outputAllowed(_ session: String, connectionID: UUID, recheck: Bool) async throws -> Bool {
        let now = clock(), epoch = outputCheckEpoch
        if !recheck, let checked = live[connectionID]?.outputChecked[session], now - checked < Self.outputRecheckMS,
           !(serveLease.map { $0.suppliers.isHidden(session) } ?? BackendRemoteServeSessionHidden.shared.contains(session)) { return true }
        guard let context = try await context(connectionID), try await visible(session, context: context) else {
            live[connectionID]?.outputChecked[session] = nil; return false
        }
        // A change that landed during the check is not overwritten by its older answer.
        if epoch == outputCheckEpoch { live[connectionID]?.outputChecked[session] = now }
        return true
    }
    static let outputRecheckMS: Double = 5_000
    private func forgetOutputChecks(device: String? = nil) {
        outputCheckEpoch &+= 1
        for id in Array(live.keys) where device == nil || live[id]?.device?.id == device { live[id]?.outputChecked.removeAll() }
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
        let seen = await ledgerSeen()
        for session in sessionSource where try await visible(session.id, context: context) { result.append(sessionValue(session, seen: seen[session.id])) }
        return result
    }
    /// When this Mac last saw each remembered session typed into or start a turn (its ledger's `lastSeenAt`, kept
    /// across app restarts).
    private func ledgerSeen() async -> [String: Double] {
        guard let entries = try? await state.ledgerEntries() else { return [:] }
        var seen: [String: Double] = [:]
        for entry in entries { if let at = entry.saved["lastSeenAt"].number { seen[entry.id] = at } }
        return seen
    }
    /// 27 Oct (the phone's Overview "Recent", the last 24 hours): when the session last did something, in ms since
    /// 1970, as the phone reads it (`WireCodec.lastActivity`). The latest real moment known: its output or typing
    /// since this app started, a chat's last turn, what the ledger kept from before, or when it started. Never the
    /// moment the row is written.
    static func lastActivityAt(_ meta: BackendSessionMeta, live: Double?, seen: Double?) -> Double {
        max(live ?? 0, seen ?? 0, meta.createdAt)
    }
    private func statusFields(_ session: String, _ value: BackendSessionStatus) -> [NativeRPCValue.Field] {
        var fields: [NativeRPCValue.Field] = [.init("id", .string(session)), .init("status", .string(value.rawValue))]
        if let at = manager.lastActivity(session) { fields.append(.init("lastActivityAt", .number(at))) }
        return fields
    }
    /// A snapshot's history as `output` frames flagged `replay`.
    static func historyFrames(_ session: String, _ text: String) throws -> [BackendRemoteServerMessage] {
        try BackendRemoteProtocol.chunkOutput(text).map {
            try .init(.output, fields: [.init("id", .string(session)), .init("data", .string($0)), .init("replay", .bool(true))])
        }
    }
    private func sessionValue(_ meta: BackendSessionMeta, seen: Double? = nil) -> NativeRPCValue {
        // The status the session's own events last gave, never a full snapshot of it (that carries its whole raw
        // history: megabytes per session, for every list sent to a phone).
        let state = meta.exitCode == nil ? status[meta.id] ?? manager.knownStatus(meta.id) ?? manager.screen(meta.id).map { BackendSessionClassifier.classify(viewport: $0) } ?? .idle : .exited
        let row = NativeRPCValue.object([.init("id", .string(meta.id)), .init("title", .string(meta.title)), .init("cwd", .string(meta.cwd)), .init("provider", .string(meta.provider)),
            .init("status", .string(state.rawValue)), .init("exitCode", meta.exitCode.map { .number(Double($0)) } ?? .null),
            .init("lastActivityAt", .number(Self.lastActivityAt(meta, live: manager.lastActivity(meta.id), seen: seen)))])
        // Additive: a phone that knows chats lists this one with them; an older phone ignores the field.
        return meta.chat == true ? row.setting("chat", .bool(true)) : row
    }
    public func noteSessionEvent(_ event: BackendSessionEvent) async {
        if serveLease != nil {
            // The queue-owned sequenced path is the only terminal fanout.
            // Lifecycle waits for it before pruning exit/removal grants; output and
            // status never wait for a phone to catch up (#425).
            switch event {
            case .exit, .removed: await waitForPTYBoundary()
            case .data, .status: break
            }
            return
        }
        if case .status(let session, let current) = event { status[session] = current }
        for id in Array(live.keys) {
            let session: String
            switch event { case .data(let id, _), .exit(let id, _), .status(let id, _), .removed(let id, _): session = id }
            guard live[id]?.attached.contains(session) == true else { continue }
            if case .removed = event {
                guard (try? await context(id)) != nil else { continue }
                live[id]?.attached.remove(session); try? await send(id, .init(.detached, fields: [.init("id", .string(session))])); continue
            }
            guard (try? await outputAllowed(session, connectionID: id, recheck: !event.isOutput)) == true else { live[id]?.attached.remove(session); continue }
            do {
                switch event {
                case .data(_, let text): for chunk in BackendRemoteProtocol.chunkOutput(text) { try await send(id, .init(.output, fields: [.init("id", .string(session)), .init("data", .string(chunk))])) }
                case .status(_, let current): try await send(id, .init(.status, fields: statusFields(session, current)))
                case .exit(_, let code): try await send(id, .init(.exit, fields: [.init("id", .string(session)), .init("exitCode", .number(Double(code)))]))
                case .removed: break
                }
            } catch { await disconnect(id, code: 1011, reason: "Session output could not be delivered.") }
        }
        if case .exit = event { try? await broadcastSessions() }
        if case .removed = event { try? await broadcastSessions() }
    }
    public func sessionsChanged() async { forgetOutputChecks(); try? await broadcastSessions() }
    public func refreshGrants() async {
        forgetOutputChecks()
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
        guard let row = live[id] else { throw NativeRPCError(code: "unavailable", message: "The remote connection is closed.") }
        let stamped = Self.stamped(message, to: id), text = try BackendRemoteProtocol.serialize(stamped)
        // A refusal without a rid goes out only after every frame before its own has been answered (29 Oct): a phone
        // matches it to its oldest waiting read, so it never overtakes an earlier read's answer.
        if stamped.kind == .error, stamped.value["rid"] == .missing, let ticket = Self.ticket, ticket.connection == id,
           ticket.number > row.pipeline.settled {
            live[id]?.pipeline.held[ticket.number, default: []].append(text)
            return
        }
        try await row.writer.send(text)
    }
    private func unknown(_ id: UUID, _ session: String) async { await refuse(id, code: "unknown-session", message: BackendRemoteServeSessionPolicy.noSuchSession(session)) }
    private func unavailable(_ id: UUID, _ message: String) async { await refuse(id, code: "unavailable", message: message) }
    private func refuse(_ id: UUID, code: String, message: String, close: Int? = nil) async {
        if let close {
            // The connection ends with it: said at once, never held for earlier frames (29 Oct).
            if let writer = live[id]?.writer, let error = try? BackendRemoteServerMessage.error(code: code, message: message),
               let text = try? BackendRemoteProtocol.serialize(Self.stamped(error, to: id)) { try? await writer.send(text) }
            await disconnect(id, code: close, reason: message)
            return
        }
        try? await send(id, .error(code: code, message: message))
    }
    private func disconnect(_ id: UUID, code: Int, reason: String) async {
        await finishConnection(id, closeWire: (code, reason))
    }
    private func finishConnection(_ id: UUID, closeWire: (Int, String)?) async {
        guard let row = live.removeValue(forKey: id) else { return }
        signalPTYWaiters()
        // Reads still running for it stop (29 Oct, Reviewer): nobody is left to answer.
        for read in row.pipeline.reads.values { read.cancel() }
        row.pipeline.alone?.cancel()
        row.timer?.cancel(); await row.writer.close()
        // Remove first: transport close may synchronously notify closed again.
        for callback in Array(connectionClosedHandlers.values) { await callback(id) }
        if let device = row.device, !live.values.contains(where: { $0.device?.id == device.id }) {
            await deviceDisconnected?(device.id); await serveLease?.hooks.lastDeviceDisconnected(device.id)
        }
        if let closeWire { await row.wire.close(closeWire.0, closeWire.1) }
        announce()
    }
    /// The size a connection asked for a session it is attached to (attach, take, resize), and when (27 Oct).
    private func claim(_ connection: UUID, _ session: String, _ size: BackendTerminalSize) {
        claims &+= 1
        live[connection]?.viewSizes[session] = size; live[connection]?.claimOrder[session] = claims
    }
    /// Every device still attached to the session, with its size, to the session's owner logic (27 Oct). `joining`:
    /// a connection whose attach is under way, not yet in `attached`. `user`: the connection whose device just chose
    /// the session (28 Oct); `keep`: only if nobody chose it since. True when the program was given a new size.
    @discardableResult
    private func pushViewerSizes(_ session: String, joining: UUID? = nil, user: UUID? = nil, keep: Bool = false) throws -> Bool {
        var asked: [(order: UInt64, claim: BackendTerminalViewers.Claim)] = []
        for (connection, row) in live where row.attached.contains(session) || connection == joining {
            if let size = row.viewSizes[session], let device = row.device {
                asked.append((row.claimOrder[session] ?? 0, .init(viewer: device.id, size: size, name: device.name, platform: row.platform)))
            }
        }
        let chooser = user.flatMap { live[$0]?.device?.id }
        guard !asked.isEmpty || sizedSessions.contains(session) else { return false }
        if asked.isEmpty { sizedSessions.remove(session) } else { sizedSessions.insert(session) }
        let ordered = asked.sorted { $0.order < $1.order }.map(\.claim)
        if let ptySource { return try ptySource.setViewerSizes(session, ordered, user: chooser, keep: keep) }
        return try manager.setViewerSizes(session, ordered, user: chooser, keep: keep)
    }
    /// The session's owner logic says when a size or owner changes (this Mac choosing it included); every attached
    /// device that follows `size` frames is told.
    private func watchSizes() {
        guard sizeWatch == nil else { return }
        let source: any BackendRemoteServePTYSource = ptySource ?? (manager as any BackendRemoteServePTYSource)
        sizeWatch = source.observeSizes { [weak self] session in
            Task { await self?.sizesChanged(session) }
        }
    }
    private func sizesChanged(_ session: String) async {
        for id in Array(live.keys) where live[id]?.attached.contains(session) == true { try? await sendSize(id, session) }
    }
    /// `size {id, cols, rows, owner, name}` to a device that follows them, when it changed for that device. Owner:
    /// "you" (this device has it: an ordinary terminal at its own size), "mac" (this Mac has it), "phone" (another
    /// device has it), "none" (this Mac has it and has not said a size: an older phone sends `resize` to take it).
    /// `name`: how the owner is called on the other devices' panels ("Open on Asad's Mac mini"); `viewer`: the
    /// device being told; `hostName`: this Mac's name.
    static func sizeFields(_ session: String, state: BackendTerminalViewers?, viewer: String, hostName: String) -> [NativeRPCValue.Field] {
        let owner: String, name: String
        switch state?.owner ?? .mac {
        case .mac: owner = state?.applied == nil && state?.mac == nil ? "none" : "mac"; name = hostName
        case .viewer(let device): owner = device == viewer ? "you" : "phone"; name = state?.ownerName ?? ""
        }
        let size = state?.applied ?? state?.wanted
        return [.init("id", .string(session)),
                .init("cols", size.map { .number(Double($0.cols)) } ?? .null), .init("rows", size.map { .number(Double($0.rows)) } ?? .null),
                .init("owner", .string(owner)), .init("name", .string(name))]
    }
    private func sendSize(_ id: UUID, _ session: String) async throws {
        guard let row = live[id], !row.capabilities.isDisjoint(with: [Self.pictureCapability, Self.handoffCapability]) else { return }
        let fields = Self.sizeFields(session, state: (ptySource ?? (manager as any BackendRemoteServePTYSource)).viewerSizes(session),
                                     viewer: row.device?.id ?? id.uuidString, hostName: name)
        let frame = NativeRPCValue.object(fields)
        guard live[id]?.sentSize[session] != frame else { return }
        live[id]?.sentSize[session] = frame
        try await send(id, .init(.terminalSize, fields: fields))
    }
    private func announce() {
        // Attachments change only where this is said (attach, detach, a closed connection, access taken away):
        // a viewer that left stops holding its session to its size.
        for id in Array(live.keys) {
            for session in live[id]?.viewSizes.keys.filter({ live[id]?.attached.contains($0) != true }) ?? [] {
                live[id]?.viewSizes[session] = nil; live[id]?.claimOrder[session] = nil
            }
            for session in live[id]?.sentSize.keys.filter({ live[id]?.attached.contains($0) != true }) ?? [] { live[id]?.sentSize[session] = nil }
        }
        for session in sizedSessions { _ = try? pushViewerSizes(session) }
        onConnections?(connections())
        if let hooks = serveLease?.hooks { Task { await hooks.connectionsChanged() } }
    }
    /// PHONE2: the welcome's Hoot link (remote/server.ts welcome `copilot`). The phone draws its Hoot tab,
    /// and says `copilot.hello`, only when the welcome carries this object (CopilotWire.copilotConnection);
    /// without it a phone with full control never showed Hoot. Written only where Hoot is served here and
    /// only for an approved device of the owner's own, as the TS desktop did; the grant follows phone access.
    static func hootWelcomeLink(_ context: BackendRemoteHostContext, served: Bool, trust: BackendRemoteTrustStore) async -> NativeRPCValue? {
        guard served, context.kind == .mine, await BackendCopilotRemoteAccess(trust: trust).linked(context.deviceID) else { return nil }
        let level = context.phoneAccess
        return .object([.init("linked", .bool(true)), .init("open", .bool(false)),
            .init("grant", .object([.init("read", .bool(level != nil)), .init("act", .bool(level != nil && level != .look)),
                .init("alter", .bool(level == .full))]))])
    }
    /// PHONE2: how recently a phone must have typed into the session for its links to go to it.
    public static let linkActiveWindowMilliseconds: Double = 30 * 60 * 1000
    /**
     * PHONE2: a link a session asked to open goes to the phone he is driving that session from.
     *
     * The phone is "where he is" when it is attached to the session, claimed `link.open` in its
     * hello (older phones never did, so they are never sent the frame and the Mac browser opens
     * it as before), may still type into that session, and typed into it more recently than
     * anyone touched this Mac (`macLastInput`, ms on the host clock; nil when unknown) and within
     * the last half hour. Returns the phone's name when the frame went out, nil otherwise.
     */
    public func openLinkOnPhone(_ url: String, sessionID: String, macLastInput: Double?) async -> String? {
        let rows = live.compactMap { id, row -> LinkCandidate? in
            row.device == nil ? nil : LinkCandidate(id: id, claims: row.capabilities, attached: row.attached, typed: row.lastInput[sessionID])
        }
        for id in Self.linkTargets(rows, sessionID: sessionID, now: clock(), macLastInput: macLastInput) {
            guard let context = try? await context(id), (try? await visible(sessionID, context: context)) == true,
                  (try? await trust.requirePhoneAccess(context.deviceID, message: "input")) != nil,
                  let frame = try? BackendRemoteServerMessage(.linkOpen, fields: [.init("url", .string(url)), .init("session", .string(sessionID))]),
                  (try? await sendToConnection(id, message: frame)) != nil else { continue }
            return live[id]?.device?.name ?? "your phone"
        }
        return nil
    }
    /// PHONE2: one authenticated connection, as the link routing reads it.
    struct LinkCandidate: Sendable { let id: UUID; let claims: Set<String>; let attached: Set<String>; let typed: Double? }
    /// PHONE2: which connections may open a session's link, most recently typing first.
    static func linkTargets(_ rows: [LinkCandidate], sessionID: String, now: Double, macLastInput: Double?) -> [UUID] {
        rows.compactMap { row -> (UUID, Double)? in
            guard row.claims.contains("link.open"), row.attached.contains(sessionID), let typed = row.typed,
                  now - typed <= linkActiveWindowMilliseconds, macLastInput.map({ typed > $0 }) ?? true else { return nil }
            return (row.id, typed)
        }.sorted { $0.1 > $1.1 }.map { $0.0 }
    }
    private static let baseline: Set<String> = ["hello", "enroll", "ping", "list", "attach", "detach", "input", "resize", "take", "create", "close", "rename"]
    private static let requiredFeatureMessages: [String: Set<String>] = [
        "localhost": ["ports", "tunnel.open", "tunnel.close", "net.open", "net.data", "net.ack", "net.close"],
        "upload": ["upload.begin", "upload.data", "upload.end", "upload.cancel"], "credential": ["credential.ack", "credential.answer", "credential.deny"],
        "github": ["github.read", "github.connect", "github.cancel", "github.disconnect"], "host.control": ["host.status", "host.restart", "host.stop"],
        "devserver": ["dev.status", "dev.start"], "routines": ["routines", "routine.text", "routine.run", "routine.resume", "routine.delete", "routine.pause"],
        "hoot": ["hoot.hello", "hoot.attach", "hoot.detach", "hoot.state", "hoot.sessions", "hoot.pending", "hoot.start", "hoot.cancel", "hoot.stop", "hoot.bye", "hoot.answer", "hoot.say", "hoot.log", "hoot.interactive"],
        "hoot.files": ["hoot.files", "hoot.file.read", "hoot.file.write", "hoot.file.reset", "hoot.memory.delete"], "web": ["web.open"],
        "controls": ["controls.read", "controls.apply"], "usage": ["usage.read"], "send": ["session.send"], "account": ["account.read", "account.switch"],
        "logins": ["logins.read", "logins.signin", "logins.signout"], "devices": ["devices.list", "devices.revoke"], "settings": ["settings.read", "settings.apply"],
        "windows": ["window.result"], "hostwindows": ["window.call", "window.holds", "sessions.mine"],
        "watch": ["browser.watch", "browser.unwatch", "browser.frame.ack", "browser.input", "browser.surfaces", "browser.handover.take", "browser.handover.done"],
        "folders.pick": ["folders.browse"], "files": ["files.list", "files.read"], "git": ["git.status", "git.diff"], "git.write": BackendPhoneChanges.writeMessages, "panels": ["panel.read", "panel.act"],
        "browser.profiles": ["browser.profiles", "browser.profile.use", "browser.profile.clear"],
        "chats": BackendPhoneChats.messages, "pictures": BackendPhonePictures.messages, "sims": BackendPhoneDevices.messages,
        // 31 Oct (Reviewer, phone round): without these a real Mac never said push/activity in its welcome.
        "push": BackendPhonePush.messages, "activity": BackendPhoneActivity.messages,
        "browser.control": ["browser.windows", "browser.window.open", "browser.window.go", "browser.window.act", "browser.window.size", "browser.window.bind", "browser.window.shot", "browser.window.steps", "browser.window.pick"],
    ]
}

private extension BackendSessionEvent {
    var isOutput: Bool { if case .data = self { return true }; return false }
}
