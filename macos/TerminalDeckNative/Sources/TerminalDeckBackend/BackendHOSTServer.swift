import Foundation
import Darwin
import CryptoKit
import TerminalDeckNativeCore

/// Host-side owner. Creating this never starts an AI session. `launch` is the
/// existing PTY manager's resolved-id/environment seam, supplied by INT2.
public final class BackendHOSTServer: @unchecked Sendable {
    public typealias Launch = @Sendable (BackendHOSTProtocol.Launch) throws -> BackendSessionMeta
    public let hello: BackendHOSTProtocol.Hello
    private let paths: BackendHOSTPaths
    private let secret: String
    private let manager: BackendPTYManager
    private let launch: Launch
    private let beforeInput: (@Sendable (BackendHOSTProtocol.Request) throws -> Void)?
    private let readSnapshot: @Sendable (String) -> BackendHOSTProtocol.Snapshot?
    private let onIdle: @Sendable () -> Void
    private let resource: (@Sendable (String, Data) async throws -> Data)?
    private let chatUpdates: (@Sendable () async throws -> AsyncStream<NativeRPCValue>)?
    private let ownerLock: BackendHOSTFileLock
    private let control = DispatchQueue(label: "dev.terminaldeck.host.control", qos: .userInitiated)
    private let controlKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private var clients: [Int32: BackendHOSTConnection] = [:]
    private var chatTasks: [Int32: Task<Void, Never>] = [:]
    private var chatDisconnects: [Int32: DispatchSourceRead] = [:]
    private var streams: [Int32: BackendHOSTStream] = [:]
    private var source: DispatchSourceRead?
    /// 22 Oct (Reviewer, finding 5): out of file descriptors, `accept` fails while the app's connections wait, and the
    /// listener fired again at once (a spin). It now pauses briefly instead. Read and written on `control` only.
    private var acceptPaused = false
    /// How often the listener ran out of file descriptors (tests: a pause, never a spin).
    private(set) var outOfDescriptors = 0
    private var subscription: NativeRPCSubscription?
    private var stopped = false
    private var accepting = true
    private var idleWork: DispatchWorkItem?
    private var idleGeneration: UUID?
    private var idleCleanup: (@Sendable () async throws -> Void)?
    private var drainCleanup: (@Sendable () async throws -> Void)?
    private var digests: [String: Data] = [:]
    private var completed: [String: BackendSessionMeta] = [:]
    /// 18 Oct (#79): when each session was removed (system uptime). Its launch identity, launch facts and
    /// last metadata answer a retried create for `replayWindow`, then are forgotten, so a host that runs
    /// for months never reaches the launch-record limit.
    private var removedAt: [String: TimeInterval] = [:]
    private let replayWindow: TimeInterval
    private var launchFacts: [String: (BackendCreateSessionInput, BackendHOSTProtocol.Scope?)] = [:]

