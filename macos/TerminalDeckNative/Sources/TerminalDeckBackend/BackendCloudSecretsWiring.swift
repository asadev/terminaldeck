import Foundation
import TerminalDeckNativeCore

/// Lane A's wiring of saved passwords (lane V) for the lean first version (cloud-lean-v1.md item 3).
/// Nothing in this file opens a network connection, a Keychain item or a file by itself: every port is handed in
/// by the account assembly, and without that hand-over none of it exists.
public enum BackendCloudSecretsLean {
    /// The sources of this version, each under its OWN domain, so no per-domain router is needed.
    /// Out and never admitted: browser cookies, saved browser passwords, AI-subscription sign-ins, GitHub.
    /// 14 Nov (owner): project secret files join as `project-files` under `project` (BackendProjectSecretFilesStore).
    public static let sources: [String: CloudSecretsDomain] = [
        "api": .apiKey, "servers": .server, "ssh": .ssh, "mcp-user": .mcp, "tasks": .taskConnection, "receiver": .receiver, "voice": .app, BackendWhatsAppKeysStore.source: .whatsapp,
        BackendProjectSecretFilesRules.sourceId: .project
    ]
    /// A store joins only when its source id AND its domain are on the list above, and once per domain.
    /// Anything else is left out whole: no adapter, no domain in the sync core, no count.
    public static func admitted(_ stores: [any CloudSecretsLogicalStore]) -> [any CloudSecretsLogicalStore] {
        var domains: Set<String> = [], kept: [any CloudSecretsLogicalStore] = []
        for store in stores {
            guard let domain = sources[store.sourceId], domain == store.domain, domains.insert(domain.rawValue).inserted else { continue }
            kept.append(store)
        }
        return kept
    }
    /// Exactly the domains the sync core may admit as saved passwords.
    public static func domains(_ stores: [any CloudSecretsLogicalStore]) -> Set<String> {
        Set(admitted(stores).map { $0.domain.rawValue })
    }

    /// The sync transport reports the service's `secrets_locked` answer as `CloudFailure.secretsLocked`. Lane V's
    /// coordinator reads that answer as `.remote` with the service's code (after a lost acknowledgement it means
    /// "already approved"). Same refusal, in the shape V handles; every other error passes through untouched.
    public static func controlFailure(_ error: any Error, requestId: String) -> any Error {
        guard let failure = error as? CloudFailure, failure == .secretsLocked else { return error }
        return CloudFailure.remote(.init(code: "secrets_locked", message: "Saved passwords are locked for this request.",
                                         retryable: false, requestId: requestId))
    }
    /// Lane V's control port over the account's own authenticated, budgeted sender. Method, path, body and request id
    /// go out exactly as V made them. `devices` is the account's own device list.
    /// `statusCache` (14 Nov, 31 status reads in five minutes from two Macs): every `GET /secrets/status` of this
    /// identity is answered from the one kept answer until something says the state may have changed.
    public static func control(send: @escaping BackendCloudSecretsControl.Send,
                               devices: @escaping @Sendable () async throws -> CloudDeviceList,
                               statusCache: BackendCloudSecretsStatusCache? = nil) -> BackendCloudSecretsControl {
        BackendCloudSecretsControl(send: { method, path, body, requestId in
            let isStatus = method == "GET" && path == BackendCloudSecretsStatusCache.path
            if isStatus, let kept = statusCache?.kept() { return kept }
            // PASSWORDS-5 point 7: at start the first status read waits until the account's socket is connected (the
            // reads that went out before it all failed, each saying "the last answer did not arrive"), and readers at
            // the same moment share ONE read: one read at start, not four.
            if isStatus, let statusCache {
                await statusCache.untilConnected()
                if let kept = statusCache.kept() { return kept }
                return try await statusCache.shared {
                    let generation = statusCache.reading()
                    do {
                        let data = try await send(method, path, body, requestId)
                        statusCache.keep(data, generation: generation)
                        return data
                    } catch { throw BackendCloudSecretsLean.controlFailure(error, requestId: requestId) }
                }
            }
            let generation = isStatus ? (statusCache?.reading() ?? 0) : 0
            // Anything this Mac sends to a saved-password route may change the state: the next status read is fresh.
            if !isStatus { statusCache?.invalidate() }
            do {
                let data = try await send(method, path, body, requestId)
                if isStatus { statusCache?.keep(data, generation: generation) } else { statusCache?.invalidate() }
                return data
            } catch {
                if !isStatus { statusCache?.invalidate() }
                throw BackendCloudSecretsLean.controlFailure(error, requestId: requestId)
            }
        }, registeredDevice: { deviceId in
            let list = try await devices()
            return try BackendCloudSecretsLean.registeredDevice(deviceId, in: list.devices)
        }, deviceNames: {
            try await BackendCloudSecretsLean.deviceNames(devices().devices)
        })
    }
    /// PASSWORDS-5 point 6: each active device by the name pages show (its friendly name, else its recorded label), and
    /// whether the list says it is approved for saved passwords. One row per device id.
    public static func deviceNames(_ devices: [CloudDevice]) -> [CloudSecretsDeviceName] {
        var seen: Set<String> = []
        return devices.compactMap { device in
            guard device.status == .active, seen.insert(device.deviceId).inserted else { return nil }
            return CloudSecretsDeviceName(deviceId: device.deviceId, name: device.shownName, holdsKey: device.secretsApproved,
                                          signedOutBefore: device.signedOutBefore == true)
        }
    }
    /// One device of this account with the keys the service registered for it. Only an active device, listed exactly once.
    public static func registeredDevice(_ deviceId: String, in devices: [CloudDevice]) throws -> CloudDeviceRegistration {
        let found = devices.filter { $0.deviceId == deviceId }
        guard found.count == 1, let device = found.first, device.status == .active else { throw CloudFailure.invalidRequest }
        return CloudDeviceRegistration(deviceId: device.deviceId, label: device.label, platform: device.platform, appVersion: device.appVersion,
                                       signPublicJwk: device.signPublicJwk, wrapPublicJwk: device.wrapPublicJwk)
    }
}

/// The one saved-passwords tool of this version. It can read the state and OPEN this Mac's own sheets; it has no
/// field for recovery words, for either code, for adding or dismissing an MCP server, and no "start new" action
/// (this version's sign-in gives no ticket for it). `cloud.browser` is not registered at all.
public enum BackendCloudSecretsLeanTool {
    public static let owner = "cloud-secrets"
    public static let id = "cloud.secrets"
    public static let actions = ["status", "setup", "request_device", "open_approval", "recover"]
    public static func definition() throws -> BackendMCPTool {
        let schema: NativeRPCValue = .object([.init("type", .string("object")), .init("properties", .object([
            .init("action", .object([.init("type", .string("string")), .init("enum", .array(actions.map(NativeRPCValue.string)))])),
            .init("approvalId", .object([.init("type", .string("string"))]))])),
            .init("required", .array([.string("action")])), .init("additionalProperties", .bool(false))])
        return try BackendMCPTool(id: id, wireName: "cloud_secrets",
            description: "Read whether saved passwords are on in Cloud, turn them on (the key is made on this Mac; no words), ask another device, open another device's request, or (older accounts only) use recovery words. Nothing secret is accepted or returned here.",
            inputSchema: schema, tier: .alter)
    }
    /// Only the lean actions and the two fields above ever reach lane V's dispatcher.
    public static func arguments(_ arguments: NativeRPCValue) throws -> CloudValue {
        guard let fields = arguments.fields, Set(fields.map(\.key)).count == fields.count,
              Set(fields.map(\.key)).isSubset(of: ["action", "approvalId"]),
              let action = arguments["action"].string, actions.contains(action) else { throw CloudFailure.invalidRequest }
        return CloudValue(arguments)
    }
    public static func invoke(_ tools: BackendCloudSecretsTools, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        let checked = try Self.arguments(arguments)
        let result = try await tools.invoke(id, arguments: checked)
        return result.raw
    }
    /// Gap 1b (14 Nov): the READ-ONLY state of saved passwords, at the same level as the other Cloud read tools
    /// (`cloud.status`, `cloud.versions`, `cloud.reach.status`: tier `.read`). `cloud.secrets` itself is `.alter`
    /// (its actions open this Mac's sheets), so an AI-app key at "work" or "look" level ([read, act] / [read]) and any
    /// unattended caller were refused even its `status`: that, not the registration, kept it from an integrator.
    public static let statusID = "cloud.secrets.status"
    public static func statusDefinition() throws -> BackendMCPTool {
        let schema: NativeRPCValue = .object([.init("type", .string("object")), .init("properties", .object([])),
                                              .init("additionalProperties", .bool(false))])
        return try BackendMCPTool(id: statusID, wireName: "cloud_secrets_status",
            description: "Read saved passwords on this Mac: the page's state word and since when, which device sealed this Mac's copy of the key, how many devices can open it (and the names this Mac knows), whether the stricter setting (ask on each new device) is on here, and whether a passkey spare key exists (made on which device, when). Names, counts and dates only: never a key, code, token, id or e-mail.",
            inputSchema: schema, tier: .read)
    }
    /// Joins the same MCP path as the account's own tools; `visible` is the same gate plus "this identity's saved
    /// passwords are still open". `summary` (the graph's `summary()`) adds the read-only `cloud.secrets.status`.
    public static func registrations(tools: BackendCloudSecretsTools,
                                     visible: @escaping @Sendable () async -> Bool,
                                     summary: (@Sendable () async -> NativeRPCValue)? = nil) async throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        guard await visible() else { return [] }
        let spec = try definition()
        var entries: [(BackendMCPTool, BackendNativeMCPServer.Handler)] = [(spec, { _, arguments in
            guard await visible() else { throw CloudFailure.gateClosed }
            let value = try await BackendCloudSecretsLeanTool.invoke(tools, arguments: arguments)
            return .value(value)
        })]
        if let summary {
            entries.append((try statusDefinition(), { _, arguments in
                guard await visible() else { throw CloudFailure.gateClosed }
                guard (arguments.fields ?? []).isEmpty else { throw CloudFailure.invalidRequest }
                return .value(await summary())
            }))
        }
        return entries
    }
}

/// The gate lane V reads at every boundary. One answer from the service is used until shortly before it runs out,
/// so a capture of many records asks the service once, not once per record. Closed for good once sealed.
public actor BackendCloudSecretsGate {
    private let fetch: @Sendable () async throws -> CloudGate
    private let clock: @Sendable () -> Int64
    private var held: CloudGate?
    private var sealed = false
    public init(fetch: @escaping @Sendable () async throws -> CloudGate,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.fetch = fetch; self.clock = now
    }
    public func current() async throws -> CloudGate {
        guard !sealed else { throw CloudFailure.gateClosed }
        if let held, let until = held.expiresAt, until - 30_000 > clock() { return held }
        let fresh = try await fetch()
        guard !sealed else { throw CloudFailure.gateClosed }
        held = fresh
        return fresh
    }
    public func seal() { sealed = true; held = nil }
    public nonisolated func policy(now: @escaping @Sendable () -> Int64) -> CloudSecretsPolicy {
        CloudSecretsPolicy(capabilities: { try await self.current() }, now: now)
    }
}

