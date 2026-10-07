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
        let service = BackendRemoteServeAccountService(profiles: { [BackendRemoteServeAccountPortFixture.profile("system", system: true), BackendRemoteServeAccountPortFixture.profile()] }, attribution: { _ in nil }, probe: { profile in
            await calls.record(profile.id)
            return .init(state: .signedIn, account: "sherzod.davlatov@gmail.com", plan: "max", detail: "Signed in as sherzod.davlatov@gmail.com on the max plan.")
        })
        let state = try await service.read("nothing-by-that-id"), asked = await calls.ids()
        XCTAssertEqual(asked.count, state.accounts.count)
        for row in state.accounts {
            XCTAssertEqual(row["signIn"], .object([.init("state", .string("signed-in")), .init("account", .string("sherzod.davlatov@gmail.com")), .init("plan", .string("max")), .init("detail", .string("Signed in as sherzod.davlatov@gmail.com on the max plan."))]))
            XCTAssertEqual(row["signIn"]["command"], .missing)
        }
    }
    func testFailedProbesLeaveSignInUnsaidOnEveryAccount() async throws {
        let service = BackendRemoteServeAccountService(profiles: { [BackendRemoteServeAccountPortFixture.profile("system", system: true), BackendRemoteServeAccountPortFixture.profile()] }, attribution: { _ in nil }, probe: { _ in throw Failure.probe })
        let state = try await service.read("nothing-by-that-id")
        XCTAssertGreaterThan(state.accounts.count, 0); for row in state.accounts { XCTAssertEqual(row["signIn"], .missing) }
    }
    func testMachineLoginReadNeedsNoSessionAndKeepsSameIdentityProjection() async throws {
        let service = BackendRemoteServeAccountService(profiles: { [BackendRemoteServeAccountPortFixture.profile("system", system: true), BackendRemoteServeAccountPortFixture.profile()] }, attribution: { _ in nil }, probe: { _ in
            .init(state: .signedIn, account: "sherzod.davlatov@gmail.com", plan: "max", detail: "Signed in.")
        }, login: FakeLogin())
        let feature = try XCTUnwrap(service.loginFeature()), frame = try BackendRemoteServeAccountPortFixture.message(#"{"t":"logins.read","rid":"l1"}"#)
        let answer = try await feature.handle(frame, BackendRemoteServeAccountPortFixture.context()).first
        XCTAssertEqual(answer?.kind, .loginState)
        let rows = answer?.value["accounts"].elements ?? []
        XCTAssertTrue(rows.contains { $0["name"].string == "work@example.com" }); XCTAssertTrue(rows.contains { $0["system"].bool == true })
        XCTAssertEqual(rows.first { $0["id"].string == "work" }?["color"], .string("--accent"))
        XCTAssertTrue(rows.allSatisfy { $0["signIn"]["account"].string == "sherzod.davlatov@gmail.com" })
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
    private enum Failure: Error { case probe }
    private actor ProbeCalls { var values: [String] = []; func record(_ id: String) { values.append(id) }; func ids() -> [String] { values } }
    private actor FakeLogin: BackendRemoteServeAccountLoginLifecycle {
        var ids: [String] = []
        func signIn(accountID: String) -> BackendRemoteServeAccountOutcome { ids.append(accountID); return .init(ok: true, message: "A terminal is open on this computer for work@example.com. Finish the login in it.", session: "sess-new") }
        func signOut(accountID: String) -> BackendRemoteServeAccountOutcome { .init(ok: true, message: "Signed out.", session: nil) }
        func signed() -> [String] { ids }
    }
}
