/**
 * What a login is called on the bar, and the four ways that has gone wrong.
 *
 * The rule is pure — a `WireAccount` and a `WireSignIn` in, a string out — so
 * every case he has ever reported about it can be written down here rather than
 * re-found on a simulator. The screen itself is checked by looking at it; what a
 * screenshot cannot show is *why* a row says what it says, and each of these is
 * a decision that would keep passing a glance while being wrong.
 *
 * The complaint they exist for, Asad, 2026-08-26, on the account sheet on his
 * phone reading "Default", "Default (Codex CLI)", "Default (Gemini CLI)":
 *
 *   > *"when we click on this link it should clearly mention the name of the
 *   > account here instead of saying default — name of the account should be
 *   > there."*
 */

import XCTest
@testable import TerminalDeck

final class AccountNamingTests: XCTestCase {

    /// The rows the far machine actually sends for a machine nobody has added an
    /// account to: one system profile per agent, each named after its own key.
    private func install(_ id: String, _ name: String, _ provider: String,
                         signIn: WireSignIn? = nil) -> WireAccount {
        WireAccount(id: id, name: name, provider: provider, color: nil, system: true, signIn: signIn)
    }

    // MARK: - The complaint

    func testTheThreeRowsHeFilmedNoLongerAllSayDefault() {
        /*
         * The exact list off a fresh machine, in the exact words the sheet drew
         * them in. None of the three has an address to print, so all three fall
         * to the third rung — and the third rung has to name the agent, or the
         * fix would be three rows reading "Your own install" instead of three
         * rows reading "Default". Same defect, politer word.
         */
        let rows = [
            install("system", "Default", "claude"),
            install("system:codex", "Default (Codex CLI)", "codex"),
            install("system:gemini", "Default (Gemini CLI)", "gemini"),
        ]
        let labels = rows.map { accountLoginLabel($0) }
        XCTAssertEqual(labels, [
            "Your own Claude Code install",
            "Your own Codex CLI install",
            "Your own Gemini CLI install",
        ])
        XCTAssertEqual(Set(labels).count, 3, "three accounts, three different captions")
        for label in labels {
            XCTAssertFalse(label.lowercased().contains("default"),
                           "the word the chip exists to suppress is back on the chip")
        }
    }

    // MARK: - Rung 1: the address

    func testASignedInInstallIsNamedByItsAddressAndNotByItsKey() {
        let row = install("system", "Default", "claude",
                          signIn: WireSignIn(state: "signed-in", account: "app.imatch.ae@gmail.com"))
        XCTAssertEqual(accountLoginLabel(row), "app.imatch.ae@gmail.com")
    }

    func testAnExpiredClaudeLoginDoesNotGetToKeepItsAddress() {
        /*
         * The trap, and the reason rung 1 is gated on the *state* rather than on
         * the address being present. `claude auth status --json` answers
         * `{"loggedIn": false, "email": "…"}` for an expired login, so the
         * address outlives the session it belonged to. Reading `account` alone
         * would put a stale address on a chip for a session that is signed in as
         * nobody — confidently wrong, which is worse than "Default".
         */
        let expired = install("system", "Default", "claude",
                              signIn: WireSignIn(state: "signed-out", account: "app.imatch.ae@gmail.com"))
        XCTAssertEqual(accountLoginLabel(expired), "Your own Claude Code install")
        XCTAssertNil(namedLogin(expired))

        // And a state this build has never heard of is not the signed-in one
        // either. The wire keeps `state` a bare string on purpose; an unknown
        // value falls to a lower rung rather than being read optimistically.
        let future = install("system", "Default", "claude",
                             signIn: WireSignIn(state: "reauthenticating", account: "a@b.com"))
        XCTAssertEqual(accountLoginLabel(future), "Your own Claude Code install")
    }