/// Where the event tap leaves the service's notices for whoever listens now (the signed-in identity's graph), or nobody.
public final class BackendCloudSecretsEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: (@Sendable (CloudEvent) -> Void)?
    /// Reach by account hears the same socket's `devices` and `gate` notices (no second socket).
    private var reachListener: (@Sendable (CloudEvent) -> Void)?
    /// The kept `/secrets/status` answer of this identity; the socket's own notices make it stale.
    public let statusCache: BackendCloudSecretsStatusCache
    public init(statusCache: BackendCloudSecretsStatusCache = .init()) { self.statusCache = statusCache }
    public func listen(_ listener: (@Sendable (CloudEvent) -> Void)?) { lock.withLock { self.listener = listener } }
    public func listenReach(_ listener: (@Sendable (CloudEvent) -> Void)?) { lock.withLock { self.reachListener = listener } }
    public func post(_ event: CloudEvent) {
        if let reason = BackendCloudSecretsStatusCache.noticeReasons[event.type] {
            // The floor: a notice inside the minute after the last read only marks the kept answer stale; the same
            // notice is shown again once, when the minute is up, so nothing is missed (only delayed by under a minute).
            if case .deferred(let afterMs) = statusCache.notice(reason, type: event.type) { followUp(event, afterMs: afterMs) }
        }
        // PASSWORDS-5 point 7: the socket said hello, so the account is connected: the held first status read goes out.
        if event.type == "hello" { statusCache.connected() }
        deliver(event)
    }
    private func deliver(_ event: CloudEvent) {
        let (current, reach) = lock.withLock { (listener, reachListener) }
        current?(event)
        reach?(event)
    }
    /// One follow-up per notice type at a time; it re-shows the newest notice of that type when the minute is up.
    private var waiting: [String: CloudEvent] = [:]
    /// The follow-ups waiting now, by notice kind, with the wait each was scheduled with (ms). Recorded when scheduled,
    /// not when its task first runs, so it can be read at once.
    private var scheduled: [String: Int64] = [:]
    var followUpsWaiting: [String: Int64] { lock.withLock { scheduled } }
    private func followUp(_ event: CloudEvent, afterMs: Int64) {
        let first = lock.withLock { () -> Bool in
            let first = waiting[event.type] == nil
            waiting[event.type] = event
            if first { scheduled[event.type] = afterMs }
            return first
        }
        guard first else { return }
        let sleep = statusCache.sleep
        Task { [weak self] in
            await sleep(afterMs)
            guard let self else { return }
            let due = self.lock.withLock { () -> CloudEvent? in
                self.scheduled.removeValue(forKey: event.type)
                return self.waiting.removeValue(forKey: event.type)
            }
            guard let due else { return }
            // Only the listener (saved passwords) hears it again; reach heard the notice when it came.
            _ = self.statusCache.notice(BackendCloudSecretsStatusCache.noticeReasons[due.type] ?? "a notice", type: due.type)
            let current = self.lock.withLock { self.listener }
            current?(due)
        }
    }
}

/// 14 Nov (the 0220za watch: both Macs read `/secrets/status` 31 times in five minutes; before that build no Mac read
/// it on a timer at all): ONE kept answer of `GET /secrets/status` for this identity. Every reader (the page, the
/// start line, the read tool, a capture's key check, an automatic answer) takes it; the service is asked again only
/// when something says the state may have changed:
/// - his own look (opening Settings → Cloud, Check again, a press, Sync now) and anything this Mac sent to a
///   saved-password route: at once;
/// - the socket's own notices (`vault`, `approval`, `devices`, `hello`, `gate`): at most ONE read per 60 seconds (the
///   floor). A notice inside the minute marks the answer stale and is shown again when the minute is up;
/// - otherwise at most once every 15 minutes.
/// Nothing on a timer asks the service. Only a good answer is kept. Every service read says its reason in ONE log line
/// (`cloud passwords: status read (reason: …)`).
public final class BackendCloudSecretsStatusCache: @unchecked Sendable {
    public static let path = "/secrets/status"
    public static let maximumAgeMs: Int64 = 900_000
    public static let noticeFloorMs: Int64 = 60_000
    public static let noticeReasons: [String: String] = [
        "vault": "vault notice", "approval": "approval notice", "devices": "devices notice", "hello": "reconnected", "gate": "gate notice"
    ]
    public enum Notice: Equatable { case now, deferred(afterMs: Int64) }
    private let lock = NSLock()
    private var held: (at: Int64, data: Data)?
    /// Why the next service read happens (said in its log line).
    private var reason = "app start"
    /// When the service was last asked (for the notice floor).
    private var lastReadAt: Int64?
    /// A notice came inside the minute: the kept answer is stale from the end of that minute.
    private var staleFrom: Int64?
    /// Moves on with every invalidation: an answer asked before a change is never kept after it.
    private var stamp = 0
    private let clock: @Sendable () -> Int64
    let sleep: @Sendable (Int64) async -> Void
    /// Where the reason lines go (the saved-passwords guarded log); set when the identity's saved passwords attach.
    private var log: CloudSecretsLog?
    /// PASSWORDS-5 point 7: the first status read waits for the socket's hello (`connected()`), at most this long
    /// (then it goes out anyway, and nothing is held again). nil (fixtures): nothing is held.
    private let holdFirstReadMs: Int64?
    private var holding: Bool
    private var holdTimerStarted = false
    private var connectWaiters: [CheckedContinuation<Void, Never>] = []
    /// The status read going out now, shared by every reader that asks meanwhile (one read, not one per reader).
    private var inflight: (id: Int, task: Task<Data, any Error>)?
    private var inflightIds = 0
    public init(now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
                sleep: @escaping @Sendable (Int64) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) },
                holdFirstReadMs: Int64? = nil) {
        clock = now; self.sleep = sleep
        self.holdFirstReadMs = holdFirstReadMs; holding = holdFirstReadMs != nil
    }
    /// The app's wait for the socket at start (seconds after the engine is ready the socket is normally up).
    public static let appHoldFirstReadMs: Int64 = 20_000
    /// Returns at once once connected (or never held); the first caller starts the one time limit.
    func untilConnected() async {
        let (hold, startTimer) = lock.withLock { () -> (Bool, Bool) in
            guard holding else { return (false, false) }
            let first = !holdTimerStarted
            holdTimerStarted = true
            return (true, first)
        }
        guard hold else { return }
        if startTimer, let limit = holdFirstReadMs {
            let sleep = self.sleep
            Task { [weak self] in
                await sleep(limit)
                self?.connected(timedOut: true)
            }
        }
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                guard holding else { return true }
                connectWaiters.append(waiter)
                return false
            }
            if now { waiter.resume() }
        }
    }
    /// Tests: how many reads wait for the connection now.
    var heldReads: Int { lock.withLock { connectWaiters.count } }
    /// The socket said hello (or the time limit passed): held reads go out, and nothing is held again.
    public func connected(timedOut: Bool = false) {
        let (waiters, out) = lock.withLock { () -> ([CheckedContinuation<Void, Never>], CloudSecretsLog?) in
            guard holding else { return ([], nil) }
            holding = false
            if timedOut { reason = "app start (no connection after " + String((holdFirstReadMs ?? 0) / 1000) + " seconds)" }
            let all = connectWaiters
            connectWaiters = []
            return (all, timedOut ? log : nil)
        }
        out?.say("status read waited for the connection and goes out without it")
        for waiter in waiters { waiter.resume() }
    }
    /// One status read at a time: a reader that comes while one is going out takes that one's answer.
    func shared(_ read: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let (id, task, mine) = lock.withLock { () -> (Int, Task<Data, any Error>, Bool) in
            if let inflight { return (inflight.id, inflight.task, false) }
            inflightIds &+= 1
            let made = Task { try await read() }
            inflight = (inflightIds, made)
            return (inflightIds, made, true)
        }
        defer { if mine { lock.withLock { if inflight?.id == id { inflight = nil } } } }
        return try await task.value
    }
    public func use(log: CloudSecretsLog?) { lock.withLock { self.log = log } }
    func kept() -> Data? {
        lock.withLock {
            guard let held else { return nil }
            let now = clock(), age = now - held.at
            if let staleFrom, now >= staleFrom { self.held = nil; return nil }
            guard age >= 0, age < Self.maximumAgeMs else { self.held = nil; reason = "15-minute check"; return nil }
            return held.data
        }
    }
    /// A service read is about to go out: its one log line. Returns the generation the answer belongs to.
    func reading() -> Int {
        let (line, out, stampNow) = lock.withLock { () -> (String, CloudSecretsLog?, Int) in
            let line = "status read (reason: " + reason + ")"
            lastReadAt = clock(); staleFrom = nil; reason = "the last answer did not arrive"
            return (line, log, stamp)
        }
        out?.say(line)
        return stampNow
    }
    func keep(_ data: Data, generation: Int) {
        lock.withLock {
            guard generation == stamp else { return }
            held = (clock(), data)
            // The next read after this one is, unless something says otherwise, a key check before a send.
            reason = "key check before a send"
        }
    }
    /// His own look or a change this Mac sent: the next status read asks the service at once.
    public func invalidate(_ why: String = "a change this Mac sent") { lock.withLock { held = nil; staleFrom = nil; reason = why; stamp &+= 1 } }
    /// A socket notice: at once when the last read is a minute old, otherwise stale when that minute is up.
    func notice(_ why: String, type: String) -> Notice {
        lock.withLock {
            let now = clock()
            guard let last = lastReadAt, now - last < Self.noticeFloorMs, held != nil else {
                // The first read of the run keeps its reason ("app start").
                held = nil; staleFrom = nil; if lastReadAt != nil { reason = why }; stamp &+= 1
                return .now
            }
            let due = last + Self.noticeFloorMs
            if staleFrom == nil { staleFrom = due; reason = why }
            return .deferred(afterMs: max(0, due - now))
        }
    }
}

/// What the sync core is built with for saved passwords. Empty unless this identity's saved passwords were wired
/// before the core was first needed.
public final class BackendCloudSecretsEngineParts: @unchecked Sendable {
    private let lock = NSLock()
    private var held: (domains: Set<String>, content: any CloudContentPort)?
    public init() {}
    public func set(domains: Set<String>, content: any CloudContentPort) { lock.withLock { held = (domains, content) } }
    public var domains: Set<String> { lock.withLock { held?.domains ?? [] } }
    public var content: (any CloudContentPort)? { lock.withLock { held?.content } }
}

