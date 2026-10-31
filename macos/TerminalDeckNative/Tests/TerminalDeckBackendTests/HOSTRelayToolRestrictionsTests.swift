import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor RelayRulesFixture {
    var snapshot: BackendHOSTProtocol.Snapshot
    var tools: Set<String> = ["demo.change", "tools.run"]
    var permitted = true
    var rules: NativeRPCValue
    var profileMissing = false
    var executed = 0
    init() {
        let allowed = NativeRPCValue.object([.init("action", .string("read")), .init("path", .string("safe"))])
        var input = BackendCreateSessionInput(cwd: "/fixture", provider: "codex")
        input.chat = true; input.agentProfileID = "saved-agent"
        let meta = BackendSessionMeta(id: "helper-session", input: input, spawn: .init(provider: "codex", command: "fixture", args: [], path: "/fixture"))
        snapshot = .init(sequence: 0, session: meta, pid: 1234, replay: "", screen: nil, scrollbackText: nil,
            status: .idle, input: input, scope: .init(.init(rememberTab: false, fromAI: true)))
        rules = .object([.init("version", .number(1)), .init("tools", .array([.object([
            .init("service", .string("demo")), .init("tool", .string("demo.change")),
            .init("cases", .array([.object([.init("arguments", allowed)])]))])]))])
    }
    func adoption() throws -> BackendHOSTSessionToolRelay.Adoption {
        guard permitted else { throw BackendHOSTFailure.authentication }
        return .init(snapshot: snapshot, currentTools: tools, currentTiers: [.read, .act, .alter], originalSessionLimits: .missing)
    }
    func live() -> BackendSessionMeta { snapshot.session }
    func profile(_ id: String) -> NativeRPCValue? {
        guard !profileMissing, id == "saved-agent" else { return nil }
        return .object([.init("id", .string(id)), .init("toolUseRestrictions", rules)])
    }
    func deny() { rules = .object([.init("version", .number(1)), .init("tools", .array([.object([.init("service", .string("demo")), .init("tool", .string("demo.change")), .init("cases", .array([]))])]))]) }
    func revoke() { permitted = false }
    func reconnect() { permitted = true; snapshot.pid = (snapshot.pid ?? 0) + 1 }
    func changeRoot() { snapshot.input?.taskProject = "/foreign" }
    func changeBirth() { snapshot.session = .init(id: "helper-session", input: snapshot.input!, spawn: .init(provider: "codex", command: "fixture", args: [], path: "/fixture"), now: Date(timeIntervalSince1970: 1)) }
    func changeAccount() { snapshot.session.profileId = "different-account" }
    func changeSession() { snapshot.session = .init(id: "foreign-session", input: snapshot.input!, spawn: .init(provider: "codex", command: "fixture", args: [], path: "/fixture")) }
    func changeScope() { snapshot.scope = .init(.init(rememberTab: false, isAppComposed: true)) }
    func removeProfile() { profileMissing = true }
    func shrinkGrant() { tools = ["tools.run"] }
    func hit() { executed += 1 }
    func count() -> Int { executed }
}

