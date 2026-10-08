import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Plans contain identifiers only. The kernel captures before-images while
/// the original write receipt is live; callers cannot supply recovery bytes.
public enum BackendAppsRecoveryOperation: Sendable, Equatable {
    case releaseOwnedLock(path: String, ownerToken: String)
    case restoreAppFile(path: String)
    case restoreContainer(id: String)
    case recoverDatabase(originalID: String)
    case restoreCaddyRoute(routeID: String, collectionPath: String)
    case removeCreatedContainers
    case removeAppWorkDirectory(path: String)
    case restoreBackupTimer(unit: String)
    public var name: String {
        switch self {
        case .releaseOwnedLock: "release-owned-lock"
        case .restoreAppFile: "restore-captured-file"
        case .restoreContainer: "restore-captured-service"
        case .recoverDatabase: "recover-owned-database-pair"
        case .restoreCaddyRoute: "restore-captured-route"
        case .removeCreatedContainers: "remove-transaction-candidates"
        case .removeAppWorkDirectory: "remove-transaction-work"
        case .restoreBackupTimer: "restore-captured-timer"
        }
    }
}

public struct BackendAppsRecoveryScope: Sendable {
    public let transactionID: UUID
    public let serverID: String
    public let appID: String
    public let ownerID: String
    public let requestID: UUID?
    public let stateRoot: String
    public let resourcePrefix: String
    public let privateNetwork: String
    public let caddyServerKey: String?
    public let caddyAutosavePath: String?
    public let lifetimeSeconds: Double
    public var appDirectory: String { stateRoot + "/" + appID }
    public var ownerToken: String { transactionID.uuidString }
    public var caddyLockPath: String { "/var/lib/" + resourcePrefix + "-caddy-lock" }
    public var caddyRouteID: String { resourcePrefix + "-" + appID }
    public var routeCollectionPath: String { "/config/apps/http/servers/" + (caddyServerKey ?? "terminaldeck") + "/routes" }
    fileprivate init(runtime: BackendAppsRuntime, server: String, app: String, context: NativeRPCContext?, lifetime: Double) {
        transactionID = UUID(); serverID = server; appID = app; ownerID = context?.ownerID ?? "injected-test"
        requestID = context?.requestID; stateRoot = runtime.stateRoot; resourcePrefix = runtime.resourcePrefix
        privateNetwork = runtime.privateNetwork; caddyServerKey = runtime.caddyServerKey
        caddyAutosavePath = runtime.caddyAutosavePath; lifetimeSeconds = lifetime
    }
}

public struct BackendAppsRecoveryAudit: Sendable {
    public let transactionID: UUID, serverID: String, appID: String, ownerID: String
    public let event: String, operation: String?
    public let successful: Bool?
    public let sequence: UInt64
    public var value: NativeRPCValue { BackendAppsValidation.object([
        ("transactionId", .string(transactionID.uuidString)), ("serverId", .string(serverID)),
        ("appId", .string(appID)), ("ownerId", .string(ownerID)), ("event", .string(event)),
        ("operation", operation.map(NativeRPCValue.string) ?? .null),
        ("successful", successful.map(NativeRPCValue.bool) ?? .null), ("sequence", .number(Double(sequence)))
    ]) }
}

/// DKA captures one authenticated lease AFTER checking the actual accepted
/// write receipt. Fields are private to this kernel, never ordinary RPC I/O.
/// Each callback must recheck the pinned server lifetime/host identity; it
/// must not re-resolve an expired caller or reconnect to a replacement server.
public struct BackendAppsRecoveryTransport: Sendable {
    fileprivate let execute: BackendAppsRuntime.Execute
    fileprivate let docker: BackendAppsRuntime.HTTP
    fileprivate let caddy: BackendAppsRuntime.HTTP
    fileprivate let authorizeRegistration: @Sendable (NativeRPCContext?) async throws -> Void
    fileprivate let validateBinding: @Sendable () async throws -> Void
    fileprivate let close: @Sendable () async -> Void
    public init(execute: @escaping BackendAppsRuntime.Execute, docker: @escaping BackendAppsRuntime.HTTP,
                caddy: @escaping BackendAppsRuntime.HTTP,
                authorizeRegistration: @escaping @Sendable (NativeRPCContext?) async throws -> Void,
                validateBinding: @escaping @Sendable () async throws -> Void,
                close: @escaping @Sendable () async -> Void) {
        self.execute = execute; self.docker = docker; self.caddy = caddy
        self.authorizeRegistration = authorizeRegistration; self.validateBinding = validateBinding; self.close = close
    }
    /// Teardown only. An issuer can release a lease refused by its post-capture
    /// authority check without exposing any of the private recovery I/O.
    public func closePinned() async { await close() }
}

