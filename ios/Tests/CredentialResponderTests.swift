/**
 * The policy: who gets asked, who gets answered silently, and who gets refused.
 *
 * These are the four lines of `CREDENTIAL-PROXY.md` written as assertions. Every
 * one of them is a claim about somebody else's `git push` sitting on a socket,
 * so the refusals are tested as hard as the approvals — a denied request, a
 * request with no account behind it, a machine that vanished mid-question, and
 * an answer for a repository nobody was asked about.
 *
 * No UI and no network. The prompt is a `View` reading `asking`; everything that
 * decides what `asking` becomes is here.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class CredentialResponderTests: XCTestCase {

    // MARK: - Doubles

    /// A GitHub account with no Keychain behind it, and a counter, because
    /// *when* the token is read is part of the design: not while a prompt is on
    /// screen, only when a reply is built.
    private final class FakeAccounts: GitHubAccountStore {
        var account: GitHubAccount?
        var secret: String?
        private(set) var tokenReads = 0

        init(login: String? = "asadev", token: String? = "gho_secret") {
            if let login {
                account = GitHubAccount(login: login, source: .signIn, connectedAt: Date())
            }
            secret = token
        }

        func token() -> String? {
            tokenReads += 1
            return secret
        }

        func connect(login: String, token: String, source: GitHubAccount.Source) {
            account = GitHubAccount(login: login, source: source, connectedAt: Date())
            secret = token
        }

        func disconnect() {
            account = nil
            secret = nil
        }
    }

    private func responder(_ accounts: FakeAccounts) -> (CredentialResponder, () -> [(String, CredentialAnswer)]) {
        let responder = CredentialResponder(accounts: accounts)
        var sent: [(String, CredentialAnswer)] = []
        responder.route = { machine, answer in sent.append((machine, answer)) }
        return (responder, { sent })
    }

    private func ask(id: String = "r1",
                     machine: String = "mac-1",
                     name: String = "MacBook",
                     repo: String? = "asadev/terminaldeck",
                     operation: CredentialOperation = .write,
                     prompt: Bool = true) -> CredentialRequest {
        CredentialRequest(id: id, machineId: machine, machineName: name,
                          origin: "github.com", repo: repo, operation: operation, prompt: prompt)
    }

    // MARK: - Silent

    /**
     * A read is answered without anybody being interrupted.
     *
     * This is most of what the feature does: every fetch, pull and clone in a
     * session on somebody else's machine comes through here, and a prompt for
     * each of them would train a person to tap Approve without reading.
     */
    func testAReadIsAnsweredWithoutAPrompt() {
        let accounts = FakeAccounts()
        let (responder, sent) = responder(accounts)

        responder.receive(ask(operation: .read, prompt: false))

        XCTAssertNil(responder.asking, "nobody should be asked about a fetch")
        guard sent().count == 2 else { return XCTFail("expected an ack and an answer: \(sent().count)") }
        XCTAssertEqual(sent()[0].1, .ack(id: "r1"))
        XCTAssertEqual(sent()[1].1, .login(id: "r1", username: "asadev", password: "gho_secret", remember: false))
    }

    /**
     * An already-approved push is silent too, and that is the desktop's call.
     *
     * It arrives as `prompt: false` on a `write`. The desktop is the side that
     * remembers which repositories this device has approved *on that machine*,
     * so a phone that second-guessed it would be a second source of truth with
     * no way to reconcile the two.
     */
    func testAnApprovedPushIsSilentBecauseTheDesktopSaidSo() {
        let accounts = FakeAccounts()
        let (responder, sent) = responder(accounts)

        responder.receive(ask(operation: .write, prompt: false))

        XCTAssertNil(responder.asking)
        XCTAssertEqual(sent().last?.1, .login(id: "r1", username: "asadev", password: "gho_secret", remember: false))
    }

    // MARK: - The acknowledgement

    /**
     * Every request is acknowledged, including one that is about to be refused.
     *
     * The ack is what tells the desktop this device is *there*, and it is the
     * frame the whole feature's failure mode rests on: without it, a phone in a
     * drawer and a person who is thinking look identical, and the desktop has to
     * wait out the human deadline before it can say "your device isn't
     * reachable" — a thirty-second stall on a push with nothing on screen.
     */
    func testEveryRequestIsAcknowledgedFirstEvenWhenItWillBeRefused() {
        let accounts = FakeAccounts(login: nil, token: nil)
        let (responder, sent) = responder(accounts)

        responder.receive(ask())

        XCTAssertEqual(sent().first?.1, .ack(id: "r1"))
        XCTAssertEqual(sent().last?.1, .refuse(id: "r1", reason: .noAccount))
    }

    /// "No account" is not "denied". It is a different thing to be told and has
    /// a different fix — the desktop's wording for it points at this phone
    /// rather than at the person who pushed.
    func testNoAccountIsNotARefusal() {
        let accounts = FakeAccounts(login: nil, token: nil)
        let (responder, sent) = responder(accounts)

        responder.receive(ask(prompt: false))

        XCTAssertEqual(sent().last?.1, .refuse(id: "r1", reason: .noAccount))
        XCTAssertNil(responder.asking, "there is nothing to ask a person about")
    }

    // MARK: - The prompt

    func testAPushRaisesTheQuestionAndAnswersNothingUntilItIsAnswered() {
        let accounts = FakeAccounts()
        let (responder, sent) = responder(accounts)

        responder.receive(ask())

        XCTAssertEqual(responder.asking?.id, "r1")
        XCTAssertEqual(sent().map(\.1), [.ack(id: "r1")], "the ack, and nothing else, until a button is pressed")
    }

    /**
     * The token is not read while somebody is deciding.
     *
     * A person may take a minute over this prompt, and for that minute the bytes
     * that grant a push have no reason to be in this process. They are read when
     * the reply is built and go into that reply and nowhere else.
     */
    func testTheTokenIsNotTouchedWhileTheQuestionIsOnScreen() {
        let accounts = FakeAccounts()
        let (responder, _) = responder(accounts)

        responder.receive(ask())
        XCTAssertEqual(accounts.tokenReads, 0)

        responder.approve(remember: false)
        XCTAssertEqual(accounts.tokenReads, 1)
    }

    func testApproveAlwaysSendsTheScopeAndPlainApproveDoesNot() {
        let accounts = FakeAccounts()
        let (responder, sent) = responder(accounts)

        responder.receive(ask(id: "a"))
        responder.approve(remember: false)
        responder.receive(ask(id: "b"))
        responder.approve(remember: true)

        XCTAssertEqual(sent().last?.1, .login(id: "b", username: "asadev", password: "gho_secret", remember: true))
        let first = sent().first { if case .login(let id, _, _, _) = $0.1 { return id == "a" } else { return false } }
        XCTAssertEqual(first?.1, .login(id: "a", username: "asadev", password: "gho_secret", remember: false))
    }

    /**
     * "Always" is dropped when the desktop could not name the repository.
     *
     * There is nothing to attach the always to, the desktop refuses to record an
     * approval it cannot key, and sending it anyway would be this phone claiming
     * a consent that nothing acts on. The prompt hides the button for the same
     * reason.
     */
    func testAlwaysIsNotClaimedForARepositoryWithNoName() {
        let accounts = FakeAccounts()
        let (responder, sent) = responder(accounts)

        responder.receive(ask(repo: nil))
        responder.approve(remember: true)

        XCTAssertEqual(sent().last?.1, .login(id: "r1", username: "asadev", password: "gho_secret", remember: false))
    }

    func testDenyRefusesAndClearsTheScreen() {
        let accounts = FakeAccounts()
        let (responder, sent) = responder(accounts)

        responder.receive(ask())
        responder.deny()

        XCTAssertNil(responder.asking)
        XCTAssertEqual(sent().last?.1, .refuse(id: "r1", reason: .denied))
    }

    /**
     * Disconnecting GitHub while a prompt is up is answered honestly.
     *
     * The button did not fail; there is simply no account any more. Anything
     * else would be a tap that reports success and produces a push that cannot
     * happen.
     */
    func testApprovingWithTheAccountGoneRefusesRatherThanPretending() {
        let accounts = FakeAccounts()
        let (responder, sent) = responder(accounts)

        responder.receive(ask())
        accounts.disconnect()
        responder.approve(remember: false)

        XCTAssertEqual(sent().last?.1, .refuse(id: "r1", reason: .noAccount))
    }

    // MARK: - Several at once

    func testASecondQuestionWaitsAndArrivesWhenTheFirstIsAnswered() {
        let accounts = FakeAccounts()
        let (responder, sent) = responder(accounts)

        responder.receive(ask(id: "first"))
        responder.receive(ask(id: "second", machine: "pc-2", name: "Work PC"))

        XCTAssertEqual(responder.asking?.id, "first", "two prompts stacked on each other is not a question")
        XCTAssertEqual(responder.waiting.map(\.id), ["second"])
        // Both were acknowledged the moment they arrived: the one behind the
        // prompt is not allowed to look like a device that is not there.
        XCTAssertTrue(sent().contains { $0.1 == .ack(id: "second") })

        responder.approve(remember: false)
        XCTAssertEqual(responder.asking?.id, "second")
        XCTAssertEqual(responder.asking?.machineName, "Work PC")
    }

    /// Replies go to the machine that asked, not to whichever one is on screen.
    /// Getting this wrong would answer one computer's question on another's
    /// socket.
    func testAnAnswerIsRoutedBackToTheMachineThatAsked() {
        let accounts = FakeAccounts()
        let (responder, sent) = responder(accounts)

        responder.receive(ask(id: "r", machine: "pc-2", name: "Work PC"))
        responder.approve(remember: false)

        XCTAssertEqual(sent().last?.0, "pc-2")
    }

    // MARK: - Things going away

    /**
     * A machine that disconnected takes its question with it.
     *
     * The desktop settles a pending request the moment its last connection to a
     * device goes, so the buttons on screen would be answering nothing. A
     * control that looks pressable has to do something.
     */
    func testAQuestionFromAMachineThatWentAwayIsTakenOffTheScreen() {
        let accounts = FakeAccounts()
        let (responder, _) = responder(accounts)

        responder.receive(ask(id: "gone", machine: "mac-1"))
        responder.receive(ask(id: "still-here", machine: "pc-2", name: "Work PC"))
        responder.machineLost("mac-1")

        XCTAssertEqual(responder.asking?.id, "still-here", "the other machine's question survives")
        XCTAssertTrue(responder.waiting.isEmpty)
    }

    func testLosingAMachineDropsItsWaitingQuestionsToo() {
        let accounts = FakeAccounts()
        let (responder, _) = responder(accounts)

        responder.receive(ask(id: "front", machine: "pc-2", name: "Work PC"))
        responder.receive(ask(id: "behind", machine: "mac-1"))
        responder.machineLost("mac-1")

        XCTAssertEqual(responder.asking?.id, "front")
        XCTAssertTrue(responder.waiting.isEmpty)
    }

    /**
     * A phone will not hold questions without limit.
     *
     * Unreachable through a desktop that behaves — it refuses more than four in
     * flight per device — so this is about a machine that has stopped behaving,
     * and the answer is immediate rather than silent.
     */
    func testTooManyQuestionsAreRefusedRatherThanAccumulated() {
        let accounts = FakeAccounts()
        let (responder, sent) = responder(accounts)

        for index in 0 ..< (CredentialResponder.maxPending + 4) {
            responder.receive(ask(id: "q\(index)"))
        }

        XCTAssertEqual(responder.waiting.count + 1, CredentialResponder.maxPending)
        let refusals = sent().filter { $0.1 == .refuse(id: "q\(CredentialResponder.maxPending)", reason: .denied) }
        XCTAssertEqual(refusals.count, 1, "the one past the cap is told so")
    }

    // MARK: - Nothing to answer

    /// Pressing a button with no question on screen is not a crash and is not a
    /// frame. It is the state after an expiry, and the sheet's own dismissal can
    /// race it.
    func testPressingAButtonWithNothingAskedSendsNothing() {
        let accounts = FakeAccounts()
        let (responder, sent) = responder(accounts)

        responder.approve(remember: true)
        responder.deny()

        XCTAssertTrue(sent().isEmpty)
    }
}