    public init(paths: BackendHOSTPaths, hostVersion: String, manager: BackendPTYManager,
                launch: @escaping Launch,
                snapshot: @escaping @Sendable (String) -> BackendHOSTProtocol.Snapshot?,
                onIdle: @escaping @Sendable () -> Void,
                resource: (@Sendable (String, Data) async throws -> Data)? = nil,
                chatUpdates: (@Sendable () async throws -> AsyncStream<NativeRPCValue>)? = nil,
                pcDecisionValidation: Bool = false,
                beforeInput: (@Sendable (BackendHOSTProtocol.Request) throws -> Void)? = nil,
                replayWindow: TimeInterval = 600) throws {
        self.paths = paths; self.manager = manager; self.launch = launch; self.onIdle = onIdle; self.replayWindow = replayWindow
        readSnapshot = snapshot
        self.resource = resource; self.chatUpdates = chatUpdates; self.beforeInput = beforeInput
        try paths.prepare(); secret = try paths.secret(create: false)
        ownerLock = try BackendHOSTFileLock(paths.directory.appendingPathComponent("owner.lock"))
        hello = .init(protocolVersion: BackendHOSTProtocol.version, hostVersion: hostVersion,
                      hostPID: getpid(), instance: UUID(), chatService: chatUpdates == nil ? nil : 1, pcDecisionValidation: pcDecisionValidation ? 1 : nil,
                      chatSteering: chatUpdates == nil ? nil : 1, chatFeatures: chatUpdates == nil ? nil : 1,
                      chatOwnedTerminals: chatUpdates == nil ? nil : 1, chatSessionFeatures: chatUpdates == nil ? nil : 1,
                      accountUnknownChannel: resource == nil ? nil : 1)
        control.setSpecific(key: controlKey, value: 1)
        var address = try BackendHOSTSocket.address(paths.socket)
        var existing = stat()
        if lstat(paths.socket, &existing) == 0 {
            // The exclusive owner lock proves no conforming host can race
            // this stale cleanup. A listening socket is always left alone.
            if let probe = try? BackendHOSTSocket.connect(paths.socket) {
                Darwin.close(probe); throw BackendHOSTFailure.unavailable
            }
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == geteuid(),
                  unlink(paths.socket) == 0 else { throw BackendHOSTFailure.authentication }
        } else if errno != ENOENT { throw BackendHOSTFailure.io(errno) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BackendHOSTFailure.io(errno) }
        var bound = false
        do {
            try BackendHOSTSocket.secure(fd)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw BackendHOSTFailure.io(errno) }
            bound = true
            guard chmod(paths.socket, 0o600) == 0, listen(fd, 16) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw BackendHOSTFailure.io(errno) }
        } catch { Darwin.close(fd); if bound { _ = unlink(paths.socket) }; throw error }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: control)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in self?.accept(fd) }
        self.source = source
        subscription = manager.remoteServeObserve { [weak self] event in self?.publish(event) }
        source.resume()
        control.async { [weak self] in self?.scheduleIdle() }
    }

    private func accept(_ listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                if errno == EMFILE || errno == ENFILE || errno == ENOBUFS || errno == ENOMEM { pauseAccepting() }
                return
            }
            do { try BackendHOSTSocket.secure(fd); try BackendHOSTSocket.sameUser(fd) }
            catch { Darwin.close(fd); continue }
            let connection = BackendHOSTConnection(fd: fd)
            let allowed = lock.withLock { () -> Bool in
                guard !stopped, clients.count < BackendHOSTProtocol.maximumConnections else { return false }
                clients[fd] = connection; return true
            }
            guard allowed else { connection.shutdown(); continue }
            DispatchQueue.global(qos: .utility).async { [self, connection] in
                defer { withExtendedLifetime(connection) {} }
                do {
                    let request = try BackendHOSTSocket.read(BackendHOSTProtocol.Request.self, from: fd,
                                                            maximum: BackendHOSTProtocol.maximumRequestBytes)
                    guard BackendHOSTSocket.sameSecret(request.secret, secret) else { throw BackendHOSTFailure.authentication }
                    guard request.protocolVersion == BackendHOSTProtocol.version else {
                        try BackendHOSTSocket.write(BackendHOSTProtocol.Response(hello: hello, error: "Incompatible session host protocol."), to: fd)
                        finish(fd); return
                    }
                    if request.operation != .hello, request.instance != hello.instance {
                        throw BackendHOSTFailure.remote("The session host changed. Reattach before retrying any operation.")
                    }
                    control.async { [self, connection] in handle(request, connection: connection) }
                } catch {
                    // Authentication/decoding failures disclose no secret or request.
                    try? BackendHOSTSocket.write(BackendHOSTProtocol.Response(error: "The private host request was refused."), to: fd)
                    finish(fd)
                }
            }
        }
    }

    /// Out of descriptors: the waiting connections stay queued and the listener tries again after a short pause,
    /// once a session or connection has given one back.
    private func pauseAccepting() {
        outOfDescriptors += 1
        guard !acceptPaused, let source else { return }
        acceptPaused = true; source.suspend()
        control.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
            guard let self, acceptPaused else { return }
            acceptPaused = false; self.source?.resume()
        }
    }

    private func viewportSnapshot(_ id: String) -> BackendHOSTProtocol.Snapshot? {
        #if TD_HOST_INTEGRATED
        guard var value = manager.hostViewport(id) else { return nil }
        #else
        guard var value = readSnapshot(id) else { return nil } // no host build: the full snapshot, as before
        #endif
        let facts = lock.withLock { launchFacts[id] }
        value.input = facts?.0; value.scope = facts?.1
        return value
    }
    /// The full snapshot plus the terminal as it is now, read with its sequence (27 Oct).
    private func remountSnapshot(_ id: String) -> BackendHOSTProtocol.Snapshot? {
        #if TD_HOST_INTEGRATED
        guard var value = manager.hostSnapshot(id, remount: true) else { return nil }
        #else
        guard var value = readSnapshot(id) else { return nil } // no host build: the full snapshot, as before
        #endif
        let facts = lock.withLock { launchFacts[id] }
        value.input = facts?.0; value.scope = facts?.1
        return value
    }
    private func snapshot(_ id: String) -> BackendHOSTProtocol.Snapshot? {
        guard var value = readSnapshot(id) else { return nil }
        let facts = lock.withLock { launchFacts[id] }
        value.input = facts?.0; value.scope = facts?.1
        return value
    }

    private func handle(_ request: BackendHOSTProtocol.Request, connection: BackendHOSTConnection) {
        let fd = connection.fd
        guard !lock.withLock({ stopped }) else { finish(fd); return }
        if request.operation == .chatWatch {
            guard let chatUpdates else { send(.init(error: "Chat survival is unavailable in this helper."), connection: connection); return }
            let task = Task { [self, connection] in
                do {
                    for await value in try await chatUpdates() {
                        let response = BackendHOSTProtocol.Response(resourcePayload: try value.encodedJSON())
                        try await Task.detached { try BackendHOSTSocket.write(response, to: connection.fd) }.value
                    }
                } catch { /* The app left; the chat engine and its permission waiters stay. */ }
                finish(fd)
            }
            let disconnect = DispatchSource.makeReadSource(fileDescriptor: fd, queue: control)
            disconnect.setEventHandler { [weak self] in self?.finish(fd) }
            disconnect.resume()
            let live = lock.withLock { () -> Bool in
                guard clients[fd] != nil else { return false }
                chatTasks[fd] = task; chatDisconnects[fd] = disconnect; return true
            }
            if !live { task.cancel(); disconnect.cancel() }
            return
        }
        if request.operation == .create, let value = request.launch, value.input.chat == true {
            guard hello.chatService == 1, let resource, accepting, value.id == value.metadata.id, UUID(uuidString: value.id) != nil else {
                send(.init(error: "This helper cannot keep a chat running."), connection: connection); return
            }
            do {
                let bytes = try JSONEncoder.sorted.encode(value), digest = Data(try BackendPCDecisionHostValidation.launchDigest(value).utf8)
                if let previous = digests[value.id] {
                    guard previous == digest, removedAt[value.id] == nil, let session = manager.list().first(where: { $0.id == value.id }) else {
                        throw BackendHOSTFailure.uncertainLaunch(value.id)
                    }
                    send(.init(snapshot: snapshot(value.id), session: session), connection: connection); return
                }
                try BackendHOSTFiles.atomicWrite(Data("active".utf8), to: paths.activeFile)
                digests[value.id] = digest; lock.withLock { launchFacts[value.id] = (value.input, value.scope) }
                idleWork?.cancel(); idleGeneration = nil
                Task { [self, connection] in
                    do {
                        let meta = try JSONDecoder().decode(BackendSessionMeta.self, from: await resource("chats.launch", bytes))
                        control.async { [self, connection] in
                            completed[value.id] = meta; refreshStreams(value.id)
                            send(.init(snapshot: snapshot(value.id), session: meta), connection: connection)
                        }
                    } catch {
                        // 22 Oct: a launch that never started leaves no launch record behind (forgotten after the replay window).
                        control.async { [self] in if !manager.list().contains(where: { $0.id == value.id }) { markRemoved(value.id) } }
                        send(.init(error: "The helper could not start this chat: " + error.localizedDescription), connection: connection)
                    }
                }
            } catch { send(.init(error: "The chat launch was not confirmed. Reattach before retrying."), connection: connection) }
            return
        }
        if request.operation == .watch {
            let stream = BackendHOSTStream(connection: connection) { [weak self] in self?.finish(fd) }
            lock.withLock { streams[fd] = stream }
            // Events are buffered before snapshots are read. Each session's
            // own watermark excludes bytes already present in its replay.
            let ids = manager.list().map(\.id)
            stream.begin(ids: ids) { [weak self] id in self?.snapshot(id) }
            return
        }
        if request.operation == .stopAll, hello.chatService == 1, let resource {
            accepting = false
            Task { [self, connection] in
                do {
                    _ = try await resource("chats.stopAll", Data("{}".utf8))
                    control.async { [self, connection] in manager.beginShutdown(); send(.init(success: true), connection: connection); scheduleIdle() }
                } catch { send(.init(error: "The helper could not confirm every chat stopped."), connection: connection) }
            }
            return
        }
        if request.operation == .drain {
            Task { [self, connection] in
                let drained = await manager.drain(timeoutMilliseconds: request.drainTimeout)
                if drained {
                    let cleanup = control.sync { drainCleanup }
                    do { try await cleanup?(); send(.init(success: true), connection: connection) }
                    catch { send(.init(success: false, error: "Owned session descendants have not all stopped; their resources remain protected."), connection: connection) }
                } else { send(.init(success: false), connection: connection) }
            }
            return
        }
        if request.operation == .resource {
            guard let resource, let method = request.resourceMethod, method.utf8.count <= 128,
                  let payload = request.resourcePayload, payload.count <= BackendHOSTProtocol.maximumRequestBytes else {
                send(.init(error: "The requested persistent host service is unavailable."), connection: connection); return
            }
            // Reject old senders on the socket queue, before detached work or any validation
            // can outlive their deadline. No journal entry, pipe write or restart can follow.
            do { try BackendHOSTChats.validateDeliveryIdentity(method, payload: payload) }
            catch { send(.init(error: error.localizedDescription), connection: connection); return }
            Task { [self, connection] in
                do {
                    let reply = try await BackendPCDecisionHostValidation.$incoming.withValue(request.pcDecision) {
                        try await resource(method, payload)
                    }
                    if method == "chats.open", let meta = try? JSONDecoder().decode(BackendSessionMeta.self, from: reply) {
                        control.async { [self] in refreshStreams(meta.id) }
                    }
                    send(.init(resourcePayload: reply), connection: connection)
                }
                // L8 (10 Oct): say WHY. The bare sentence hid every account-facade refusal behind one text.
                catch {
                    send(.init(error: "The persistent host service could not complete " + method + ": " + error.localizedDescription,
                               errorCode: error is BackendHOSTUnknownChannel ? BackendHOSTUnknownChannel.code : (["chats.say", "chats.steer"].contains(method) ? (error as? NativeRPCError)?.code : nil)), connection: connection)
                }
            }
            return
        }
        do {
            let response: BackendHOSTProtocol.Response
            switch request.operation {
            case .hello: response = .init(hello: hello)
            case .list: response = .init(sessions: manager.list())
            case .snapshot:
                let target = try id(request)
                response = .init(snapshot: request.viewportOnly == true ? viewportSnapshot(target)
                                 : request.remount == true ? remountSnapshot(target) : snapshot(target))
            case .create:
                guard accepting, let value = request.launch, value.id == value.metadata.id,
                      UUID(uuidString: value.id) != nil else { throw BackendHOSTFailure.invalid("Invalid or stopped host launch.") }
                let digest = Data(try BackendPCDecisionHostValidation.launchDigest(value).utf8)
                if let original = digests[value.id] {
                    guard original == digest else { throw BackendHOSTFailure.invalid("A session id cannot be reused for a different launch.") }
                    guard removedAt[value.id] == nil else { throw BackendHOSTFailure.remote("That session was stopped. It cannot be relaunched by retrying its old request.") }
                    guard let existing = manager.list().first(where: { $0.id == value.id }) ?? completed[value.id] else {
                        throw BackendHOSTFailure.uncertainLaunch(value.id)
                    }
                    response = .init(snapshot: snapshot(value.id), session: existing)
                } else {
                    // 22 Oct (Asad): no session-count or launch-record limit. Records of removed sessions are
                    // forgotten after their replay window, so a host that runs for months stays small.
                    forgetRemoved()
                    try BackendHOSTFiles.atomicWrite(Data("active".utf8), to: paths.activeFile)
                    // A launch adapter that throws after starting cannot cause
                    // a second spawn on retry; retain the identity first.
                    digests[value.id] = digest
                    lock.withLock { launchFacts[value.id] = (value.input, value.scope) }
                    let created: BackendSessionMeta
                    do { created = try launch(value) }
                    catch {
                        if let existing = manager.list().first(where: { $0.id == value.id }) {
                            completed[value.id] = existing
                        } else { markRemoved(value.id) }
                        throw error
                    }
                    guard created.id == value.id else {
                        manager.kill(created.id)
                        throw BackendHOSTFailure.invalid("The host launch adapter did not preserve the session identity.")
                    }
                    completed[value.id] = created
                    idleWork?.cancel(); idleWork = nil; idleGeneration = nil
                    refreshStreams(value.id)
                    response = .init(snapshot: snapshot(value.id), session: created)
                }
            case .write:
                guard let bytes = request.bytes, bytes.count <= BackendHOSTProtocol.maximumInputBytes else {
                    throw BackendHOSTFailure.invalid("Invalid or oversized session input.")
                }
                guard request.expectedCreatedAt.map(\.isFinite) ?? true else { throw BackendHOSTFailure.invalid("Invalid session incarnation.") }
                try beforeInput?(request)
                if request.pcDecision != nil, beforeInput == nil { throw BackendPCDecisionHostValidation.held() }
                try manager.write(try id(request), bytes: bytes, expectedCreatedAt: request.expectedCreatedAt); response = .init(success: true)
            case .setWatched:
                guard let watched = request.watched else { throw BackendHOSTFailure.invalid("Missing watch state.") }
                manager.setWatched(watched); response = .init(success: true)
            case .resize:
                guard let cols = request.cols, let rows = request.rows else { throw BackendHOSTFailure.invalid("Missing terminal size.") }
                try manager.resize(try id(request), cols: cols, rows: rows); response = .init(success: true)
            case .rename:
                guard let title = request.title, title.utf8.count <= 4_096 else { throw BackendHOSTFailure.invalid("Invalid session title.") }
                let id = try id(request), success = manager.rename(id, title: title)
                refreshStreams(id); response = .init(snapshot: snapshot(id), success: success)
            case .account:
                guard let account = request.account else { throw BackendHOSTFailure.invalid("Missing account identity.") }
                let id = try id(request), session = manager.setAccount(id, account: account, home: request.home)
                refreshStreams(id); response = .init(snapshot: snapshot(id), session: session)
            case .conversation:
                guard let conversation = request.conversation, conversation.utf8.count <= 4_096 else { throw BackendHOSTFailure.invalid("Missing conversation identity.") }
                let id = try id(request); manager.setAgentSessionId(id, conversationId: conversation)
                refreshStreams(id); response = .init(snapshot: snapshot(id), success: true)
            case .remove:
                let id = try id(request); markRemoved(id)
                manager.kill(id, reason: request.reason ?? .stopped); response = .init(success: true)
            case .stopAll:
                accepting = false; manager.beginShutdown(); response = .init(success: true); scheduleIdle()
            case .chatWatch, .watch, .drain, .resource: throw BackendHOSTFailure.invalid("Invalid host operation.")
            }
            send(response, connection: connection)
        } catch {
            // Never echo an underlying launch error that could contain argv.
            send(.init(error: "The session host could not complete " + request.operation.rawValue + "."), connection: connection)
            scheduleIdle()
        }
    }

    private func id(_ request: BackendHOSTProtocol.Request) throws -> String {
        guard let id = request.id, UUID(uuidString: id) != nil else { throw BackendHOSTFailure.invalid("Invalid session id.") }
        return id
    }
    private func send(_ response: BackendHOSTProtocol.Response, connection: BackendHOSTConnection) {
        DispatchQueue.global(qos: .utility).async { [self, connection] in
            defer { withExtendedLifetime(connection) {} }
            try? BackendHOSTSocket.write(response, to: connection.fd); finish(connection.fd)
        }
    }
    private func publish(_ value: BackendRemoteServePTYEvent) {
        let event = BackendHOSTProtocol.Event(sequence: value.sequence, event: value.event)
        let subscribers = lock.withLock { Array(streams.values) }
        for stream in subscribers { stream.offer(event) }
        // 18 Oct (#435): output chunks change no metadata, so they do not scan the session list.
        guard event.kind != .data else { return }
        control.async { [weak self] in
            guard let self else { return }
            if let meta = manager.list().first(where: { $0.id == event.id }) { completed[event.id] = meta }
            if event.kind == .removed { markRemoved(event.id) }
            if event.kind == .exit, var meta = completed[event.id] { meta.exitCode = event.exitCode; completed[event.id] = meta }
            if event.kind == .exit || event.kind == .removed { scheduleIdle() }
        }
    }
    private func markRemoved(_ id: String) {
        if removedAt[id] == nil { removedAt[id] = ProcessInfo.processInfo.systemUptime }
        forgetRemoved()
    }
    private func forgetRemoved() {
        let cutoff = ProcessInfo.processInfo.systemUptime - replayWindow
        for (id, at) in removedAt where at <= cutoff {
            removedAt[id] = nil; digests[id] = nil; completed[id] = nil
            lock.withLock { launchFacts[id] = nil }
        }
    }
    /// Launch records still held (tests read it; the control queue owns them).
    var retainedLaunches: Int { control.sync { digests.count + completed.count + removedAt.count } + lock.withLock { launchFacts.count } }
    private func finish(_ fd: Int32) {
        let removed = lock.withLock { () -> BackendHOSTConnection? in
            streams[fd] = nil
            chatTasks.removeValue(forKey: fd)?.cancel()
            chatDisconnects.removeValue(forKey: fd)?.cancel()
            return clients.removeValue(forKey: fd)
        }
        removed?.shutdown()
    }
    private func refreshStreams(_ id: String) {
        let subscribers = lock.withLock { Array(streams.values) }
        for stream in subscribers { stream.refresh(id: id) { [weak self] in self?.snapshot(id) } }
    }
    private func scheduleIdle() {
        idleWork?.cancel(); idleWork = nil; idleGeneration = nil
        guard !manager.list().contains(where: { $0.exitCode == nil }) else { return }
        let generation = UUID(); idleGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, !manager.list().contains(where: { $0.exitCode == nil }) else { return }
            Task { [self] in
                guard await manager.drain(timeoutMilliseconds: 2_000) else {
                    control.async { [self] in scheduleIdle() }; return
                }
                let cleanup = control.sync { () -> (Bool, (@Sendable () async throws -> Void)?) in
                    (idleGeneration == generation && !manager.list().contains(where: { $0.exitCode == nil }), idleCleanup)
                }
                guard cleanup.0 else { return }
                do { try await cleanup.1?() }
                catch { control.async { [self] in scheduleIdle() }; return }
                control.async { [self] in
                    guard idleGeneration == generation, !manager.list().contains(where: { $0.exitCode == nil }) else { return }
                    _ = unlink(paths.activeFile.path)
                    stopListening(); onIdle()
                }
            }
        }
        idleWork = work
        // Startup/last-exit grace allows snapshot recovery of a short command.
        control.asyncAfter(deadline: .now() + .seconds(30), execute: work)
    }
    public func setIdleCleanup(_ cleanup: @escaping @Sendable () async throws -> Void) {
        control.sync { idleCleanup = cleanup }
    }
    public func setDrainCleanup(_ cleanup: @escaping @Sendable () async throws -> Void) {
        control.sync { drainCleanup = cleanup }
    }
    public func notifyMetadataChanged(sessionID: String) {
        control.async { [weak self] in self?.refreshStreams(sessionID) }
    }

    /// Disconnect clients without touching any PTY. Used only when the host
    /// has drained, or by an owned scratch fixture during its cleanup.
    public func stopListening() {
        if DispatchQueue.getSpecific(key: controlKey) == nil { control.sync { stopOnControl() } }
        else { stopOnControl() }
    }
    private func stopOnControl() {
        idleWork?.cancel(); idleWork = nil; idleGeneration = nil
        let state = lock.withLock { () -> (Bool, [Int32], [BackendHOSTStream]) in
            guard !stopped else { return (false, [], []) }
            stopped = true; return (true, Array(clients.keys), Array(streams.values))
        }
        guard state.0 else { return }
        // A paused listener is resumed after cancelling, so its cancel handler closes the socket.
        source?.cancel(); if acceptPaused { acceptPaused = false; source?.resume() }; source = nil
        subscription?.cancel(); subscription = nil
        for stream in state.2 { stream.close() }
        for fd in state.1 { finish(fd) }
        _ = unlink(paths.socket)
    }
    deinit {
        source?.cancel(); if acceptPaused { source?.resume() } // a suspended source must never be released
        subscription?.cancel(); idleWork?.cancel()
        for connection in clients.values { connection.shutdown() }
        _ = unlink(paths.socket)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}

