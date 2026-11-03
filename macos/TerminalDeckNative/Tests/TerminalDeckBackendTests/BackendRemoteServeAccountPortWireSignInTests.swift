import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeAccountPortWireSignInTests: XCTestCase {
    func testOwnerSignInAnswersTheExactTerminalReturnedByLocalRunner() async throws {
        let login = Login(), accounts = BackendRemoteServeAccountService(profiles: { [] }, attribution: { _ in nil }, login: login)
        let feature = try XCTUnwrap(accounts.loginFeature())
        let frame = try BackendRemoteServeAccountPortFixture.message(#"{"t":"logins.signin","rid":"l2","accountId":"p-work"}"#)
        let answer = try await feature.handle(frame, BackendRemoteServeAccountPortFixture.context()).first, signed = await login.calls()
        XCTAssertEqual(answer?.kind, .loginSignedIn); XCTAssertEqual(answer?.value["rid"], .string("l2"))
        XCTAssertEqual(answer?.value["ok"], .bool(true)); XCTAssertEqual(answer?.value["session"], .string("sess-3")); XCTAssertEqual(signed, ["p-work"])
    }
    private actor Login: BackendRemoteServeAccountLoginLifecycle {
        var signed: [String] = []
        func signIn(accountID: String) -> BackendRemoteServeAccountOutcome { signed.append(accountID); return .init(ok: true, message: "A terminal is open.", session: "sess-3") }
        func signOut(accountID: String) -> BackendRemoteServeAccountOutcome { .init(ok: true, message: "Signed out.", session: nil) }
        func calls() -> [String] { signed }
    }
}
