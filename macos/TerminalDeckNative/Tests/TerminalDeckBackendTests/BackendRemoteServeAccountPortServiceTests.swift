import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeAccountPortServiceTests: XCTestCase {
    func testSpawnEstablishedLoginSelectsTheActualMenuRowAndPaletteName() async throws {
        let service = BackendRemoteServeAccountService(profiles: { [BackendRemoteServeAccountPortFixture.profile("system", name: "Default", system: true), BackendRemoteServeAccountPortFixture.profile()] }, attribution: { _ in
            .init(provider: "claude", configDir: "/test/account/work", profileId: "work", profileName: "work@example.com", source: "spawn", email: nil, reason: nil)
        })
        let state = try await service.read("far-session-1")
        XCTAssertTrue(state.accounts.contains { $0["name"].string == "work@example.com" }); XCTAssertTrue(state.accounts.contains { $0["system"].bool == true })
        XCTAssertEqual(state.current["id"], .string("work")); XCTAssertEqual(state.current["color"], .string("--accent"))
    }
    func testUnestablishedAndUnknownSessionsKeepRealListWithoutGuessingCurrent() async throws {
        let service = BackendRemoteServeAccountService(profiles: { [BackendRemoteServeAccountPortFixture.profile()] }, attribution: { id in
            id == "unknown" ? nil : .init(provider: nil, configDir: nil, profileId: nil, profileName: nil, source: nil, email: nil, reason: "No process account was established.")
        })
        for id in ["outside-app", "unknown"] { let state = try await service.read(id); XCTAssertEqual(state.current, .null); XCTAssertGreaterThan(state.accounts.count, 0) }
    }
    func testEveryAccountIsProbedAndSendsExactFourIdentityFields() async throws {
        let calls = ProbeCalls()
        // Two different logins (one login twice is one row: testOneLoginKeptTwiceIsOneRowAndAnotherAIsStaysItsOwn).
        let address: @Sendable (String) -> String = { $0 == "system" ? "sherzod.davlatov@gmail.com" : "work@example.com" }
        let service = BackendRemoteServeAccountService(profiles: { [BackendRemoteServeAccountPortFixture.profile("system", system: true), BackendRemoteServeAccountPortFixture.profile()] }, attribution: { _ in nil }, probe: { profile in
            await calls.record(profile.id)
            return .init(state: .signedIn, account: address(profile.id), plan: "max", detail: "Signed in as \(address(profile.id)) on the max plan.")
        })
        let state = try await service.read("nothing-by-that-id"), asked = await calls.ids()
        XCTAssertEqual(asked.count, state.accounts.count)
        for row in state.accounts {
            let mail = address(row["id"].string ?? "")
            XCTAssertEqual(row["signIn"], .object([.init("state", .string("signed-in")), .init("account", .string(mail)), .init("plan", .string("max")), .init("detail", .string("Signed in as \(mail) on the max plan."))]))
            XCTAssertEqual(row["signIn"]["command"], .missing)
        }
    }
    func testFailedProbesLeaveSignInUnsaidOnEveryAccount() async throws {
        let service = BackendRemoteServeAccountService(profiles: { [BackendRemoteServeAccountPortFixture.profile("system", system: true), BackendRemoteServeAccountPortFixture.profile()] }, attribution: { _ in nil }, probe: { _ in throw Failure.probe })
        let state = try await service.read("nothing-by-that-id")
        XCTAssertGreaterThan(state.accounts.count, 0); for row in state.accounts { XCTAssertEqual(row["signIn"], .missing) }
    }
    func testMachineLoginReadNeedsNoSessionAndKeepsSameIdentityProjection() async throws {
        let service = BackendRemoteServeAccountService(profiles: { [BackendRemoteServeAccountPortFixture.profile("system", system: true), BackendRemoteServeAccountPortFixture.profile()] }, attribution: { _ in nil }, probe: { profile in
            .init(state: .signedIn, account: profile.system ? "sherzod.davlatov@gmail.com" : "work@example.com", plan: "max", detail: "Signed in.")
        }, login: FakeLogin())
        let feature = try XCTUnwrap(service.loginFeature()), frame = try BackendRemoteServeAccountPortFixture.message(#"{"t":"logins.read","rid":"l1"}"#)
        let answer = try await feature.handle(frame, BackendRemoteServeAccountPortFixture.context()).first
        XCTAssertEqual(answer?.kind, .loginState)
        let rows = answer?.value["accounts"].elements ?? []
        XCTAssertTrue(rows.contains { $0["name"].string == "work@example.com" }); XCTAssertTrue(rows.contains { $0["system"].bool == true })
        XCTAssertEqual(rows.first { $0["id"].string == "work" }?["color"], .string("--accent"))
        XCTAssertTrue(rows.allSatisfy { $0["signIn"]["account"].string == ($0["system"].bool == true ? "sherzod.davlatov@gmail.com" : "work@example.com") })
        XCTAssertTrue(rows.allSatisfy { $0["signIn"]["command"] == .missing })
    }
    func testSignInIsForwardedWithExactLocalSentenceAndSession() async throws {
        let login = FakeLogin(), service = BackendRemoteServeAccountService(profiles: { [] }, attribution: { _ in nil }, login: login)
        let feature = try XCTUnwrap(service.loginFeature()), frame = try BackendRemoteServeAccountPortFixture.message(#"{"t":"logins.signin","rid":"l2","accountId":"p-work"}"#)
        let answer = try await feature.handle(frame, BackendRemoteServeAccountPortFixture.context()).first, ids = await login.signed()
        XCTAssertEqual(ids, ["p-work"])
        XCTAssertEqual(answer?.value["ok"], .bool(true)); XCTAssertEqual(answer?.value["session"], .string("sess-new"))
        XCTAssertEqual(answer?.value["message"], .string("A terminal is open on this computer for work@example.com. Finish the login in it."))
    }
    func testGuestLoginRequestIsUnavailableWithoutReachingLocalRunner() async throws {
        let login = FakeLogin(), service = BackendRemoteServeAccountService(profiles: { [] }, attribution: { _ in nil }, login: login)
        let feature = try XCTUnwrap(service.loginFeature()), frame = try BackendRemoteServeAccountPortFixture.message(#"{"t":"logins.signin","rid":"l2","accountId":"p-work"}"#)
        let answer = try await feature.handle(frame, BackendRemoteServeAccountPortFixture.context(kind: .guest)).first, ids = await login.signed()
        XCTAssertEqual(answer?.value["code"], .string("unavailable")); XCTAssertEqual(answer?.value["message"], .string("This Mac does not manage its logins from here.")); XCTAssertEqual(ids, [])
    }
    /// 28 Oct (phone review: app.imatch.ae@gmail.com twice in Switch account): one row per login, as the Mac's lists.
    func testOneLoginKeptTwiceIsOneRowAndAnotherAIsStaysItsOwn() async throws {
        let fixture = BackendRemoteServeAccountPortFixture.self
        let codex = BackendAccountProfile(id: "system:codex", name: "Default (Codex)", provider: "codex", configDir: "/test/account/codex", system: true, color: "--accent", createdAt: 1)
        let api = BackendAccountProfile(id: "api-key-0123456789abcdef01234567", name: "app@example.com", provider: "claude", configDir: "/test/account/api", system: false, color: "--accent", createdAt: 1)
        var kept = fixture.profile("kept-app", name: "app@example.com"); kept.keptSlots = ["keychain:Claude Code-credentials"]
        let profiles = [fixture.profile("system", name: "Default", system: true), kept, fixture.profile("work"), codex, api]
        let probe: BackendRemoteServeAccountService.Probe = { profile in
            switch profile.id {
            case "work": return .init(state: .signedIn, account: "work@example.com", plan: "max", detail: "Signed in.")
            case "api-key-0123456789abcdef01234567": return .init(state: .signedIn, account: nil, plan: "API", detail: "API key.")
            default: return .init(state: .signedIn, account: "app@example.com", plan: "max", detail: "Signed in.")   // this Mac's own Claude and Codex, and the kept copy
            }
        }
        // No session on it: this Mac's own sign-in stays, the app's copy of the same login folds into it.
        let plain = BackendRemoteServeAccountService(profiles: { profiles }, attribution: { _ in nil }, probe: probe)
        let ids = try await plain.read("none").accounts.compactMap { $0["id"].string }
        XCTAssertEqual(ids, ["system", "work", "system:codex", "api-key-0123456789abcdef01234567"],
                       "the same address under Codex is another AI's login; an API key is its own kind")
        // A session running on the kept copy: that row stays (ticked) and this Mac's own folds into it.
        let running = BackendRemoteServeAccountService(profiles: { profiles }, attribution: { _ in
            .init(provider: "claude", configDir: "/test/account/kept-app", profileId: "kept-app", profileName: "app@example.com", source: "spawn", email: nil, reason: nil)
        }, probe: probe)
        let state = try await running.read("far-session-1")
        XCTAssertEqual(state.current["id"], .string("kept-app"))
        XCTAssertEqual(state.accounts.compactMap { $0["id"].string }, ["kept-app", "work", "system:codex", "api-key-0123456789abcdef01234567"])
        // Hoot's own list folds the same way (a login kept twice is one row; Hoot's account stays).
        let ready = NativeRPCValue.object([.init("provider", .string("claude")), .init("profileId", .string("kept-2")), .init("accounts", .array([
            .object([.init("id", .string("system")), .init("name", .string("Default")), .init("provider", .string("claude")), .init("signedIn", .bool(true))]),
            .object([.init("id", .string("kept-1")), .init("name", .string("app@example.com")), .init("provider", .string("claude")), .init("signedIn", .bool(true))]),
            .object([.init("id", .string("kept-2")), .init("name", .string("App@Example.com")), .init("provider", .string("claude")), .init("signedIn", .bool(true))])]))])
        let hoot = try BackendINT2HootPhone.accountState(rid: "r1", ready: ready)
        XCTAssertEqual((hoot.value["accounts"].elements ?? []).compactMap { $0["id"].string }, ["system", "kept-2"])
        XCTAssertEqual(hoot.value["current"]["id"], .string("kept-2"))
        // With the live sign-in facts (as the Mac's Hoot setup reads them): this Mac's own sign-in is kept-2's login and
        // folds into it; kept-1's saved name is stale (it holds another login) and stays, named by its address.
        func fact(_ address: String) -> NativeRPCValue { .object([.init("state", .string("signed-in")), .init("account", .string(address)), .init("detail", .string("Signed in."))]) }
        let live = ready.setting("signIns", .object([.init("system", fact("app@example.com")), .init("kept-1", fact("new@example.com")), .init("kept-2", fact("app@example.com"))]))
        let named = try BackendINT2HootPhone.accountState(rid: "r2", ready: live)
        let rows = named.value["accounts"].elements ?? []
        XCTAssertEqual(rows.compactMap { $0["id"].string }, ["kept-1", "kept-2"])
        XCTAssertEqual(rows.first?["signIn"]["account"].string, "new@example.com")
        XCTAssertEqual(named.value["current"]["id"], .string("kept-2"))
    }
    private enum Failure: Error { case probe }
    private actor ProbeCalls { var values: [String] = []; func record(_ id: String) { values.append(id) }; func ids() -> [String] { values } }
    private actor FakeLogin: BackendRemoteServeAccountLoginLifecycle {
        var ids: [String] = []
        func signIn(accountID: String) -> BackendRemoteServeAccountOutcome { ids.append(accountID); return .init(ok: true, message: "A terminal is open on this computer for work@example.com. Finish the login in it.", session: "sess-new") }
        func signOut(accountID: String) -> BackendRemoteServeAccountOutcome { .init(ok: true, message: "Signed out.", session: nil) }
        func signed() -> [String] { ids }
    }
}