/// A slow/disconnected app is dropped after 8 MiB of queued live output; the
/// PTY continues and a new connection can recover bounded replay.
private final class BackendHOSTStream: @unchecked Sendable {
    private let connection: BackendHOSTConnection
    private var fd: Int32 { connection.fd }
    private let finish: @Sendable () -> Void
    private let writer = DispatchQueue(label: "dev.terminaldeck.host.stream", qos: .userInteractive) // live output to the app
    private let lock = NSLock()
    private var starting = true
    private var closed = false
    private var pending: [BackendHOSTProtocol.Event] = []
    private var queuedBytes = 0
    private var watermarks: [String: UInt64] = [:]
    private var disconnect: DispatchSourceRead?
    init(connection: BackendHOSTConnection, finish: @escaping @Sendable () -> Void) { self.connection = connection; self.finish = finish }
    func begin(ids: [String], snapshot: @escaping @Sendable (String) -> BackendHOSTProtocol.Snapshot?) {
        writer.async { [self] in
            do {
                // Retain only one replay snapshot at a time, never all rings.
                for id in ids {
                    guard !lock.withLock({ closed }) else { return }
                    if let value = snapshot(id) {
                        lock.withLock { watermarks[id] = value.sequence }
                        try BackendHOSTSocket.write(BackendHOSTProtocol.Response(snapshot: value), to: fd)
                    }
                }
                try BackendHOSTSocket.write(BackendHOSTProtocol.Response(ready: true), to: fd)
                lock.lock()
                guard !closed else { lock.unlock(); return }
                for event in pending where event.kind == .exit || event.kind == .removed || event.sequence > (watermarks[event.id] ?? 0) {
                    let bytes = (event.text?.utf8.count ?? 0) + 512
                    enqueue(.init(event: event), bytes: bytes)
                }
                // Preserve the bytes still queued, excluding replayed events.
                queuedBytes = pending.filter { $0.kind == .exit || $0.kind == .removed || $0.sequence > (watermarks[$0.id] ?? 0) }.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) + 512 }
                pending.removeAll(); starting = false
                lock.unlock()
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: writer)
                source.setEventHandler { [weak self] in self?.close() }
                // Resume before publishing, so close never cancels a suspended source.
                source.resume()
                let cancel = lock.withLock { () -> Bool in
                    if closed { return true }; disconnect = source; return false
                }
                if cancel { source.cancel() }
            } catch { close() }
        }
    }
    func offer(_ event: BackendHOSTProtocol.Event) {
        let bytes = (event.text?.utf8.count ?? 0) + 512
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if queuedBytes + bytes > 8 * 1024 * 1024 { lock.unlock(); close(); return }
        if starting { queuedBytes += bytes; pending.append(event) }
        else if event.kind == .exit || event.kind == .removed || event.sequence > (watermarks[event.id] ?? 0) { queuedBytes += bytes; enqueue(.init(event: event), bytes: bytes) }
        lock.unlock()
    }
    // Called while locked; writer never blocks the PTY's event callback.
    private func enqueue(_ value: BackendHOSTProtocol.Response, bytes: Int) {
        writer.async { [weak self] in
            guard let self, !lock.withLock({ closed }) else { return }
            let covered = lock.withLock { value.event.map { $0.kind != .exit && $0.kind != .removed && $0.sequence <= (watermarks[$0.id] ?? 0) } ?? false }
            do { if !covered { try BackendHOSTSocket.write(value, to: fd) } }
            catch { close(); return }
            if bytes > 0 { lock.withLock { queuedBytes -= bytes } }
        }
    }
    func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !closed else { return false }; closed = true; pending.removeAll(); return true
        }
        if shouldClose { disconnect?.cancel(); finish() }
    }
    func refresh(id: String, snapshot: @escaping @Sendable () -> BackendHOSTProtocol.Snapshot?) {
        writer.async { [weak self] in
            guard let self, !lock.withLock({ closed }), let value = snapshot() else { return }
            lock.withLock { watermarks[id] = value.sequence }
            do { try BackendHOSTSocket.write(BackendHOSTProtocol.Response(snapshot: value), to: fd) }
            catch { close() }
        }
    }
    deinit { disconnect?.cancel(); connection.shutdown() }
}

/// Retained by every pending reader/writer. shutdown interrupts I/O; the fd
/// cannot be reused until the last operation releases this object.
final class BackendHOSTConnection: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var shut = false
    init(fd: Int32) { self.fd = fd }
    func shutdown() {
        lock.withLock { if !shut { shut = true; _ = Darwin.shutdown(fd, SHUT_RDWR) } }
    }
    deinit { Darwin.close(fd) }
}