/// The sync core is the only reader of the service's event socket. This hands every call through to the real
/// transport unchanged and shows each event to the sink on its way to the sync core, so saved passwords hear the
/// service's `vault` and `approval` notices without a second socket and without a timer. It never holds an event back.
public final class BackendCloudSecretsEventTap: CloudTransportPort, CloudSyncWakePort, CloudSyncRegistrationPort {
    public typealias Upstream = CloudTransportPort & CloudSyncWakePort & CloudSyncRegistrationPort
    private let upstream: any Upstream
    private let sink: BackendCloudSecretsEventSink
    public init(upstream: any Upstream, sink: BackendCloudSecretsEventSink) { self.upstream = upstream; self.sink = sink }
    public func capabilities() async throws -> CloudGate { try await upstream.capabilities() }
    public func registerDevice(_ request: CloudDeviceRegistration) async throws -> CloudDeviceRegistrationReceipt { try await upstream.registerDevice(request) }
    public func devices() async throws -> CloudDeviceList { try await upstream.devices() }
    public func state() async throws -> CloudRemoteState { try await upstream.state() }
    public func backoff(milliseconds: Int64) async throws { try await upstream.backoff(milliseconds: milliseconds) }
    public func commit(_ segment: CloudSegment) async throws -> CloudReceipt { try await upstream.commit(segment) }
    public func changes(after: CloudSequence, limit: Int) async throws -> CloudChangePage { try await upstream.changes(after: after, limit: limit) }
    public func prepareBlobs(_ items: [CloudBlobUpload]) async throws -> [CloudBlobTicket] { try await upstream.prepareBlobs(items) }
    public func finalizeBlobs(_ items: [CloudBlobFinalize]) async throws -> [CloudBlobResult] { try await upstream.finalizeBlobs(items) }
    public func readBlobs(ids: [String]) async throws -> [CloudBlobDownload] { try await upstream.readBlobs(ids: ids) }
    public func publishCheckpoint(_ request: CloudCheckpointRequest) async throws -> CloudCheckpointReceipt { try await upstream.publishCheckpoint(request) }
    public func checkpoint() async throws -> CloudCheckpoint? { try await upstream.checkpoint() }
    public func verifyCheckpoint(id: String, inventoryDigest: String, counts: CloudCounts) async throws -> [String] {
        try await upstream.verifyCheckpoint(id: id, inventoryDigest: inventoryDigest, counts: counts)
    }
    public func applied(brainSeq: CloudSequence, secretsSeq: CloudSequence, checkpointId: String?) async throws -> CloudAppliedReceipt {
        try await upstream.applied(brainSeq: brainSeq, secretsSeq: secretsSeq, checkpointId: checkpointId)
    }
    public func takeLease(_ request: CloudLeaseRequest) async throws -> CloudLease { try await upstream.takeLease(request) }
    public func releaseLease(resourceId: String, generation: CloudSequence) async throws {
        try await upstream.releaseLease(resourceId: resourceId, generation: generation)
    }
    public func events() async -> AsyncThrowingStream<CloudEvent, Error> {
        let source = await upstream.events()
        let sink = self.sink
        return AsyncThrowingStream { continuation in
            let forward = Task {
                do {
                    for try await event in source {
                        sink.post(event)
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in forward.cancel() }
        }
    }
    public func stop() async { await upstream.stop() }
    public func onWake(_ handler: @escaping @Sendable () async -> Void) async { await upstream.onWake(handler) }
    public func currentDeviceId() async throws -> String { try await upstream.currentDeviceId() }
}

/// Joins each saved-password source to the sync core exactly once, and only after this Mac holds the key (the sync
/// core asks a source for its inventory when it joins, which needs the key).
actor BackendCloudSecretsRegistrar {
    private let outbox: any CloudOutboxPort
    private let adapters: [CloudSecretsLogicalAdapter]
    private var joined: Set<String> = []
    private var running: Task<[String: any Error], Never>?
    init(outbox: any CloudOutboxPort, adapters: [CloudSecretsLogicalAdapter]) { self.outbox = outbox; self.adapters = adapters }
    /// Unlock still requires every source to be preserved before remote values may be merged.
    func registerAll() async throws {
        let failures = await registerAvailable()
        if let error = adapters.compactMap({ failures[$0.sourceId] }).first { throw error }
    }
    /// A source whose inventory cannot be read must not stop the other kinds joining or saving.
    /// Concurrent reconnect/change callbacks share one pass, so a successful adapter never joins twice.
    func registerAvailable() async -> [String: any Error] {
        if let running { return await running.value }
        let task = Task { await self.registerPending() }
        running = task
        defer { running = nil }
        return await task.value
    }
    private func registerPending() async -> [String: any Error] {
        var failures: [String: any Error] = [:]
        for adapter in adapters where !joined.contains(adapter.sourceId) {
            do {
                try await outbox.register(adapter: adapter)
                joined.insert(adapter.sourceId)
            } catch { failures[adapter.sourceId] = error }
        }
        return failures
    }
    func joinedSources() -> Set<String> { joined }
}

/// What the Cloud page shows of saved passwords. State only; nothing here can unlock, allow or add anything.
public struct BackendCloudSecretsPage: Sendable, Equatable {
    public enum Standing: Sendable, Equatable {
        /// The service could not be asked just now.
        case unknown
        /// This account has no saved passwords in Cloud yet.
        case notSetUp
        /// The account has them; this Mac holds no key.
        case locked
        /// Key saved here, the service has not confirmed this Mac yet.
        case waitingForCloud
        /// Cloud's saved passwords are newer than this Mac's key (started anew on another device).
        case startedAnew(String)
        /// This Mac's key exists but cannot be opened (lane V's `BackendCloudSecretsKeyBlocked`).
        case keyBlocked(String)
        /// The login store is blocked (lane V's `BackendCloudRecoveryBlocked`).
        case loginStoreBlocked(String)
        /// The key that opens this Mac's OWN saved passwords is gone (lane V's local stores, `keyLost`). "Allow
        /// login store" cannot bring it back and is not offered; never "Protected".
        case keyLost(String)
        /// Lane V: this Mac's own stores could not be checked just now. Its own state with "Check again"; never
        /// "Protected" and no "Allow login store".
        case cannotCheck(String)
        /// This Mac holds the confirmed key.
        case protected
    }
    public struct Approval: Sendable, Equatable, Identifiable {
        public let id: String
        public let expiresAt: Int64
        public init(id: String, expiresAt: Int64) { self.id = id; self.expiresAt = expiresAt }
    }
    /// An MCP server from another device that waits for the person's own click.
    public struct Waiting: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let removed: Bool
        public init(id: String, title: String, removed: Bool) { self.id = id; self.title = title; self.removed = removed }
    }
    public var standing: Standing = .unknown
    /// Plain words for items left on this Mac (lane V's `service.gaps()`).
    public var gaps: [String] = []
    /// 15 Nov (after 0220zh): the KINDS left out ("API keys", "MCP servers"), so the state line says which, never
    /// "Some saved items". Fixed titles of the sources (`BackendCloudSecretsLeanCoverage.title`), never an item's name.
    public var gapKinds: [String] = []
    public var approvals: [Approval] = []
    public var waiting: [Waiting] = []
    /// One plain line when the person's last press here did not finish; nil otherwise. A press never fails silently.
    public var problem: String?
    /// Incoming items closed on this Mac without being applied, as lane V counts them ("2: A removal … was listed
    /// for you, not applied here."). Shown until the person has seen them.
    public var skipped: [String] = []
    /// One plain sentence per source of this version that is NOT saved in Cloud from this Mac. Never silently missing.
    public var notSaved: [String] = []
    /// Review B-M2: part of the check could not be read (the list of MCP servers that wait). The page then says
    /// "could not check" with Check again, never "ready".
    public var couldNotCheck = false
    /// This Mac holds a Cloud key for saved passwords (also one that waits for Cloud).
    public var cloudKeyHere = false
    /// Lane V S-A1: the account has saved passwords set up in Cloud (vault not unset). Without it, "Ask another
    /// device" and "Use recovery words" cannot help and are not offered.
    public var cloudSetUp = false
    /// Automatic hand-over (owner, 14 Nov): this Mac has no key yet and opens by itself as soon as one of his other
    /// devices answers. The page then says one quiet line and offers nothing to press on the normal path.
    public var opensBySelf = false
    /// "Saved passwords opened on <device>, <date>." for each device this Mac answered by itself (names and dates only).
    public var openedOn: [String] = []
    /// The automatic set-up did not finish: "Turn on" is offered (with one plain line).
    public var turnOnFailed = false
    /// Review point 5: Cloud's copy cannot be opened by any device. Said as it is, with "Start again" when possible.
    public var cannotOpen = false
    public var startAgainAvailable = false
    /// This account has recovery words (an older account): "Use recovery words" may be offered.
    public var offersRecoveryWords = false
    /// The owner's stricter setting ("Ask me on each new device") as THIS Mac applies it. nil = not shown
    /// (this Mac holds no key, so it answers nobody).
    public var askOnNewDevice: Bool?
    /// Review blocker 2: he switched the stricter setting off on another device; a relayed "off" is never taken, so
    /// it is still on here. One plain line beside the switch says so.
    public var askOffElsewhere = false
    /// Review blocker 3: the service cannot carry the setting to his other devices yet: "On this Mac only".
    public var askThisMacOnly = false
    /// 15 Nov: "Keep saved passwords and secret files off my phones" as THIS Mac applies it (off by default). nil = not
    /// shown (this Mac holds no key, so it hands nothing to anyone).
    public var phonesOff: Bool?
    /// A Mac with no key yet whose account asks for a click on each new device: its one waiting line says so.
    public var waitsForClick = false
    /// "Start again" was pressed and waits out its 5 seconds behind Undo (set by the app's page model).
    public var startingAgain = false
    /// His passkey can open the Cloud copy here (a spare of this generation is on file and this Mac can use passkeys):
    /// the one control is then "Open with my passkey" (never a code).
    public var opensWithPasskey = false
    /// Slice 2: "Passkey spare key made on <device>, <date>." from the service's own record of who added this
    /// generation's spare (a spare he did not make is then visible). nil = none, or the passkey is not on this Mac.
    public var spareMade: String?
    /// Gap 2: no spare of this generation exists and his passkey works here: "Make a passkey spare key" (his press).
    public var canMakeSpare = false
    /// PASSWORDS-5 point 4: a second passkey was made on this Mac after this generation's spare already existed, so the
    /// spare may no longer open. Said in warning colour, with "Make my spare key again" beside it.
    public var spareWarning: String?
    /// Point 4 repair: "Make my spare key again" beside the warning (his press only).
    public var canRepairSpare = false
    /// What the last "Make my spare key again" said ("Your spare key still works.", or why it was not done).
    public var spareNote: String?
    /// "Passkey spare key replaced on <device>, <date>." whenever the service's status carries a replace (every Mac).
    public var spareReplaced: String?
    public init() {}

    /// The order of what the one line says (lane V's wiring, lean item 5): this Mac's Cloud key blocked, the login
    /// store blocked, this Mac's own stores' key lost, started anew, then waiting for Cloud, locked or not set up,
    /// and only then Protected.
    public static func standing(keyBlocked: String?, loginStoreBlocked: String?, keyLost: String? = nil, cannotCheck: String? = nil,
                                protection: CloudSecretsProtection, available: Bool, cloudAhead: String?, vault: CloudVaultState?) -> Standing {
        if let keyBlocked { return .keyBlocked(keyBlocked) }
        if let loginStoreBlocked { return .loginStoreBlocked(loginStoreBlocked) }
        if let keyLost { return .keyLost(keyLost) }
        if let cannotCheck { return .cannotCheck(cannotCheck) }
        if let cloudAhead { return .startedAnew(cloudAhead) }
        switch protection {
        case .waitingForCloud: return .waitingForCloud
        case .protected: return available ? .protected : .unknown
        case .locked:
            guard let vault else { return .unknown }
            return vault == .unset ? .notSetUp : .locked
        }
    }
}

public enum BackendCloudSecretsWords {
    /// The one state line. It reads "Protected" only when this Mac holds the confirmed key AND nothing is left out;
    /// with a gap or a wait it says that instead.
    public static func state(_ page: BackendCloudSecretsPage) -> String {
        switch page.standing {
        // Page-names 2: the same state, in the same words, on the Cloud summary's row and in this part.
        case .unknown: return "Could not be checked on this Mac just now"
        // On by default (owner, 14 Nov): "not set up" only lasts until this Mac made the key by itself.
        case .notSetUp: return turningOn
        case .locked:
            if page.startingAgain { return startingAgain }
            if page.cannotOpen { return cannotOpen }
            if page.opensBySelf { return page.waitsForClick ? waitingForClick : opening }
            return "Locked on this Mac"
        case .waitingForCloud: return CloudSecretsProtection.waitingAdvice
        case .startedAnew(let text), .keyBlocked(let text), .loginStoreBlocked(let text), .keyLost(let text), .cannotCheck(let text): return text
        case .protected: return page.gaps.isEmpty ? on : notInCloudYet(page.gapKinds)
        }
    }
    /// The plain truth while a kind is left out: "API keys are not in Cloud yet from this Mac", "API keys and MCP servers
    /// are ...", "The voice key is ...". Fixed kind titles only.
    public static func notInCloudYet(_ kinds: [String]) -> String {
        guard let first = kinds.first else { return "Some saved items are not in Cloud yet from this Mac" }
        // "The voice key" reads "the voice key" after the first place in the line.
        let named = kinds.enumerated().map { index, kind in index > 0 && kind.hasPrefix("The ") ? "the " + String(kind.dropFirst(4)) : kind }
        let joined = named.count == 1 ? first : named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1]
        let verb = kinds.count == 1 && first.hasPrefix("The ") ? "is" : "are"
        return joined + " " + verb + " not in Cloud yet from this Mac"
    }
    /// One more plain sentence where the state line alone does not say what to do; nil otherwise.
    public static func advice(_ page: BackendCloudSecretsPage) -> String? {
        switch page.standing {
        // Page-names 2: the one sentence about saved passwords that are off, said here only (the summary's row says the state).
        case .notSetUp: return nil
        // His page rule (review point 9): no explanatory sentences under the state.
        case .locked: return nil
        default: return nil
        }
    }
    public static let on = "On"
    public static let turningOn = "Turning on"
    /// The row's state while this Mac waits for one of his devices (his page rule: one short state).
    public static let opening = "Opening…"
    /// Review point 5: the dead state, said once.
    public static let cannotOpen = "The Cloud copy of your saved passwords can't be opened. Your logins on this Mac are safe."
    /// "Start again" waits out its 5 seconds (Undo beside it).
    public static let startingAgain = "Starting again…"
    /// A new device whose account asks for a click on each new device (the stricter setting).
    public static let waitingForClick = "Allow this Mac on one of your other devices"
    /// Slice 2: the one control where his passkey can open the copy.
    public static let openWithPasskey = "Open with my passkey"
    /// The stricter setting's switch (owner's words, 14 Nov). Off by default.
    public static let askSwitch = "Ask for my passkey on each new device"
    /// Gap 2: the one control that makes the passkey spare key by his press.
    public static let makeSpare = "Make a passkey spare key"
    /// PASSWORDS-5 point 4, review fix 2: true in the race too (the other device may have been making it just then).
    public static let spareOrphaned = "A second passkey was made on this Mac while another device was making your spare key. Your spare key may no longer open."
    /// The one control beside the warning (his press only).
    public static let repairSpare = "Make my spare key again"
    /// The system refused the new passkey because the spare's own passkey is still on this Mac.
    public static let spareStillWorks = "Your spare key still works."
    public static func spareNotRepaired(_ why: String) -> String { "Your spare key was not made again: " + why + "." }
    /// From the service's record of the last replace of this generation's spare.
    public static func spareReplaced(_ name: String?, at milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
        let who = name.map { $0.isEmpty ? "another device" : $0 } ?? "this Mac"
        return "Passkey spare key replaced on " + who + ", " + date + "."
    }
    public static func openedOn(_ name: String, at milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
        return "Saved passwords opened on " + name + ", " + date + "."
    }
    /// Slice 2: who made this generation's passkey spare key (the service's own record), names and dates only.
    public static func spareMade(_ name: String?, at milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
        let who = name.map { $0.isEmpty ? "another device" : $0 } ?? "this Mac"
        return "Passkey spare key made on " + who + ", " + date + "."
    }
    public static let approval = "Another device is asking to open your saved passwords."
    /// Review blocker 3: the stricter switch's name until the passkey ships (no passkey is asked yet); `askSwitch`
    /// keeps the passkey wording for slice 2.
    public static let askMeSwitch = "Ask me on each new device"
    /// Review blocker 3: beside the switch while the service cannot carry it to his other devices.
    public static let askThisMacOnly = "On this Mac only"
    /// 15 Nov (owner): the stricter way for his phones, off by default. The only new switch.
    public static let phonesOffSwitch = "Keep saved passwords and secret files off my phones and browsers"
    /// Review blocker 2: he switched it off on another device; here it stays on until he switches it off here.
    public static let askStillOnHere = "You switched this off on another device. It is still on for this Mac."
    /// Review blocker 4: a press right after this Mac was controlled from another device is not taken.
    public static let pressRefused = "This Mac was just being controlled from another device, so that was not done. Wait a moment and press it yourself."
    /// Review B-M2: a source whose last save to Cloud failed is named, never dropped. Shown with the gaps, so the
    /// state line is not "Protected" and the row is not settled until a later save gets through.
    public static func notSavedToCloud(_ title: String, reason: String?) -> String {
        var line = "Not saved to Cloud from this Mac: " + title + "."
        if let reason, !reason.isEmpty { line += " " + reason + (reason.hasSuffix(".") ? "" : ".") }
        return line + " It is tried again at the next sync."
    }
    /// Said under the state line when a press on this section did not finish (Cloud did not answer, another sheet
    /// was open). Closing a sheet yourself is not a problem and says nothing.
    public static let stepNotFinished = "That step did not finish. Try it again."
    public static let waitingList = "MCP servers from your other devices wait here. Nothing is added until you add it."
}