    func testASignedInReportWithNoAddressIsNotAnAddress() {
        // A machine that answers `{"state":"signed-in","account":""}` — or omits
        // the address altogether — has not named anybody. An empty caption on a
        // row that is about to be pressed is worse than a sentence about the
        // install, so both fall through to rung 3 rather than printing nothing.
        let empty = install("system", "Default", "claude",
                            signIn: WireSignIn(state: "signed-in", account: ""))
        XCTAssertEqual(accountLoginLabel(empty), "Your own Claude Code install")
        let absent = install("system", "Default", "claude",
                             signIn: WireSignIn(state: "signed-in", account: nil))
        XCTAssertEqual(accountLoginLabel(absent), "Your own Claude Code install")
    }

    // MARK: - Rung 2: the name, when a person chose it

    func testAnAccountSomebodyNamedKeepsItsName() {
        let mine = WireAccount(id: "work", name: "Client work", provider: "claude",
                               color: "--accent", system: false, signIn: nil)
        XCTAssertEqual(accountLoginLabel(mine), "Client work")
        XCTAssertEqual(namedLogin(mine), "Client work")
    }

    func testAGeneratedNameIsNeverTreatedAsAName() {
        // `system` and `system:<agent>` are minted by `profiles.ts` and never by
        // a person, so the name beside them is generated whatever it says.
        XCTAssertTrue(isGeneratedAccountId("system"))
        XCTAssertTrue(isGeneratedAccountId("system:gemini"))
        XCTAssertFalse(isGeneratedAccountId("work"))
        XCTAssertFalse(isGeneratedAccountId("systematic"))
    }

    func testAnOlderMachineThatSendsNoSystemFlagIsStillReadOffTheId() {
        /*
         * The `or` in `isGeneratedAccount`, and it is load-bearing on this client
         * more than any other. `WireCodec.account` decodes `system` as
         * `row["system"] as? Bool == true`, so a desktop whose build predates the
         * field arrives here as an explicit `false` — and trusting the flag alone
         * would read that as *"somebody named this account Default (Gemini
         * CLI)"* and print the slug he filmed.
         */
        let old = WireAccount(id: "system:gemini", name: "Default (Gemini CLI)",
                              provider: "gemini", color: nil, system: false, signIn: nil)
        XCTAssertTrue(isGeneratedAccount(old))
        XCTAssertEqual(accountLoginLabel(old), "Your own Gemini CLI install")
    }

    // MARK: - Rung 3: which install this is

    func testCodexFallsToTheInstallBecauseItsCliNamesNobody() {
        /*
         * Not a rare case. `codex login status` prints *"Logged in using
         * ChatGPT"* and never an address, by design — so a signed-in Codex row
         * reaches rung 3 every single time. If the fallback were the sign-in
         * state instead, every Codex login in the list would be named after its
         * plan and two of them would be indistinguishable.
         */
        let codex = install("system:codex", "Default (Codex CLI)", "codex",
                            signIn: WireSignIn(state: "signed-in", account: nil))
        XCTAssertEqual(accountLoginLabel(codex), "Your own Codex CLI install")
        XCTAssertNil(namedLogin(codex))
    }

    func testAListAlreadyFilteredToOneAgentMayDropTheAgentsName() {
        /*
         * `namesTheAgent: false` is for a list whose rows all belong to one
         * agent, where the name distinguishes nothing and what is left is a
         * vendor's product name printed in a pop-up:
         *
         *   > *"You should not mention in any settings or any pop-up a specific
         *   > tool or LLM, because they can use some other also."*
         *
         * Nothing on the session bar passes it — that sheet lists every login on
         * the far machine — and the assertion below is what keeps the default
         * from quietly flipping under a later edit.
         */
        let row = install("system", "Default", "claude")
        XCTAssertEqual(accountLoginLabel(row, namesTheAgent: false), "Your own install")
        XCTAssertEqual(accountLoginLabel(row), "Your own Claude Code install")
    }

