import Foundation
import Darwin
import TerminalDeckNativeCore

/// A projection, not another PTY/parser/replay owner. Delivery and attach/reset
/// share one queue so an old connection cannot publish into a new attachment.
public final class BackendHOSTClient: @unchecked Sendable {
    /// L8 (11 Oct, helper crash recovery): the host this ONE client talks to. Every owner in the app (accounts,
    /// tool leases, project tools, the launcher's bridge, usage) holds this same object; when the host dies and a
    /// new one is started on the same private socket, `adopt` moves the client to it and every owner follows.
    public var hello: BackendHOSTProtocol.Hello { helloLock.withLock { currentHello } }
    private var currentHello: BackendHOSTProtocol.Hello
    private let helloLock = NSLock()
    public let paths: BackendHOSTPaths
    private let secret: String
    private let delivery = DispatchQueue(label: "dev.terminaldeck.host.client", qos: .userInteractive)
    private let deliveryKey = DispatchSpecificKey<UInt8>()
    private var stream: BackendHOSTConnection?
    private var generation: UUID?
    private var connected = false
    private var snapshots: [String: BackendHOSTProtocol.Snapshot] = [:]
    private var order: [String] = []
    private var epochs: [String: UInt64] = [:]
    private var removed: Set<String> = []
    /// 22 Oct: finished job histories the app is opening again (`readmit`); see BackendHOSTManagerBridge.readmit.
    private var readmitting: Set<String> = []
    private var deliveredRemovals: Set<String> = []
    private var deliveredExits: Set<String> = []
    private var terminalFacts: [String: BackendHOSTProtocol.Event] = [:]
    private var pending: [String: [BackendHOSTProtocol.Event]] = [:]
    private var pendingBytes = 0
    private struct Callbacks: Sendable {
        var snapshot: @Sendable (BackendHOSTProtocol.Snapshot) -> Void
        var event: @Sendable (BackendHOSTProtocol.Event) -> Void
        var ready: @Sendable () -> Void
        var disconnect: @Sendable () -> Void
    }
    private var callbacks: Callbacks?
    public var isConnected: Bool { serialized { connected } }

    public init(paths: BackendHOSTPaths) throws {
        self.paths = paths; secret = try paths.secret(create: false)
        let fd = try BackendHOSTSocket.connect(paths.socket)
        defer { Darwin.close(fd) }
        try BackendHOSTSocket.write(BackendHOSTProtocol.Request(secret: secret, operation: .hello), to: fd,
                                    maximum: BackendHOSTProtocol.maximumRequestBytes)
        let response = try BackendHOSTSocket.read(BackendHOSTProtocol.Response.self, from: fd)
        guard let hello = response.hello else { throw BackendHOSTFailure.authentication }
        guard hello.protocolVersion == BackendHOSTProtocol.version else { throw BackendHOSTFailure.incompatible(hello.protocolVersion) }
        currentHello = hello
        delivery.setSpecific(key: deliveryKey, value: 1)
    }
    /// Move to the host that now answers on this socket (a NEW instance after a crash). Its sessions are its
    /// own; the old instance's cached state and watch stream are dropped (the bridge re-attaches). Refuses a
    /// host of another protocol, another data folder or with another secret: same safety as the first connect.
    public func adopt(_ fresh: BackendHOSTClient) throws {
        guard fresh.paths.socket == paths.socket, fresh.secret == secret else { throw BackendHOSTFailure.authentication }
        let next = fresh.hello
        guard next.protocolVersion == BackendHOSTProtocol.version else { throw BackendHOSTFailure.incompatible(next.protocolVersion) }
        serialized {
            stream?.shutdown(); stream = nil; generation = nil; connected = false; callbacks = nil
            snapshots.removeAll(); order.removeAll(); epochs.removeAll(); removed.removeAll(); readmitting.removeAll()
            deliveredRemovals.removeAll(); deliveredExits.removeAll(); terminalFacts.removeAll(); pending.removeAll(); pendingBytes = 0
        }
        helloLock.withLock { currentHello = next }
    }

