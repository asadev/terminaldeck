import Foundation
import Darwin
import TerminalDeckNativeCore

/// Helper assembly with durable pre-exec ownership, orphan recovery and an
/// optional real account/hook/MCP factory. The app entrypoint stays unwired.
public final class BackendHOSTRuntime: @unchecked Sendable {
    public typealias BeforeExec = @Sendable (String, Int32) throws -> Void
    public typealias InstallGate = @Sendable (@escaping BeforeExec) throws -> Void
    public typealias ResourceFactory = @Sendable (Data, BackendHOSTProtocol.Hello) async throws -> BackendHOSTResources
    public let server: BackendHOSTServer
    public let inventory: BackendHOSTOrphanInventory
    private let manager: BackendPTYManager
    private let state: BackendHOSTRuntimeState

    public init(paths: BackendHOSTPaths, hostVersion: String, manager: BackendPTYManager,
                launch: @escaping BackendHOSTServer.Launch,
                snapshot: @escaping @Sendable (String) -> BackendHOSTProtocol.Snapshot?,
                installGate: @escaping InstallGate,
                resources: ResourceFactory? = nil,
                onIdle: @escaping @Sendable () -> Void) throws {
        self.manager = manager
        // Loading a journal signals nothing. The server's owner lock must be
        // acquired before recovery, admission or a record mutation is enabled.
        inventory = try BackendHOSTOrphanInventory(directory: paths.directory.appendingPathComponent("owned-processes"))
        let state = try BackendHOSTRuntimeState(inventory: inventory, manager: manager, factory: resources, paths: paths)
        self.state = state
        let updates: (@Sendable () async throws -> AsyncStream<NativeRPCValue>)?
        if resources != nil { updates = { @Sendable in try await state.chatUpdates() } } else { updates = nil }
        server = try BackendHOSTServer(paths: paths, hostVersion: hostVersion, manager: manager, launch: { value in
            try state.admit(value)
            defer { state.launchFinished(value.id) }
            do { return try launch(value) }
            catch { state.launchFailed(value); throw error }
        }, snapshot: snapshot, onIdle: onIdle, resource: { method, payload in try await state.invoke(method, payload: payload) },
            chatUpdates: updates, pcDecisionValidation: resources != nil, beforeInput: { try state.beforeInput($0) })
        state.setHost(server.hello)
        do {
            try installGate { id, pid in try state.beforeExec(id: id, pid: pid) }
            server.setIdleCleanup { try await state.idleCleanup() }
            server.setDrainCleanup { try await state.confirmStop() }
            state.startRecovery()
        } catch { server.stopListening(); throw error }
    }
    public func stopAccepting() { server.stopListening() }
}

