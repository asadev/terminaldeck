import Foundation
import Darwin
import TerminalDeckNativeCore

/// Host-owned duplex Unix relay. Replacing the app attachment cancels only
/// its outstanding callbacks; the MCP endpoint/caller/file owner stays alive.
public final class BackendHOSTAppRelayServer: @unchecked Sendable {
    private struct Pending: Sendable {
        var attachment: UUID
        var scope: BackendMCPCancellation
        var observer: UUID?
        var reply: CheckedContinuation<BackendMCPToolReply, Never>
        var call: BackendHOSTAppRelayProtocol.Call?
    }
    private let host: BackendHOSTProtocol.Hello
    private let secret: String
    private let path: String
    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: "dev.terminaldeck.host.app-relay.accept", qos: .userInitiated)
    private var source: DispatchSourceRead?
    private var clients: [Int32: BackendHOSTConnection] = [:]
    private var binding: BackendHOSTAppRelayConnection?
    private var pending: [UUID: Pending] = [:]
    private var stopped = false
    private var ownsSocket = false

    public init(paths: BackendHOSTPaths, host: BackendHOSTProtocol.Hello) throws {
        guard host.hostPID == getpid(), host.protocolVersion == BackendHOSTProtocol.version else { throw BackendHOSTFailure.authentication }
        self.host = host; secret = try paths.secret(create: false)
        try paths.prepare(); path = paths.directory.appendingPathComponent("app-relay.sock").path
        var address = try BackendHOSTSocket.address(path), info = stat()
        if lstat(path, &info) == 0 {
            if let connected = try? BackendHOSTSocket.connect(path) { Darwin.close(connected); throw BackendHOSTFailure.unavailable }
            guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(), unlink(path) == 0 else { throw BackendHOSTFailure.authentication }
        } else if errno != ENOENT { throw BackendHOSTFailure.io(errno) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BackendHOSTFailure.io(errno) }
        var owned = false
        do {
            try BackendHOSTSocket.secure(fd)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard result == 0 else { throw BackendHOSTFailure.io(errno) }; owned = true; ownsSocket = true
            guard chmod(path, 0o600) == 0, listen(fd, 16) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw BackendHOSTFailure.io(errno) }
        } catch { Darwin.close(fd); if owned { _ = unlink(path) }; throw error }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: listenerQueue)
        source.setCancelHandler { Darwin.close(fd) }; source.setEventHandler { [weak self] in self?.accept(fd) }
        self.source = source; source.resume()
    }

    public func projection() -> BackendHOSTAppRelayProjection {
        lock.withLock { .init(attached: binding != nil, appPID: binding?.peerPID, pendingCalls: pending.count, hostInstance: host.instance) }
    }
    public func appAttachmentID() -> UUID? { lock.withLock { binding?.attachment } }
    /// Only an actual outstanding helper-issued call on the current authenticated
    /// app attachment can be revalidated. Caller-looking metadata is not evidence.
    public func currentSessionCall(_ id: UUID) throws -> BackendHOSTAppRelayCall {
        let value = try lock.withLock { () throws -> (BackendHOSTAppRelayProtocol.Call, BackendMCPCancellation) in
            guard !stopped, let binding, let pending = pending[id], pending.attachment == binding.attachment,
                  !pending.scope.isCancelled, let call = pending.call else { throw BackendHOSTFailure.authentication }
            return (call, pending.scope)
        }
        return try value.0.decode(id: id, cancellation: value.1)
    }
    public func invoke(tool: BackendMCPTool, context: BackendMCPCallContext, taskProject: String?, arguments: NativeRPCValue) async -> BackendMCPToolReply {
        guard context.allowedTiers.contains(tool.tier),
              BackendMCPToolNames.permits(tool.id, granted: context.allowedTools) || BackendMCPToolNames.permits(tool.wireName, granted: context.allowedTools),
              !context.cancellation.isCancelled else { return .failure("This caller is not permitted to use that tool.") }
        let payload: BackendHOSTAppRelayProtocol.Call
        do { payload = try .init(tool: tool, context: context, taskProject: taskProject, arguments: arguments) }
        catch { return .failure("The original tool arguments could not be relayed.") }
        return await exchange(operation: .call, call: payload, control: nil, scope: context.cancellation)
    }
    public func invokeControl(operation: BackendHOSTAppRelayControl.Operation, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        guard let attachment = appAttachmentID() else { throw BackendHOSTFailure.unavailable }
        let payload = try BackendHOSTAppRelayProtocol.Control(operation: operation, arguments: arguments)
        let reply = await exchange(operation: .control, call: nil, control: payload, scope: BackendMCPCancellation())
        guard attachment == appAttachmentID() else { throw BackendHOSTFailure.unavailable }
        // L8 (10 Oct): carry the app's own refusal text; "the session host is unavailable" hid every reason.
        if reply.isError {
            let reason = reply.content.compactMap { $0["text"].string }.joined(separator: " ")
            throw reason.isEmpty ? BackendHOSTFailure.unavailable : BackendHOSTFailure.remote(reason)
        }
        if let value = reply.structuredContent { return value }
        guard let text = reply.content.first?["text"].string else { throw BackendHOSTFailure.invalid("Missing private host control receipt.") }
        return try NativeRPCValue.parseJSON(Data(text.utf8), maximumBytes: BackendHOSTAppRelayProtocol.maximumArguments)
    }
    private func exchange(operation: BackendHOSTAppRelayProtocol.Frame.Operation, call: BackendHOSTAppRelayProtocol.Call?,
                          control: BackendHOSTAppRelayProtocol.Control?, scope: BackendMCPCancellation) async -> BackendMCPToolReply {
        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let (target, refusal) = lock.withLock { () -> (BackendHOSTAppRelayConnection?, String) in
                    guard !stopped, let binding, !scope.isCancelled, !Task.isCancelled else { return (nil, BackendHOSTAppRelayProtocol.unavailable) }
                    guard pending.count < BackendHOSTAppRelayProtocol.maximumCalls else { return (nil, BackendHOSTAppRelayProtocol.busy) }
                    pending[id] = Pending(attachment: binding.attachment, scope: scope, observer: nil, reply: continuation, call: call)
                    return (binding, "")
                }
                guard let target else { continuation.resume(returning: .failure(refusal)); return }
                let observer = scope.observe { [weak self] in self?.cancel(id, attachment: target.attachment) }
                let registered = lock.withLock { () -> Bool in
                    guard pending[id] != nil else { return false }; pending[id]?.observer = observer; return true
                }
                if !registered { scope.removeObserver(observer); return }
                var frame = BackendHOSTAppRelayProtocol.Frame(operation, instance: host.instance, attachment: target.attachment, id: id)
                frame.call = call; frame.control = control
                target.send(frame) { [weak self] in self?.disconnected(target) }
            }
        }, onCancel: { [weak self] in self?.cancel(id, attachment: nil) })
    }
    private func cancel(_ id: UUID, attachment: UUID?) {
        let state = lock.withLock { () -> (Pending, BackendHOSTAppRelayConnection?)? in
            guard let value = pending[id], attachment == nil || value.attachment == attachment else { return nil }
            pending[id] = nil
            return (value, binding?.attachment == value.attachment ? binding : nil)
        }
        guard let (value, target) = state else { return }
        if let observer = value.observer { value.scope.removeObserver(observer) }
        if let target {
            target.send(.init(.cancel, instance: host.instance, attachment: target.attachment, id: id)) { [weak self] in self?.disconnected(target) }
        }
        value.reply.resume(returning: .failure("The original MCP request was cancelled."))
    }
    private func accept(_ listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; return }
            let connection = BackendHOSTConnection(fd: fd)
            let allowed = lock.withLock { () -> Bool in
                guard !stopped, clients.count < BackendHOSTProtocol.maximumConnections else { return false }
                clients[fd] = connection; return true
            }
            guard allowed else { connection.shutdown(); continue }
            DispatchQueue.global(qos: .utility).async { [self, connection] in
                var attached: BackendHOSTAppRelayConnection?
                defer {
                    if let attached { disconnected(attached) }
                    lock.withLock { clients[fd] = nil }; connection.shutdown()
                }
                do {
                    try BackendHOSTSocket.secure(fd)
                    let peer = try BackendHOSTAppRelayPeer.pid(fd)
                    let frame = try BackendHOSTSocket.read(BackendHOSTAppRelayProtocol.Frame.self, from: fd, maximum: BackendHOSTAppRelayProtocol.maximumHandshake)
                    guard frame.version == BackendHOSTAppRelayProtocol.version, frame.operation == .attach,
                          frame.instance == host.instance, frame.pid == peer,
                          BackendHOSTSocket.sameSecret(frame.secret ?? "", secret) else { throw BackendHOSTFailure.authentication }
                    let target = BackendHOSTAppRelayConnection(connection: connection, attachment: UUID(), peerPID: peer)
                    attached = target
                    try target.handshake(.init(.attached, instance: host.instance, attachment: target.attachment)) { [self] in
                        let previous = lock.withLock { () -> BackendHOSTAppRelayConnection? in
                            guard !stopped else { return target }
                            let previous = binding; binding = target; return previous
                        }
                        if previous === target { return false }
                        if let previous { disconnected(previous) }
                        return true
                    }
                    while true {
                        let reply = try BackendHOSTSocket.read(BackendHOSTAppRelayProtocol.Frame.self, from: fd,
                            maximum: BackendHOSTAppRelayProtocol.maximumFrame, allowIdle: true)
                        guard reply.version == BackendHOSTAppRelayProtocol.version, reply.instance == host.instance,
                              reply.attachment == target.attachment else { throw BackendHOSTFailure.authentication }
                        if reply.operation == .detach { break }
                        guard reply.operation == .reply, let id = reply.id, let answer = reply.reply else { throw BackendHOSTFailure.invalid("Invalid app relay receipt.") }
                        let decoded = try answer.decode()
                        let value = lock.withLock { () -> Pending? in
                            guard binding?.attachment == target.attachment, let value = pending[id], value.attachment == target.attachment else { return nil }
                            pending[id] = nil; return value
                        }
                        if let value {
                            if let observer = value.observer { value.scope.removeObserver(observer) }
                            value.reply.resume(returning: decoded)
                        }
                    }
                } catch { /* Do not echo private frames, arguments or secrets. */ }
            }
        }
    }
    private func disconnected(_ target: BackendHOSTAppRelayConnection) {
        let abandoned = lock.withLock { () -> [Pending] in
            if binding?.attachment == target.attachment { binding = nil }
            let values = pending.filter { $0.value.attachment == target.attachment }
            for id in values.keys { pending[id] = nil }
            return Array(values.values)
        }
        target.shutdown()
        for value in abandoned {
            if let observer = value.observer { value.scope.removeObserver(observer) }
            value.reply.resume(returning: .failure(BackendHOSTAppRelayProtocol.unavailable))
        }
    }
    public func stop() {
        let state = lock.withLock { () -> ([BackendHOSTConnection], BackendHOSTAppRelayConnection?, [Pending])? in
            guard !stopped else { return nil }
            stopped = true; let state = (Array(clients.values), binding, Array(pending.values))
            clients.removeAll(); binding = nil; pending.removeAll(); return state
        }
        guard let state else { return }
        source?.cancel(); source = nil
        state.1?.shutdown(); for connection in state.0 { connection.shutdown() }
        for value in state.2 {
            if let observer = value.observer { value.scope.removeObserver(observer) }
            value.reply.resume(returning: .failure(BackendHOSTAppRelayProtocol.unavailable))
        }
        if ownsSocket { _ = unlink(path); ownsSocket = false }
    }
    deinit { source?.cancel(); for connection in clients.values { connection.shutdown() }; if ownsSocket { _ = unlink(path) } }
}