public struct BackendAppsRecoveryHandle: Sendable {
    fileprivate let transaction: UUID, nonce: UUID
    fileprivate init(transaction: UUID) { self.transaction = transaction; nonce = UUID() }
}
public struct BackendAppsRecoveryOutcome: Sendable {
    public let completed: Bool
    public let reason: String?
    fileprivate init(_ completed: Bool, _ reason: String? = nil) { self.completed = completed; self.reason = reason }
}
public struct BackendAppsRecoveryTransaction: Sendable {
    public let scope: BackendAppsRecoveryScope
    fileprivate let kernel: BackendAppsRecovery
    fileprivate let seal: UUID
    public func register(_ operation: BackendAppsRecoveryOperation) async throws -> BackendAppsRecoveryHandle {
        try await kernel.register(self, operation: operation)
    }
    public func perform(_ handle: BackendAppsRecoveryHandle) async throws -> BackendAppsRecoveryOutcome {
        try await kernel.perform(self, handle: handle)
    }
    public func registered(_ operation: BackendAppsRecoveryOperation) async -> BackendAppsRecoveryHandle? {
        await kernel.registered(self, operation: operation)
    }
    public func belongs(to recovery: BackendAppsRecovery) -> Bool { kernel === recovery }
}
public enum BackendAppsRecoveryContext {
    @TaskLocal public static var current: BackendAppsRecoveryTransaction?
    @TaskLocal public static var active: [BackendAppsRecoveryTransaction] = []
    public static func transaction(serverID: String, appID: String) -> BackendAppsRecoveryTransaction? {
        if let current, current.scope.serverID == serverID, current.scope.appID == appID { return current }
        return active.last { $0.scope.serverID == serverID && $0.scope.appID == appID }
    }
}

