import Foundation
import CryptoKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Real core consent, effect receipts and caller authority; recovery transports
/// are pinned fixture callbacks only. No SSH, Docker, Caddy or other I/O runs.
@MainActor
final class BackendAppsMCPRecoveryAuthorityTests: XCTestCase {
    private actor FactoryPause {
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() {
            released = true
            waiter?.resume(); waiter = nil
        }
    }

    private struct Rig: Sendable {
        let control: BackendDeckCoreSecurityControl
        let log: BackendDeckCoreSecurityActionLog
        let joins: BackendCompositionProductionBindings
        let authority: BackendCompositionAuthority
        let approval: BackendDockerMCPServerApproval
        let consent: BackendDeckCoreSecurityConsentBroker
        let questions: BackendDeckCoreSecurityTestBox<Int>

        func call(_ tool: String, arguments: NativeRPCValue, caller: BackendDeckCoreSecurityCaller) async throws -> BackendDeckCoreSecurityCallResult {
            let scope = BackendMCPCancellation()
            let grant = BackendDeckCoreSecurityGrant(attended: true, caller: { caller })
            let result = await BackendDeckCoreSecurityServer.authenticatedCall(grant: grant, scope: scope,
                wrapper: { [joins] grant, cancellation, operation in
                    try await joins.authenticated(grant: grant, cancellation: cancellation, operation: operation)
                }, call: { [control] in
                    await control.call(name: tool, arguments: arguments, options: .init(caller: caller, cancellation: scope))
                })
            return try XCTUnwrap(result)
        }
    }

    private struct Fixture: Sendable {
        let issuer: BackendAppsMCPRecoveryAuthority
        let kernel: BackendAppsRecovery
        let runtime: BackendAppsRuntime
        let captures: BackendDeckCoreSecurityTestBox<Int>
        let pinnedIO: BackendDeckCoreSecurityTestBox<Int>
        let ordinaryIO: BackendDeckCoreSecurityTestBox<Int>
        let closes: BackendDeckCoreSecurityTestBox<Int>
        let audits: BackendDeckCoreSecurityTestBox<[NativeRPCValue]>
        let clock: BackendDeckCoreSecurityTestBox<Double>
        let livePin: BackendDeckCoreSecurityTestBox<Bool>
        let fileContents: BackendDeckCoreSecurityTestBox<Data>
    }

    private struct Sealed: Sendable {
        let transaction: BackendAppsRecoveryTransaction
        let handle: BackendAppsRecoveryHandle
        let rpc: NativeRPCContext
    }