    public func attach(onSnapshot: @escaping @Sendable (BackendHOSTProtocol.Snapshot) -> Void,
                       onEvent: @escaping @Sendable (BackendHOSTProtocol.Event) -> Void,
                       onReady: @escaping @Sendable () -> Void,
                       onDisconnect: @escaping @Sendable () -> Void) throws {
        let connection = BackendHOSTConnection(fd: try BackendHOSTSocket.connect(paths.socket))
        try BackendHOSTSocket.secure(connection.fd, timeoutSeconds: 0)
        let token = UUID()
        serialized {
            stream?.shutdown(); stream = connection; generation = token; connected = false
            snapshots.removeAll(); order.removeAll(); epochs.removeAll(); removed.removeAll(); readmitting.removeAll()
            deliveredRemovals.removeAll(); deliveredExits.removeAll(); terminalFacts.removeAll(); pending.removeAll(); pendingBytes = 0
            callbacks = .init(snapshot: onSnapshot, event: onEvent, ready: onReady, disconnect: onDisconnect)
        }
        do { try BackendHOSTSocket.write(request(.watch), to: connection.fd, maximum: BackendHOSTProtocol.maximumRequestBytes) }
        catch {
            setupFailed(token)
            connection.shutdown(); throw error
        }
        DispatchQueue.global(qos: .utility).async { [weak self, connection] in
            guard let self else { connection.shutdown(); return }
            do {
                while true {
                    let response = try BackendHOSTSocket.read(BackendHOSTProtocol.Response.self, from: connection.fd, allowIdle: true)
                    let active = try consume(response, token: token)
                    if !active { break }
                }
            } catch {
                serialized {
                    guard generation == token else { return }
                    connected = false; stream = nil; generation = nil
                    let callback = callbacks?.disconnect; callbacks = nil; callback?()
                }
            }
            connection.shutdown()
        }
    }

    private func consume(_ response: BackendHOSTProtocol.Response, token: UUID) throws -> Bool {
        try serialized {
            guard generation == token else { return false }
            if let error = response.error { throw BackendHOSTFailure.remote(error) }
            if let snapshot = response.snapshot { try install(snapshot) }
            else if response.ready == true { connected = true; callbacks?.ready() }
            else if let event = response.event { _ = try event.sessionEvent(); try accept(event) }
            else { throw BackendHOSTFailure.invalid("Invalid host stream frame.") }
            return generation == token
        }
    }
    private func setupFailed(_ token: UUID) {
        serialized {
            guard generation == token else { return }
            stream?.shutdown(); stream = nil; generation = nil; connected = false; callbacks = nil
        }
    }

    // Deterministic receipt-order seam. Tests exercise the real delivery path
    // without depending on OS scheduling to reproduce an app teardown race.
    func hostTestingGeneration() -> UUID? { serialized { generation } }
    func hostTestingReceive(_ response: BackendHOSTProtocol.Response, generation: UUID) throws {
        _ = try consume(response, token: generation)
    }
    func hostTestingSetupFailed(generation: UUID) { setupFailed(generation) }

    private func install(_ value: BackendHOSTProtocol.Snapshot) throws {
        let id = value.session.id
        let originalGeneration = generation
        if removed.contains(id) {
            // Only the snapshot of a history the app asked to open again comes back, as a new row whose own later
            // exit and removal are delivered again. Any other late snapshot never resurrects a removed row.
            guard readmitting.remove(id) != nil else { return }
            removed.remove(id); deliveredRemovals.remove(id); deliveredExits.remove(id); terminalFacts[id] = nil
        }
        guard value.sequence >= (snapshots[id]?.sequence ?? 0) else { return }
        if snapshots[id] == nil { order.append(id) }
        var projection = value
        if let terminal = terminalFacts[id], terminal.sequence > value.sequence {
            projection.session.exitCode = terminal.exitCode; projection.pid = nil; projection.status = .exited
        }
        projection.replay = ""; projection.screen = nil; projection.scrollbackText = nil
        snapshots[id] = projection; epochs[id, default: 0] &+= 1
        var presented = value
        presented.session = projection.session; presented.pid = projection.pid; presented.status = projection.status
        callbacks?.snapshot(presented)
        guard generation == originalGeneration else { return }
        let waiting = pending.removeValue(forKey: id) ?? []
        for event in waiting {
            guard generation == originalGeneration else { return }
            pendingBytes -= (event.text?.utf8.count ?? 0) + 512
            if event.kind == .exit || event.kind == .removed || event.sequence > value.sequence { try accept(event) }
        }
    }