    func testAnAgentThisBuildHasNeverHeardOfGetsATrueSentenceAndNotItsSlug() {
        // A `custom:` agent somebody added on the far machine. "Your own
        // custom:my-agent install" would be a slug leaking onto a screen, which
        // is the complaint rather than the fix.
        let unknown = install("system:custom:my-agent", "Default (my-agent)", "custom:my-agent")
        XCTAssertEqual(accountLoginLabel(unknown), "Your own install")

        // The same for a machine too old to name its agent at all.
        let unnamed = WireAccount(id: "system", name: "Default", provider: nil,
                                  color: nil, system: true, signIn: nil)
        XCTAssertEqual(accountLoginLabel(unnamed), "Your own install")
    }

    // MARK: - The wire

    func testTheSignInReportIsDecodedOffTheAccountRow() {
        /*
         * The half that was missing. `account-serve.ts`'s `toWire` has spread a
         * `signIn` object onto every account row since 2026-08-21; this client
         * decoded id/name/provider/color/system and dropped it, which is why the
         * chip could not have told the truth even if it had wanted to.
         */
        let row: [String: Any] = [
            "id": "system",
            "name": "Default",
            "provider": "claude",
            "color": "--accent",
            "system": true,
            "signIn": ["state": "signed-in", "account": "app.imatch.ae@gmail.com",
                       "plan": "max", "detail": "Signed in as app.imatch.ae@gmail.com on the max plan"],
        ]
        let account = WireCodec.account(row)
        XCTAssertEqual(account?.signIn, WireSignIn(state: "signed-in", account: "app.imatch.ae@gmail.com"))
        XCTAssertEqual(account.map { accountLoginLabel($0) }, "app.imatch.ae@gmail.com")
    }

    func testAMachineThatSaidNothingIsNotAMachineThatSaidSignedOut() {
        /*
         * Absent is a real answer meaning *that machine did not say* — an older
         * desktop, or a probe that threw on the far side. It must not collapse
         * into "signed out": the two have different remedies and only one of
         * them is fixed by logging in again. Here it simply falls to the rung
         * below, which says something true either way.
         */
        XCTAssertNil(WireCodec.signIn(nil))
        XCTAssertNil(WireCodec.signIn("signed-in"))
        XCTAssertNil(WireCodec.signIn(["account": "a@b.com"]), "no state is not a report")
        XCTAssertNil(WireCodec.signIn(["state": ""]))

        let quiet: [String: Any] = ["id": "system", "name": "Default", "provider": "claude", "system": true]
        XCTAssertNil(WireCodec.account(quiet)?.signIn)
        XCTAssertEqual(WireCodec.account(quiet).map { accountLoginLabel($0) }, "Your own Claude Code install")
    }

    func testAnAddressIsCleanedTheWayEveryOtherPrintedStringIs() {
        // It arrives from another machine and lands in a chip on a phone. A
        // control character or a two-thousand-character "address" is a bar that
        // no longer fits on the screen — `displayLine` is the one door.
        let report = WireCodec.signIn(["state": "signed-in", "account": "  a@b.com\u{0007}  "])
        XCTAssertEqual(report?.account, "a@b.com")
        XCTAssertNil(WireCodec.signIn(["state": "signed-in", "account": "   "])?.account)
        let long = String(repeating: "x", count: 500) + "@b.com"
        XCTAssertEqual(WireCodec.signIn(["state": "signed-in", "account": long])?.account?.count,
                       WireCodec.maxDisplayLine)
    }

    func testAnAccountBuiltWithoutASignInStillCompilesAndMeansNothingWasSaid() {
        // The initialiser defaults `signIn` so that every row built by hand —
        // here, and in whatever fixture comes next — keeps meaning "this machine
        // said nothing" without restating it.
        let row = WireAccount(id: "system", name: "Default", provider: "claude", color: nil, system: true)
        XCTAssertNil(row.signIn)
    }
}