/// A weak way back from the status tool to the graph that owns it. Set once, at the end of the graph's init.
final class BackendCloudSecretsGraphLink: @unchecked Sendable {
    weak var graph: BackendCloudSecretsGraph?
}

/// One signed-in identity's saved passwords: lane V's service over the account's own outbox, the `cloud.secrets`
/// tool and what the Cloud page shows. Built per subject + device, sealed at sign-out or a closed gate, never reused.
public actor BackendCloudSecretsGraph {
    public enum Action: String, Sendable { case setup, requestDevice, recover, openApproval, startAgain, openWithPasskey, makeSpare, repairSpare }
    public nonisolated let service: CloudSecretsService
    public nonisolated let tools: BackendCloudSecretsTools
    public nonisolated let sourceIds: [String]
    /// One sentence per source of this version that is not saved from this Mac (`BackendCloudSecretsLeanCoverage`).
    public nonisolated let notSaved: [String]
    /// This Mac's own stores, as lane V's local-store check sees them (`BackendCloudRecoveryLocalStores.standing()`).
    /// Sources join the sync core and are captured only while this says `.ready`.
    private let localStanding: @Sendable () async -> BackendCloudRecoveryLocalStanding
    private let registrar: BackendCloudSecretsRegistrar
    private let content: CloudSecretsContent
    private let local: any CloudSecretsLocalKeyPort
    private let policy: CloudSecretsPolicy
    private let gate: BackendCloudSecretsGate?
    private let deviceId: String
    private let mcp: BackendCloudSecretsMCPStore?
    /// 15 Nov: the sealed shelf reads what each source hands the sync core (`exportRecords`), in this order.
    private let adapters: [CloudSecretsLogicalAdapter]
    private let projectFiles: BackendProjectSecretFilesStore?
    private let deleteOwners: [String: any CloudDeleteOwning]
    /// The page/tool router chooses an owner by source, after its ordinary project-scope check. Bin operations
    /// are for the person's page only; the tools lane must never register them.
    public func deleteOwner(sourceId: String) -> (any CloudDeleteOwning)? { sealed ? nil : deleteOwners[sourceId] }
    /// Review 15 Nov (decision 7): "can you delete right now". False while any older Mac exists (the gate is closed),
    /// while saved passwords are locked, or for a source without a sealed Bin: the pages hide BOTH bin buttons then,
    /// and `deleteItems` refuses with `CloudDeleteWords.cloudNeedsUpdatedMacs`.
    public func canDelete(sourceId: String) async -> Bool {
        guard !sealed, let owner = deleteOwners[sourceId] else { return false }
        if let files = owner as? BackendProjectSecretFilesStore { return await files.canDeleteEverywhere() }
        if let saved = owner as? BackendProjectSecretFilesSavedDeleteOwner { return await saved.canDeleteEverywhere() }
        return false
    }

    /// The same path for page and tool deletes. The caller supplies person/AI attribution and ONE group for
    /// the whole action. No confirmation, brake or Bin access is added here.
    public func deleteItems(sourceId: String, items: [CloudDeleteItem], scope: CloudDeleteScope, by actor: CloudDeleteActor) async throws -> CloudBinGroup {
        guard !sealed, let owner = deleteOwners[sourceId] else { throw CloudFailure.unavailable }
        let group = try await owner.deleteItems(items, scope: scope, by: actor)
        _ = try await service.captureChanged(sourceId: sourceId)
        changed()
        return group
    }
    public func bringBack(sourceId: String, items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem] {
        guard !sealed, let owner = deleteOwners[sourceId] else { throw CloudFailure.unavailable }
        let restored = try await owner.bringBack(items, to: to)
        _ = try await service.captureChanged(sourceId: sourceId)
        changed()
        return restored
    }

    private let changed: @Sendable () -> Void
    private var sealed = false
    private var stopObserving: (@Sendable () -> Void)?
    private var loginStoreBlocked: String?
    private var pressProblem: String?
    /// Review B-M2: the last failed save to Cloud per source id, in plain words; cleared by the next good save.
    private var saveFailures: [String: String] = [:]
    /// Automatic hand-over (owner, 14 Nov). nil = the earlier behaviour (sheets and codes).
    private let automatic: CloudSecretsAutoTrust?
    /// Review blocker 4: true while a press cannot be taken as the person's own (the app's own remote-input path
    /// posted just now), as for the trust presses. The real guard unless a fixture replaces it.
    private var pressRefused: @Sendable () -> Bool = { BackendRemoteInputGuard.system.refusesPress() }
    /// Fixtures only: how a press is checked.
    public func guardPresses(_ refused: @escaping @Sendable () -> Bool) { pressRefused = refused }
    /// Waits the given milliseconds (the app: a real sleep; tests: nothing). Used only to ask again after this Mac's
    /// request ran out, and to look again a moment after a device joined.
    private let pause: @Sendable (Int64) async -> Void
    private var askAgain: Task<Void, Never>?
    private var openedOn: [String] = []
    /// On by default (owner, 14 Nov): the app passes true, so the account's first device makes the key at start with
    /// no press. Fixtures that test the earlier presses leave it false.
    private let turnsOnBySelf: Bool
    /// The automatic set-up did not finish: the page then shows "Turn on" (a press). Never touches `pressProblem`.
    private var turnOnFailed = false
    /// Review point 5: Cloud has a copy that no device can open (nobody holds the key, no own copy here).
    private var cannotOpen = false
    /// "Start again" can work only with the service's reset ticket; until that exists the dead-state line stands alone.
    private let startAgainAvailable: Bool
    /// The dead state is said only after nobody could open the copy for this long (a first Mac in the middle of its
    /// set-up is not "nobody"). Tests pass 0.
    private let deadAfter: Int64
    private var nobodySince: Int64?
    /// Condition (c): the service refused "Start again" because a device still holds (or is still setting up) this
    /// generation's key. For that generation the page never says "can't be opened" again; it waits for that device.
    private var heldElsewhereEpoch: Int?
    /// Slice 2: his passkey (the app: AuthenticationServices); nil = no spare key on this Mac.
    private let passkey: (any CloudSecretsPasskeyPort)?
    /// PASSWORDS-5 point 3: the wait before the passkey offers itself (the app: a random 5 to 40 seconds), so two Macs
    /// updated together do not both show the sheet: the first one made wins, the other reads it fresh and shows none.
    /// nil (fixtures): no wait.
    private let spareOfferWait: (@Sendable () async -> Void)?
    public static let spareOfferWaitMs: ClosedRange<Int64> = 5_000...40_000
    /// The app's wait: a random time in `spareOfferWaitMs`.
    public static let randomSpareOfferWait: @Sendable () async -> Void = {
        try? await Task.sleep(nanoseconds: UInt64(Int64.random(in: BackendCloudSecretsGraph.spareOfferWaitMs)) * 1_000_000)
    }
    /// A spare of the current generation is on file and this Mac can use it (asked when this Mac looks, not per page).
    private var spareCanOpen = false
    /// Gap 1 (14 Nov): one plain line per state change in the app's log (`CloudSecretsLog`: names and plain words only).
    private let log: CloudSecretsLog
    /// The page's state word and since when (this Mac's clock), for the read tool and the start line.
    private var stateSince: (word: String, at: Int64)?
    private var startSaid = false
    private var deadSaid = false
    /// Review fix 1: the read tool's answer is kept for 30 seconds (it costs 6-10 service requests), so a caller in a
    /// loop cannot use up his Cloud allowance. Dropped at any change of state on this Mac. The start line uses it too.
    private var kept: (at: Int64, facts: SummaryFacts)?
    /// The last "Make my spare key again" outcome in plain words (cleared by the next one).
    private var spareNote: String?
    private static let keptFor: Int64 = 30_000

    /// `stores` pass the lean list once more here, so nothing outside it can join whoever builds this.
    public init(recovery: CloudRecoveryCoordinator, content: CloudSecretsContent, policy: CloudSecretsPolicy, gate: BackendCloudSecretsGate? = nil,
                local: any CloudSecretsLocalKeyPort, deviceId: String, outbox: any CloudOutboxPort, stores: [any CloudSecretsLogicalStore],
                retainConflict: @escaping @Sendable (CloudOperation) async throws -> Void, known: (any CloudSecretsKnownStore)?,
                restoreLocalStores: @escaping @Sendable () async throws -> Void,
                localStanding: @escaping @Sendable () async -> BackendCloudRecoveryLocalStanding = { .ready },
                changed: @escaping @Sendable () -> Void = {}, turnsOnBySelf: Bool = false, startAgainAvailable: Bool = false,
                deadAfter: Int64 = 120_000,
                automatic: CloudSecretsAutoTrust? = nil, passkey: (any CloudSecretsPasskeyPort)? = nil,
                spareOfferWait: (@Sendable () async -> Void)? = nil,
                log: CloudSecretsLog = .none,
                pause: @escaping @Sendable (Int64) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) }) throws {
        let kept = BackendCloudSecretsLean.admitted(stores)
        let adapters = kept.map { store in
            CloudSecretsLogicalAdapter(store: store, content: content, policy: policy, deviceId: deviceId,
                keepConflicts: { try await outbox.enqueue($0, files: []) }, retainIncomingConflict: retainConflict, known: known)
        }
        let joiner = BackendCloudSecretsRegistrar(outbox: outbox, adapters: adapters)
        let made = try CloudSecretsService(recovery: recovery, policy: policy, content: content, outbox: outbox, adapters: adapters,
            prepareSynchronization: { try await joiner.registerAll() }, restoreLocalStores: restoreLocalStores)
        service = made
        // `cloud.browser` is not part of this version: the lean tool never dispatches it. What this Mac does not
        // save is named in every status answer, in the same sentences the page shows.
        let unsaved = BackendCloudSecretsLeanCoverage.notSaved(registered: Set(kept.map { $0.sourceId }))
        // The tool never says "protected" while a save to Cloud failed (review B-M2): it asks this graph, which it
        // reaches weakly (the graph holds the tool).
        let owner = BackendCloudSecretsGraphLink()
        tools = BackendCloudSecretsTools(secrets: made, policy: policy, browser: { _, _ in throw CloudFailure.unavailable }, notSaved: unsaved,
                                         localStanding: localStanding, saveFailures: { await owner.graph?.failedSaves() ?? [] })
        notSaved = unsaved
        self.localStanding = localStanding
        sourceIds = kept.map { $0.sourceId }.sorted()
        registrar = joiner
        self.adapters = adapters
        projectFiles = kept.compactMap { $0 as? BackendProjectSecretFilesStore }.first
        self.content = content; self.local = local; self.policy = policy; self.gate = gate; self.deviceId = deviceId
        mcp = kept.compactMap { ($0 as? BackendCloudSecretsMCPStore) ?? ($0 as? BackendProjectSecretFilesSavedDeleteOwner)?.mcpStore }.first
        deleteOwners = Dictionary(uniqueKeysWithValues: kept.compactMap { store in
            (store as? any CloudDeleteOwning).map { (store.sourceId, $0) }
        })
        self.changed = changed
        self.automatic = automatic; self.pause = pause; self.turnsOnBySelf = turnsOnBySelf
        self.startAgainAvailable = startAgainAvailable; self.deadAfter = deadAfter; self.passkey = passkey
        self.spareOfferWait = spareOfferWait
        self.log = log
        owner.graph = self
    }

    /// One plain sentence per source whose last save to Cloud failed, for the `cloud.secrets` status answer.
    func failedSaves() -> [String] { sourceIds.compactMap { saveFailures[$0] } }

    /// A failure in plain words for the log (this Mac's own store refusals named; everything else `CloudSecretsLog.cause`).
    private static func cause(_ error: any Error) -> String {
        if error is BackendCloudRecoveryBlocked { return "the login store is blocked" }
        if error is BackendCloudRecoveryKeyLost { return "this Mac's own key for its saved passwords is lost" }
        if error is BackendCloudRecoveryNotConverted { return "this Mac's own saved passwords are not converted yet" }
        if error is BackendCloudSecretsKeyBlocked { return "this Mac cannot open its saved-password key right now" }
        return CloudSecretsLog.cause(error)
    }

    /// What the last step said about the login store: lane V's "Allow login store first" stays on the page until a
    /// later step gets through.
    private func note(_ error: (any Error)?) {
        guard let error else { loginStoreBlocked = nil; return }
        if let refusal = error as? BackendCloudRecoveryBlocked { loginStoreBlocked = refusal.errorDescription ?? refusal.reason }
    }
    /// The end of a PRESS on the Cloud page. Unlike the quiet steps (start, the service's notices), a press that did
    /// not finish is said on the page. The person closing a sheet is not a failure.
    private func notePress(_ error: (any Error)?) {
        note(error)
        // A blocked login store and a lost local key have their own state line; a closed sheet is no failure.
        guard let error, !(error is BackendCloudRecoveryBlocked), !(error is BackendCloudRecoveryKeyLost), !(error is BackendCloudRecoveryNotConverted),
              !(error is CancellationError) else { pressProblem = nil; return }
        pressProblem = BackendCloudSecretsWords.stepNotFinished
    }
    public func isSealed() -> Bool { sealed }
    /// The owners' own change observers; `stop` removes them. Removed at once if this identity is already sealed.
    public func observing(_ stop: @escaping @Sendable () -> Void) {
        if sealed { stop() } else { stopObserving = stop }
    }
    private func finishWaiting() async {
        do { _ = try await service.finishPendingAcknowledgement(); note(nil) } catch { note(error) }
    }
    /// At start: finish an acknowledgement the service never confirmed, or (key already here) join the sync core
    /// and send what changed since the last run. Never on a timer.
    public func catchUp() async {
        guard !sealed else { return }
        switch await service.protection() {
        case .waitingForCloud: await finishWaiting()
        case .protected:
            await captureAll()
            _ = await answerBySelf()
            // 14 Nov: the start line first. The spare offer below waits for the system passkey sheet, which waits for
            // him (the MacBook's sheet sat behind a locked screen and its start line was never written).
            await sayStart()
            // Slice 2: the spare key, once per generation, with only the system's passkey sheet. A spare made now drops
            // the start line's kept answer (it said "none yet").
            await offerSpare()
        case .locked: if opensItself { await openBySelf() }
        }
        await sayStart()
        changed()
    }
    /// The passkey's own offer (once per run, see the coordinator). PASSWORDS-5 point 3: after a short random wait, so
    /// two Macs started together do not both show it; the offer then reads the state fresh right before its sheet.
    private func offerSpare() async {
        guard passkey != nil else { return }
        if let spareOfferWait {
            changed()
            await spareOfferWait()
            guard !sealed, await service.protection() == .protected else { return }
        }
        if await service.offerSpareOnce(passkey: passkey) { kept = nil }
    }
    /// Gap 1c: ONE summary line at start (after an update too), so a watch after an install reads the state from the
    /// log with the screen locked.
    private func sayStart() async {
        guard !startSaid else { return }
        startSaid = true
        log.say("at start: " + (await summaryLine()))
    }
    /// Either automatic step is wired (the app); fixtures of the earlier presses wire neither and see no change.
    private var opensItself: Bool { turnsOnBySelf || automatic != nil }
    /// On by default (owner, 14 Nov). A Mac with no key: the account's FIRST device makes the key by itself (no
    /// sheet, no words); any later device asks the others by itself (automatic mode) and opens when one answers.
    /// Two first devices at once: the service takes one set-up; the other then simply asks.
    private func openBySelf() async {
        guard !sealed, let status = try? await service.status() else { return }
        if status.state == .unset {
            guard turnsOnBySelf else { return }
            log.say("turning on: nothing in Cloud yet, this Mac sets the Cloud copy up")
            do {
                try await service.setupSilently()
                log.say("set the Cloud copy up on this Mac (the first device of the account)")
                note(nil); turnOnFailed = false; cannotOpen = false
                // This Mac's existing logins go into the new vault at once.
                await captureAll()
                // Review point 4: a second Mac that asked meanwhile is answered now, not after its 10-minute re-ask.
                _ = await answerBySelf()
                // Slice 2: the account's first Mac makes the spare key (only the system's passkey sheet). The start line
                // is written first: the sheet waits for him.
                await sayStart()
                await offerSpare()
                return
            } catch is CancellationError { return }
            catch {
                log.say("turning on did not finish: " + Self.cause(error))
                note(error)
                guard let again = try? await service.status(), again.state == .ready, await service.protection() == .locked else {
                    // Could not turn on just now: the page offers "Turn on" to try again.
                    turnOnFailed = !(error is BackendCloudRecoveryBlocked)
                    return
                }
            }
        }
        // Review blocker 1: a set-up the service accepted whose key never reached this Mac's store opens from the
        // copy this Mac sealed for itself.
        if (try? await service.reopenOwnCopy()) == true {
            log.say("opened this Mac's own copy (a set-up that had not finished here)")
            note(nil); cannotOpen = false
            await captureAll()
            _ = await answerBySelf()
            return
        }
        // Review point 5: nobody can open the Cloud copy: said once, never "will open..." for ever. Still asked, so a
        // device that does hold it opens it here after all.
        spareCanOpen = await service.spareCanOpen(passkey: passkey)
        let epoch = (try? await service.status())?.epoch
        if await service.nobodyCanOpen(), heldElsewhereEpoch == nil || heldElsewhereEpoch != epoch {
            let now = policy.now(), since = nobodySince ?? now
            nobodySince = since
            cannotOpen = now - since >= deadAfter
        } else { nobodySince = nil; cannotOpen = false }
        if cannotOpen, !deadSaid {
            deadSaid = true
            log.say("no device can open the Cloud copy" + (startAgainAvailable ? "; Start again offered" : "") + (spareCanOpen ? "; Open with my passkey offered" : ""))
        } else if !cannotOpen { deadSaid = false }
        await askBySelf()
    }
    /// Automatic mode only: one request at a time, asked again by itself after it ran out (10 minutes), never a sheet.
    private func askBySelf() async {
        guard !sealed, let automatic, await automatic.on(), await service.protection() == .locked else { return }
        if let waiting = await service.waitingRequest(), waiting.expiresAt > policy.now() { return }
        let approval: CloudApproval
        do { approval = try await service.requestApproval() }
        catch { log.say("asking your other devices did not go out: " + Self.cause(error)); return }
        let strict = await service.askHint()
        log.say("asked your other devices; waiting (Opening…) for " + (strict ? "your click on one of your other computers (stricter setting on)" : "any of your other computers to answer by itself"))
        askAgain?.cancel()
        let wait = max(0, approval.expiresAt - policy.now()) + 1_000, pause = self.pause
        askAgain = Task { [weak self] in
            await pause(wait)
            guard !Task.isCancelled, let self else { return }
            await self.askAgainNow()
        }
    }
    private func askAgainNow() async {
        // Looks again whole: its own copy, the dead state, then a new request.
        if await service.protection() == .locked { await openBySelf() }
        changed()
    }
    /// Automatic mode only: answers every pending request of another device that passes all the coordinator's checks.
    /// Returns true when something was left for a person (or for a later look).
    private func answerBySelf() async -> Bool {
        guard !sealed, let automatic, await automatic.on(), await service.protection() == .protected,
              let status = try? await service.status() else { return false }
        let now = policy.now()
        var left = false
        for approval in status.pendingApprovals where approval.targetDeviceId != deviceId && approval.expiresAt > now {
            do {
                // The name comes from THIS Mac's trusted list (review point 8), never the service's label.
                if let name = try await service.answerAutomatically(id: approval.approvalId) {
                    log.say("answered a request from " + CloudSecretsLog.name(name) + " by itself")
                    openedOn.append(BackendCloudSecretsWords.openedOn(name, at: policy.now()))
                    if openedOn.count > 5 { openedOn.removeFirst(openedOn.count - 5) }
                } else { left = true }
            } catch {
                log.say("answering a request by itself failed: " + Self.cause(error))
                left = true
            }
        }
        return left
    }
    /// A request or a device change: answer now, and look twice more a moment later when something was left (this
    /// Mac's trusted-device list takes in a newly joined device a few seconds after the service lists it).
    private func answerSoon() async {
        for attempt in 0..<3 {
            guard await answerBySelf() else { break }
            if attempt < 2 { await pause(5_000) }
        }
    }
    /// Joins the sources (once) and sends what changed in each. Only while this Mac holds the confirmed key AND its
    /// own stores open: with a lost or blocked local key nothing joins and nothing is captured.
    private func captureAll() async {
        guard await localStanding() == .ready else { return }
        let failures = await registrar.registerAvailable()
        for id in sourceIds {
            if let error = failures[id] { note(error); failed(id, error) }
            else { await capture(id) }
        }
        if failures.isEmpty { note(nil) }
    }
    /// One source's save to Cloud. A failure is kept and named on the page (review B-M2), never dropped.
    private func capture(_ id: String) async {
        do {
            _ = try await service.captureChanged(sourceId: id)
            if saveFailures.removeValue(forKey: id) != nil {
                log.say("saving " + BackendCloudSecretsLeanCoverage.title(id) + " works again")
            }
        } catch { failed(id, error) }
    }
    private func failed(_ id: String, _ error: any Error) {
        // A blocked login store and a lost local key have their own state line; they are not a failed save.
        guard !(error is BackendCloudRecoveryBlocked), !(error is BackendCloudRecoveryKeyLost), !(error is BackendCloudRecoveryNotConverted), !(error is CancellationError) else { return }
        let reason = (error as? LocalizedError)?.errorDescription
        let words = BackendCloudSecretsWords.notSavedToCloud(BackendCloudSecretsLeanCoverage.title(id), reason: reason)
        if saveFailures[id] != words {
            // Only a fixed kind name and the secret-safe classification, never the error's text or a record.
            log.say("saving " + BackendCloudSecretsLeanCoverage.title(id) + " did not finish: " + Self.cause(error))
        }
        saveFailures[id] = words
    }
    /// "Sync now" on the Cloud page: the voice key and a renamed server have no change signal of their own.
    public func syncNow() async {
        guard !sealed, await service.protection() == .protected else { return }
        await captureAll()
        changed()
    }
    /// The person has seen the skipped items.
    public func dismissNotices() async {
        guard !sealed else { return }
        await service.dismissNotices()
        changed()
    }
    /// From the account's one event socket. `vault` is the service's saved-passwords notice {state, epoch, version};
    /// `approval` says another device asks to be allowed. Both arrive only on the signed-in, device-proved socket.
    public func event(_ event: CloudEvent) async {
        guard !sealed else { return }
        defer { kept = nil }
        // PASSWORDS-5 point 1: any notice may mean a spare was made elsewhere: an open passkey sheet here is withdrawn
        // (no service read unless a sheet is open).
        await service.withdrawSpareSheetIfMade()
        if event.type == "approval" || event.type == "devices" {
            if event.type == "devices" {
                // Review point 5: the device that held an unfinished set-up may be gone for good (removed): look again
                // whole, so "Opening…" never stays up until a restart.
                heldElsewhereEpoch = nil
                if opensItself, await service.protection() == .locked { await openBySelf() }
                // A device that held the key was signed out from another device: the key change may be due now.
                await lookAtKeyChange()
            }
            await answerSoon()
            changed(); return
        }
        // The sync core's socket has just (re)connected: it is about to fetch, at start, on waking and when the
        // network returns. Saved passwords capture at the same moments, never on a timer of their own.
        if event.type == "hello" {
            switch await service.protection() {
            case .protected:
                // A key change made while this Mac was away (or one still due) first, so it captures under the new key.
                await lookAtKeyChange()
                await captureAll()
                // Requests made while this Mac was away are answered now ("opens the moment one comes online").
                _ = await answerBySelf()
                changed()
            case .locked:
                if opensItself { await openBySelf(); changed() }
            case .waitingForCloud: break
            }
            return
        }
        guard event.type == "vault" else { return }
        if let epoch = event.payload.raw["epoch"].number, let whole = Int(exactly: epoch), whole > 0 { await service.noteCloudEpoch(whole) }
        switch await service.protection() {
        case .locked:
            // This Mac may have asked another device: its answer is what this notice announces. Quiet when nothing was asked.
            do { try await service.receiveApproval(); note(nil) }
            catch {
                // Quiet when nothing was asked (the coordinator refuses with invalidRequest then).
                if await service.waitingRequest() != nil { log.say("taking the answer did not finish: " + Self.cause(error)) }
                note(error)
            }
            if opensItself, await service.protection() == .protected { await captureAll() }
        case .waitingForCloud: await finishWaiting()
        case .protected:
            // This Mac asked for the NEW key after a key change (no copy was sealed for it): the notice is its answer.
            if await service.keyBehind(), await service.waitingRequest() != nil {
                do { try await service.receiveApproval(); note(nil); await captureAll() }
                catch { log.say("taking the new key did not finish: " + Self.cause(error)); note(error) }
            }
            await lookAtKeyChange()
        }
        changed()
    }
    /// Design B2/B3 (a lost Mac signed out from another device), on `vault`, `devices` and `hello` only, never a timer:
    /// take the new key's copy sealed for this Mac, or make the due key change here; behind with no copy for this Mac,
    /// ask his other devices for it exactly as a new Mac does. No sheet, no click; nothing local is deleted.
    private func lookAtKeyChange() async {
        guard !sealed, await service.protection() == .protected else { return }
        do {
            switch try await service.keyChange() {
            case .rotated, .tookCopy:
                note(nil)
                await captureAll()
            case .nothing:
                guard await service.keyBehind(), let automatic, await automatic.on() else { return }
                if let waiting = await service.waitingRequest(), waiting.expiresAt > policy.now() { return }
                do { _ = try await service.requestApproval(); log.say("asked your other devices for the new saved-passwords key") }
                catch { log.say("asking for the new saved-passwords key did not go out: " + Self.cause(error)) }
            }
        } catch is CancellationError { return }
        catch { log.say("the saved-passwords key change did not finish: " + Self.cause(error)); note(error) }
    }
    /// Design B4: this Mac was signed out by ANOTHER device. Its Cloud keys go (never his data); see
    /// `CloudSecretsLocalKeyForgetPort`. Works also after the graph was sealed by the sign-out.
    public func forgetKeysAfterRemoteSignOut() async {
        guard let port = local as? any CloudSecretsLocalKeyForgetPort else { return }
        do { try await port.forgetAfterRemoteSignOut(); log.say("signed out from another device: this Mac's Cloud keys were removed; everything else is kept") }
        catch { log.say("signed out from another device: this Mac's Cloud keys could not all be removed: " + Self.cause(error)) }
    }
    /// One of the owners says its saved values changed.
    public func sourceChanged(_ sourceId: String) async {
        guard !sealed, sourceIds.contains(sourceId) else { return }
        guard await service.protection() == .protected, await localStanding() == .ready else { return }
        let failures = await registrar.registerAvailable()
        if let error = failures[sourceId] { note(error); failed(sourceId, error) }
        else { await capture(sourceId); note(nil) }
        changed()
    }
    /// A press on the Cloud page. Each opens lane V's own sheet; the person finishes there.
    public func perform(_ action: Action, approvalId: String? = nil) async {
        guard !sealed else { return }
        defer { kept = nil }
        do {
            switch action {
            case .repairSpare:
                // Point 4 repair: his own press only (refused right after the app's own remote input, as the others).
                guard !pressRefused() else {
                    log.say("Make my spare key again refused: this Mac was just controlled from another device")
                    pressProblem = BackendCloudSecretsWords.pressRefused; changed(); return
                }
                guard let passkey else { throw CloudFailure.unavailable }
                switch await service.repairSpare(passkey: passkey) {
                case .stillWorks: spareNote = BackendCloudSecretsWords.spareStillWorks
                case .replaced, .cancelled: spareNote = nil
                case .notDone(let why): spareNote = BackendCloudSecretsWords.spareNotRepaired(why)
                }
            case .makeSpare:
                // Gap 2: his own press only (refused right after the app's own remote input, as the other presses).
                guard !pressRefused() else {
                    log.say("Make a passkey spare key refused: this Mac was just controlled from another device")
                    pressProblem = BackendCloudSecretsWords.pressRefused; changed(); return
                }
                guard let passkey else { throw CloudFailure.unavailable }
                switch await service.makeSpare(passkey: passkey) {
                case .added, .cancelled, .notOffered: break
                case .failed: throw CloudFailure.unavailable
                }
            case .setup:
                // Condition (d): after an interrupted set-up the key this Mac already sealed for itself opens first;
                // only an account with nothing in Cloud is set up afresh.
                log.say("Turn on pressed")
                if (try? await service.reopenOwnCopy()) == true {
                    log.say("opened this Mac's own copy (a set-up that had not finished here)")
                    turnOnFailed = false; cannotOpen = false
                    await captureAll()
                } else {
                    try await service.setupSilently()
                    log.say("set the Cloud copy up on this Mac (the first device of the account)")
                    turnOnFailed = false
                    await captureAll()
                }
            case .startAgain:
                guard startAgainAvailable else { throw CloudFailure.unavailable }
                // Review blocker 4: not after the app's own remote input.
                guard !pressRefused() else {
                    log.say("Start again refused: this Mac was just controlled from another device")
                    pressProblem = BackendCloudSecretsWords.pressRefused; changed(); return
                }
                log.say("Start again pressed")
                // Its own copy first (an interrupted set-up on THIS Mac is not "nobody").
                if (try? await service.reopenOwnCopy()) == true {
                    log.say("opened this Mac's own copy instead of starting again")
                    cannotOpen = false; await captureAll(); break
                }
                do { try await service.startAgain(); log.say("started again: a fresh Cloud copy from this Mac") }
                catch CloudFailure.remote(let detail) where detail.code == "not_approved" {
                    // Condition (c): a device still holds this generation (or is still setting it up): not dead.
                    log.say("Start again refused by the service: a device still holds this copy; waiting for it")
                    heldElsewhereEpoch = (try? await service.status())?.epoch
                    cannotOpen = false; nobodySince = nil
                    await askBySelf()
                    break
                }
                cannotOpen = false
                await captureAll()
            case .openWithPasskey:
                guard let passkey else { throw CloudFailure.unavailable }
                log.say("Open with my passkey pressed")
                do { try await service.openWithSpare(passkey: passkey) }
                catch is CancellationError { log.say("open with your passkey: sheet cancelled"); throw CancellationError() }
                catch { log.say("open with your passkey did not finish: " + Self.cause(error)); throw error }
                cannotOpen = false; spareCanOpen = false
                await captureAll()
            case .requestDevice:
                _ = try await service.requestApproval()
                log.say("asked another device (your press)")
            case .recover: try await service.beginRecovery()
            case .openApproval:
                guard let approvalId else { throw CloudFailure.invalidRequest }
                try await service.openApproval(id: approvalId)
            }
            notePress(nil)
        } catch {
            if !(error is CancellationError), action != .openWithPasskey, action != .makeSpare, action != .repairSpare {
                log.say(action.rawValue + " did not finish: " + Self.cause(error))
            }
            notePress(error)
        }
        changed()
    }
    /// The stricter setting's switch on the Cloud page (owner's press only; no tool reaches this).
    public func setAskOnNewDevice(_ value: Bool) async {
        guard !sealed else { return }
        defer { kept = nil }
        // Review blocker 4: not after the app's own remote input (as the trust presses).
        guard !pressRefused() else {
            log.say("the stricter setting was not changed: this Mac was just controlled from another device")
            pressProblem = BackendCloudSecretsWords.pressRefused; changed(); return
        }
        do {
            let carried = try await service.setAskOnNewDevice(value)
            log.say("stricter setting (ask on each new device) switched " + (value ? "on" : "off") + " here; "
                    + (carried ? "carried to your other devices" : "kept on this Mac only"))
            pressProblem = nil
        } catch {
            log.say("the stricter setting could not be changed: " + Self.cause(error))
            notePress(error)
        }
        changed()
    }
    /// "Add…" on the waiting list: lane V's sheet shows everything that would run; only the click there adds it.
    public func addWaiting(_ id: String) async {
        guard !sealed, let mcp else { return }
        do { _ = try await mcp.add(id); pressProblem = nil } catch { notePress(error) }
        changed()
    }
    public func dismissWaiting(_ id: String) async {
        guard !sealed, let mcp else { return }
        do { try await mcp.dismiss(id); pressProblem = nil } catch { notePress(error) }
        changed()
    }
    /// The sign-out guard's first question (R5, security review S17): does THIS MAC hold a saved-passwords key?
    /// Lane V's own fact (`signOutState().keyOnThisMac`): true also for a key that waits for Cloud or cannot be
    /// read right now, because sign-out would strand that key too.
    public func keyHeld() async -> Bool {
        guard !sealed else { return false }
        return await service.signOutState().keyOnThisMac
    }
    /// The sign-out guard's question (R5): does Cloud hold the recovery copy the confirmed recovery words open?
    /// Lane V's own fact (`recoveryWordsOnFile`). Throws when Cloud could not be asked: the account then says
    /// "could not be asked", not "not confirmed".
    public func recoveryWordsConfirmed() async throws -> Bool {
        guard !sealed else { return false }
        let state = await service.signOutState()
        // Set up silently (no words exist): nothing for him to confirm; the last-device warning says what is lost.
        if state.withoutWords { return true }
        guard let onFile = state.recoveryWordsOnFile else { throw CloudFailure.unavailable }
        return onFile
    }
    /// The last-device warning: an older account whose Cloud copy the recovery words still open.
    public func recoveryWordsOnFile() async -> Bool {
        guard !sealed else { return false }
        return await service.signOutState().recoveryWordsOnFile == true
    }
    public func page() async -> BackendCloudSecretsPage {
        var page = BackendCloudSecretsPage()
        guard !sealed else { return page }
        page.problem = pressProblem
        page.turnOnFailed = turnOnFailed
        page.notSaved = notSaved
        let bySource = await service.gaps()
        page.gaps = Array(Set(bySource.values.flatMap { $0 })).sorted() + sourceIds.compactMap { saveFailures[$0] }
        page.gapKinds = sourceIds.filter { bySource[$0]?.isEmpty == false || saveFailures[$0] != nil }.map(BackendCloudSecretsLeanCoverage.title)
        let closed = await service.notices()
        page.skipped = closed.keys.sorted().map { reason in "\(closed[reason] ?? 0): " + reason }
        if let mcp {
            do {
                let items = try await mcp.pendingItems()
                page.waiting = items.map { BackendCloudSecretsPage.Waiting(id: $0.id, title: $0.title, removed: $0.kind == .removed) }
            } catch {
                // Review B-M2: a list that cannot be read is "could not check", never "nothing waits".
                page.couldNotCheck = true
            }
        }
        var keyBlocked: String?
        do { _ = try await local.read() }
        catch let refusal as BackendCloudSecretsKeyBlocked { keyBlocked = refusal.errorDescription ?? "This Mac can't open its saved-password key right now." }
        catch {}
        let protection = await service.protection()
        let state = await content.state(storageClass: .secrets)
        let status = try? await service.status()
        var ahead: String?
        if !state.available, state.epoch > 0 { ahead = state.reason ?? "Saved passwords were started anew on another device." }
        page.cloudKeyHere = protection != .locked
        page.openedOn = Array(openedOn.suffix(1))
        if protection == .locked, status?.state == .ready {
            page.cannotOpen = cannotOpen
            page.startAgainAvailable = cannotOpen && startAgainAvailable
            page.opensWithPasskey = spareCanOpen
            if !cannotOpen, let automatic {
                page.opensBySelf = await automatic.on()
                if page.opensBySelf { page.waitsForClick = await service.askHint() }
            }
        }
        if protection == .protected, automatic != nil {
            let ask = await service.askState()
            page.askOnNewDevice = ask.on; page.askOffElsewhere = ask.offElsewhere; page.askThisMacOnly = ask.thisMacOnly
            page.phonesOff = await service.phonesOff()
        }
        if protection == .protected, let passkey, await passkey.available(), let made = await service.spareMade() {
            page.spareMade = BackendCloudSecretsWords.spareMade(made.name, at: made.at)
        }
        if page.spareMade == nil { page.canMakeSpare = await canMakeSpare() }
        // PASSWORDS-5 point 1: a fresh look at the page also withdraws a sheet whose spare was made elsewhere meanwhile.
        if await service.withdrawSpareSheetIfMade() { page.spareMade = nil; page.canMakeSpare = false }
        // Point 4: the warning and its one repair control (service 7750c816e replaces a spare of the same generation).
        if protection == .protected, await service.spareOrphaned() {
            page.spareWarning = BackendCloudSecretsWords.spareOrphaned
            page.canRepairSpare = passkey != nil
        }
        page.spareNote = spareNote
        if let replaced = await service.spareReplaced() {
            page.spareReplaced = BackendCloudSecretsWords.spareReplaced(replaced.name, at: replaced.at)
        }
        // Review point 7: offered only where recovery words exist (never after a silent set-up).
        page.offersRecoveryWords = await service.recoveryWordsExist() == true
        // This Mac's own stores (lane V's local-store check): blocked = "Allow login store"; key lost = said as it
        // is, with no button that cannot help.
        var storeBlocked = loginStoreBlocked, storeKeyLost: String?, storeCannotCheck: String?
        let setUp = status?.state != .unset
        page.cloudSetUp = status.map { $0.state != .unset } ?? false
        let local = await localStanding()
        switch local {
        case .ready: break
        case .blocked: if storeBlocked == nil { storeBlocked = local.words(cloudKeyHere: page.cloudKeyHere) }
        case .keyLost: storeKeyLost = local.words(cloudKeyHere: page.cloudKeyHere, cloudSetUp: setUp)
        case .cannotCheck: storeCannotCheck = local.words(cloudKeyHere: page.cloudKeyHere, cloudSetUp: setUp) ?? "This Mac's own saved passwords could not be checked right now."
        // Not converted yet: said as it is, with only "Check again" (which converts when macOS need not ask).
        case .notConverted: storeCannotCheck = local.words(cloudKeyHere: page.cloudKeyHere, cloudSetUp: setUp)
        }
        page.standing = BackendCloudSecretsPage.standing(keyBlocked: keyBlocked, loginStoreBlocked: storeBlocked, keyLost: storeKeyLost,
            cannotCheck: storeCannotCheck, protection: protection,
            available: state.available, cloudAhead: ahead, vault: status?.state)
        // Review blocker 1 and point 6: only computers' requests, never one whose signature does not verify.
        if page.standing == .protected, status != nil {
            page.approvals = await service.approvalsForPerson().map { BackendCloudSecretsPage.Approval(id: $0.approvalId, expiresAt: $0.expiresAt) }
        }
        track(BackendCloudSecretsWords.state(page))
        return page
    }
    /// 15 Nov: "Keep saved passwords and secret files off my phones" (owner's press on the Cloud page only; no tool reaches
    /// this). On: no phone is handed the key from now on, and the sealed shelf leaves the Cloud (`shelfSealed` says so).
    public func setPhonesOff(_ value: Bool) async {
        guard !sealed else { return }
        defer { kept = nil }
        guard !pressRefused() else {
            log.say("the phones setting was not changed: this Mac was just controlled from another device")
            pressProblem = BackendCloudSecretsWords.pressRefused; changed(); return
        }
        do {
            let carried = try await service.setPhonesOff(value)
            log.say("saved passwords " + (value ? "kept off your phones" : "on your phones again") + " from this Mac; "
                    + (carried ? "carried to your other devices" : "kept on this Mac only"))
            pressProblem = nil
        } catch {
            log.say("the phones setting could not be changed: " + Self.cause(error))
            notePress(error)
        }
        changed()
    }

    /// What the sealed shelf may carry right now (15 Nov).
    public enum ShelfSealed: Sendable {
        /// His records exactly as the sync core gets them, with the sealer of the current key generation.
        /// `failed`: the sources that could not be read this round (source id -> fixed reason words, never a name or a
        /// value). Their records are absent; the round decides what that means (BackendCloudShelfSealedRound).
        case ready(sealer: CloudSecretsShelfSealer, records: [CloudSecretRecord], projectNames: [String: String], failed: [String: String])
        /// His setting keeps saved passwords off his phones: both sealed kinds leave the shelf.
        case keptOff
        /// Locked, not set up, signed out, or a source could not be read this round: nothing is put (and nothing cleared).
        case notNow
    }
    /// The sealed shelf's material for one round. Never logged, never a tool answer: the records live in memory for the
    /// round only. 15 Nov fix: a source that cannot be read no longer stops the whole round; it is named in `failed`
    /// and the round keeps what his phones already show of it (BackendCloudShelfSealedRound).
    public func shelfSealed() async -> ShelfSealed {
        guard !sealed, await service.protection() == .protected else { return .notNow }
        if await service.phonesOff() { return .keptOff }
        let state = await content.state(storageClass: .secrets)
        guard state.available, state.epoch > 0, let sealer = try? await content.shelfSealer(epoch: state.epoch) else { return .notNow }
        var records: [CloudSecretRecord] = []
        var failed: [String: String] = [:]
        for adapter in adapters {
            let found: [CloudSecretRecord]
            do { found = try await adapter.exportRecords() }
            catch { failed[adapter.sourceId] = BackendCloudShelfSealed.reason(error); continue }
            // Too large to sync is too large for the shelf (the sync core's own estimate).
            records += found.filter { record in
                guard let plain = try? CloudSecretsCanonical.encode(record) else { return false }
                return (plain.count + 2) / 3 * 4 + 1024 <= CloudWire.maximumRecordPayloadBytes
            }
        }
        var names: [String: String] = [:]
        if let projectFiles { names = await projectFiles.projectNames() }
        return .ready(sealer: sealer, records: records, projectNames: names, failed: failed)
    }

    /// Cloud file manager (owner, 15 Nov: "a saved password's value shows only after a click on Show"): the value of
    /// ONE saved password, read from this Mac's own store for that source, for the person's own press of "Show" in the
    /// Cloud page's reading pane. Never a tool, never logged, never kept: the page holds it until the selection changes.
    /// nil while locked or sealed, when this Mac does not hold it, or when it is not one plain value.
    public func revealValue(sourceId: String, recordId: String) async -> String? {
        guard !sealed, await service.protection() == .protected else { return nil }
        // Review fix 8: an MCP server, a server key or a Receiver record is not one plain value (its only plain text
        // can be the sending Mac's name or a source name): nothing is shown for them.
        guard Self.revealable(sourceId: sourceId) else { return nil }
        for adapter in adapters where adapter.sourceId == sourceId {
            guard let records = try? await adapter.exportRecords(),
                  let record = records.first(where: { $0.recordId == recordId }) else { continue }
            return Self.plainValue(record.payload.raw)
        }
        return nil
    }
    /// The one value a saved password holds: the text itself, or the one secret field of its record.
    static func revealable(sourceId: String) -> Bool { !["mcp-user", "ssh", "receiver"].contains(sourceId) }
    static func plainValue(_ raw: NativeRPCValue) -> String? {
        if case .string(let text) = raw { return text.isEmpty ? nil : text }
        guard let fields = raw.fields else { return nil }
        for name in ["value", "secret", "password", "token", "key", "apiKey", "privateKey"] {
            if let field = fields.first(where: { $0.key == name }), case .string(let text) = field.value, !text.isEmpty { return text }
        }
        let texts = fields.compactMap { field -> String? in if case .string(let text) = field.value, !text.isEmpty { return text }; return nil }
        return texts.count == 1 ? texts[0] : nil
    }

    /// Gap 2: "Make a passkey spare key" is offered while this Mac holds the key, the passkey works here and the service
    /// says this generation has no spare.
    private func canMakeSpare() async -> Bool {
        guard let passkey, await service.protection() == .protected, await passkey.available() else { return false }
        return await service.spareMissing()
    }
    /// The page's state word, remembered with the time it began (said in the log when it changes).
    private func track(_ word: String) {
        guard stateSince?.word != word else { return }
        kept = nil
        let first = stateSince == nil
        stateSince = (word, policy.now())
        if !first { log.say("state now: " + word) }
    }
    /// One line of the whole state, for the start line.
    private func summaryLine() async -> String {
        let facts = await keptFacts()
        var parts = ["state " + facts.state]
        if let from = facts.copyFrom { parts.append("this Mac's copy from " + from) }
        // 14 Nov: a count the service did not answer is "not read yet", never 0 (a 0 reads as "nobody can open it").
        parts.append("devices that can open it " + (facts.devices.map(String.init) ?? "not read yet")
            + (facts.names.isEmpty ? "" : " (known here: " + facts.names.joined(separator: ", ") + ")"))
        if let strict = facts.strict { parts.append("stricter setting here " + (strict ? "on" : "off")) }
        parts.append("passkey spare key " + facts.spare)
        return parts.joined(separator: "; ")
    }
    private struct SummaryFacts {
        var state: String; var since: Int64?; var copyFrom: String?; var devices: Int?; var names: [String]; var strict: Bool?; var spare: String
        var spareBy: String?; var spareAt: Int64?
    }
    /// The kept answer while it is under 30 seconds old; otherwise one fresh round of requests, kept.
    private func keptFacts() async -> SummaryFacts {
        let now = policy.now()
        if let kept, now >= kept.at, now - kept.at < Self.keptFor { return kept.facts }
        let fresh = await summaryFacts()
        kept = (now, fresh)
        return fresh
    }
    private func summaryFacts() async -> SummaryFacts {
        let shown = await page()
        let word = BackendCloudSecretsWords.state(shown)
        let status = try? await service.status()
        var spare = "not available on this Mac", spareBy: String?, spareAt: Int64?
        if let passkey, await passkey.available() {
            if let made = await service.spareMade() {
                spareBy = CloudSecretsLog.name(made.name ?? "this Mac"); spareAt = made.at
                spare = "made on " + (spareBy ?? "this Mac") + ", " + CloudSecretsLog.date(made.at)
            } else { spare = shown.canMakeSpare ? "none yet" : "none known" }
        }
        let protected = await service.protection() == .protected
        // Point 8: copyFrom first (the device that sealed this Mac's copy holds the key, and is then listed below).
        let copyFrom = protected ? await service.copyFrom() : nil
        var names = await service.holdersKnownHere()
        if let copyFrom, !names.isEmpty, !names.contains(copyFrom) { names.append(copyFrom) }
        return SummaryFacts(state: word, since: stateSince?.at, copyFrom: copyFrom,
                            devices: status?.approvedDeviceCount, names: names,
                            strict: shown.askOnNewDevice, spare: spare, spareBy: spareBy, spareAt: spareAt)
    }
    /// Gap 1b: what the read-only `cloud.secrets.status` answers. Names, counts, dates and plain words only.
    public func summary() async -> NativeRPCValue {
        guard !sealed else { return .object([.init("state", .string("signed out"))]) }
        let facts = await keptFacts()
        func text(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
        return .object([
            .init("state", .string(facts.state)),
            .init("since", text(facts.since.map(CloudSecretsLog.date))),
            .init("copyFrom", text(facts.copyFrom)),
            .init("devicesThatCanOpen", facts.devices.map { .number(Double($0)) } ?? .null),
            .init("devicesKnownHere", .array(facts.names.map(NativeRPCValue.string))),
            .init("stricterSettingHere", facts.strict.map(NativeRPCValue.bool) ?? .null),
            .init("passkeySpare", .string(facts.spare)),
            .init("passkeySpareMadeOn", text(facts.spareBy)),
            .init("passkeySpareMadeAt", text(facts.spareAt.map(CloudSecretsLog.date))),
            .init("note", .string("copyFrom is the device that sealed this Mac's copy of the key (\"this Mac\" where it set the copy up). The service counts the devices that can open it; it names none, so devicesKnownHere lists only what this Mac knows."))
        ])
    }
    /// Sign-out or a closed gate: the tool stops, lane V's sheets close, observers go, the gate closes for good.
    public func seal() async {
        guard !sealed else { return }
        sealed = true
        askAgain?.cancel(); askAgain = nil
        stopObserving?(); stopObserving = nil
        await tools.stop()
        await service.seal()
        await gate?.seal()
        changed()
    }
}

