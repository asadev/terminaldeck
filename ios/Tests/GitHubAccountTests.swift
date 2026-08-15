/**
 * The GitHub account: where the token lives, and the two ways it gets there.
 *
 * Against the **real** Keychain, like `CredentialStoreTests` next door and for
 * the same reason: `SecItemAdd` on an account that already exists returns
 * `errSecDuplicateItem` and writes nothing, so a mock would happily pass a
 * store that silently refused to ever replace a token. Every case uses its own
 * service name so it cannot touch the drawer a real sign-in is in.
 *
 * The sign-in half runs against a scripted `GitHubFetch` rather than the
 * network. What is being checked there is not that GitHub works — it is that the
 * login on the account comes from **GitHub's answer** rather than from anything
 * a person typed, because that login is what the approval prompt names, and a
 * prompt that can name the wrong account is worse than no prompt.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class GitHubAccountTests: XCTestCase {

    private var store: KeychainGitHubStore!

    override func setUp() {
        super.setUp()
        store = KeychainGitHubStore(service: "dev.terminaldeck.tests.github.\(UUID().uuidString)")
    }

    override func tearDown() {
        store.disconnect()
        super.tearDown()
    }

    // MARK: - The drawer

    func testNothingIsConnectedToBeginWith() {
        XCTAssertNil(store.account)
        XCTAssertNil(store.token())
    }

    func testConnectingKeepsTheLoginAndTheSecretApart() {
        store.connect(login: "asadev", token: "gho_first", source: .signIn)

        XCTAssertEqual(store.account?.login, "asadev")
        XCTAssertEqual(store.account?.source, .signIn)
        XCTAssertEqual(store.token(), "gho_first")
    }

    /**
     * A second sign-in replaces the first.
     *
     * This is the `errSecDuplicateItem` trap. Without the update-then-add order
     * in `write`, the second call would add nothing and this phone would keep
     * answering with a token the user believes they replaced — which surfaces
     * much later, as a push refused by GitHub for reasons nothing on screen
     * explains.
     */
    func testConnectingAgainReplacesBothHalves() {
        store.connect(login: "asadev", token: "gho_first", source: .signIn)
        store.connect(login: "someone-else", token: "github_pat_second", source: .token)

        XCTAssertEqual(store.account?.login, "someone-else")
        XCTAssertEqual(store.account?.source, .token)
        XCTAssertEqual(store.token(), "github_pat_second")
    }

    /**
     * A second store over the same drawer sees the write.
     *
     * Proves the bytes reached the Keychain rather than a cache in the first
     * instance — which is the difference between a token that survives the app
     * being killed and one that does not.
     */
    func testAWriteReallyReachesTheKeychain() {
        store.connect(login: "asadev", token: "gho_persisted", source: .signIn)

        let second = KeychainGitHubStore(service: store.serviceForTesting)
        XCTAssertEqual(second.account?.login, "asadev")
        XCTAssertEqual(second.token(), "gho_persisted")
    }

    /**
     * Disconnecting is the revocation that works from this end.
     *
     * Not a flag and not a forgotten name: the secret goes, so nothing on this
     * phone can answer a credential request from any machine afterwards. A
     * lingering token behind a cleared name would be the one failure this whole
     * feature cannot have.
     */
    func testDisconnectingRemovesTheSecretAndNotJustTheName() {
        store.connect(login: "asadev", token: "gho_gone", source: .signIn)
        store.disconnect()

        XCTAssertNil(store.account)
        XCTAssertNil(store.token())

        let second = KeychainGitHubStore(service: store.serviceForTesting)
        XCTAssertNil(second.account)
        XCTAssertNil(second.token(), "a token left behind that no screen describes is the worst outcome here")
    }

    // MARK: - Getting a token

    /// A scripted GitHub. Each entry is matched by the path of the request, so
    /// the order the flow makes its calls in is not baked into the double.
    private func scripted(_ answers: [String: (Int, String)]) -> GitHubFetch {
        { request in
            let path = request.url?.path ?? ""
            guard let (status, body) = answers[path] else {
                throw GitHubSignInError.sentence("nothing scripted for \(path)")
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    /// Give the flow's own task a chance to run. Generous by default, because
    /// the device flow deliberately waits out GitHub's five-second poll
    /// interval before its first attempt — obeying that is what keeps a real
    /// sign-in from being rate limited.
    private func settle(_ signIn: GitHubSignIn,
                        seconds: Double = 10,
                        until done: @escaping () -> Bool) async {
        for _ in 0 ..< Int(seconds * 50) {
            if done() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /**
     * A pasted token is validated by being used, and the login comes back from
     * GitHub.
     *
     * The fallback the design keeps on purpose — a fine-grained token scoped to
     * one repository, with an expiry — and it must produce an account
     * indistinguishable from a signed-in one, because the prompt draws both the
     * same way.
     */
    func testAPastedTokenIsCheckedAgainstGitHubAndKeepsTheNameGitHubGives() async {
        let signIn = GitHubSignIn(accounts: store, fetch: scripted([
            "/user": (200, #"{"login":"asadev","id":1}"#),
        ]))

        signIn.useToken("  github_pat_abc  ")
        await settle(signIn) { self.store.account != nil }

        XCTAssertEqual(store.account?.login, "asadev", "the name is GitHub's, never one this app guessed")
        XCTAssertEqual(store.account?.source, .token)
        XCTAssertEqual(store.token(), "github_pat_abc", "trimmed, because a paste carries whitespace")
    }

    func testATokenGitHubRefusesConnectsNothing() async {
        let signIn = GitHubSignIn(accounts: store, fetch: scripted([
            "/user": (401, #"{"message":"Bad credentials"}"#),
        ]))

        signIn.useToken("github_pat_wrong")
        await settle(signIn) { if case .failed = signIn.phase { return true } else { return false } }

        XCTAssertNil(store.account)
        XCTAssertNil(store.token())
        guard case let .failed(sentence) = signIn.phase else { return XCTFail("expected a failure") }
        XCTAssertEqual(sentence, "GitHub did not accept that token.")
    }

    func testAnEmptyPasteSaysSoRatherThanCallingGitHub() async {
        let signIn = GitHubSignIn(accounts: store, fetch: scripted([:]))

        signIn.useToken("   ")

        guard case let .failed(sentence) = signIn.phase else { return XCTFail("expected a failure") }
        XCTAssertEqual(sentence, "Paste a token first.")
    }

    /**
     * A token longer than the wire will carry is refused here, not on the first
     * push.
     *
     * `parseClientMessage` refuses a longer secret and answers a refused frame
     * by **closing the socket**, so letting one through would cost the
     * connection rather than one push — at a moment nobody can connect it to the
     * paste that caused it.
     */
    func testATokenTooLongForTheWireIsRefusedWhereItWasTyped() async {
        let signIn = GitHubSignIn(accounts: store, fetch: scripted([:]))

        signIn.useToken(String(repeating: "x", count: Wire.maxCredentialSecretLength + 1))

        guard case .failed = signIn.phase else { return XCTFail("expected a failure") }
        XCTAssertNil(store.account)
    }

    /**
     * The device flow puts a code on screen before anything else happens.
     *
     * The code is shown as text and the browser is sent to the plain
     * verification URI, never to GitHub's `verification_uri_complete`, which
     * fills the field in for you — that is a link which grants access if it is
     * forwarded.
     */
    func testSigningInShowsTheCodeAndThenFinishes() async {
        let signIn = GitHubSignIn(accounts: store, fetch: scripted([
            "/login/device/code": (200, #"""
            {"device_code":"dev","user_code":"ABCD-1234",
             "verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
            """#),
            "/login/oauth/access_token": (200, #"{"access_token":"gho_flow","token_type":"bearer"}"#),
            "/user": (200, #"{"login":"asadev"}"#),
        ]))

        signIn.start()
        await settle(signIn) { if case .waiting = signIn.phase { return true } else { return false } }

        guard case let .waiting(userCode, uri) = signIn.phase else {
            return XCTFail("expected a code on screen, got \(signIn.phase)")
        }
        XCTAssertEqual(userCode, "ABCD-1234")
        XCTAssertEqual(uri.absoluteString, "https://github.com/login/device")

        // The poll waits GitHub's own five seconds before its first attempt, so
        // this is the one case here that has to spend them.
        await settle(signIn) { self.store.account != nil }
        XCTAssertEqual(store.account?.login, "asadev")
        XCTAssertEqual(store.account?.source, .signIn)
        XCTAssertEqual(store.token(), "gho_flow")
    }

    func testCancellingTheFlowStopsTheDeviceCodeBeingUsed() async {
        let signIn = GitHubSignIn(accounts: store, fetch: scripted([
            "/login/device/code": (200, #"""
            {"device_code":"dev","user_code":"ABCD-1234",
             "verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}
            """#),
            "/login/oauth/access_token": (200, #"{"access_token":"gho_flow"}"#),
            "/user": (200, #"{"login":"asadev"}"#),
        ]))

        signIn.start()
        await settle(signIn) { if case .waiting = signIn.phase { return true } else { return false } }
        signIn.cancel()

        // Long enough for the poll's first attempt to have fired if it were
        // still alive. A task that outlives the screen wakes the radio every
        // five seconds for a code nobody is going to enter.
        try? await Task.sleep(for: .seconds(6))
        XCTAssertNil(store.account)
        XCTAssertEqual(signIn.phase, .idle)
    }
}
