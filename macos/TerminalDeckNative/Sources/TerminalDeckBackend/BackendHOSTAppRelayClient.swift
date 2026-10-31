import Foundation
import Darwin
import TerminalDeckNativeCore

/// Retained by the actual app graph. Its handler must invoke the current real
/// authorization/consent/cancellation path, never an always-allow surrogate.
public final class BackendHOSTAppRelayClient: @unchecked Sendable {
    public typealias Handler = @Sendable (BackendHOSTAppRelayCall) async throws -> BackendMCPToolReply
    public typealias ControlHandler = @Sendable (BackendHOSTAppRelayControl) async throws -> NativeRPCValue
    private struct Work: Sendable { var scope: BackendMCPCancellation; var task: Task<Void, Never>?; var control = false }
    private let host: BackendHOSTProtocol.Hello
    private let target: BackendHOSTAppRelayConnection
    private let lock = NSLock()
    private var handler: Handler?
    private var controlHandler: ControlHandler?
    private var work: [UUID: Work] = [:]
    private var stopped = false

    public init(paths: BackendHOSTPaths, host: BackendHOSTProtocol.Hello, handler: @escaping Handler) throws {
        self.host = host; self.handler = handler
        let base = BackendHOSTConnection(fd: try BackendHOSTSocket.connect(paths.directory.appendingPathComponent("app-relay.sock").path))
        do {
            guard try BackendHOSTAppRelayPeer.pid(base.fd) == host.hostPID else { throw BackendHOSTFailure.authentication }
            var attach = BackendHOSTAppRelayProtocol.Frame(.attach, instance: host.instance)
            attach.secret = try paths.secret(create: false); attach.pid = getpid()
            try BackendHOSTSocket.write(attach, to: base.fd, maximum: BackendHOSTAppRelayProtocol.maximumHandshake)
            let reply = try BackendHOSTSocket.read(BackendHOSTAppRelayProtocol.Frame.self, from: base.fd, maximum: BackendHOSTAppRelayProtocol.maximumHandshake)
            guard reply.version == BackendHOSTAppRelayProtocol.version, reply.operation == .attached,
                  reply.instance == host.instance, let attachment = reply.attachment else { throw BackendHOSTFailure.authentication }
            target = BackendHOSTAppRelayConnection(connection: base, attachment: attachment, peerPID: host.hostPID)
        } catch { base.shutdown(); throw error }
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.readLoop() }
    }

    /// nil visibly disables app-dependent calls during real graph teardown.
    /// Replacing the app's callbacks does not alter the host caller table.
    public func setHandler(_ handler: Handler?) {
        let retiring = lock.withLock { () -> [Work] in self.handler = handler; return handler == nil ? Array(work.values) : [] }
        for call in retiring { call.scope.cancel(); call.task?.cancel() }
    }
    public var hostIdentity: BackendHOSTProtocol.Hello { host }
    public var isAttached: Bool { lock.withLock { !stopped } }
    public func attachmentID() -> UUID? { lock.withLock { stopped ? nil : target.attachment } }
    public func setControlHandler(_ handler: ControlHandler?) {
        let retiring = lock.withLock { () -> [Work] in controlHandler = handler; return handler == nil ? work.values.filter(\.control) : [] }
        for call in retiring { call.scope.cancel(); call.task?.cancel() }
    }
    private func readLoop() {
        do {
            while !lock.withLock({ stopped }) {
                let frame = try BackendHOSTSocket.read(BackendHOSTAppRelayProtocol.Frame.self, from: target.fd,
                    maximum: BackendHOSTAppRelayProtocol.maximumFrame, allowIdle: true)
                guard frame.version == BackendHOSTAppRelayProtocol.version, frame.instance == host.instance,
                      frame.attachment == target.attachment, let id = frame.id else { throw BackendHOSTFailure.authentication }
                switch frame.operation {
                case .call:
                    guard let payload = frame.call else { throw BackendHOSTFailure.invalid("Missing original MCP call.") }
                    try receive(id: id, payload: payload)
                case .control:
                    guard let payload = frame.control else { throw BackendHOSTFailure.invalid("Missing private host control.") }
                    try receiveControl(id: id, payload: payload)
                case .cancel:
                    let old = lock.withLock { work[id] }
                    old?.scope.cancel(); old?.task?.cancel()
                default: throw BackendHOSTFailure.invalid("Invalid app relay request.")
                }
            }
        } catch { detach() }
    }
    private enum Admission { case accepted, duplicate, full, stopped }
    /// 18 Oct (#109): the host forgets a cancelled call at once, this side only once its
    /// handler unwinds, so a full table here is a busy app. Refuse that call alone; a
    /// repeated id is already being answered. Neither tears down the whole relay.
    private func admit(_ id: UUID, _ entry: Work) -> Admission {
        lock.withLock {
            if stopped { return .stopped }
            if work[id] != nil { return .duplicate }
            guard work.count < BackendHOSTAppRelayProtocol.maximumCalls else { return .full }
            work[id] = entry; return .accepted
        }
    }
    private func reply(_ id: UUID, _ answer: BackendMCPToolReply) {
        var frame = BackendHOSTAppRelayProtocol.Frame(.reply, instance: host.instance, attachment: target.attachment, id: id)
        do { frame.reply = try .init(answer); target.send(frame) { [weak self] in self?.detach() } }
        catch { detach() }
    }
    private func receiveControl(id: UUID, payload: BackendHOSTAppRelayProtocol.Control) throws {
        let scope = BackendMCPCancellation(), call = try payload.decode(id: id, cancellation: scope)
        switch admit(id, Work(scope: scope, task: nil, control: true)) {
        case .accepted: break
        case .full: reply(id, .failure(BackendHOSTAppRelayProtocol.busy)); return
        case .duplicate, .stopped: return
        }
        let handler = lock.withLock { controlHandler }
        let task = Task { [weak self] in
            guard let self else { return }
            let answer: BackendMCPToolReply
            do {
                try Task.checkCancellation()
                guard let handler, !scope.isCancelled else { throw BackendHOSTFailure.unavailable }
                let value = try await handler(call)
                try Task.checkCancellation()
                guard !scope.isCancelled else { throw CancellationError() }
                answer = .value(value)
            } catch {
                // #152: the app's own refusal ("That account no longer exists") goes back; the host carries it on.
                let reason = handler == nil || scope.isCancelled ? nil : Self.refusal(error)
                answer = .failure(reason ?? "The current app could not authorize or complete this private host control.")
            }
            let shouldSend = lock.withLock { () -> Bool in work[id] = nil; return !stopped }
            if shouldSend { reply(id, answer) }
        }
        let cancel = lock.withLock { () -> Bool in if work[id] != nil { work[id]?.task = task }; return stopped || scope.isCancelled }
        if cancel { scope.cancel(); task.cancel() }
    }
    static func refusal(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        let text = (error as? NativeRPCError)?.message ?? (error as? LocalizedError)?.errorDescription ?? ""
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? nil : String(said.prefix(1_000))
    }
    private func receive(id: UUID, payload: BackendHOSTAppRelayProtocol.Call) throws {
        let scope = BackendMCPCancellation()
        let call = try payload.decode(id: id, cancellation: scope)
        switch admit(id, Work(scope: scope, task: nil)) {
        case .accepted: break
        case .full: reply(id, .failure(BackendHOSTAppRelayProtocol.busy)); return
        case .duplicate, .stopped: return
        }
        let handler = lock.withLock { self.handler }
        let task = Task { [weak self] in
            guard let self else { return }
            let answer: BackendMCPToolReply
            do {
                try Task.checkCancellation()
                guard !scope.isCancelled, let handler else { throw BackendHOSTFailure.unavailable }
                let result = try await handler(call)
                try Task.checkCancellation()
                guard !scope.isCancelled else { throw CancellationError() }
                answer = result
            } catch {
                // 30 Oct (Decker): the app's own refusal goes back in words (as the private controls above already do);
                // the generic sentence is left only for an error that says nothing.
                answer = .failure(scope.isCancelled ? "The original MCP request was cancelled." : handler == nil
                    ? BackendHOSTAppRelayProtocol.unavailable : Self.refusal(error) ?? "The attached app could not authorize or complete this tool.")
            }
            let shouldSend = lock.withLock { () -> Bool in work[id] = nil; return !stopped }
            if shouldSend { reply(id, answer) }
        }
        let cancelTask = lock.withLock { () -> Bool in
            if work[id] != nil { work[id]?.task = task }
            return stopped || scope.isCancelled
        }
        if cancelTask { scope.cancel(); task.cancel() }
    }
    public func detach() {
        let tasks = lock.withLock { () -> [Work] in
            guard !stopped else { return [] }; stopped = true; handler = nil; controlHandler = nil
            let tasks = Array(work.values); work.removeAll(); return tasks
        }
        target.shutdown()
        for task in tasks { task.scope.cancel(); task.task?.cancel() }
    }
    deinit { target.shutdown() }
}