/// No standing authority, daemon or timer. Deadlines are monotonic and checked
/// on every use; teardown closes leases. Handles are sealed and one-shot.
public actor BackendAppsRecovery {
    public typealias Capture = @Sendable (BackendAppsRecoveryScope, NativeRPCContext?) async throws -> BackendAppsRecoveryTransport
    public typealias Audit = @Sendable (BackendAppsRecoveryAudit) async throws -> Void
    private enum Snapshot: Sendable {
        case lock(String, String), file(String, Data?), container(String, Bool, Bool, [String])
        case route(String, String, NativeRPCValue?), candidates, work(String), timer(String, Bool, Bool)
        case database(BackendAppsRecoveryDatabaseBaseline)
    }
    private struct Step: Sendable { let operation: BackendAppsRecoveryOperation, snapshot: Snapshot; let ordinal: Int; var consumed = false; var completed: Bool? }
    private struct Entry: Sendable {
        let scope: BackendAppsRecoveryScope, seal: UUID, transport: BackendAppsRecoveryTransport, deadline: Double
        var steps: [UUID: Step] = [:]; var bytes = 0; var executing = false; var capturing = false
    }
    private var entries: [UUID: Entry] = [:]
    private let capture: Capture, audit: Audit, monotonic: @Sendable () -> Double
    private var sequence: UInt64 = 0
    private var pendingBegins = 0
    public init(capture: @escaping Capture, audit: @escaping Audit,
                monotonic: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.capture = capture; self.audit = audit; self.monotonic = monotonic
    }
    public func begin(runtime: BackendAppsRuntime, serverID: String, appID: String, lifetimeSeconds: Double = 3900) async throws -> BackendAppsRecoveryTransaction {
        try Task.checkCancellation()
        let expired = entries.filter { monotonic() >= $0.value.deadline }
        for (id, entry) in expired { entries[id] = nil; try? await emit(entry.scope, "expired", nil, false); await entry.transport.close() }
        _ = try BackendAppsValidation.id(appID); _ = try BackendAppsValidation.id(runtime.resourcePrefix)
        guard !serverID.isEmpty, serverID != "local", runtime.privateNetwork.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$"#, options: .regularExpression) != nil,
              ["/var/lib/terminaldeck/apps", "/var/lib/" + runtime.resourcePrefix + "-apps"].contains(runtime.stateRoot),
              lifetimeSeconds.isFinite, (1...3900).contains(lifetimeSeconds), entries.count + pendingBegins < 8 else { throw denial("The app recovery transaction is invalid or unavailable.") }
        pendingBegins += 1
        defer { pendingBegins -= 1 }
        if let key = runtime.caddyServerKey { _ = try BackendAppsValidation.identifier(key) }
        let context = NativeCompositionCallContext.rpc
        let scope = BackendAppsRecoveryScope(runtime: runtime, server: serverID, app: appID, context: context, lifetime: lifetimeSeconds)
        // Capture must deny read-only/unapproved/expired callers. It pins the
        // actual server generation and transport; a TaskLocal cannot mint it.
        let transport = try await capture(scope, context)
        let seal = UUID(), now = monotonic()
        guard now.isFinite else { await transport.close(); throw denial("The recovery clock is unavailable.") }
        do {
            try Task.checkCancellation(); try await transport.authorizeRegistration(context); try await transport.validateBinding()
            try await emit(scope, "issued", nil, true)
            try Task.checkCancellation(); try await transport.authorizeRegistration(context); try await transport.validateBinding()
            try Task.checkCancellation()
        } catch { await transport.close(); throw denial("The original write receipt expired or the recovery transaction could not be audited.") }
        guard entries.count < 8 else { await transport.close(); throw denial("Too many app recovery transactions are active.") }
        entries[scope.transactionID] = .init(scope: scope, seal: seal, transport: transport, deadline: now + lifetimeSeconds)
        return .init(scope: scope, kernel: self, seal: seal)
    }
    public func finish(_ transaction: BackendAppsRecoveryTransaction) async {
        guard let entry = entries[transaction.scope.transactionID], entry.seal == transaction.seal else { return }
        entries[transaction.scope.transactionID] = nil
        try? await emit(entry.scope, "closed", nil, entry.steps.values.allSatisfy { !$0.consumed || $0.completed == true })
        await entry.transport.close()
    }
    public func shutdown() async {
        let old = entries; entries.removeAll()
        for entry in old.values { try? await emit(entry.scope, "revoked", nil, false); await entry.transport.close() }
    }
    private func checked(_ transaction: BackendAppsRecoveryTransaction) throws -> Entry {
        guard let entry = entries[transaction.scope.transactionID], entry.seal == transaction.seal,
              entry.scope.serverID == transaction.scope.serverID, entry.scope.appID == transaction.scope.appID,
              monotonic().isFinite, monotonic() < entry.deadline else { throw denial("The recovery capability is expired, revoked or belongs to another transaction.") }
        return entry
    }
    fileprivate func register(_ transaction: BackendAppsRecoveryTransaction, operation: BackendAppsRecoveryOperation) async throws -> BackendAppsRecoveryHandle {
        var entry = try checked(transaction)
        guard !entry.executing, !entry.capturing, entry.steps.count < 32 else { throw denial("The recovery plan cannot be changed now.") }
        let context = NativeCompositionCallContext.rpc
        guard context?.ownerID == entry.scope.ownerID || context == nil && entry.scope.requestID == nil,
              context?.requestID == entry.scope.requestID else { throw denial("This caller cannot expand another transaction's recovery plan.") }
        if case .restoreAppFile = operation, let prior = entry.steps.first(where: { $0.value.operation == operation }) {
            guard !prior.value.consumed else { throw denial("A file already recovered in this transaction cannot be rebaselined.") }
            try Task.checkCancellation()
            try await entry.transport.authorizeRegistration(NativeCompositionCallContext.rpc)
            return .init(transaction: entry.scope.transactionID, nonce: prior.key)
        }
        entry.capturing = true; entries[entry.scope.transactionID] = entry
        defer { entries[entry.scope.transactionID]?.capturing = false }
        try Task.checkCancellation()
        try await entry.transport.authorizeRegistration(context)
        try Task.checkCancellation()
        let snapshot = try await captureSnapshot(operation, entry: entry)
        try await entry.transport.authorizeRegistration(context)
        entry = try checked(transaction)
        let size: Int
        switch snapshot { case .file(_, let data): size = data?.count ?? 0; case .route(_, _, let value): size = value?.compact.utf8.count ?? 0; default: size = 256 }
        guard entry.bytes + size <= 2_097_152 else { throw denial("The recovery snapshot is too large.") }
        let handle = BackendAppsRecoveryHandle(transaction: entry.scope.transactionID)
        try await emit(entry.scope, "sealed", operation.name, true)
        try await entry.transport.authorizeRegistration(context)
        try Task.checkCancellation()
        entry = try checked(transaction)
        guard !entry.executing, entry.steps.count < 32, entry.bytes + size <= 2_097_152 else { throw denial("The recovery plan cannot admit another captured step.") }
        entry.steps[handle.nonce] = .init(operation: operation, snapshot: snapshot, ordinal: entry.steps.count + 1); entry.bytes += size
        entries[entry.scope.transactionID] = entry
        return handle
    }
    fileprivate func registered(_ transaction: BackendAppsRecoveryTransaction, operation: BackendAppsRecoveryOperation) -> BackendAppsRecoveryHandle? {
        guard let entry = try? checked(transaction), let pair = entry.steps.filter({ $0.value.operation == operation && !$0.value.consumed }).max(by: { $0.value.ordinal < $1.value.ordinal }) else { return nil }
        return .init(transaction: entry.scope.transactionID, nonce: pair.key)
    }
    fileprivate func perform(_ transaction: BackendAppsRecoveryTransaction, handle: BackendAppsRecoveryHandle) async throws -> BackendAppsRecoveryOutcome {
        var entry = try checked(transaction)
        guard handle.transaction == entry.scope.transactionID, let step = entry.steps[handle.nonce], !step.consumed, !entry.executing, !entry.capturing else { throw denial("This recovery step is consumed, busy or belongs to another transaction.") }
        entry.steps[handle.nonce]?.consumed = true; entry.executing = true; entries[entry.scope.transactionID] = entry
        defer { if var latest = entries[entry.scope.transactionID] { latest.executing = false; entries[entry.scope.transactionID] = latest } }
        try await emit(entry.scope, "started", step.operation.name, nil)
        let succeeded: Bool
        do { succeeded = try await recover(step.snapshot, entry: entry) }
        catch { entries[entry.scope.transactionID]?.steps[handle.nonce]?.completed = false; try? await emit(entry.scope, "finished", step.operation.name, false); return .init(false, "The sealed recovery step could not be verified. Saved recovery notes remain.") }
        entries[entry.scope.transactionID]?.steps[handle.nonce]?.completed = succeeded
        do { try await emit(entry.scope, "finished", step.operation.name, succeeded) }
        catch { entries[entry.scope.transactionID]?.steps[handle.nonce]?.completed = false; return .init(false, "The recovery result could not be audited. Inspect the saved recovery notes.") }
        return .init(succeeded, succeeded ? nil : "The sealed recovery step could not be verified. Saved recovery notes remain.")
    }
    private func emit(_ scope: BackendAppsRecoveryScope, _ event: String, _ operation: String?, _ success: Bool?) async throws {
        sequence &+= 1
        try await audit(.init(transactionID: scope.transactionID, serverID: scope.serverID, appID: scope.appID,
                             ownerID: scope.ownerID, event: event, operation: operation, successful: success, sequence: sequence))
    }
    private func denial(_ message: String) -> NativeRPCError { .init(code: "access-denied", message: message) }

    private func command(_ entry: Entry, _ script: String, input: Data? = nil, maximumBytes: Int = 1_048_576) async throws -> BackendServersRunResult {
        try await checkBinding(entry)
        return try await entry.transport.execute(entry.scope.serverID, "sh -c " + BackendAppsRuntime.quote(script), input, 30_000, maximumBytes)
    }
    private func checkBinding(_ entry: Entry) async throws {
        guard let live = entries[entry.scope.transactionID], live.seal == entry.seal,
              monotonic().isFinite, monotonic() < live.deadline else { throw denial("This recovery transaction expired or was revoked.") }
        try await entry.transport.validateBinding()
        guard let current = entries[entry.scope.transactionID], current.seal == entry.seal,
              monotonic().isFinite, monotonic() < current.deadline else { throw denial("The recovery transaction expired while validating its binding.") }
    }
    private func docker(_ entry: Entry, _ method: String, _ path: String, _ body: Data? = nil) async throws -> BackendAppsHTTPResponse {
        try await checkBinding(entry); return try await entry.transport.docker(entry.scope.serverID, method, path, body)
    }
    private func caddy(_ entry: Entry, _ method: String, _ path: String, _ body: Data? = nil) async throws -> BackendAppsHTTPResponse {
        try await checkBinding(entry); return try await entry.transport.caddy(entry.scope.serverID, method, path, body)
    }
    private func captureSnapshot(_ operation: BackendAppsRecoveryOperation, entry: Entry) async throws -> Snapshot {
        let scope = entry.scope, q = BackendAppsRuntime.quote
        switch operation {
        case .releaseOwnedLock(let path, let token):
            guard token == scope.ownerToken, scopedLock(path, scope) else { throw denial("A recovery lock must belong to this transaction.") }
            return .lock(path, token)
        case .restoreAppFile(let path):
            guard scopedFile(path, scope) else { throw denial("That file is outside this app's recovery scope.") }
            let result = try await command(entry, parentChecks(path, scope) + "; test ! -L \(q(path)) || exit 45; test -e \(q(path)) || exit 44; test -f \(q(path)) || exit 45; cat -- \(q(path))")
            if result.code == 44 { return .file(path, nil) }
            guard result.code == 0, !result.truncated else { throw denial("The original app file could not be captured safely.") }
            if path.hasPrefix("/etc/systemd/system/") {
                guard result.stdout.split(separator: "\n").contains(Substring("# Terminal Deck managed backup for " + scope.appID)) else { throw denial("That existing backup unit is not owned by this app.") }
            }
            return .file(path, Data(result.stdout.utf8))
        case .restoreContainer(let id):
            _ = try BackendAppsValidation.identifier(id)
            let value = try await ownedContainer(entry, id)
            guard value["Config"]["Labels"]["io.terminaldeck.transaction"].string != scope.ownerToken else { throw denial("A transaction-created candidate cannot be its own original recovery witness.") }
            guard let running = value["State"]["Running"].bool else { throw denial("The original service state is unavailable.") }
            let network = value["NetworkSettings"]["Networks"][scope.privateNetwork]
            let aliases = (network["Aliases"].elements ?? []).compactMap(\.string)
            guard aliases.count <= 32, aliases.allSatisfy({ $0.utf8.count <= 253 && $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil }) else { throw denial("The original private service address is invalid.") }
            return .container(id, running, !network.isNullish, aliases)
        case .restoreCaddyRoute(let id, let collection):
            guard id == scope.caddyRouteID, collection == scope.routeCollectionPath else { throw denial("That route is outside this app's recovery scope.") }
            let response = try await caddy(entry, "GET", "/id/" + id)
            if response.status == 404 { return .route(id, collection, nil) }
            guard response.ok, let value = try? response.value(), value["@id"].string == id, value.compact.utf8.count <= 131_072 else { throw denial("The original owned app route could not be captured.") }
            return .route(id, collection, value)
        case .recoverDatabase(let originalID):
            _ = try BackendAppsValidation.identifier(originalID)
            let original = try await ownedContainer(entry, originalID)
            let path = scope.appDirectory + "/state.json"
            let saved = try await command(entry, "set -eu; " + parentChecks(path, scope) + "; test ! -L " + q(path) + "; cat -- " + q(path))
            guard saved.code == 0, !saved.truncated else { throw denial("The database's captured identity could not be read.") }
            let record = try BackendAppsValidation.json(Data(saved.stdout.utf8))
            return .database(try BackendAppsRecoveryDatabase.capture(scope: scope, originalID: originalID, record: record, original: original))
        case .removeCreatedContainers: return .candidates
        case .removeAppWorkDirectory(let path):
            let prefix = scope.appDirectory + "/" + scope.resourcePrefix + "-builds/"
            guard path.hasPrefix(prefix), !path.dropFirst(prefix.count).isEmpty, !path.dropFirst(prefix.count).contains("/"), !path.contains(".."), path.range(of: #"^[A-Za-z0-9/_.-]+$"#, options: .regularExpression) != nil else { throw denial("That work folder is outside this transaction.") }
            return .work(path)
        case .restoreBackupTimer(let unit):
            let actual = try await BackendAppsRecoveryTimer.capture(scope: scope, unit: unit) { script in
                try await self.command(entry, script, maximumBytes: 4096)
            }
            return .timer(unit, actual.enabled, actual.active)
        }
    }
    private func recover(_ snapshot: Snapshot, entry: Entry) async throws -> Bool {
        let scope = entry.scope, q = BackendAppsRuntime.quote
        switch snapshot {
        case .lock(let path, let token):
            let result = try await command(entry, "set -eu; " + parentChecks(path, scope) + "; test ! -L \(q(path)); test -e \(q(path)) || exit 0; test ! -L \(q(path + "/owner")); test -f \(q(path + "/owner")); test \"$(cat -- \(q(path + "/owner")))\" = \(q(token)); rm -- \(q(path + "/owner")); rmdir -- \(q(path))", maximumBytes: 1024)
            return result.code == 0 && !result.truncated
        case .file(let path, let before):
            try await requireAppLock(entry)
            if let before {
                let temp = path + ".recovery-" + scope.transactionID.uuidString
                let script = parentChecks(path, scope) + "; set -eu; umask 077; test ! -L \(q(path)); trap 'rm -f -- \(q(temp))' EXIT; trap 'exit 130' HUP INT TERM; set -C; cat > \(q(temp)); chmod 600 \(q(temp)); sync -f \(q(temp)); mv -f -- \(q(temp)) \(q(path)); sync -f \(q(String(path[..<path.lastIndex(of: "/")!])))"
                let result = try await command(entry, script, input: before)
                guard result.code == 0, !result.truncated else { return false }
                let verified = try await command(entry, "set -eu; " + parentChecks(path, scope) + "; sha256sum -- \(q(path)) | cut -d ' ' -f1", maximumBytes: 128)
                let digest = SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined()
                return verified.code == 0 && !verified.truncated && verified.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == digest
            }
            let result = try await command(entry, "set -eu; " + parentChecks(path, scope) + "; test ! -L \(q(path)); rm -f -- \(q(path)); test ! -e \(q(path))")
            return result.code == 0 && !result.truncated
        case .container(let id, let running, let connected, let aliases):
            try await requireAppLock(entry); _ = try await ownedContainer(entry, id)
            let network = scope.privateNetwork
            let current = try await ownedContainer(entry, id)["NetworkSettings"]["Networks"][network]
            if !current.isNullish {
                let body = BackendAppsValidation.object([("Container", .string(id)), ("Force", .bool(true))])
                guard try await docker(entry, "POST", "/networks/\(network)/disconnect", body.encodedJSON()).ok else { return false }
            }
            if connected {
                let body = BackendAppsValidation.object([("Container", .string(id)), ("EndpointConfig", BackendAppsValidation.object([("Aliases", .array(aliases.map(NativeRPCValue.string)))]))])
                guard try await docker(entry, "POST", "/networks/\(network)/connect", body.encodedJSON()).ok else { return false }
            }
            let status = try await docker(entry, "POST", "/containers/\(id)/" + (running ? "start" : "stop?t=10"))
            guard status.ok || status.status == 304 else { return false }
            let checked = try await ownedContainer(entry, id)
            return checked["State"]["Running"].bool == running && !checked["NetworkSettings"]["Networks"][network].isNullish == connected
        case .route(let id, let collection, let previous):
            let acquired = try await acquireRouteLock(entry)
            do {
                let found = try await caddy(entry, "GET", "/id/" + id)
                guard found.ok || found.status == 404 else { throw denial("The owned app route could not be checked.") }
                if let previous {
                    let response = try await caddy(entry, found.status == 404 ? "PUT" : "PATCH", found.status == 404 ? collection + "/0" : "/id/" + id, previous.encodedJSON())
                    guard response.ok else { throw denial("The owned app route could not be restored.") }
                } else if found.status != 404 {
                    guard try await caddy(entry, "DELETE", "/id/" + id).ok else { throw denial("The transaction's app route could not be withdrawn.") }
                }
                let verified = try await verifyRoute(entry, id, previous)
                if acquired { guard try await releaseRouteLock(entry) else { return false } }
                return verified
            } catch { if acquired { _ = try? await releaseRouteLock(entry) }; throw error }
        case .database(let baseline):
            try await requireAppLock(entry)
            return try await BackendAppsRecoveryDatabase.recover(scope: scope, baseline: baseline) { method, path, body in
                try await self.docker(entry, method, path, body)
            }
        case .candidates:
            try await requireAppLock(entry)
            let statePath = scope.appDirectory + "/state.json"
            let savedState = try await command(entry, "set -eu; " + parentChecks(statePath, scope) + "; test ! -L \(q(statePath)); cat -- \(q(statePath))")
            guard savedState.code == 0, !savedState.truncated, let state = try? BackendAppsValidation.json(Data(savedState.stdout.utf8)), state["id"].string == scope.appID else { return false }
            let filters = BackendAppsValidation.object([("label", .array([.string("io.terminaldeck.app=" + scope.appID), .string("io.terminaldeck.managed=true"), .string("io.terminaldeck.transaction=" + scope.ownerToken)]))]).compact.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            let listed = try await docker(entry, "GET", "/containers/json?all=true&filters=" + filters)
            guard listed.ok, let rows = try listed.value().elements, rows.count <= 16 else { return false }
            for row in rows {
                guard row["Labels"]["io.terminaldeck.app"].string == scope.appID, row["Labels"]["io.terminaldeck.transaction"].string == scope.ownerToken,
                      row["Labels"]["io.terminaldeck.managed"].string == "true", let id = row["Id"].string else { return false }
                _ = try BackendAppsValidation.identifier(id)
                let inspected = try await ownedContainer(entry, id)
                guard inspected["Config"]["Labels"]["io.terminaldeck.transaction"].string == scope.ownerToken else { return false }
                if state["containerId"].string == id && state["status"].string == "running" { return false }
                if (state["deployments"].elements ?? []).contains(where: { $0["id"] == state["activeDeploymentId"] && $0["containerId"].string == id }) { return false }
                if state["kind"].string == "app" {
                    let routes = try await caddy(entry, "GET", "/config/apps/http/servers")
                    guard routes.ok || routes.status == 404 else { return false }
                    if routes.ok {
                        let ip = inspected["NetworkSettings"]["Networks"][scope.privateNetwork]["IPAddress"].string
                        guard let ip, !ip.isEmpty, let value = try? routes.value(), validHTTPServers(value) else { return false }
                        if routeUses(value, ip: ip) { return false }
                    }
                } else if ["postgres", "mysql", "redis", "mongodb"].contains(state["kind"].string ?? "") {
                    if inspected["State"]["Running"].bool == true {
                        // A running restore candidate may be the only viable
                        // service. A captured original must have been restored
                        // and positively checked before it can be retired.
                        let originals = entry.steps.values.filter { step in
                            if case .container(_, let running, let connected, _) = step.snapshot { return running && connected && step.completed == true }
                            return false
                        }
                        guard !originals.isEmpty else { return false }
                        for step in originals {
                            if case .container(let originalID, _, _, let aliases) = step.snapshot {
                                guard originalID != id else { return false }
                                let original = try await ownedContainer(entry, originalID)
                                guard original["State"]["Running"].bool == true, original["State"]["Health"]["Status"].string == "healthy",
                                      original["Config"]["Labels"]["io.terminaldeck.transaction"].string != scope.ownerToken,
                                      original["NetworkSettings"]["Networks"][scope.privateNetwork].fields != nil,
                                      Set((original["NetworkSettings"]["Networks"][scope.privateNetwork]["Aliases"].elements ?? []).compactMap(\.string)) == Set(aliases) else { return false }
                            }
                        }
                    }
                } else { return false }
                let removed = try await docker(entry, "DELETE", "/containers/\(id)?force=true&v=false")
                guard removed.ok || removed.status == 404 else { return false }
            }
            return true
        case .work(let path):
            try await requireAppLock(entry)
            let marker = path + "/.recovery-owner"
            let script = "set -eu; " + parentChecks(marker, scope) + "; test -e \(q(path)) || exit 0; test ! -L \(q(marker)); test \"$(cat -- \(q(marker)))\" = \(q(scope.ownerToken)); rm -rf -- \(q(path)); test ! -e \(q(path))"
            let result = try await command(entry, script); return result.code == 0 && !result.truncated
        case .timer(let unit, let enabled, let active):
            try await requireAppLock(entry)
            return try await BackendAppsRecoveryTimer.restore(scope: scope, unit: unit, enabled: enabled, active: active) { script in
                try await self.command(entry, script, maximumBytes: 4096)
            }
        }
    }
    private func ownedContainer(_ entry: Entry, _ id: String) async throws -> NativeRPCValue {
        let response = try await docker(entry, "GET", "/containers/\(id)/json")
        guard response.ok, let value = try? response.value(), value["Id"].string == id,
              value["Config"]["Labels"]["io.terminaldeck.app"].string == entry.scope.appID,
              value["Config"]["Labels"]["io.terminaldeck.managed"].string == "true" else { throw denial("That service is not owned by the captured app.") }
        return value
    }
    private func routeUses(_ value: NativeRPCValue, ip: String) -> Bool {
        if let fields = value.fields {
            return fields.contains { field in
                if field.key == "dynamic_upstreams", !field.value.isNullish { return true }
                if field.key == "dial" {
                    guard var dial = field.value.string else { return true }
                    if dial.contains("{") || dial.contains("}") { return true }
                    if let slash = dial.firstIndex(of: "/") {
                        guard ["tcp", "tcp4", "tcp6"].contains(String(dial[..<slash])) else { return true }
                        dial = String(dial[dial.index(after: slash)...])
                    }
                    let host = String(dial.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
                    guard parts.count == 4 else { return true }
                    let bytes = parts.compactMap { Int($0) }
                    guard bytes.count == 4, bytes.allSatisfy({ (0...255).contains($0) }), parts.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return true }
                    return bytes.map(String.init).joined(separator: ".") == ip
                }
                return routeUses(field.value, ip: ip)
            }
        }
        return value.elements?.contains(where: { routeUses($0, ip: ip) }) == true
    }
    private func validHTTPServers(_ value: NativeRPCValue) -> Bool {
        guard let servers = value.fields else { return false }
        return servers.allSatisfy { server in
            guard server.value.fields != nil else { return false }
            let routes = server.value["routes"]
            if routes.isNullish { return true }
            guard let rows = routes.elements else { return false }
            return rows.allSatisfy { $0.fields != nil }
        }
    }
    private func requireAppLock(_ entry: Entry) async throws { try await requireLock(entry, entry.scope.appDirectory + "/.lock") }
    private func acquireRouteLock(_ entry: Entry) async throws -> Bool {
        let q = BackendAppsRuntime.quote, path = entry.scope.caddyLockPath, token = entry.scope.ownerToken
        let script = """
        set -eu
        umask 077
        \(parentChecks(path, entry.scope))
        test ! -L \(q(path))
        if test -d \(q(path)); then
          test ! -L \(q(path + "/owner"))
          test -f \(q(path + "/owner"))
          test "$(cat -- \(q(path + "/owner")))" = \(q(token))
          printf '%s' held
        else
          mkdir -- \(q(path))
          printf '%s' \(q(token)) > \(q(path + "/owner"))
          chmod 600 -- \(q(path + "/owner"))
          printf '%s' acquired
        fi
        """
        let result = try await command(entry, script, maximumBytes: 128)
        guard result.code == 0, !result.truncated, ["held", "acquired"].contains(result.stdout) else { throw denial("Another transaction owns the address lock; recovery stopped.") }
        return result.stdout == "acquired"
    }
    private func releaseRouteLock(_ entry: Entry) async throws -> Bool {
        let q = BackendAppsRuntime.quote, path = entry.scope.caddyLockPath
        let script = "set -eu; test ! -L \(q(path)); test ! -L \(q(path + "/owner")); test \"$(cat -- \(q(path + "/owner")))\" = \(q(entry.scope.ownerToken)); rm -- \(q(path + "/owner")); rmdir -- \(q(path))"
        let result = try await command(entry, script, maximumBytes: 128)
        return result.code == 0 && !result.truncated
    }
    private func requireLock(_ entry: Entry, _ path: String) async throws {
        let q = BackendAppsRuntime.quote
        let result = try await command(entry, "test ! -L \(q(path)) && test ! -L \(q(path + "/owner")) && test \"$(cat -- \(q(path + "/owner")))\" = \(q(entry.scope.ownerToken))", maximumBytes: 128)
        guard result.code == 0, !result.truncated else { throw denial("The transaction no longer owns its recovery lock.") }
    }
    private func verifyRoute(_ entry: Entry, _ id: String, _ expected: NativeRPCValue?) async throws -> Bool {
        guard let path = entry.scope.caddyAutosavePath, path.hasPrefix("/"), !path.contains(".."), path.range(of: #"^[A-Za-z0-9/_.-]+$"#, options: .regularExpression) != nil else { return false }
        let q = BackendAppsRuntime.quote
        let saved = try await command(entry, "set -eu; " + parentChecks(path, entry.scope) + "; test ! -L \(q(path)); cat -- \(q(path))")
        guard saved.code == 0, !saved.truncated, let config = try? BackendAppsValidation.json(Data(saved.stdout.utf8)) else { return false }
        let rows = config["apps"]["http"]["servers"][entry.scope.caddyServerKey ?? "terminaldeck"]["routes"].elements ?? []
        let actual = rows.first { $0["@id"].string == id }
        if expected == nil { return actual == nil }
        guard let actual, let expected else { return false }
        return equivalent(actual, expected)
    }
    private func equivalent(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool {
        if let af = a.fields, let bf = b.fields { return af.count == bf.count && af.allSatisfy { f in bf.contains { $0.key == f.key && equivalent($0.value, f.value) } } }
        if let ae = a.elements, let be = b.elements { return ae.count == be.count && zip(ae, be).allSatisfy { pair in equivalent(pair.0, pair.1) } }
        return a == b
    }
    private func scopedLock(_ path: String, _ scope: BackendAppsRecoveryScope) -> Bool {
        if path == scope.appDirectory + "/.lock" || path == scope.caddyLockPath { return true }
        let prefix = scope.stateRoot + "/" + (scope.resourcePrefix == "td-test" ? "td-test-removed-" : ".removed-") + scope.appID + "-"
        return path.hasPrefix(prefix) && path.hasSuffix("/.lock") && !path.contains("..") && path.dropFirst(prefix.count).dropLast(6).contains("/") == false
    }
    private func scopedFile(_ path: String, _ scope: BackendAppsRecoveryScope) -> Bool {
        let files: Set<String> = ["state.json", ".env", "backup-policy.json", "backup-run.sh", ".backup-s3-credentials", "push-deliveries.json", "data-restore-intent.json", "data-backup-policy-recovery.json", "data-binding-intent.json"]
        if path.hasPrefix(scope.appDirectory + "/"), files.contains(String(path.dropFirst(scope.appDirectory.count + 1))) { return true }
        let bindingPrefix = scope.appDirectory + "/.data-binding-"
        if path.hasPrefix(bindingPrefix) {
            let tail = String(path.dropFirst(bindingPrefix.count))
            for suffix in [".env", ".state.json"] where tail.hasSuffix(suffix) {
                let nonce = String(tail.dropLast(suffix.count))
                if nonce.count == 36 && UUID(uuidString: nonce) != nil { return true }
            }
        }
        return ["service", "timer"].contains { path == "/etc/systemd/system/" + scope.resourcePrefix + "-" + scope.appID + "-backup." + $0 }
    }
    private func parentChecks(_ path: String, _ scope: BackendAppsRecoveryScope) -> String {
        var current = "", checks: [String] = []
        for piece in path.split(separator: "/").dropLast() { current += "/" + piece; checks.append("test ! -L " + BackendAppsRuntime.quote(current) + " || exit 45") }
        return checks.joined(separator: "; ")
    }
}

fileprivate extension BackendAppsRecoveryHandle {
    init(transaction: UUID, nonce: UUID) { self.transaction = transaction; self.nonce = nonce }
}
