import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRemoteServeHostPortGitHubTests: XCTestCase {
    private static func state(connected: Bool) -> NativeRPCValue {
        .object([.init("connected", .bool(connected)), .init("identity", connected ? .object([
            .init("login", .string("asadev")), .init("name", .string("Asad Iqbal")), .init("avatarUrl", .string("https://a/1")), .init("htmlUrl", .string("https://github.com/asadev"))]) : .null),
            .init("source", connected ? .string("device-flow") : .null), .init("appConfigured", .bool(true)),
            .init("installUrl", .string("https://github.com/apps/terminaldeck/installations/new")), .init("pending", .null), .init("failure", .null),
            .init("disconnect", connected ? .string("Signs this machine out of GitHub locally.") : .null),
            .init("repo", .string("private/repo")), .init("branch", .string("private-branch")), .init("access", .object([.init("private", .bool(true))]))])
    }
    private func context(_ kind: BackendRemoteDeviceKind = .mine) -> BackendRemoteHostContext {
        .init(connectionID: UUID(), deviceID: "device-1", kind: kind, address: "100.64.0.2", peerPublicKey: Data(repeating: 7, count: 32),
              claimedCapabilities: ["github"], reach: .init(kind: kind, unrestricted: kind == .mine, folders: [], accounts: nil, drivesWindows: kind == .mine))
    }
    func testConnectedAndPendingGitHubWireExactProjection() {
        let wire = BackendRemoteServeGitHub.wire(Self.state(connected: true), flowFailure: "stale")
        let expected = NativeRPCValue.object([.init("connected", .bool(true)), .init("login", .string("asadev")), .init("name", .string("Asad Iqbal")),
            .init("avatarUrl", .string("https://a/1")), .init("source", .string("device-flow")), .init("appConfigured", .bool(true)),
            .init("installUrl", .string("https://github.com/apps/terminaldeck/installations/new")), .init("pending", .null), .init("failure", .null),
            .init("disconnect", .string("Signs this machine out of GitHub locally."))])
        XCTAssertEqual(wire, expected); XCTAssertEqual(wire["repo"], .missing); XCTAssertEqual(wire["access"], .missing)
        let pending = Self.state(connected: false).setting("pending", .object([.init("userCode", .string("WDJB-MJHT")),
            .init("verificationUri", .string("https://github.com/login/device")), .init("expiresAt", .number(1_900_000_000_000)), .init("installUrl", .string("private-copy"))]))
        let view = BackendRemoteServeGitHub.wire(pending, flowFailure: nil)
        XCTAssertEqual(view["pending"], .object([.init("userCode", .string("WDJB-MJHT")), .init("verificationUri", .string("https://github.com/login/device")), .init("expiresAt", .number(1_900_000_000_000))]))
        XCTAssertEqual(view["pending"]["installUrl"], .missing)
    }
    func testFlowFailureReadFailurePrecedenceAndConnectedClearing() {
        let state = Self.state(connected: false)
        XCTAssertEqual(BackendRemoteServeGitHub.wire(state, flowFailure: "You cancelled the GitHub sign-in.")["failure"].string, "You cancelled the GitHub sign-in.")
        let failed = state.setting("failure", .object([.init("message", .string("The read failed."))]))
        XCTAssertEqual(BackendRemoteServeGitHub.wire(failed, flowFailure: "old")["failure"].string, "The read failed.")
        XCTAssertEqual(BackendRemoteServeGitHub.wire(Self.state(connected: true), flowFailure: "a stale reason from a previous attempt")["failure"], .null)
    }
    func testFourGitHubHandlersReturnMatchedStateAndGuestCannotMutate() async throws {
        let auth = Auth(Self.state(connected: false)), access = BackendRemoteServeGitHub(authenticator: auth)
        let feature = await access.feature()
        XCTAssertEqual(feature.capability, "github"); XCTAssertEqual(feature.policy, .ownerOnly)
        for (tag, rid) in [("github.read","r1"),("github.connect","c1"),("github.cancel","x1"),("github.disconnect","d1")] {
            let answer = try await feature.handle(.init(.object([.init("t", .string(tag)), .init("rid", .string(rid))])), context())
            XCTAssertEqual(answer.count, 1); XCTAssertEqual(answer[0].kind, .githubState); XCTAssertEqual(answer[0].value["rid"].string, rid)
            if tag == "github.connect" { XCTAssertEqual(answer[0].value["github"]["pending"]["userCode"].string, "WDJB-MJHT") }
        }
        let before = await auth.calls
        let guest = try await feature.handle(.init(.object([.init("t", .string("github.connect")), .init("rid", .string("g1"))])), context(.guest))
        XCTAssertEqual(guest[0].value["code"].string, "unauthorized")
        XCTAssertEqual(guest[0].value["message"].string, "Only this machine’s own devices manage its GitHub sign-in.")
        let after = await auth.calls; XCTAssertEqual(after, before)
        XCTAssertEqual(try BackendRemoteServeHostRefusals.missing("github.read")?.value["message"].string, "This Mac does not manage its GitHub sign-in from here.")
    }
    func testGitHubChangeListenersNotifyAndUnsubscribe() async throws {
        let auth = Auth(Self.state(connected: false)), access = BackendRemoteServeGitHub(authenticator: auth), count = Counter()
        let token = await access.onChanged { await count.add() }
        await access.emitChanged(); await access.emitChanged(); await access.unsubscribe(token); await access.emitChanged()
        let calls = await count.value; XCTAssertEqual(calls, 2)
        await auth.replace(Self.state(connected: true))
        let push = try await access.changedMessage()
        XCTAssertEqual(push.kind, .githubChanged); XCTAssertEqual(push.value["github"]["login"].string, "asadev")
    }
    func testNativeGitHubCredentialAdapterUsesEnvironmentOrNoneWithNoCommands() async throws {
        for token in ["ghp_env", ""] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendRemoteServeGitHubPort-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let auth = try BackendGitHubAuthenticator(dataDirectory: root, environment: token.isEmpty ? [:] : ["GH_TOKEN": token],
                http: NoHTTP(), tools: NoTools(), resolveRepo: { _ in .null })
            let result = await BackendRemoteServeNativeGitHub(authenticator: auth).gitCredential()
            if token.isEmpty { XCTAssertNil(result) }
            else { XCTAssertEqual(result?.username, "x-access-token"); XCTAssertEqual(result?.password, "ghp_env") }
        }
    }
    private actor Auth: BackendRemoteServeGitHubAuthenticator {
        var current: NativeRPCValue; var calls: [String] = []
        init(_ state: NativeRPCValue) { current = state }
        func status() -> NativeRPCValue { calls.append("read"); return current }
        func connect() {
            calls.append("connect"); current = current.setting("pending", .object([.init("userCode", .string("WDJB-MJHT")), .init("verificationUri", .string("https://github.com/login/device")), .init("expiresAt", .number(1))]))
        }
        func cancelConnect() -> NativeRPCValue { calls.append("cancel"); current = current.setting("pending", .null); return current }
        func disconnect() -> NativeRPCValue { calls.append("disconnect"); current = current.setting("connected", .bool(false)).setting("identity", .null); return current }
        func flowFailure() -> String? { nil }
        func replace(_ state: NativeRPCValue) { current = state }
    }
    private actor Counter { var value = 0; func add() { value += 1 } }
    private struct NoHTTP: BackendGitHubHTTPFetching {
        func fetch(url: String, method: String, headers: [String: String], body: String?, timeoutMilliseconds: Int) async throws -> BackendGitHubHTTPResponse { throw NativeRPCError(code: "unexpected", message: "A credential read must not use network") }
    }
    private struct NoTools: BackendGitHubToolRunning {
        func run(tool: String, arguments: [String], cwd: String?, environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome { throw NativeRPCError(code: "unexpected", message: "A credential read must not run a command") }
    }
}