    private func accept(_ event: BackendHOSTProtocol.Event) throws {
        let id = event.id
        // Removal and process exit are different receipts. Removing a tab
        // must not suppress the later exit that releases its account leases.
        if event.kind == .removed {
            removed.insert(id); snapshots[id] = nil; order.removeAll { $0 == id }
            for waiting in pending.removeValue(forKey: id) ?? [] {
                pendingBytes -= (waiting.text?.utf8.count ?? 0) + 512
                if waiting.kind == .exit, deliveredExits.insert(id).inserted { callbacks?.event(waiting) }
            }
            if deliveredRemovals.insert(id).inserted { callbacks?.event(event) }
            return
        }
        if event.kind == .exit {
            terminalFacts[id] = event
            if snapshots[id] == nil, !removed.contains(id) { try buffer(event); return }
            if var value = snapshots[id] {
                value.sequence = max(value.sequence, event.sequence); value.session.exitCode = event.exitCode
                value.pid = nil; value.status = .exited; snapshots[id] = value; epochs[id, default: 0] &+= 1
            }
            if deliveredExits.insert(id).inserted { callbacks?.event(event) }
            return
        }
        guard !removed.contains(id) else { return }
        guard var value = snapshots[id] else {
            try buffer(event); return
        }
        guard event.sequence > value.sequence else { return }
        value.sequence = event.sequence; epochs[id, default: 0] &+= 1
        switch event.kind {
        case .exit: value.session.exitCode = event.exitCode; value.pid = nil; value.status = .exited
        case .status: if let status = event.status { value.status = status }
        case .removed:
            return // handled independently above
        case .data: break
        }
        snapshots[id] = value; callbacks?.event(event)
    }
    private func buffer(_ event: BackendHOSTProtocol.Event) throws {
        let bytes = (event.text?.utf8.count ?? 0) + 512
        guard pendingBytes + bytes <= 8 * 1024 * 1024 else { throw BackendHOSTFailure.unavailable }
        pendingBytes += bytes; pending[event.id, default: []].append(event)
    }

    /// The next snapshot of this removed row is accepted once (a finished job's history opened again).
    public func readmit(_ id: String) { serialized { _ = readmitting.insert(id) } }
    public func cachedSessions() -> [BackendSessionMeta] { serialized { order.compactMap { snapshots[$0]?.session } } }
    public func cachedPID(_ id: String) -> Int32? { serialized { connected ? snapshots[id]?.pid : nil } }
    /// The last status the event stream gave this session (no snapshot asked for).
    public func cachedStatus(_ id: String) -> BackendSessionStatus? { serialized { snapshots[id]?.status } }
    public func list() throws -> [BackendSessionMeta] {
        guard let value = try call(request(.list)).sessions else { throw BackendHOSTFailure.invalid("Missing host session list.") }; return value
    }
    public func snapshot(_ id: String, remount: Bool = false) throws -> BackendHOSTProtocol.Snapshot? {
        var value = request(.snapshot, id: id); if remount { value.remount = true }
        return try call(value).snapshot
    }
    /// The visible screen only (an older helper answers its full snapshot; only `screen` is used).
    /// HOSTLOST (9 Oct): after the stream drops, is the SAME host instance still answering?
    /// true = a transient drop; false = a different host (it died and launchd started a new,
    /// empty one) or none at all within the probe. Never sends anything but `hello`.
    public func sameHostAnswers() -> Bool {
        guard let fresh = try? BackendHOSTClient(paths: paths) else { return false }
        return fresh.hello.instance == hello.instance && fresh.hello.hostPID == hello.hostPID
    }
    public func viewport(_ id: String) throws -> String? {
        var value = request(.snapshot, id: id); value.viewportOnly = true
        return try call(value).snapshot?.screen
    }