extension BackendCloudSecretsServerPort {
    /// Uses the Servers owner's ONE credentials object. No new password store and no direct Keychain access.
    public func deleteRuleStore(stateRoot: URL, gate: @escaping @Sendable () async -> Bool,
                                macName: @escaping @Sendable (String) async -> String? = { _ in nil },
                                serviceClock: @escaping @Sendable () async -> Int64? = { nil },
                                now: @escaping @Sendable () -> Int64) -> BackendProjectSecretFilesSavedDeleteOwner {
        let credentials = credentials
        return .init(store: store, stateRoot: stateRoot, gate: gate, name: { record in
            (try? BackendCloudSecretsRecords.decode(BackendCloudSecretsServerValue.self, record, source: record.sourceId, domain: .server))?.server?.name ?? "Server sign-in"
        }, remove: { record in
            do {
                let value = try BackendCloudSecretsRecords.decode(BackendCloudSecretsServerValue.self, record, source: record.sourceId, domain: .server)
                guard try credentials.read(record.recordId) == value.credential() else { return false }
                let outcome = try credentials.forget(record.recordId)
                guard outcome.ok else { throw CloudFailure.unavailable }
                return try credentials.read(record.recordId) == nil
            } catch { throw CloudFailure.unavailable }
        }, macName: macName, serviceClock: serviceClock, now: now)
    }
}

public enum BackendCloudSecretsSavedDeleteOwners {
    public static func voice(_ owner: BackendOSVoiceService, stateRoot: URL, gate: @escaping @Sendable () async -> Bool,
                             macName: @escaping @Sendable (String) async -> String? = { _ in nil },
                             serviceClock: @escaping @Sendable () async -> Int64? = { nil },
                             now: @escaping @Sendable () -> Int64) -> BackendProjectSecretFilesSavedDeleteOwner {
        .init(store: BackendCloudSecretsVoiceStore(sourceId: "voice", owner: owner), stateRoot: stateRoot, gate: gate,
              name: { _ in "Voice key" }, remove: { record in
            do {
                let value = try BackendCloudSecretsRecords.decode(BackendCloudSecretsVoiceValue.self, record, source: "voice", domain: .app)
                guard try await owner.cloudSavedKey() == value else { return false }
                try await owner.forget()
                return try await owner.cloudSavedKey() == nil
            } catch { throw CloudFailure.unavailable }
        }, macName: macName, serviceClock: serviceClock, now: now)
    }
}