final class HOSTRelayToolRestrictionsTests: XCTestCase, @unchecked Sendable {
    private let args = NativeRPCValue.object([.init("action", .string("read")), .init("path", .string("safe"))])
    private func core() throws -> BackendDeckCoreSecurityControl {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-relay-rules-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try .init(log: .init(directory: root), consent: .init(ask: { _ in false }))
    }
    private func install(_ core: BackendDeckCoreSecurityControl, fixture: RelayRulesFixture,
                         precheck: (@Sendable () async -> Void)? = nil, effect: Bool = false) async throws {
        let inspector = BackendToolUseRestrictions(subject: { context in
            let caller = try await BackendToolUseRestrictions.authenticatedSessionCaller(context, endpoint: nil)
            // No app endpoint, task assignment, launchFacts or remembered-tab ledger exists.
            return try BackendToolUseRestrictions.resolve(caller: caller, live: await fixture.live(), task: nil,
                namedProfile: context.relaySessionProof?.agentProfileID, lead: false)
        }, profile: { await fixture.profile($0) })
        await core.setToolUseInspector { context, tool, args, expected in try await inspector.inspect(context, tool: tool, arguments: args, expected: expected) }
        let schema = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"action":{"type":"string"},"path":{"type":"string"}},"required":["action","path"],"additionalProperties":true}"#.utf8))
        let spec = try BackendMCPTool(id: "demo.change", wireName: "demo_change", description: "Fixture", inputSchema: schema, tier: .act)
        let authority = BackendDeckCoreToolContextAuthority()
        try await core.register([.init(tool: spec, summary: { _, _ in "Fixture action" }, precheckAsync: { _, _ in await precheck?() }, run: { arguments, context in
            if effect {
                return try await authority.withContext(context) { native in
                    let scoped = try await authority.context(for: native)
                    _ = try await core.prepareEffect(context: scoped, tool: "demo.change", arguments: arguments, tier: .act, sentence: "Fixture effect", ownerMustAnswer: false)
                    await fixture.hit(); return .init(value: .string("allowed"))
                }
            }
            await fixture.hit(); return .init(value: .string("allowed"))
        }), .init(tool: try .init(id: "tools.run", wireName: "tools_run", description: "Run", inputSchema: .object([]), tier: .read),
            summary: { _, _ in "Run fixture" }, run: { _, _ in .init(value: .null) })])
    }
    private func call(tool: String = "demo.change", arguments: NativeRPCValue? = nil, session: String = "helper-session",
                      cancellation: BackendMCPCancellation = .init()) -> BackendHOSTAppRelayCall {
        .init(id: UUID(), toolID: tool, wireName: tool.replacingOccurrences(of: ".", with: "_"), tier: tool == "tools.run" ? .read : .act,
            context: .init(sessionID: session, machineID: "", projectRoot: nil, attended: true, allowedTools: ["demo.change", "tools.run"],
                allowedTiers: [.read, .act, .alter], cancellation: cancellation), taskProject: nil, arguments: arguments ?? args)
    }
    private func relay(_ core: BackendDeckCoreSecurityControl, fixture: RelayRulesFixture) -> BackendHOSTSessionToolRelay {
        .init(core: core, currentAdoption: { _ in try await fixture.adoption() })
    }
    private func refused(_ body: () async throws -> BackendMCPToolReply) async -> Bool {
        do { return try await body().isError } catch { return true }
    }
    func testRestoredNoTabSavedAgentAllowedExactCaseRunsWithoutAppRegistration() async throws {
        let fixture = RelayRulesFixture(), core = try core()
        try await install(core, fixture: fixture, effect: true)
        let reply = try await relay(core, fixture: fixture).invoke(call())
        XCTAssertFalse(reply.isError)
        let count = await fixture.count(); XCTAssertEqual(count, 1)
    }
    func testDeniedActionArgumentAndForgedAgentClaimsNeverReachHandler() async throws {
        for bad in [args.setting("action", .string("delete")), args.setting("path", .string("foreign")),
                    args.setting("agentProfileID", .string("unrestricted"))] {
            let fixture = RelayRulesFixture(), core = try core()
            try await install(core, fixture: fixture)
            let result = await refused { try await self.relay(core, fixture: fixture).invoke(self.call(arguments: bad)) }
            XCTAssertTrue(result)
            let count = await fixture.count(); XCTAssertEqual(count, 0)
        }
    }
    func testServiceOutsideOriginalGrantAndCrossSessionCannotAdopt() async throws {
        let fixture = RelayRulesFixture(), core = try core()
        try await install(core, fixture: fixture)
        let serviceDenied = await refused { try await self.relay(core, fixture: fixture).invoke(self.call(tool: "other.change")) }
        let crossSessionDenied = await refused { try await self.relay(core, fixture: fixture).invoke(self.call(session: "foreign-session")) }
        XCTAssertTrue(serviceDenied); XCTAssertTrue(crossSessionDenied)
        let count = await fixture.count(); XCTAssertEqual(count, 0)
    }
    func testSessionLookingCallerWithoutSealedProofIsRefused() async throws {
        let fixture = RelayRulesFixture(), core = try core()
        try await install(core, fixture: fixture)
        let result = await core.call(name: "demo.change", arguments: args,
            options: .init(caller: .init(kind: .session, tiers: [.read, .act, .alter], sessionID: "helper-session", machineID: ""), granted: ["demo.change", "tools.run"]))
        XCTAssertFalse(result.ok)
        let count = await fixture.count(); XCTAssertEqual(count, 0)
    }
    func testCanonicalToolsRunCarriesTheSameNarrowProof() async throws {
        let fixture = RelayRulesFixture(), core = try core()
        try await install(core, fixture: fixture, effect: true)
        let request = NativeRPCValue.object([.init("name", .string("demo_change")), .init("arguments", args), .init("reason", .string("Fixture wrapper"))])
        let reply = try await relay(core, fixture: fixture).invoke(call(tool: "tools.run", arguments: request))
        XCTAssertFalse(reply.isError)
        let count = await fixture.count(); XCTAssertEqual(count, 1)
    }
    func testRevocationRuleTighteningScopeAndProcessChangesAfterAwaitRefuseEffect() async throws {
        for mutation in ["revoke", "rules", "scope", "pid", "birth", "account", "root", "session", "grant", "profile"] {
            let fixture = RelayRulesFixture(), core = try core()
            try await install(core, fixture: fixture, precheck: {
                switch mutation {
                case "revoke": await fixture.revoke()
                case "rules": await fixture.deny()
                case "scope": await fixture.changeScope()
                case "pid": await fixture.reconnect()
                case "birth": await fixture.changeBirth()
                case "account": await fixture.changeAccount()
                case "root": await fixture.changeRoot()
                case "session": await fixture.changeSession()
                case "grant": await fixture.shrinkGrant()
                default: await fixture.removeProfile()
                }
            }, effect: true)
            let result = await refused { try await self.relay(core, fixture: fixture).invoke(self.call()) }
            XCTAssertTrue(result, mutation)
            let count = await fixture.count(); XCTAssertEqual(count, 0, mutation)
        }
    }
    func testSamePIDAccountChangeDuringAdoptionAwaitCannotUseEarlierSnapshot() async throws {
        let fixture = RelayRulesFixture(), core = try core()
        try await install(core, fixture: fixture)
        let relay = BackendHOSTSessionToolRelay(core: core, currentAdoption: { _ in
            let beforeAwait = try await fixture.adoption()
            await fixture.changeAccount() // retained-grant lookup suspended while metadata changed
            let current = await fixture.live()
            guard BackendHOSTSessionToolRelay.matchesCurrentSession(beforeAwait.snapshot, current: current, pid: beforeAwait.snapshot.pid) else {
                throw BackendHOSTFailure.authentication
            }
            return beforeAwait
        })
        let denied = await refused { try await relay.invoke(self.call()) }
        XCTAssertTrue(denied)
        let count = await fixture.count(); XCTAssertEqual(count, 0)
    }
    func testCurrentMetadataFenceIncludesConversationHomeBirthAndAliveState() async throws {
        let fixture = RelayRulesFixture()
        let original = try await fixture.adoption().snapshot
        XCTAssertTrue(BackendHOSTSessionToolRelay.matchesCurrentSession(original, current: original.session, pid: original.pid))
        var changed = original.session
        changed.homeProfileId = "other-home"
        XCTAssertFalse(BackendHOSTSessionToolRelay.matchesCurrentSession(original, current: changed, pid: original.pid))
        changed = original.session; changed.agentSessionId = "other-provider-conversation"
        XCTAssertFalse(BackendHOSTSessionToolRelay.matchesCurrentSession(original, current: changed, pid: original.pid))
        changed = original.session; changed.exitCode = 0
        XCTAssertFalse(BackendHOSTSessionToolRelay.matchesCurrentSession(original, current: changed, pid: original.pid))
        await fixture.changeBirth()
        let reborn = await fixture.live()
        XCTAssertFalse(BackendHOSTSessionToolRelay.matchesCurrentSession(original, current: reborn, pid: original.pid))
    }
    func testReconnectRequiresFreshAdoptionAndTheSameSavedRulesRemainEffective() async throws {
        let fixture = RelayRulesFixture(), core = try core()
        try await install(core, fixture: fixture)
        await fixture.reconnect()
        let valid = try await relay(core, fixture: fixture).invoke(call())
        XCTAssertFalse(valid.isError)
        await fixture.deny()
        let denied = await refused { try await self.relay(core, fixture: fixture).invoke(self.call()) }
        XCTAssertTrue(denied)
        let count = await fixture.count(); XCTAssertEqual(count, 1)
    }
    func testCancelledRelayNeverReachesEffect() async throws {
        let fixture = RelayRulesFixture(), core = try core(), cancellation = BackendMCPCancellation()
        try await install(core, fixture: fixture, precheck: { cancellation.cancel() }, effect: true)
        let denied = await refused { try await self.relay(core, fixture: fixture).invoke(self.call(cancellation: cancellation)) }
        XCTAssertTrue(denied)
        let count = await fixture.count(); XCTAssertEqual(count, 0)
    }
    func testHelperRelayWithNoInspectorCannotUseDefaultOptionalGate() async throws {
        let fixture = RelayRulesFixture(), core = try core()
        let spec = try BackendMCPTool(id: "demo.change", wireName: "demo_change", description: "Scratch startup guard",
            inputSchema: .object([.init("type", .string("object"))]), tier: .act)
        try await core.register([.init(tool: spec, summary: { _, _ in "Scratch effect" }, run: { _, _ in
            await fixture.hit(); return .init(value: .null)
        })])
        let denied = await refused { try await self.relay(core, fixture: fixture).invoke(self.call()) }
        XCTAssertTrue(denied)
        let count = await fixture.count(); XCTAssertEqual(count, 0)
    }
    func testBootstrapRefusesRestoredSessionsUntilInspectorReadyWithoutChangingOwnerGrant() async throws {
        let fixture = RelayRulesFixture(), core = try core()
        try await install(core, fixture: fixture)
        await core.holdSessionToolsUntilRestrictionsReady()
        let held = await refused { try await self.relay(core, fixture: fixture).invoke(self.call()) }
        XCTAssertTrue(held)
        let owner = await core.call(name: "demo.change", arguments: args)
        XCTAssertTrue(owner.ok)
        let inspector = BackendToolUseRestrictions(subject: { context in
            let caller = try await BackendToolUseRestrictions.authenticatedSessionCaller(context, endpoint: nil)
            return try BackendToolUseRestrictions.resolve(caller: caller, live: await fixture.live(), task: nil,
                namedProfile: context.relaySessionProof?.agentProfileID, lead: false)
        }, profile: { await fixture.profile($0) })
        await core.setToolUseInspector { context, tool, args, expected in try await inspector.inspect(context, tool: tool, arguments: args, expected: expected) }
        let ready = try await relay(core, fixture: fixture).invoke(call())
        XCTAssertFalse(ready.isError)
        let count = await fixture.count(); XCTAssertEqual(count, 2)
    }
    func testSealedProofCannotAuthorizeAnotherCallOrSurviveRelayCompletion() async throws {
        let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act], sessionID: "helper-session", machineID: "")
        let native = BackendMCPCallContext(sessionID: "helper-session", machineID: "", projectRoot: nil, attended: true,
            allowedTools: ["demo.change"], allowedTiers: [.read, .act], cancellation: .init())
        let proof = BackendDeckCoreRelaySessionProof(caller: caller, tools: ["demo.change"], tool: "demo.change", arguments: args,
            cancellation: .init(), attended: true, agentProfileID: "saved-agent", refresh: { caller })
        try proof.claim(callID: "one-call", caller: caller, native: native, granted: ["demo.change"], tool: "demo.change", arguments: args)
        let context = BackendDeckCoreSecurityCallContext(native: native, caller: caller, callID: "one-call", attended: true,
            granted: ["demo.change"], sessionLimits: .missing, now: { 0 }, startedByCopilot: { _ in false }, noteStarted: { _ in }, relaySessionProof: proof)
        let current = try await proof.currentCaller(for: context)
        XCTAssertEqual(current.sessionID, "helper-session")
        XCTAssertThrowsError(try proof.claim(callID: "second-call", caller: caller, native: native, granted: ["demo.change"], tool: "demo.change", arguments: args))
        proof.end()
        do { _ = try await proof.currentCaller(for: context); XCTFail("Ended proof was retained as a grant") } catch {}
    }
    func testRetainedHelperGrantIsRecheckedAndRevocationAfterAwaitRefuses() async throws {
        let server = BackendNativeMCPServer(), endpoint = BackendHOSTMCPPreservedEndpoint(server: server)
        let spec = try BackendMCPTool(id: "demo.change", wireName: "demo_change", description: "Scratch grant fixture", inputSchema: .object([]), tier: .read)
        try await server.registerTool(spec) { _, _ in .value(.null) }
        _ = try await server.start()
        addTeardownBlock { await server.stop() }
        let switcher = RelayGrantSwitch()
        let registration = try await endpoint.register(token: String(repeating: "a", count: 64),
            grant: .init(attended: true, allowedTools: ["demo.change"], allowedTiers: [.read], permitted: { await switcher.check() }))
        try await endpoint.bind(registration, sessionID: "helper-session", machineID: "")
        let context = BackendMCPCallContext(sessionID: "helper-session", machineID: "", projectRoot: nil, attended: true,
            allowedTools: ["demo.change"], allowedTiers: [.read], cancellation: .init())
        let initial = try await endpoint.currentSessionCaller(context)
        XCTAssertEqual(initial["sessionID"].string, "helper-session")
        XCTAssertTrue(initial["token"].isNullish)
        await switcher.onCheck { await endpoint.revoke(registration) }
        do { _ = try await endpoint.currentSessionCaller(context); XCTFail("Revoked retained grant survived its suspended permission callback") } catch {}
        do { _ = try await endpoint.currentSessionCaller(context); XCTFail("Revoked retained grant was reconstructed from matching metadata") } catch {}
    }

}

private actor RelayGrantSwitch {
    private var action: (@Sendable () async -> Void)?
    func onCheck(_ action: @escaping @Sendable () async -> Void) { self.action = action }
    func check() async -> Bool { if let action { self.action = nil; await action() }; return true }
}
