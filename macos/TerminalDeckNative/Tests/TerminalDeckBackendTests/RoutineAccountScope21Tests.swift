#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Real request/ticket and account-authorization boundaries, with a fake CLI.
/// No app, session host, model, network or real profile/vault is opened.
@MainActor
final class RoutineAccountScope21Tests: XCTestCase {
    func testAcceptedAsyncLaunchUsesCurrentOwnerAfterOriginalTicketExpires() async throws {
        let fixture = try await fixture(), ready = RoutineAccountScope21Latch()
        let capture = BackendRoutinesLaunchCapture()
        let native = BackendMCPCallContext(sessionID: "scope21-session", machineID: "scope21-machine", projectRoot: nil,
            attended: true, allowedTools: ["routines.run"], allowedTiers: [.read, .act], cancellation: .init())
        let core = BackendDeckCoreSecurityCallContext(native: native,
            caller: .init(kind: .key, tiers: [.read, .act], keyID: "scope21-key"), callID: UUID().uuidString,
            attended: true, granted: ["routines.run"], sessionLimits: .object([]), now: { 1_791_900_000_000 },
            startedByCopilot: { _ in false }, noteStarted: { _ in })
        let job = try await fixture.authority.coreContexts.withContext(core) { native in
            let original = try await fixture.authority.rpc(native)
            try fixture.authority.authorizeMetadata(original)
            try await fixture.authority.authorize(native, tool: "routines.run", arguments: .object([]),
                tier: .act, sentence: "Run the private fixture routine")
            return await BackendHOSTProfileScope.withContext(original) {
                await NativeCompositionCallContext.$rpc.withValue(original) {
                    Task {
                        await ready.wait()
                        let inherited = try? BackendHOSTProfileScope.requireCurrent()
                        let expired: Bool
                        do { try fixture.authority.authorizeMetadata(original); expired = false }
                        catch { expired = true }
                        let runner = BackendRoutinesCopilotRunner(options: .init(mcpConfig: { "/scope21/fake-unattended.json" },
                            copilotRoot: fixture.root, environment: [:],
                            launch: { await capture.launch($0, text: "NOTHING-TO-REPORT") }, actions: BackendRoutinesTestActions(),
                            hoot: { _ in
                                try await BackendRoutinesAppProfileScope.withOwner(authority: fixture.authority) {
                                    let context = try await fixture.authorizedAccountRead()
                                    guard context.caller == .nativeApp else { throw BackendHOSTFailure.authentication }
                                    return .init(provider: "claude", command: "/scope21/fake-claude", model: nil, effort: nil, environment: [:])
                                }
                            }))
                        let request = BackendRoutinesRunRequest(routine: .init(id: "scope21", name: "Private scope check",
                            triggers: [.manual], folder: fixture.root.path, prompt: "Read fake reports."),
                            runId: "scope21-run", cause: .manual(by: "user"), chain: [])
                        let outcome = await runner.run(request)
                        return RoutineAccountScope21Result(outcome: outcome, original: original, inherited: inherited, expired: expired,
                            restored: try? BackendHOSTProfileScope.requireCurrent())
                    }
                }
            }
        }
        // withContext has returned and cancelled the actual original call ticket.
        await ready.open()
        let result = await job.value
        XCTAssertTrue(result.expired, "The public request must still expire normally.")
        XCTAssertEqual(result.inherited?.requestID, result.original.requestID, "Reproduce TaskLocal inheritance.")
        XCTAssertTrue(result.outcome.ok, result.outcome.error ?? "")
        XCTAssertEqual(result.restored?.requestID, result.original.requestID, "The internal owner scope must not leak.")
        let launches = await capture.inputs
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches.first?.command, "/scope21/fake-claude")
        XCTAssertTrue(launches.first?.args.contains("--strict-mcp-config") == true)
        XCTAssertThrowsError(try fixture.authority.authorizeMetadata(result.original))
    }

    func testInternalFollowUpScopeOverridesInheritedPageAndRestoresIt() async throws {
        let fixture = try await fixture()
        let page = NativeRPCContext(caller: .page, ownerID: "unregistered-page")
        let result = try await BackendHOSTProfileScope.withContext(page) {
            let answer: BackendRoutinesRunOutcome = try await BackendRoutinesAppProfileScope.withOwner(authority: fixture.authority) {
                let owner = try await fixture.authorizedAccountRead()
                guard owner.ownerID == BackendCompositionRoot.appOwnerID else { throw BackendHOSTFailure.authentication }
                return .init(ok: true, output: "Fake follow-up completed.")
            }
            let restored = try BackendHOSTProfileScope.requireCurrent()
            return (answer, restored.requestID)
        }
        XCTAssertTrue(result.0.ok)
        XCTAssertEqual(result.1, page.requestID)
        XCTAssertThrowsError(try fixture.authority.authorizeMetadata(page))
        XCTAssertNil(BackendHOSTProfileScope.context)
    }

    func testMissingRevokedAndClosedAppOwnersRefuseBeforeWork() async throws {
        let fixture = try await fixture(), probe = RoutineAccountScope21Probe()
        for state in ["missing", "revoked", "closed"] {
            if state == "revoked" { fixture.authority.revokeLocalUI() }
            if state == "closed" { fixture.authority.close() }
            do {
                _ = try await BackendRoutinesAppProfileScope.withOwner(authority: state == "missing" ? nil : fixture.authority) {
                    await probe.touch()
                    return true
                }
                XCTFail("A \(state) app owner must not run the account lookup.")
            } catch let error as NativeRPCError {
                XCTAssertEqual(error.code, state == "missing" ? "unavailable" : "access-denied")
            }
        }
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
    }

    private func fixture() async throws -> RoutineAccountScope21Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-routine-account21-" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try NativeStateStore(file: root.appendingPathComponent("state.json"), ownership: .exclusive)
        let environment = ["HOME": home.path, "PATH": "/nonexistent"]
        let prepared = BackendCompositionSessions.Prepared(environment: environment)
        let registry = NativeChannelRegistry()
        let settings = BackendAppSettingsStore(userData: root, writable: true)
        let state = await BackendCompositionState.make(store: store, settings: settings,
            dataRoot: root, registry: registry, copilotRoot: { _ in root.appendingPathComponent("hoot").path })
        let configuration = try BackendAccountConfiguration(dataDirectory: root, homeDirectory: home,
            appName: "Scope21 fake", appID: "scope21", helperExecutable: URL(fileURLWithPath: "/nonexistent/helper"),
            inheritedEnvironment: prepared.environment)
        let authority = try BackendCompositionAuthority(prepared: prepared, state: state, configuration: configuration,
            coreContexts: BackendDeckCoreToolContextAuthority(), gate: .init(authorize: { core, tool, _, tier, _, _ in
                guard core.caller.keyID == "scope21-key", tool == "routines.run", tier == .act else { throw BackendHOSTFailure.authentication }
            }, record: { _, _, _, _ in throw BackendHOSTFailure.unavailable }), hidden: .init())
        let attachment = UUID()
        let accounts = BackendHOSTAccountControlAuthority(hostInstance: UUID(), currentAttachment: { attachment },
            authorizeRPC: { try await authority.authorizeSessionRPC($0, channel: $1, arguments: $2) },
            authorizeMetadata: { try authority.authorizeMetadata($0) }, authorizeMutation: { try authority.authorizeMutation($0) })
        addTeardownBlock {
            accounts.close(); authority.close()
            await state.stop(); await registry.shutdown(); await store.close()
            try? FileManager.default.removeItem(at: root)
        }
        return .init(root: root, authority: authority, accounts: accounts)
    }
}

private struct RoutineAccountScope21Fixture: Sendable {
    let root: URL
    let authority: BackendCompositionAuthority
    let accounts: BackendHOSTAccountControlAuthority
    func authorizedAccountRead() async throws -> NativeRPCContext {
        let context = try BackendHOSTProfileScope.requireCurrent()
        let request = try accounts.begin(channel: "host.profiles.find", arguments: [.string("scope21-fake-profile")], context: context)
        defer { accounts.complete(request.nonce) }
        let approval = try await accounts.authorize(request: request, cancellation: .init())
        guard approval.validates(request) else { throw BackendHOSTFailure.authentication }
        return context
    }
}

private struct RoutineAccountScope21Result: Sendable {
    let outcome: BackendRoutinesRunOutcome
    let original: NativeRPCContext
    let inherited: NativeRPCContext?
    let expired: Bool
    let restored: NativeRPCContext?
}

private actor RoutineAccountScope21Latch {
    private var opened = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func open() { opened = true; waiting?.resume(); waiting = nil }
}

private actor RoutineAccountScope21Probe {
    private(set) var calls = 0
    func touch() { calls += 1 }
}
#endif
