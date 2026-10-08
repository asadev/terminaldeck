import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Real core receipts, caller tickets and production approval guard. Only the
/// post-guard I/O counter is fake; no SSH, Engine, PTY or process is started.
/// These tests preserve the ordinary-I/O refusal that a separate, narrowly
/// authorized cleanup receipt must not weaken.
@MainActor
final class BackendAppsMCPCancellationTests: XCTestCase {
    private struct Rig: Sendable {
        let control: BackendDeckCoreSecurityControl
        let joins: BackendCompositionProductionBindings
        let authority: BackendCompositionAuthority
        let approval: BackendDockerMCPServerApproval
        let questions: BackendDeckCoreSecurityTestBox<Int>

        func call(_ tool: String, arguments: NativeRPCValue) async throws {
            let caller = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter],
                                                       keyID: "fixture-key", keyName: "Fixture", askFirst: false)
            let cancellation = BackendMCPCancellation()
            let grant = BackendDeckCoreSecurityGrant(attended: true, caller: { caller })
            let result = await BackendDeckCoreSecurityServer.authenticatedCall(grant: grant, scope: cancellation,
                wrapper: { [joins] grant, scope, operation in
                    try await joins.authenticated(grant: grant, cancellation: scope, operation: operation)
                }, call: { [control] in
                    await control.call(name: tool, arguments: arguments,
                                       options: .init(caller: caller, attended: true, cancellation: cancellation))
                })
            _ = try XCTUnwrap(result)
        }
    }

    private func rig() async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackendAppsMCPCancellation-" + UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let stateFile = directory.appendingPathComponent("data", isDirectory: true).appendingPathComponent("state.json", isDirectory: false)
        let store = try NativeStateStore(file: stateFile, ownership: .readOnly)
        let data = try XCTUnwrap(store.file).deletingLastPathComponent().standardizedFileURL
        let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: directory.path)
        let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
            registry: root.registry, copilotRoot: { _ in directory.appendingPathComponent("copilot", isDirectory: true).path })
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: directory,
            appName: "Terminal Deck Fixture", appID: "terminaldeck", helperExecutable: directory.appendingPathComponent("never-run-helper"),
            inheritedEnvironment: root.preparedSessions.environment)
        XCTAssertEqual(store.file?.deletingLastPathComponent().standardizedFileURL, configuration.dataDirectory.standardizedFileURL)
        XCTAssertEqual(root.preparedSessions.environment, configuration.inheritedEnvironment)
        let questions = BackendDeckCoreSecurityTestBox<Int>(0)
        let holder = BackendDeckCoreSecurityTestBox<BackendDeckCoreSecurityConsentBroker?>(nil)
        let consent = BackendDeckCoreSecurityConsentBroker(ask: { request in
            questions.edit { $0 += 1 }
            guard let broker = holder.get() else { return false }
            Task { _ = await broker.respond(id: request.id, approved: true, by: "window") }
            return true
        })
        holder.set(consent)
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: directory.appendingPathComponent("actions")), consent: consent)
        let joins = BackendCompositionProductionBindings(root: root, state: state, configuration: configuration)
        let authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state,
            configuration: configuration, coreContexts: joins.contexts, gate: control.compositionGate(), hidden: joins.hidden)
        try joins.bind(authority: authority)
        let approval = BackendDockerMCPServerApproval(authority: authority, consent: consent, knownServer: { $0 == "saved-server" })
        addTeardownBlock {
            await consent.stop()
            holder.set(nil)
            authority.close()
            await state.stop()
            try await root.shutdown()
        }
        return Rig(control: control, joins: joins, authority: authority, approval: approval, questions: questions)
    }

    private func runtime(_ rig: Rig, io: BackendDeckCoreSecurityTestBox<Int>) -> BackendAppsRuntime {
        .init(execute: { server, _, _, _, _ in
            // Same trusted callback entry as production checkIO; delegates
            // to its real authority/approval rather than a fake ticket table.
            guard let context = NativeCompositionCallContext.rpc else {
                throw NativeRPCError(code: "access-denied", message: "This server operation has no current caller.")
            }
            try await rig.approval.authorize(context: context, channel: "apps:transport", target: server,
                                             changing: false, summary: "Fixture I/O", arguments: .object([]))
            io.edit { $0 += 1 }
            return .init(code: 0, stdout: "")
        })
    }

    private func install(_ rig: Rig, handler: @escaping BackendNativeMCPServer.Handler) async throws {
        let tool = try XCTUnwrap(try BackendAppsMCP.specifications().first { $0.id == "apps.restart" })
        let bundle = try BackendDockerMCPComposition.bundle(registrations: [(tool, handler)], joins: rig.joins,
            validate: { try BackendAppsMCP.validate(tool: $0, arguments: $1) },
            summary: { BackendAppsMCP.summary(tool: $0, arguments: $1) },
            preflight: { context, _, arguments in try await rig.approval.checkScope(caller: context.caller, target: arguments["serverId"].string) })
        try await rig.control.register(bundle.policies)
    }

    private var arguments: NativeRPCValue { .object([.init("serverId", .string("saved-server")), .init("appId", .string("demo"))]) }

    func testFreshCleanupTaskKeepsRPCButCannotReviveCancelledMutationTicket() async throws {
        let r = try await rig(), io = BackendDeckCoreSecurityTestBox<Int>(0)
        let observed = BackendDeckCoreSecurityTestBox<NativeRPCValue>(.missing)
        let runtime = runtime(r, io: io)
        try await install(r) { [authority = r.authority, joins = r.joins] native, _ in
            try await joins.prepareNative(native, tier: .alter, sentence: "Restart app demo on saved-server", ownerMustAnswer: true)
            let rpc = try await authority.rpc(native)
            try authority.authorizeMutation(rpc)
            native.cancellation.cancel()
            let value = await NativeCompositionCallContext.$rpc.withValue(rpc) {
                await Task { () -> NativeRPCValue in
                    let inherited = NativeCompositionCallContext.rpc
                    let taskCancelled = Task.isCancelled
                    do {
                        _ = try await runtime.execute("saved-server", "fixture-cleanup", nil, 10_000, 1024)
                        return .object([.init("dispatched", .bool(true))])
                    } catch {
                        return .object([.init("dispatched", .bool(false)), .init("code", .string((error as? NativeRPCError)?.code ?? "unexpected")),
                                        .init("sameOwner", .bool(inherited?.ownerID == rpc.ownerID)),
                                        .init("sameRequest", .bool(inherited?.requestID == rpc.requestID)), .init("taskCancelled", .bool(taskCancelled))])
                    }
                }.value
            }
            observed.set(value)
            return .value(.object([.init("checked", .bool(true))]))
        }
        try await r.call("apps.restart", arguments: arguments)
        let value = observed.get()
        XCTAssertEqual(r.questions.get(), 1)
        XCTAssertEqual(value["sameOwner"].bool, true)
        XCTAssertEqual(value["sameRequest"].bool, true)
        XCTAssertEqual(value["taskCancelled"].bool, false)
        XCTAssertEqual(value["code"].string, "unavailable")
        XCTAssertEqual(value["dispatched"].bool, false)
        XCTAssertEqual(io.get(), 0)
    }

    func testDetachedCleanupHasNoRPCWhileOriginalApprovedCallIsStillUsable() async throws {
        let r = try await rig(), io = BackendDeckCoreSecurityTestBox<Int>(0)
        let observed = BackendDeckCoreSecurityTestBox<NativeRPCValue>(.missing)
        let runtime = runtime(r, io: io)
        try await install(r) { [authority = r.authority, joins = r.joins] native, _ in
            try await joins.prepareNative(native, tier: .alter, sentence: "Restart app demo on saved-server", ownerMustAnswer: true)
            let rpc = try await authority.rpc(native)
            try authority.authorizeMutation(rpc)
            try await NativeCompositionCallContext.$rpc.withValue(rpc) {
                let value = await Task.detached { () -> NativeRPCValue in
                    let missing = NativeCompositionCallContext.rpc == nil
                    do {
                        _ = try await runtime.execute("saved-server", "fixture-cleanup", nil, 10_000, 1024)
                        return .object([.init("dispatched", .bool(true))])
                    } catch {
                        return .object([.init("dispatched", .bool(false)), .init("missingRPC", .bool(missing)),
                                        .init("code", .string((error as? NativeRPCError)?.code ?? "unexpected"))])
                    }
                }.value
                observed.set(value)
                // Prove the detached failure was missing provenance, not an
                // already cancelled/revoked original call or unavailable I/O.
                _ = try await runtime.execute("saved-server", "fixture-original", nil, 10_000, 1024)
            }
            return .value(.object([.init("checked", .bool(true))]))
        }
        try await r.call("apps.restart", arguments: arguments)
        let value = observed.get()
        XCTAssertEqual(r.questions.get(), 1)
        XCTAssertEqual(value["missingRPC"].bool, true)
        XCTAssertEqual(value["code"].string, "access-denied")
        XCTAssertEqual(value["dispatched"].bool, false)
        XCTAssertEqual(io.get(), 1)
    }
}