    public func create(_ launch: BackendHOSTProtocol.Launch) throws -> BackendSessionMeta {
        // The app's authoritative callback may need MainActor. Never block it
        // while waiting for the helper's reverse authorization call.
        if BackendPCDecisionDelivery.required, Thread.isMainThread { throw BackendPCDecisionHostValidation.held() }
        let prepared = try prepareCreate(launch)
        defer { BackendPCDecisionHostValidation.revoke(prepared.pcDecision) }
        return try performCreate(prepared)
    }
    /// Capture app-local authority before the detached socket hop. Cancellation
    /// revokes even a ticket already inside its authoritative callback await.
    public func createAsync(_ launch: BackendHOSTProtocol.Launch) async throws -> BackendSessionMeta {
        let prepared = try prepareCreate(launch)
        defer { BackendPCDecisionHostValidation.revoke(prepared.pcDecision) }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .userInitiated) { [self, prepared] in try performCreate(prepared) }.value
            try Task.checkCancellation()
            return result
        }, onCancel: { BackendPCDecisionHostValidation.revoke(prepared.pcDecision) })
    }
    private func prepareCreate(_ launch: BackendHOSTProtocol.Launch) throws -> BackendHOSTProtocol.Launch {
        var prepared = launch
        prepared.pcDecision = try BackendPCDecisionHostValidation.issue(host: hello, session: launch.id,
            digest: BackendPCDecisionHostValidation.launchDigest(launch), input: launch.input.chat == true)
        return prepared
    }
    private func performCreate(_ launch: BackendHOSTProtocol.Launch) throws -> BackendSessionMeta {
        var request = request(.create); request.launch = launch
        let state = serialized { (generation, epochs[launch.id] ?? 0) }
        let response: BackendHOSTProtocol.Response
        do { response = try call(request) }
        catch let error as BackendHOSTFailure {
            switch error {
            case .remote, .invalid, .authentication, .incompatible: throw error
            default: throw BackendHOSTFailure.uncertainLaunch(launch.id)
            }
        } catch { throw BackendHOSTFailure.uncertainLaunch(launch.id) }
        guard let session = response.session, session.id == launch.id else { throw BackendHOSTFailure.uncertainLaunch(launch.id) }
        return try serialized {
            guard generation == state.0 else { throw BackendHOSTFailure.uncertainLaunch(launch.id) }
            guard !removed.contains(launch.id) else { throw BackendHOSTFailure.remote("The session was stopped while its launch reply was arriving.") }
            if let snapshot = response.snapshot, snapshots[launch.id] == nil || epochs[launch.id] == state.1 { try install(snapshot) }
            guard generation == state.0 else { throw BackendHOSTFailure.uncertainLaunch(launch.id) }
            return snapshots[launch.id]?.session ?? session
        }
    }
    public func write(_ id: String, bytes: Data) throws { try write(id, bytes: bytes, expectedCreatedAt: nil) }
    public func write(_ id: String, bytes: Data, expectedCreatedAt: Double?) throws {
        if BackendPCDecisionDelivery.required, Thread.isMainThread { throw BackendPCDecisionHostValidation.held() }
        let value = try prepareWrite(id, bytes: bytes, expectedCreatedAt: expectedCreatedAt)
        defer { BackendPCDecisionHostValidation.revoke(value.pcDecision) }
        try success(call(value))
    }
    public func writeAsync(_ id: String, bytes: Data, expectedCreatedAt: Double? = nil) async throws {
        let value = try prepareWrite(id, bytes: bytes, expectedCreatedAt: expectedCreatedAt)
        defer { BackendPCDecisionHostValidation.revoke(value.pcDecision) }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let response = try await Task.detached(priority: .userInitiated) { [self, value] in try call(value) }.value
            try Task.checkCancellation()
            try success(response)
        }, onCancel: { BackendPCDecisionHostValidation.revoke(value.pcDecision) })
    }
    private func prepareWrite(_ id: String, bytes: Data, expectedCreatedAt: Double?) throws -> BackendHOSTProtocol.Request {
        var value = request(.write, id: id); value.bytes = bytes; value.expectedCreatedAt = expectedCreatedAt
        value.pcDecision = try BackendPCDecisionHostValidation.issue(host: hello, session: id,
            digest: BackendPCDecisionHostValidation.writeDigest(id: id, bytes: bytes, expectedCreatedAt: expectedCreatedAt), input: true)
        return value
    }
    public func setWatched(_ watched: Bool) throws {
        var value = request(.setWatched); value.watched = watched; try success(call(value))
    }
    public func drain(timeoutMilliseconds: Int = 2_000) async throws -> Bool {
        var value = request(.drain); value.drainTimeoutMilliseconds = timeoutMilliseconds
        let drain = value
        return try await Task.detached { [self] in try call(drain).success == true }.value
    }
    public func resize(_ id: String, cols: Int, rows: Int) throws {
        var value = request(.resize, id: id); value.cols = cols; value.rows = rows; try success(call(value))
    }
    public func rename(_ id: String, title: String) throws -> Bool {
        var value = request(.rename, id: id); value.title = title
        let state = serialized { (generation, epochs[id] ?? 0) }
        let response = try call(value); try apply(response, id: id, state: state)
        guard let success = response.success else { throw BackendHOSTFailure.invalid("Missing rename result.") }; return success
    }
    public func setAccount(_ id: String, account: BackendAccountIdentity, home: String?) throws -> BackendSessionMeta? {
        var value = request(.account, id: id); value.account = account; value.home = home
        let state = serialized { (generation, epochs[id] ?? 0) }
        let response = try call(value); try apply(response, id: id, state: state); return response.session
    }
    public func setConversation(_ id: String, conversation: String) throws {
        var value = request(.conversation, id: id); value.conversation = conversation
        let state = serialized { (generation, epochs[id] ?? 0) }
        let response = try call(value); try success(response); try apply(response, id: id, state: state)
    }
    public func remove(_ id: String, reason: BackendRemovalReason = .stopped) throws {
        var value = request(.remove, id: id); value.reason = reason; try success(call(value))
        serialized { removed.insert(id); snapshots[id] = nil; order.removeAll { $0 == id } }
    }
    public func stopAll() throws {
        try success(call(request(.stopAll)))
        guard try call(request(.drain)).success == true else { throw BackendHOSTFailure.remote("The host's processes have not all exited. Retry Stop Everything.") }
    }
    public func resource(_ method: String, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        var value = request(.resource); value.resourceMethod = method; value.resourcePayload = try arguments.encodedJSON()
        if BackendPCDecisionHostValidation.needsEffectValidation(method), BackendPCDecisionDelivery.required {
            guard let id = arguments["id"].string else { throw BackendPCDecisionHostValidation.held() }
            value.pcDecision = try BackendPCDecisionHostValidation.issue(host: hello, session: id,
                digest: BackendPCDecisionHostValidation.digest(method: method, payload: value.resourcePayload!), input: true)
        }
        let envelope = value.pcDecision
        defer { BackendPCDecisionHostValidation.revoke(envelope) }
        let response = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) { [self, value] in try call(value) }.value
        }, onCancel: { BackendPCDecisionHostValidation.revoke(envelope) })
        try Task.checkCancellation()
        guard let payload = response.resourcePayload else { throw BackendHOSTFailure.invalid("Missing persistent host service reply.") }
        // 28 Oct (Asad's 12 MB chat: "JSON body is too large" on every send, seen-marker and phone read): a reply is
        // read up to the frame limit the helper writes it with, not the 8 MB request limit. A chat must never become
        // unopenable because its conversation grew.
        return try NativeRPCValue.parseJSON(payload, maximumBytes: BackendHOSTProtocol.maximumFrameBytes)
    }
    /// Dedicated pushed chat stream. The helper replays the durable store on every attachment.
    private final class ChatWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: BackendHOSTConnection?
        private var cancelled = false
        var active: Bool { lock.withLock { !cancelled } }
        func install(_ next: BackendHOSTConnection) -> Bool {
            lock.withLock {
                guard !cancelled else { next.shutdown(); return false }
                connection?.shutdown(); connection = next; return true
            }
        }
        func cancel() { lock.withLock { cancelled = true; connection?.shutdown(); connection = nil } }
    }

    public func watchChats(_ receive: @escaping @Sendable (NativeRPCValue) async -> Void) throws -> @Sendable () -> Void {
        guard hello.chatService == 1 else { throw BackendHOSTFailure.unavailable }
        let connection = BackendHOSTConnection(fd: try BackendHOSTSocket.connect(paths.socket))
        do {
            try BackendHOSTSocket.secure(connection.fd, timeoutSeconds: 0)
            try BackendHOSTSocket.write(request(.chatWatch), to: connection.fd, maximum: BackendHOSTProtocol.maximumRequestBytes)
        } catch { connection.shutdown(); throw error }
        let watch = ChatWatch()
        _ = watch.install(connection)
        Task { [weak self, watch] in
            var current = connection
            defer { current.shutdown() }
            while watch.active, !Task.isCancelled {
                do {
                    while watch.active, !Task.isCancelled {
                        let reading = current
                        // Blocking socket reads must not occupy Swift's cooperative executor.
                        let frame: BackendHOSTProtocol.Response = try await withCheckedThrowingContinuation { continuation in
                            DispatchQueue.global(qos: .utility).async {
                                do { continuation.resume(returning: try BackendHOSTSocket.read(BackendHOSTProtocol.Response.self, from: reading.fd, allowIdle: true)) }
                                catch { continuation.resume(throwing: error) }
                            }
                        }
                        guard frame.error == nil, let payload = frame.resourcePayload else { throw BackendHOSTFailure.unavailable }
                        guard watch.active else { return }
                        await receive(try NativeRPCValue.parseJSON(payload, maximumBytes: BackendHOSTProtocol.maximumFrameBytes))
                    }
                } catch {
                    current.shutdown()
                    guard watch.active, !Task.isCancelled else { return }
                    NSLog("[chat watch] Connection lost; reconnecting and replaying current chats.")
                }
                while watch.active, !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                        guard watch.active, let self else { return }
                        let next = BackendHOSTConnection(fd: try BackendHOSTSocket.connect(self.paths.socket))
                        do {
                            try BackendHOSTSocket.secure(next.fd, timeoutSeconds: 0)
                            try BackendHOSTSocket.write(self.request(.chatWatch), to: next.fd, maximum: BackendHOSTProtocol.maximumRequestBytes)
                        } catch { next.shutdown(); throw error }
                        guard watch.install(next) else { return }
                        current = next; break
                    } catch {
                        if Task.isCancelled { return }
                    }
                }
            }
        }
        return { watch.cancel() }
    }
    public func detach() {
        serialized { stream?.shutdown(); stream = nil; generation = nil; connected = false; callbacks = nil }
    }
    private func apply(_ response: BackendHOSTProtocol.Response, id: String, state: (UUID?, UInt64)) throws {
        if let snapshot = response.snapshot {
            try serialized { if generation == state.0, snapshots[id] == nil || epochs[id] == state.1 { try install(snapshot) } }
        }
    }
    private func success(_ response: BackendHOSTProtocol.Response) throws {
        guard response.success == true else { throw BackendHOSTFailure.invalid("The host did not confirm the operation.") }
    }
    private func request(_ operation: BackendHOSTProtocol.Request.Operation, id: String? = nil) -> BackendHOSTProtocol.Request {
        var value = BackendHOSTProtocol.Request(secret: secret, operation: operation, id: id)
        value.instance = hello.instance; return value
    }
    private func call(_ request: BackendHOSTProtocol.Request) throws -> BackendHOSTProtocol.Response {
        let fd = try BackendHOSTSocket.connect(paths.socket)
        defer { Darwin.close(fd) }
        try BackendHOSTSocket.write(request, to: fd, maximum: BackendHOSTProtocol.maximumRequestBytes)
        let response = try BackendHOSTSocket.read(BackendHOSTProtocol.Response.self, from: fd,
                                                  frameTimeoutMilliseconds: Self.replyDeadlineMilliseconds(request))
        if let error = response.error {
            if ["chats.say", "chats.steer"].contains(request.resourceMethod ?? ""), let code = response.errorCode {
                throw NativeRPCError(code: code, message: error)
            }
            throw response.errorCode == BackendHOSTUnknownChannel.code ? BackendHOSTUnknownChannel(error) : BackendHOSTFailure.remote(error)
        }
        return response
    }
    /// A chat start or a provider feature (a Codex fork, or a wait on the provider) can take longer than 10 s while the
    /// helper goes on (FIXFORK, POSIX 60). 18 Oct (#81): the reply's own deadline says so; the socket timeout never did,
    /// because frames are read with poll.
    static func replyDeadlineMilliseconds(_ request: BackendHOSTProtocol.Request) -> Int {
        if request.operation == .drain { return request.drainTimeout + 10_000 }
        if request.operation == .create, request.launch?.input.chat == true { return 90_000 }
        if request.operation == .resource, request.resourceMethod == "chats.provider" { return 90_000 }
        // 29 Oct (Asad: Send now failed "POSIX status 60"): Send now stops the answer, waits up to 10 s for the AI to
        // confirm, and may start it again before the message goes in; a send may start the AI. The reply comes when
        // that is done, so it is waited for, never cut off at 10 s while the helper goes on.
        // Chat Enter reaches the same send through chats.type, including its interruption wait.
        if request.operation == .resource, ["chats.steer", "chats.say", "chats.type"].contains(request.resourceMethod ?? "") { return 60_000 }
        if request.operation == .resource, ["chats.interrupt", "chats.stop"].contains(request.resourceMethod ?? "") { return 30_000 }
        return 10_000
    }
    private func serialized<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: deliveryKey) != nil { return try work() }
        return try delivery.sync(execute: work)
    }
    deinit { stream?.shutdown() }
}