final class BackendRemoteServeHostPortRosterTests: XCTestCase {
    private func fixture() async throws -> (URL, BackendRemoteTrustStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendRemoteServeRosterPort-" + UUID().uuidString)
        let trust = BackendRemoteTrustStore(directory: root, clock: { 1_760_000_000_000 }); try await trust.open(); return (root, trust)
    }
    func testRosterMineIdentityKindAndConnectedFlag() async throws {
        let (root, trust) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let device = try await trust.enrollVerifiedDevice(name: "iPhone", address: "100.64.0.2", publicKey: Data(repeating: 7, count: 32)).device
        let roster = BackendRemoteServeRoster(trust: trust, connected: { [device.id] }, drop: { _ in }, forget: { _ in }, announce: {})
        let rows = await roster.list(); XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"].string, device.id); XCTAssertEqual(rows[0]["name"].string, "iPhone")
        XCTAssertEqual(rows[0]["kind"].string, "mine"); XCTAssertEqual(rows[0]["status"].string, "approved"); XCTAssertEqual(rows[0]["connected"], .bool(true))
        await trust.close()
    }
    func testUnrecordedKindIsGuestAndPendingDeviceIsListed() async throws {
        let (root, trust) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let offer = try await trust.createPairingOffer()
        let pending = try await trust.redeem(offer.token, name: "Nexus", address: "100.64.0.2", publicKey: nil).device
        let roster = BackendRemoteServeRoster(trust: trust, connected: { [] }, drop: { _ in }, forget: { _ in }, announce: {})
        let rows = await roster.list(); XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"].string, pending.id); XCTAssertEqual(rows[0]["kind"].string, "guest")
        XCTAssertEqual(rows[0]["status"].string, "pending"); XCTAssertEqual(rows[0]["connected"], .bool(false))
        _ = try await trust.approve(pending.id, kind: .guest)
        await trust.close()
        try FileManager.default.removeItem(at: root.appendingPathComponent("remote-device-kinds.json"))
        try await trust.open()
        let legacy = await roster.list()
        XCTAssertEqual(legacy[0]["status"].string, "approved")
        XCTAssertEqual(legacy[0]["kind"].string, "guest"); XCTAssertEqual(legacy[0]["connected"], .bool(false))
        await trust.close()
    }
    func testRevokeCascadeRevokesBeforeDropAndRunsOnce() async throws {
        let (root, trust) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let device = try await trust.enrollVerifiedDevice(name: "Gone", address: "100.64.0.2", publicKey: Data(repeating: 7, count: 32)).device
        let trace = Trace()
        let roster = BackendRemoteServeRoster(trust: trust, connected: { [device.id] },
            drop: { id in await trace.append("drop:" + id, revoked: await trust.device(id)?.revoked == true) },
            forget: { await trace.append("forget:" + $0) }, announce: { await trace.append("announce") })
        let removed = try await roster.revoke(device.id); XCTAssertTrue(removed)
        let rows = await roster.list(); XCTAssertTrue(rows.isEmpty)
        let events = await trace.events; XCTAssertEqual(events, ["drop:" + device.id, "forget:" + device.id, "announce"])
        let proof = await trace.revokedAtDrop; XCTAssertTrue(proof)
        let again = try await roster.revoke(device.id); XCTAssertFalse(again)
        let twice = await trace.events; XCTAssertEqual(twice, events)
        await trust.close()
    }
    func testUnknownRevokeDoesNotDropForgetOrAnnounce() async throws {
        let (root, trust) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let trace = Trace(), roster = BackendRemoteServeRoster(trust: trust, connected: { [] }, drop: { await trace.append("drop:" + $0) }, forget: { await trace.append("forget:" + $0) }, announce: { await trace.append("announce") })
        let removed = try await roster.revoke("no-such-device"); XCTAssertFalse(removed)
        let events = await trace.events; XCTAssertTrue(events.isEmpty)
        await trust.close()
    }
    private actor Trace {
        var events: [String] = []; var revokedAtDrop = false
        func append(_ event: String, revoked: Bool = false) { events.append(event); if event.hasPrefix("drop:") { revokedAtDrop = revoked } }
    }
}