    private let key = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter],
        keyID: "recovery-key", keyName: "Fixture AI", askFirst: false)
    private var arguments: NativeRPCValue { .object([.init("serverId", .string("saved-server")), .init("appId", .string("demo"))]) }
    nonisolated private static let beforeImage = "PASSWORD=fixture-recovery-secret"

    private func rig(approve: Bool = true, deliverOnly: Bool = false,
                     onQuestion: @escaping @Sendable () -> Void = {}) async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackendAppsMCPRecoveryAuthority-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let stateFile = directory.appendingPathComponent("data", isDirectory: true).appendingPathComponent("state.json", isDirectory: false)
        let store = try NativeStateStore(file: stateFile, ownership: .readOnly)
        let data = try XCTUnwrap(store.file).deletingLastPathComponent().standardizedFileURL
        let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: directory.path)
        let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
            registry: root.registry, copilotRoot: { _ in directory.appendingPathComponent("copilot").path })
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: directory,
            appName: "Terminal Deck Fixture", appID: "terminaldeck", helperExecutable: directory.appendingPathComponent("never-run-helper"), inheritedEnvironment: root.preparedSessions.environment)
        let questions = BackendDeckCoreSecurityTestBox<Int>(0)
        let holder = BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityConsentBroker?>(nil)
        let consent = BackendDeckCoreSecurityConsentBroker(ask: { question in
            questions.edit { $0 += 1 }
            onQuestion()
            guard approve else { return false }
            if deliverOnly { return true }
            let broker = holder.get()
            Task { _ = await broker?.respond(id: question.id, approved: true, by: "window") }
            return true
        })
        holder.set(consent)
        let log = BackendDeckCoreSecurityActionLog(directory: directory.appendingPathComponent("actions"))
        let control = try BackendDeckCoreSecurityControl(log: log, consent: consent)
        let joins = BackendCompositionProductionBindings(root: root, state: state, configuration: configuration)
        let authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state,
            configuration: configuration, coreContexts: joins.contexts, gate: control.compositionGate(), hidden: joins.hidden)
        try joins.bind(authority: authority)
        let approval = BackendDockerMCPServerApproval(authority: authority, consent: consent,
            knownServer: { ["saved-server", "other-server"].contains($0) })
        addTeardownBlock {
            await consent.stop(); holder.set(nil); authority.close()
            await state.stop(); try await root.shutdown()
        }
        return Rig(control: control, log: log, joins: joins, authority: authority, approval: approval, consent: consent, questions: questions)
    }

    private func fixture(_ r: Rig, beforeFactoryReturns: @escaping @Sendable () async -> Void = {}) async throws -> Fixture {
        let captures = BackendDeckCoreSecurityTestBox<Int>(0), pinned = BackendDeckCoreSecurityTestBox<Int>(0)
        let ordinary = BackendDeckCoreSecurityTestBox<Int>(0), closes = BackendDeckCoreSecurityTestBox<Int>(0)
        let audits = BackendDeckCoreSecurityTestBox<[NativeRPCValue]>([]), clock = BackendDeckCoreSecurityTestBox<Double>(100)
        let live = BackendDeckCoreSecurityTestBox<Bool>(true)
        let fileContents = BackendDeckCoreSecurityTestBox<Data>(Data(Self.beforeImage.utf8))
        let namespace = try BackendAppsMCPRecoveryNamespace(stateRoot: "/var/lib/terminaldeck/apps", resourcePrefix: "terminaldeck",
            privateNetwork: "terminaldeck-apps", caddyServerKey: "terminaldeck",
            caddyAutosavePath: "/var/lib/caddy/terminaldeck/config/caddy/autosave.json")
        let issuer = BackendAppsMCPRecoveryAuthority(authority: r.authority, approval: r.approval, namespace: namespace,
            factory: { scope, _, authorizeRegistration in
                captures.edit { $0 += 1 }
                await beforeFactoryReturns()
                let deadline = clock.get() + scope.lifetimeSeconds
                return BackendAppsRecoveryTransport(execute: { server, command, stdin, _, _ in
                    guard server == scope.serverID, live.get(), clock.get() < deadline else {
                        throw NativeRPCError(code: "access-denied", message: "The pinned fixture connection expired.")
                    }
                    pinned.edit { $0 += 1 }
                    if let stdin {
                        XCTAssertEqual(stdin, Data(Self.beforeImage.utf8), "Only the captured before-image may be restored.")
                        fileContents.set(stdin)
                    }
                    if command.contains("sha256sum --"), command.contains(".env") {
                        let digest = SHA256.hash(data: fileContents.get()).map { String(format: "%02x", $0) }.joined()
                        return .init(code: 0, stdout: digest + "\n")
                    }
                    let contents = stdin == nil && command.contains("cat --") && command.contains(".env")
                        ? String(decoding: fileContents.get(), as: UTF8.self) : ""
                    return .init(code: 0, stdout: contents)
                }, docker: { _, _, _, _ in
                    XCTFail("These recovery plans never need Docker HTTP.")
                    throw NativeRPCError(code: "unavailable", message: "Fixture HTTP is unavailable.")
                }, caddy: { _, _, _, _ in
                    XCTFail("These recovery plans never need Caddy HTTP.")
                    throw NativeRPCError(code: "unavailable", message: "Fixture HTTP is unavailable.")
                }, authorizeRegistration: authorizeRegistration, validateBinding: {
                    guard live.get(), clock.get() < deadline else {
                        throw NativeRPCError(code: "access-denied", message: "The pinned fixture connection expired.")
                    }
                }, close: { closes.edit { $0 += 1 } })
            }, audit: { record in audits.edit { $0.append(record.value) } }, originalAction: { context in
                let native = try await r.authority.nativeCaller(context)
                return try await r.joins.nativeTool(native)
            }, monotonic: { clock.get() })
        let kernel = await issuer.kernel()
        let runtime = BackendAppsRuntime(execute: { [approval = r.approval] server, _, _, _, _ in
            guard let rpc = NativeCompositionCallContext.rpc else {
                throw NativeRPCError(code: "access-denied", message: "The fixture I/O has no caller.")
            }
            try await approval.authorize(context: rpc, channel: "apps:transport", target: server, changing: true,
                                         summary: "Fixture ordinary write", arguments: .object([]))
            ordinary.edit { $0 += 1 }; return .init(code: 0, stdout: "")
        }, privateNetwork: "terminaldeck-apps", resourcePrefix: "terminaldeck", caddyServerKey: "terminaldeck",
            caddyAutosavePath: "/var/lib/caddy/terminaldeck/config/caddy/autosave.json", stateRoot: "/var/lib/terminaldeck/apps", recovery: kernel)
        addTeardownBlock { await kernel.shutdown() }
        return Fixture(issuer: issuer, kernel: kernel, runtime: runtime, captures: captures, pinnedIO: pinned,
            ordinaryIO: ordinary, closes: closes, audits: audits, clock: clock, livePin: live, fileContents: fileContents)
    }

    private func install(_ r: Rig, toolID: String = "apps.restart", handler: @escaping BackendNativeMCPServer.Handler) async throws {
        let tool = try XCTUnwrap(try BackendAppsMCP.specifications().first { $0.id == toolID })
        let bundle = try BackendDockerMCPComposition.bundle(registrations: [(tool, handler)], joins: r.joins,
            validate: { try BackendAppsMCP.validate(tool: $0, arguments: $1) },
            summary: { BackendAppsMCP.summary(tool: $0, arguments: $1) },
            preflight: { context, _, args in try await r.approval.checkScope(caller: context.caller, target: args["serverId"].string) })
        try await r.control.register(bundle.policies)
    }

    nonisolated private static func action(_ channel: String = "apps:restart", app: String? = "demo") -> BackendAppsAction {
        .init(channel: channel, serverID: "saved-server", appID: app, destructive: false, confirmation: nil,
              preview: .object([.init("channel", .string(channel)), .init("serverId", .string("saved-server")),
                                .init("appId", app.map(NativeRPCValue.string) ?? .null)]))
    }

    nonisolated private static func prepare(_ r: Rig, _ f: Fixture, native: BackendMCPCallContext) async throws -> NativeRPCContext {
        try await r.joins.prepareNative(native, tier: .alter, sentence: "Restart app demo", ownerMustAnswer: true)
        let rpc = try await r.authority.rpc(native)
        try await f.issuer.authorizeAndRecord(action: action(), context: rpc)
        return rpc
    }

    nonisolated private static func denied(_ operation: @Sendable () async throws -> Void) async {
        do { try await operation(); XCTFail("A mismatched or expired recovery capability must be refused.") }
        catch { XCTAssertTrue(error is NativeRPCError || error is CancellationError || error is BackendSessionFailure) }
    }

    func testReadOnlyGrantAndUnapprovedWriteNeverCaptureTransport() async throws {
        for approved in [false, true] {
            let r = try await rig(approve: approved), f = try await fixture(r)
            let entered = BackendDeckCoreSecurityTestBox<Int>(0)
            try await install(r) { native, _ in
                entered.edit { $0 += 1 }
                let rpc = try await Self.prepare(r, f, native: native)
                _ = try await NativeCompositionCallContext.$rpc.withValue(rpc) {
                    try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo")
                }
                return .value(.null)
            }
            let caller = approved ? BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read], keyID: "read-only", askFirst: false) : key
            let result = try await r.call("apps.restart", arguments: arguments, caller: caller)
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.refusal, approved ? .notGranted : .noApprover)
            XCTAssertEqual(entered.get(), 0); XCTAssertEqual(f.captures.get(), 0)
            XCTAssertEqual(f.pinnedIO.get(), 0); XCTAssertEqual(f.ordinaryIO.get(), 0)
        }
    }

    func testReadActionCreatesNoRecoveryRecordAndCannotMintTransport() async throws {
        let r = try await rig(), f = try await fixture(r)
        try await install(r, toolID: "apps.read") { native, _ in
            let rpc = try await r.authority.rpc(native)
            try await f.issuer.authorizeAndRecord(action: Self.action("apps:read"), context: rpc)
            await NativeCompositionCallContext.$rpc.withValue(rpc) {
                await Self.denied { _ = try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo") }
            }
            return .value(.object([.init("checked", .bool(true))]))
        }
        let result = try await r.call("apps.read", arguments: arguments, caller: key)
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(r.questions.get(), 0); XCTAssertEqual(f.captures.get(), 0); XCTAssertEqual(f.pinnedIO.get(), 0)
    }

    func testStandingKeyStillAsksAndAcceptedReceiptPinsOnce() async throws {
        let r = try await rig(), f = try await fixture(r)
        try await install(r) { native, _ in
            let rpc = try await Self.prepare(r, f, native: native)
            try await NativeCompositionCallContext.$rpc.withValue(rpc) {
                let transaction = try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo")
                _ = try await transaction.register(.releaseOwnedLock(path: transaction.scope.appDirectory + "/.lock", ownerToken: transaction.scope.ownerToken))
                await f.kernel.finish(transaction)
            }
            return .value(.object([.init("checked", .bool(true))]))
        }
        let result = try await r.call("apps.restart", arguments: arguments, caller: key)
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(r.questions.get(), 1); XCTAssertEqual(f.captures.get(), 1)
        XCTAssertEqual(f.pinnedIO.get(), 0); XCTAssertEqual(f.closes.get(), 1)
        XCTAssertEqual(result.row["confirmed"]["by"].string, "window")
    }

    func testCoreConsentWithoutDomainReceiptCannotRecordRecoveryApproval() async throws {
        let r = try await rig(), f = try await fixture(r)
        try await install(r) { native, _ in
            let rpc = try await r.authority.rpc(native)
            await Self.denied { try await f.issuer.authorizeAndRecord(action: Self.action(), context: rpc) }
            await NativeCompositionCallContext.$rpc.withValue(rpc) {
                await Self.denied { _ = try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo") }
            }
            return .value(.object([.init("checked", .bool(true))]))
        }
        let result = try await r.call("apps.restart", arguments: arguments, caller: key)
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(r.questions.get(), 1); XCTAssertEqual(f.captures.get(), 0); XCTAssertEqual(f.pinnedIO.get(), 0)
    }

    func testServerAppOwnerRequestAndNamespaceMismatchesNeverPin() async throws {
        let r = try await rig(), f = try await fixture(r)
        try await install(r) { native, _ in
            let rpc = try await Self.prepare(r, f, native: native)
            await NativeCompositionCallContext.$rpc.withValue(rpc) {
                for (server, app) in [("other-server", "demo"), ("saved-server", "other")] {
                    await Self.denied { _ = try await f.kernel.begin(runtime: f.runtime, serverID: server, appID: app) }
                }
                let variants = [
                    BackendAppsRuntime(execute: f.runtime.execute, resourcePrefix: "td-test", caddyServerKey: "terminaldeck", stateRoot: "/var/lib/terminaldeck/apps"),
                    BackendAppsRuntime(execute: f.runtime.execute, caddyServerKey: "terminaldeck", stateRoot: "/var/lib/terminaldeck-apps"),
                    BackendAppsRuntime(execute: f.runtime.execute, privateNetwork: "other-network", caddyServerKey: "terminaldeck"),
                    BackendAppsRuntime(execute: f.runtime.execute, caddyServerKey: "other-server-key"),
                    BackendAppsRuntime(execute: f.runtime.execute, caddyServerKey: "terminaldeck", caddyAutosavePath: "/var/lib/caddy/other/autosave.json")
                ]
                for runtime in variants {
                    await Self.denied { _ = try await f.kernel.begin(runtime: runtime, serverID: "saved-server", appID: "demo") }
                }
            }
            let impostors: [NativeRPCContext?] = [
                NativeRPCContext(caller: .page, ownerID: rpc.ownerID, requestID: UUID()),
                NativeRPCContext(caller: .page, ownerID: "another-owner", requestID: rpc.requestID),
                nil
            ]
            for impostor in impostors {
                await NativeCompositionCallContext.$rpc.withValue(impostor) {
                    await Self.denied { _ = try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo") }
                }
            }
            return .value(.object([.init("checked", .bool(true))]))
        }
        let result = try await r.call("apps.restart", arguments: arguments, caller: key)
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(f.captures.get(), 0); XCTAssertEqual(f.pinnedIO.get(), 0)
    }

    func testCancelledRegistrationCannotAddPlansThroughRetainedRPC() async throws {
        let r = try await rig(), f = try await fixture(r)
        let refused = BackendDeckCoreSecurityTestBox<Bool>(false)
        try await install(r) { native, _ in
            let rpc = try await Self.prepare(r, f, native: native)
            try await NativeCompositionCallContext.$rpc.withValue(rpc) {
                let transaction = try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo")
                native.cancellation.cancel()
                await Task {
                    XCTAssertFalse(Task.isCancelled, "A fresh task does not revive the original RPC ticket.")
                    do {
                        _ = try await transaction.register(.restoreAppFile(path: transaction.scope.appDirectory + "/.env"))
                        XCTFail("Cancelled authority registered a recovery snapshot.")
                    } catch { refused.set(true) }
                }.value
                await f.kernel.finish(transaction)
            }
            return .value(.object([.init("checked", .bool(true))]))
        }
        _ = try await r.call("apps.restart", arguments: arguments, caller: key)
        XCTAssertTrue(refused.get()); XCTAssertEqual(f.captures.get(), 1)
        XCTAssertEqual(f.pinnedIO.get(), 0); XCTAssertEqual(f.closes.get(), 1)
    }

    func testSealedCleanupWorksAfterCancellationWhileOrdinaryIOStaysDeniedAndAuditHasNoSecrets() async throws {
        let r = try await rig(), f = try await fixture(r)
        let cleaned = BackendDeckCoreSecurityTestBox<Bool>(false), ordinaryRefused = BackendDeckCoreSecurityTestBox<Bool>(false)
        try await install(r) { native, _ in
            let rpc = try await Self.prepare(r, f, native: native)
            try await NativeCompositionCallContext.$rpc.withValue(rpc) {
                let transaction = try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo")
                let handle = try await transaction.register(.restoreAppFile(path: transaction.scope.appDirectory + "/.env"))
                f.fileContents.set(Data("PASSWORD=changed-by-fixture".utf8))
                native.cancellation.cancel()
                do { _ = try await f.runtime.execute("saved-server", "fixture-ordinary", nil, 1000, 1024); XCTFail("Ordinary I/O revived a cancelled caller.") }
                catch { ordinaryRefused.set(true) }
                let outcome = try await Task.detached {
                    XCTAssertNil(NativeCompositionCallContext.rpc)
                    return try await transaction.perform(handle)
                }.value
                cleaned.set(outcome.completed)
                await f.kernel.finish(transaction)
            }
            return .value(.object([.init("checked", .bool(true))]))
        }
        _ = try await r.call("apps.restart", arguments: arguments, caller: key)
        XCTAssertTrue(cleaned.get()); XCTAssertTrue(ordinaryRefused.get()); XCTAssertEqual(f.ordinaryIO.get(), 0)
        XCTAssertEqual(f.fileContents.get(), Data(Self.beforeImage.utf8))
        XCTAssertGreaterThan(f.pinnedIO.get(), 1); XCTAssertEqual(f.closes.get(), 1)
        XCTAssertFalse(f.audits.get().isEmpty)
        for record in f.audits.get() {
            XCTAssertFalse(record.compact.contains("fixture-recovery-secret"))
            XCTAssertFalse(record.compact.contains("changed-by-fixture"))
            XCTAssertFalse(record.compact.contains("PASSWORD="))
            XCTAssertFalse(record.compact.contains(".env"))
        }
        let rows = await r.log.tail()
        XCTAssertFalse(NativeRPCValue.array(rows).compact.contains("fixture-recovery-secret"))
    }

    func testReplayCrossTransactionAndExpiryCannotExpandCleanup() async throws {
        let r = try await rig(), f = try await fixture(r)
        let seals = BackendDeckCoreSecurityTestBox<[Sealed]>([])
        try await install(r) { native, _ in
            let rpc = try await Self.prepare(r, f, native: native)
            try await NativeCompositionCallContext.$rpc.withValue(rpc) {
                for _ in 0..<2 {
                    let transaction = try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo", lifetimeSeconds: 10)
                    let handle = try await transaction.register(.releaseOwnedLock(path: transaction.scope.appDirectory + "/.lock", ownerToken: transaction.scope.ownerToken))
                    seals.edit { $0.append(Sealed(transaction: transaction, handle: handle, rpc: rpc)) }
                }
            }
            return .value(.object([.init("checked", .bool(true))]))
        }
        let result = try await r.call("apps.restart", arguments: arguments, caller: key)
        XCTAssertTrue(result.ok, result.error ?? "")
        let first = try XCTUnwrap(seals.get().first), second = try XCTUnwrap(seals.get().last)
        await Self.denied { _ = try await second.transaction.perform(first.handle) }
        XCTAssertEqual(f.pinnedIO.get(), 0)
        let recovered = try await first.transaction.perform(first.handle)
        XCTAssertTrue(recovered.completed); XCTAssertEqual(f.pinnedIO.get(), 1)
        await Self.denied { _ = try await first.transaction.perform(first.handle) }
        XCTAssertEqual(f.pinnedIO.get(), 1)
        f.clock.set(110)
        await Self.denied { _ = try await second.transaction.perform(second.handle) }
        XCTAssertEqual(f.pinnedIO.get(), 1)
        await f.kernel.finish(first.transaction); await f.kernel.finish(second.transaction)
        XCTAssertEqual(f.closes.get(), 2)
    }

    func testLostPinnedServerLifetimeCannotRecoverOrReconnect() async throws {
        let r = try await rig(), f = try await fixture(r)
        let sealed = BackendDeckCoreSecurityTestBox<Sealed?>(nil)
        try await install(r) { native, _ in
            let rpc = try await Self.prepare(r, f, native: native)
            try await NativeCompositionCallContext.$rpc.withValue(rpc) {
                let transaction = try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo")
                let handle = try await transaction.register(.releaseOwnedLock(path: transaction.scope.appDirectory + "/.lock", ownerToken: transaction.scope.ownerToken))
                sealed.set(Sealed(transaction: transaction, handle: handle, rpc: rpc))
            }
            return .value(.object([.init("checked", .bool(true))]))
        }
        let result = try await r.call("apps.restart", arguments: arguments, caller: key)
        XCTAssertTrue(result.ok, result.error ?? "")
        let capability = try XCTUnwrap(sealed.get())
        f.livePin.set(false)
        let outcome = try await capability.transaction.perform(capability.handle)
        XCTAssertFalse(outcome.completed)
        XCTAssertNotNil(outcome.reason)
        XCTAssertEqual(f.captures.get(), 1, "Recovery must not capture a replacement connection.")
        XCTAssertEqual(f.pinnedIO.get(), 0); XCTAssertEqual(f.ordinaryIO.get(), 0)
        await f.kernel.finish(capability.transaction)
        XCTAssertEqual(f.closes.get(), 1)
    }

    func testRecoveryRegistrationCannotBroadenOwnedPathsLocksOrRoutes() async throws {
        let r = try await rig(), f = try await fixture(r)
        try await install(r) { native, _ in
            let rpc = try await Self.prepare(r, f, native: native)
            try await NativeCompositionCallContext.$rpc.withValue(rpc) {
                let transaction = try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo")
                let scope = transaction.scope
                for operation in [
                    BackendAppsRecoveryOperation.restoreAppFile(path: scope.stateRoot + "/other/.env"),
                    .releaseOwnedLock(path: scope.appDirectory + "/.lock", ownerToken: "another-token"),
                    .releaseOwnedLock(path: scope.stateRoot + "/other/.lock", ownerToken: scope.ownerToken),
                    .restoreCaddyRoute(routeID: "another-route", collectionPath: scope.routeCollectionPath),
                    .removeAppWorkDirectory(path: scope.appDirectory + "/../other/work")
                ] {
                    await Self.denied { _ = try await transaction.register(operation) }
                }
                await f.kernel.finish(transaction)
            }
            return .value(.object([.init("checked", .bool(true))]))
        }
        let result = try await r.call("apps.restart", arguments: arguments, caller: key)
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(f.captures.get(), 1); XCTAssertEqual(f.pinnedIO.get(), 0)
        XCTAssertEqual(f.closes.get(), 1)
    }

    func testOriginalCoreReceiptCannotApproveAnotherServerAppOrChannel() async throws {
        let r = try await rig(), f = try await fixture(r)
        try await install(r) { native, _ in
            try await r.joins.prepareNative(native, tier: .alter, sentence: "Restart app demo", ownerMustAnswer: true)
            let rpc = try await r.authority.rpc(native)
            let actions = [
                BackendAppsAction(channel: "apps:restart", serverID: "other-server", appID: "demo", destructive: false,
                    confirmation: nil, preview: .object([.init("channel", .string("apps:restart")), .init("serverId", .string("other-server")), .init("appId", .string("demo"))])),
                Self.action(app: "other"),
                Self.action("apps:deploy")
            ]
            for action in actions { await Self.denied { try await f.issuer.authorizeAndRecord(action: action, context: rpc) } }
            await NativeCompositionCallContext.$rpc.withValue(rpc) {
                await Self.denied { _ = try await f.kernel.begin(runtime: f.runtime, serverID: "other-server", appID: "demo") }
                await Self.denied { _ = try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "other") }
            }
            return .value(.object([.init("checked", .bool(true))]))
        }
        let result = try await r.call("apps.restart", arguments: arguments, caller: key)
        XCTAssertTrue(result.ok, result.error ?? "")
        XCTAssertEqual(r.questions.get(), 1); XCTAssertEqual(f.captures.get(), 0); XCTAssertEqual(f.pinnedIO.get(), 0)
    }

    func testShutdownDuringPendingNativeConsentCannotAdmitRecovery() async throws {
        let delivered = expectation(description: "Native consent delivered")
        let r = try await rig(deliverOnly: true, onQuestion: { delivered.fulfill() }), f = try await fixture(r)
        let rpc = try r.authority.localContext()
        let work = Task { try await f.issuer.authorizeAndRecord(action: Self.action(), context: rpc) }
        let deliveredResult = await XCTWaiter.fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(deliveredResult, .completed)
        let pending = await r.consent.list()
        let question = try XCTUnwrap(pending.first)
        XCTAssertEqual(question.origin, "window")
        await f.issuer.shutdown()
        let accepted = await r.consent.respond(id: question.id, approved: true, by: "window")
        XCTAssertTrue(accepted, "The real broker can settle; the closed issuer must still refuse admission.")
        await Self.denied { try await work.value }
        try r.authority.requireLocalUI(rpc)
        await NativeCompositionCallContext.$rpc.withValue(rpc) {
            await Self.denied { _ = try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo") }
        }
        XCTAssertEqual(r.questions.get(), 1); XCTAssertEqual(f.captures.get(), 0)
        XCTAssertEqual(f.pinnedIO.get(), 0); XCTAssertEqual(f.closes.get(), 0)
    }

    func testShutdownDuringFactoryAcquireRefusesAndClosesThePinOnce() async throws {
        let acquiring = expectation(description: "Pinned factory entered")
        let pause = FactoryPause()
        let r = try await rig(), f = try await fixture(r, beforeFactoryReturns: {
            acquiring.fulfill(); await pause.wait()
        })
        let rpc = try r.authority.localContext()
        try await f.issuer.authorizeAndRecord(action: Self.action(), context: rpc)
        let work = Task {
            try await NativeCompositionCallContext.$rpc.withValue(rpc) {
                try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo")
            }
        }
        let acquireResult = await XCTWaiter.fulfillment(of: [acquiring], timeout: 2)
        XCTAssertEqual(acquireResult, .completed)
        await f.issuer.shutdown()
        await pause.release()
        await Self.denied { _ = try await work.value }
        try r.authority.requireLocalUI(rpc)
        XCTAssertEqual(r.questions.get(), 1); XCTAssertEqual(f.captures.get(), 1)
        XCTAssertEqual(f.closes.get(), 1, "A raced factory result must release its one captured pin.")
        XCTAssertEqual(f.pinnedIO.get(), 0); XCTAssertEqual(f.ordinaryIO.get(), 0)
        XCTAssertFalse(f.audits.get().contains { $0["event"].string == "issued" })
    }

    func testRetainedIssuerCannotAdmitNewWorkAfterTerminalShutdown() async throws {
        let r = try await rig(), f = try await fixture(r)
        let rpc = try r.authority.localContext()
        try await f.issuer.authorizeAndRecord(action: Self.action(), context: rpc)
        XCTAssertEqual(r.questions.get(), 1)
        await f.issuer.shutdown()
        try r.authority.requireLocalUI(rpc)
        await Self.denied { try await f.issuer.authorizeAndRecord(action: Self.action(), context: rpc) }
        await NativeCompositionCallContext.$rpc.withValue(rpc) {
            await Self.denied { _ = try await f.kernel.begin(runtime: f.runtime, serverID: "saved-server", appID: "demo") }
        }
        XCTAssertEqual(r.questions.get(), 1, "Closed admission must not deliver another consent prompt.")
        XCTAssertEqual(f.captures.get(), 0); XCTAssertEqual(f.pinnedIO.get(), 0)
    }
}