private final class BackendHOSTRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private let inventory: BackendHOSTOrphanInventory
    private let manager: BackendPTYManager
    private let factory: BackendHOSTRuntime.ResourceFactory?
    private var host: BackendHOSTProtocol.Hello?
    private var recoveryTask: Task<Void, Error>?
    private var recovering = true
    private var recoveryError: String?
    private var configuring = false
    private var quiescing = false
    private var resources: BackendHOSTResources?
    private var chatLaunches: [String: BackendHOSTProtocol.Launch] = [:]
    private var chatPIDs: [String: Int32] = [:]
    private var launches: [String: BackendHOSTProtocol.Launch] = [:]
    private let requiredDecisions: BackendPCDecisionRequiredSessions
    init(inventory: BackendHOSTOrphanInventory, manager: BackendPTYManager, factory: BackendHOSTRuntime.ResourceFactory?, paths: BackendHOSTPaths) throws {
        requiredDecisions = try BackendPCDecisionRequiredSessions(directory: paths.directory)
        self.inventory = inventory; self.manager = manager; self.factory = factory
    }
    func setHost(_ value: BackendHOSTProtocol.Hello) { lock.withLock { host = value } }
    func startRecovery() {
        let task = Task<Void, Error> { try await self.recover() }
        lock.withLock { recoveryTask = task }
    }
    /// HOSTLOST (9 Oct): recovery of a dead host's processes must never block this host. Each recorded
    /// session is stopped when it can be proven ours; one that cannot (its owner still alive, an
    /// identity that cannot be read, a stop that does not finish) is no longer tracked and becomes a
    /// notice with its PIDs — never a reason to refuse configure or new sessions forever.
    private(set) var recoveryNotice: String?
    func recover() async throws {
        var left: [String] = []
        if let notice = inventory.loadNotice { left.append(notice) }
        for entry in (try? inventory.list()) ?? [] {
            let id = entry.record.sessionID
            if entry.state != .liveOwner, let proof = try? await inventory.stop(sessionID: id), proof.clean { continue }
            let pids = (try? inventory.abandon(sessionID: id)) ?? []
            if !pids.isEmpty { left.append("Session " + id.prefix(8) + " may still have processes running: " + pids.map(String.init).joined(separator: ", ")) }
        }
        let notice = left.isEmpty ? nil : left.joined(separator: "\n")
        lock.withLock { recovering = false; recoveryError = nil; recoveryNotice = notice }
        if let notice { FileHandle.standardError.write(Data(("session host recovery: " + notice + "\n").utf8)) }
    }
    func admit(_ value: BackendHOSTProtocol.Launch) throws {
        try requireDecision(value.pcDecision, session: value.id, digest: BackendPCDecisionHostValidation.launchDigest(value))
        try lock.withLock {
            guard !recovering, recoveryError == nil, !configuring, !quiescing else { throw BackendHOSTFailure.remote(recoveryError ?? "The host is preparing or closing its session resources.") }
            guard value.input.provider == nil || value.input.provider == value.metadata.provider else { throw BackendHOSTFailure.invalid("The resolved host provider does not match its launch input.") }
            guard value.machineID.map({ !$0.contains("\0") && $0.utf8.count <= 1_024 }) ?? true else { throw BackendHOSTFailure.invalid("Invalid decoded host lease machine identity.") }
            if value.preparedChat == true {
                guard value.input.chat == true, value.scope?.hostedTask == true, value.scope?.isAppComposed == true,
                      value.input.teamJob?.taskID != nil, value.accountHandle != nil, !(value.mcpLeaseIDs ?? []).isEmpty else {
                    throw BackendHOSTFailure.invalid("R47-host-owned-fenced-task-chat requires its original account and tool ownership.")
                }
                if value.scope?.appFenceID != nil {
                    guard value.command == "/usr/bin/sandbox-exec", (value.arguments.contains("-p") || value.arguments.contains("-f")) else {
                        throw BackendHOSTFailure.invalid("The task's compiled records fence is missing. No child was started.")
                    }
                }
            }
            if value.pcDecision != nil, value.ownerIndependent == true || resources == nil { throw BackendPCDecisionHostValidation.held() }
            let independent = value.ownerIndependent == true
            if independent {
                guard value.accountHandle == nil, value.mcpLeaseIDs?.isEmpty ?? true,
                      value.input.taskID == nil, value.input.taskProject == nil, value.input.agentSettings == nil,
                      value.input.originApp == nil, value.input.origin == nil || value.input.origin == .user,
                      value.input.originRoutineId == nil, value.input.originRunId == nil,
                      value.scope?.deviceBoundary == nil, value.scope?.appFenceID == nil,
                      value.scope?.isAppComposed != true else {
                    throw BackendHOSTFailure.invalid("A deferred owner cannot use the ordinary host admission path.")
                }
            }
            guard value.metadata.provider == "shell" || independent || resources != nil else {
                throw BackendHOSTFailure.remote("This AI launch still needs its existing in-app resource owner.")
            }
            launches[value.id] = value
        }
    }
    func launchFinished(_ id: String) { lock.withLock { launches[id] = nil } }
    func launchFailed(_ launch: BackendHOSTProtocol.Launch) {
        if let owner = lock.withLock({ resources }) { Task { await owner.launchAbandoned(launch) } }
    }
    func beforeExec(id: String, pid: Int32) throws {
        guard let launch = lock.withLock({ launches[id] }) else { throw BackendHOSTFailure.invalid("No authenticated host launch owns this child.") }
        try inventory.record(sessionID: id, hostPID: getpid(), pid: pid,
                             renewalFolder: NativeSignInRenewal.folder(command: launch.command, arguments: launch.arguments, environment: launch.environment))
        try inventory.observeDescendants(sessionID: id)
        if launch.ownerIndependent != true, let owner = lock.withLock({ resources }) {
            try BackendHOSTPreExecAwait.run {
                try await owner.bindBeforeExec(launch, pid: pid)
                if let proof = launch.pcDecision { try await self.validateEffect(proof, effect: .spawn, owner: owner) }
            }
        }
    }
    func beforeInput(_ request: BackendHOSTProtocol.Request) throws {
        guard let id = request.id, let bytes = request.bytes else { throw BackendPCDecisionHostValidation.held() }
        try requireDecision(request.pcDecision, session: id,
            digest: BackendPCDecisionHostValidation.writeDigest(id: id, bytes: bytes, expectedCreatedAt: request.expectedCreatedAt))
        guard let proof = request.pcDecision else { return }
        guard let owner = lock.withLock({ quiescing ? nil : resources }) else { throw BackendPCDecisionHostValidation.held() }
        try BackendHOSTPreExecAwait.run { try await self.validateEffect(proof, effect: .input, owner: owner) }
    }
    func chatUpdates() async throws -> AsyncStream<TerminalDeckNativeCore.NativeRPCValue> {
        guard let owner = lock.withLock({ quiescing ? nil : resources }) else { throw BackendHOSTFailure.unavailable }
        return try await owner.chats.subscribe()
    }
    func invoke(_ method: String, payload: Data) async throws -> Data {
        if method == "resources.configure" {
            // A first attachment waits for the new helper's orphan reconciliation instead of racing it.
            if let startup = lock.withLock({ recoveryTask }) { try await startup.value }
            if lock.withLock({ resources != nil && !quiescing }) { return Data("{\"configured\":true,\"reattached\":true}".utf8) }
            let identity = try lock.withLock { () throws -> BackendHOSTProtocol.Hello in
                if resources != nil { throw BackendHOSTFailure.invalid("Persistent resources already have an owner.") }
                guard !configuring, !recovering, !quiescing, recoveryError == nil, let host, factory != nil else { throw BackendHOSTFailure.unavailable }
                configuring = true; return host
            }
            do {
                let created = try await factory!(payload, identity)
                await created.chats.setProcessBinding { [self] id, pid in try await bindChatProcess(id, pid: pid) }
                // 9 Nov: a chat's background shell that ends while the chat is idle is seen by this same descendant watch.
                inventory.onChange { [weak self] id in self?.chatProcessesChanged(id) }
                lock.withLock { resources = created; configuring = false }
                return Data("{\"configured\":true}".utf8)
            } catch { lock.withLock { configuring = false }; throw error }
        }
        if method == "orphans.list" { return try JSONEncoder().encode(inventory.list()) }
        if method == "orphans.retry" { try await recover(); return Data("{\"recovered\":true}".utf8) }
        if method == "orphans.stop" {
            struct Stop: Decodable { let id: String }
            let request = try JSONDecoder().decode(Stop.self, from: payload)
            return try JSONEncoder().encode(await inventory.stop(sessionID: request.id))
        }
        guard let owner = lock.withLock({ quiescing ? nil : resources }) else { throw BackendHOSTFailure.unavailable }
        if method == "chats.launch" {
            let launch = try JSONDecoder().decode(BackendHOSTProtocol.Launch.self, from: payload)
            try admit(launch)
            lock.withLock { chatLaunches[launch.id] = launch }
            defer { launchFinished(launch.id) }
            do {
                return try await withDecision(launch.pcDecision, session: launch.id,
                    digest: BackendPCDecisionHostValidation.launchDigest(launch), owner: owner) {
                    try await owner.invoke(method, payload: payload)
                }
            } catch {
                _ = try? await owner.chats.invoke("chats.close", payload: NativeRPCValue.object([.init("id", .string(launch.id))]).encodedJSON())
                await owner.launchAbandoned(launch)
                throw error
            }
        }
        let reply: Data
        if BackendPCDecisionHostValidation.needsEffectValidation(method), let id = try NativeRPCValue.parseJSON(payload)["id"].string {
            try BackendPCDecisionHostValidation.requireSupportedChatEffect(method,
                required: BackendPCDecisionHostValidation.incoming != nil || requiredDecisions.contains(id))
            reply = try await withDecision(BackendPCDecisionHostValidation.incoming, session: id,
                digest: BackendPCDecisionHostValidation.digest(method: method, payload: payload), owner: owner) {
                try await owner.invoke(method, payload: payload)
            }
        } else { reply = try await owner.invoke(method, payload: payload) }
        // 18 Oct (#184): a chat that is gone starts no process again, so its launch and process id go too.
        if BackendHOSTChats.endsChat(method), let id = try? NativeRPCValue.parseJSON(payload)["id"].string {
            lock.withLock { chatLaunches[id] = nil; chatPIDs[id] = nil }
        }
        return reply
    }
    private func requireDecision(_ proof: BackendPCDecisionHostValidation.Envelope?, session: String, digest: String) throws {
        if let proof {
            guard proof.sessionID == session, proof.digest == digest, proof.host == lock.withLock({ host?.instance }),
                  UUID(uuidString: session) != nil, !proof.reference.isEmpty else { throw BackendPCDecisionHostValidation.held() }
            try requiredDecisions.bind(session: session, reference: proof.reference, live: { [manager] in
                Set(manager.list().filter { $0.exitCode == nil }.map(\.id)).union(self.lock.withLock { Set(self.launches.keys).union(self.chatLaunches.keys) })
            })
        } else if requiredDecisions.contains(session) { throw BackendPCDecisionHostValidation.held() }
    }
    private func validateEffect(_ proof: BackendPCDecisionHostValidation.Envelope,
                                effect: BackendPCDecisionHostValidation.Effect, owner: BackendHOSTResources) async throws {
        try Task.checkCancellation()
        let result = try await owner.mcp.invokeControl(operation: .decisionValidate,
            arguments: BackendPCDecisionHostValidation.arguments(proof, effect: effect))
        try Task.checkCancellation()
        let receipt = try JSONDecoder().decode(BackendPCDecisionHostValidation.Receipt.self, from: result.encodedJSON())
        guard let ticket = effect == .spawn ? proof.spawn : proof.input,
              receipt == BackendPCDecisionHostValidation.Receipt(envelope: proof, effect: effect, ticket: ticket) else {
            throw BackendPCDecisionHostValidation.held()
        }
    }
    private func withDecision(_ proof: BackendPCDecisionHostValidation.Envelope?, session: String, digest: String,
                              owner: BackendHOSTResources, operation: () async throws -> Data) async throws -> Data {
        try requireDecision(proof, session: session, digest: digest)
        guard let proof else { return try await operation() }
        return try await BackendPCDecisionDelivery.$required.withValue(true) {
            try await BackendPCDecisionDelivery.$hostedReference.withValue(proof.reference) {
                try await BackendPCDecisionDelivery.$validate.withValue({ try Task.checkCancellation() }) {
                    try await BackendPCDecisionDelivery.$finalEffect.withValue({ effect in
                        try await self.validateEffect(proof, effect: effect, owner: owner)
                    }) { try await operation() }
                }
            }
        }
    }
    private func chatProcessesChanged(_ id: String) {
        guard let owner = lock.withLock({ chatPIDs[id] != nil && !quiescing ? resources : nil }) else { return }
        Task { await owner.chats.processesChanged(id) }
    }
    private func bindChatProcess(_ id: String, pid: Int32) async throws {
        let (launch, previous, owner) = try lock.withLock { () throws -> (BackendHOSTProtocol.Launch, Int32?, BackendHOSTResources) in
            guard let launch = chatLaunches[id], let owner = resources, !quiescing else { throw BackendHOSTFailure.authentication }
            return (launch, chatPIDs[id], owner)
        }
        guard previous != pid else { return }
        if previous != nil {
            guard try inventory.forgetProvenGone(sessionID: id).clean else { throw BackendHOSTFailure.remote("The previous chat still has running work. It was left alone.") }
        }
        try inventory.record(sessionID: id, hostPID: getpid(), pid: pid,
                             renewalFolder: NativeSignInRenewal.folder(command: launch.command, arguments: launch.arguments, environment: launch.environment))
        try inventory.observeDescendants(sessionID: id)
        try await owner.bindBeforeExec(launch, pid: pid)
        let broker = await owner.accounts.accounts.broker
        if await broker.seatSnapshot(sessionID: id) != nil { try await broker.bindProcess(sessionID: id, pid: pid) }
        lock.withLock { chatPIDs[id] = pid }
    }
    func idleCleanup() async throws {
        try lock.withLock {
            guard !configuring, !recovering, !quiescing, launches.isEmpty else { throw BackendHOSTFailure.unavailable }
            quiescing = true
        }
        var complete = false
        defer { if !complete { lock.withLock { quiescing = false } } }
        for entry in try inventory.list() {
            let proof = try await inventory.stopOwned(sessionID: entry.record.sessionID)
            guard proof.clean else { throw BackendHOSTFailure.remote("Owned session descendants have not all exited.") }
        }
        if let owner = lock.withLock({ resources }) {
            #if TD_HOST_ACCOUNT_BRIDGE
            guard !(await owner.keepWhileAppAttached()) else { throw BackendHOSTFailure.unavailable }
            #endif
            try await owner.stop()
        }
        complete = true
    }
    func confirmStop() async throws {
        guard !manager.list().contains(where: { $0.exitCode == nil }), await manager.drain() else { throw BackendHOSTFailure.unavailable }
        lock.withLock { quiescing = true }
        for entry in try inventory.list() {
            let proof = try await inventory.stopOwned(sessionID: entry.record.sessionID)
            guard proof.clean else { throw BackendHOSTFailure.remote("Recorded session descendants still need cleanup.") }
        }
        if let owner = lock.withLock({ resources }) {
            #if TD_HOST_ACCOUNT_BRIDGE
            try await owner.finishStoppedSessions()
            #else
            try await owner.stop()
            #endif
        }
        lock.withLock { quiescing = false }
    }
}

/// Parent-only wait while the child is behind the POSIX exec gate. This never
/// runs on the child side of fork, nor asks a UI actor to complete the binding.
private final class BackendHOSTPreExecAwait: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    static func run(_ operation: @escaping @Sendable () async throws -> Void) throws {
        let wait = BackendHOSTPreExecAwait()
        let task = Task.detached {
            let result: Result<Void, any Error>
            do { try Task.checkCancellation(); try await operation(); result = .success(()) }
            catch { result = .failure(error) }
            wait.lock.withLock { wait.result = result }; wait.semaphore.signal()
        }
        guard wait.semaphore.wait(timeout: .now() + .seconds(5)) == .success else {
            task.cancel(); throw BackendHOSTFailure.remote("Host resource binding timed out before exec. The gated child was stopped.")
        }
        try wait.lock.withLock { try wait.result!.get() }
    }
}
