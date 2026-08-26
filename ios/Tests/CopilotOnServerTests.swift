/**
 * **Where the Copilot tab lands on a server, and what it offers when it cannot
 * land anywhere.**
 *
 * Two sentences of his, three weeks apart, and the second reshaped the screen
 * the first one asked for:
 *
 * > *"the copilot page has two options — to redirect to the session page or
 * > menu — but it doesn't make any sense. It should be just having an option to
 * > start the copilot, or chat to the copilot, or start the session or something
 * > like that, instead of just redirecting to the other pages. And copilot
 * > should have a consistent connection and all of this stuff."*
 *
 * > *"copilot page should be always landing in a copilot session according to
 * > the settings of the copilot — either in an existing session if there is any,
 * > or it should start a new. But it should be always a chat to land with,
 * > terminal and chat mode too."*
 *
 * Every rule either one produced is decided by `CopilotOnServer`, which is a
 * handful of pure functions for one reason: the ways this screen can be wrong
 * are all silent, and most of them need the screen at **two** moments to be
 * visible at all.
 *
 *  - A tab that **starts a session because somebody chose a tab**. A paid agent
 *    spawned by a thumb on the wrong pill, with no undo.
 *  - A landing that **re-runs after Back**, which makes this screen unreachable
 *    rather than making the tab a destination.
 *  - A **Start** row on a phone that has been shared nothing. The machine
 *    refuses every `create` from it, so the one row the screen exists to offer
 *    would be a dead control.
 *  - An **Open** row over a plain shell, or over a session that has exited. A
 *    button offering a conversation that opens a bare prompt.
 *  - A row naming **Claude Code** on a server that starts something else, which
 *    reads as a fact and is a guess.
 *  - Rows that **leave and come back** every time the socket blinks, which is
 *    the *"consistent connection"* complaint.
 *
 * `CopilotPillTests` covers whether a server gets the fourth pill; this covers
 * what is behind it. There is no view here on purpose — a test that had to raise
 * a real server with a running agent on it to check that Back is not undone
 * would be a test that is run once.
 *
 * ## The starting half was refused twice, and then he settled it
 *
 * > *"the copilot page will directly land into some session — not to a selection
 * > and something on the page… When we go to copilot it should just start the
 * > session; if there is already an existing session it should start from there
 * > where we left, and if not then it should create itself and start from the
 * > beginning. I told the exact same also before."*
 *
 * `Landing` used to have two cases and a comment saying there would never be a
 * third. Then it had three, gated on a setup a finger had completed. It now has
 * three and **no gate**: an absent record means *start*, and the guard the gate
 * was standing in for moved to where the actual danger was — the folder is
 * written down the moment the tab lands in something, so nothing is ever guessed
 * and silently kept.
 *
 * Both directions are pinned below, because the failure in each is expensive and
 * neither is visible without standing on the screen twice: a tab that hammers a
 * machine with `create` frames, and a tab that puts a question between somebody
 * and the thing they tapped the pill for.
 *
 * ## And the screen behind the gear, for the same reason
 *
 * > *"it doesn't mean like information about copilot. I meant all the control
 * > about copilot, all the settings of the copilot, and everything related to
 * > copilot that we need to have as options and control and settings."*
 *
 * The second half of this file walks `CopilotControl` and `CopilotSetupBook`,
 * and it is here rather than in a file of its own because it is the same tab and
 * the same failure mode. Everything that screen can get wrong is silent and most
 * of it needs a machine of a particular kind to be visible at all:
 *
 *  - A **button on two of the three screens** the tab can be showing, which goes
 *    missing exactly where it is needed — the landed session, where least is on
 *    screen naming what you are talking to.
 *  - A **desktop's section drawn over a server**, or the reverse: a grant card
 *    over a machine that has no copilot, an agent chooser over one whose copilot
 *    the setting has no bearing on. Every row in either would refuse on press.
 *  - A **control offered to a phone that may not use it** — the action log and
 *    the session list are `read` tier, and the overflow menu this screen replaced
 *    used to offer both to a phone that had been granted nothing.
 *  - The **prose back at the top**, which is the correction itself.
 *  - A **folder stored where it cannot be used**: a relative path, or one
 *    machine's path under another machine's id — or, worst, a folder the tab
 *    started in and never wrote down, which is a copilot living somewhere nobody
 *    chose and nobody can see.
 *
 * The passages themselves are still walked — `AboutCopilot` did not change, only
 * where it is reached from — for the reasons they always were: a **tool count
 * this app invented**, a **copy of the tool catalogue** (thirty-four ids across
 * `src/main/deck-control/` on the day it was written, moved twice that week),
 * and a sentence about **where a confirmation is answered** that names the wrong
 * end, which is a promise about a question with a two-minute deadline that
 * expires into a refusal.
 */

import XCTest
@testable import TerminalDeck

final class CopilotOnServerTests: XCTestCase {

    // MARK: - What the machine said, and what is drawn from it

    /**
     * **A machine that has said nothing offers nothing.**
     *
     * The first seconds of a first connection, and a phone opened while its
     * server is off. Drawing the rows on the guess that a server can obviously
     * start a session is how a control comes to refuse on every press — which is
     * the argument `src/headless/host.ts` makes about the copilot itself when it
     * declines to wire a tool-less one: *"worse than the absence, not better."*
     */
    func testAServerThatHasSaidNothingOffersNothing() {
        let nothing = CopilotOnServer.start(offer: CopilotOnServer.Offer(), granted: ["/srv/app"])

        XCTAssertFalse(nothing.now, "nothing has said this machine can start a session")
        XCTAssertFalse(nothing.inAFolder)
    }

    /**
     * **Shared nothing means the picker, not a Start button.**
     *
     * A grant list that is present and empty is a person having chosen to share
     * no folder with this device, and it is the state a *fresh server pairing
     * lands in* — so this is the ordinary case on a server rather than an edge of
     * it. `create` is refused every time in that state, and the press that
     * actually changes something is *Choose a folder*.
     *
     * Not this screen's invention: it is the rule `SessionListView`'s empty state
     * already keeps, and the two are asserted to agree by being one rule. A
     * second copy would drift, and the direction it drifts is always the copy
     * nobody is looking at.
     */
    func testAPhoneSharedNoFoldersIsOfferedTheFolderPickerAndNotAPlainStart() {
        let offer = CopilotOnServer.Offer(start: true, pickFolders: true)
        let rows = CopilotOnServer.start(offer: offer, granted: [])

        XCTAssertFalse(rows.now, "every create from this device is refused; the row would be dead")
        XCTAssertTrue(rows.inAFolder, "and this is the press that changes it")
    }

    /**
     * **Shared nothing and no picker either is an empty card, not a lit one.**
     *
     * A guest, or a host older than `folders.pick`. Nothing this screen can draw
     * would work, so it draws nothing and the headline carries the screen. The
     * alternative — a Start button that always refuses — is the exact fault the
     * rewrite removed.
     */
    func testSharedNothingWithNoPickerLeavesNoStartingRowAtAll() {
        let offer = CopilotOnServer.Offer(start: true, pickFolders: false)
        let rows = CopilotOnServer.start(offer: offer, granted: [])

        XCTAssertFalse(rows.now)
        XCTAssertFalse(rows.inAFolder)
    }

    /**
     * **A host too old to have listed its grants still starts.**
     *
     * `nil` and `[]` are two different facts and `HostLink.granted` keeps them
     * apart on purpose: nil is a machine that predates the field and enforces
     * against its own open folders, empty is a person choosing none. Collapsing
     * them would put the older host's phone in front of the newer host's
     * *"nothing is shared"* screen, with the one button that works removed.
     */
    func testAHostTooOldToHaveListedItsGrantsStillGetsAPlainStart() {
        let offer = CopilotOnServer.Offer(start: true, pickFolders: false)
        let rows = CopilotOnServer.start(offer: offer, granted: nil)

        XCTAssertTrue(rows.now, "nil is not empty — that host enforces against its own folders")
        XCTAssertFalse(rows.inAFolder)
    }

    /**
     * **A socket that dropped has not made the machine less capable.**
     *
     * This is *"copilot should have a consistent connection"*, reduced to the one
     * assertion that carries it. Every capability on `HostLink` is
     * `connection.isLive && the capability`, so a screen drawn straight off them
     * empties itself in a lift and fills back in on the platform, while nothing
     * about the machine has changed at all.
     *
     * `Offer` is therefore monotonic for as long as the screen is up. Asserted by
     * feeding it the sequence a real reconnect produces — heard, lost, heard —
     * rather than by checking the flag once, because the failure is a *later*
     * write clearing an earlier one and a single check cannot see it.
     */
    func testWhatTheMachineSaidIsKeptWhileTheSocketComesAndGoes() {
        var offer = CopilotOnServer.Offer()
        offer.heard(canStart: true, canPick: true)
        XCTAssertEqual(offer, CopilotOnServer.Offer(start: true, pickFolders: true))

        // The socket drops: both flags on `HostLink` go false together.
        offer.heard(canStart: false, canPick: false)
        XCTAssertEqual(offer, CopilotOnServer.Offer(start: true, pickFolders: true),
                       "the rows must not leave the screen because a phone went through a tunnel")

        offer.heard(canStart: true, canPick: true)
        XCTAssertEqual(offer, CopilotOnServer.Offer(start: true, pickFolders: true))
    }

    // MARK: - The agent that is already here

    /**
     * **A copilot session is one with an agent listening in it, or there is none.**
     *
     * A copilot conversation is not reachable on a server — `src/headless/cli.ts`
     * says so in `NO_COPILOT_HERE`, `src/headless/host.ts` declines to assemble
     * one without a window to confirm `alter` calls in, and the desktop's own
     * machine switcher lists no servers for the same reason. So the honest
     * offer is the agent that is already running there, and *honest* is the whole
     * of it: neither the landing nor the row may open a shell.
     */
    func testACopilotSessionIsARunningAgentAndNotAShellOrACorpse() {
        let sessions = [
            Self.session(id: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", provider: "claude", status: "exited"),
            Self.session(id: "01J8ZC4T9K5Q2V7XW3NHRF6MBE", provider: "shell", status: "idle"),
            Self.session(id: "01J8ZC4T9K5Q2V7XW3NHRF6MBF", provider: "codex", status: "working"),
        ]

        let chosen = CopilotOnServer.copilotSession(in: sessions, folder: nil)

        XCTAssertEqual(chosen?.id, "01J8ZC4T9K5Q2V7XW3NHRF6MBF",
                       "an exited session has nothing listening and a shell is not something to ask")
        XCTAssertEqual(ServerSettingsText.providerLabel(chosen?.provider ?? ""), "Codex CLI")
    }

    /**
     * **A provider the machine never named is not guessed at.**
     *
     * `RemoteSession.provider` is free-form on purpose — the vocabulary belongs
     * to the machine and a newer build will send something this app has not heard
     * of — and the empty string is a host that said nothing rather than a host
     * that said *agent*. A row built on that gap reads *Ask* over a prompt that
     * may be a bare shell, which is the same class of claim as naming Claude Code
     * on a machine that starts Codex.
     */
    func testASessionWhoseProviderWasNeverNamedIsNotOfferedAsAnAgent() {
        XCTAssertNil(CopilotOnServer.copilotSession(in: [Self.session(provider: "", status: "idle")],
                                                    folder: nil))
        XCTAssertNil(CopilotOnServer.copilotSession(in: [], folder: nil))
    }

    /**
     * **An agent this build has never heard of is still opened, under its own id.**
     *
     * The same rule the session list keeps: a build of the host newer than this
     * app will send a provider name that is not in the table, and the answer is
     * to render it rather than to drop the row. Dropping it would hide a running
     * agent from the one screen offering to reach it, for the sole reason that
     * this app is older than the machine.
     */
    func testAnUnknownAgentIsOfferedUnderTheNameTheMachineSent() {
        let chosen = CopilotOnServer.copilotSession(in: [Self.session(provider: "custom:mine",
                                                                       status: "idle")],
                                                   folder: nil)

        XCTAssertEqual(chosen?.provider, "custom:mine")
        XCTAssertEqual(ServerSettingsText.providerLabel("custom:mine"), "custom:mine",
                       "better a readable id than a guessed label")
    }

    // MARK: - What a new session will have in it

    /**
     * **The Start row names what the server is about to put in the session.**
     *
     * This is what makes *"start a session"* a truthful answer to *"start the
     * copilot"* rather than a change of subject. It is not a guess about what a
     * session usually contains: `agents.defaultProvider` is the value
     * `host-core.ts` reaches for when a `create` frame names no provider —
     * `input.provider ?? store().getPreferences().defaultProvider` — so the row
     * and the machine are reading the same field.
     */
    func testTheStartRowNamesTheAgentTheServerWillPutInIt() {
        XCTAssertEqual(CopilotOnServer.agentSentence(provider: "claude"),
                       "Starts Claude Code and opens the chat.")
        XCTAssertEqual(CopilotOnServer.agentSentence(provider: "gemini"),
                       "Starts Gemini CLI and opens the chat.")
    }

    /**
     * **A server whose default is a plain shell says so.**
     *
     * The one case where the button does *not* start an agent, and therefore the
     * one case worth being loud about. Falling back to the vaguer sentence here
     * would hide the single situation in which somebody pressing this expecting a
     * copilot gets a bare prompt.
     */
    func testAServerThatStartsAShellSaysSoRatherThanGoingVague() {
        XCTAssertEqual(CopilotOnServer.agentSentence(provider: "shell"),
                       "Starts a plain shell — no agent, no chat.")
    }

    /**
     * **A server that has not said is not spoken for.**
     *
     * Nil is *not yet* — `ServerSettingsLink` clears its rows on every welcome
     * and re-reads a moment later — and the screen's fallback sentence names no
     * agent. Naming one here would be the one thing worse than naming none: the
     * row would read *Claude Code* over a machine that starts something else, and
     * it would read that way for the first second of every reconnect.
     */
    func testAServerThatHasNotSaidIsNotSpokenFor() {
        XCTAssertNil(CopilotOnServer.agentSentence(provider: nil))
        XCTAssertNil(CopilotOnServer.agentSentence(provider: ""))
    }

    // MARK: - The socket, once and late

    /**
     * **A blink says nothing.**
     *
     * The other half of *"consistent connection"*. `ConnectionNotice` carries his
     * five seconds — comfortably longer than a relay dial or a lift, comfortably
     * shorter than the point somebody decides the app is broken — and this screen
     * says nothing at all until it has decided there is something to say.
     */
    func testABlinkingSocketPutsNothingOnTheScreen() {
        let reconnecting = ConnectionState(phase: .waiting,
                                           detail: "Reconnecting to that server.",
                                           retryAt: nil,
                                           attempts: 1)

        XCTAssertNil(CopilotOnServer.wireLine(reconnecting, showing: false),
                     "inside the grace period there is nothing worth saying")
        XCTAssertEqual(CopilotOnServer.wireLine(reconnecting, showing: true),
                       "Reconnecting to that server.")
    }

    /**
     * **A notice that has not caught up cannot draw an outage over a live wire.**
     *
     * `ConnectionNotice.isShowing` is moved by a timer, so there is a frame in
     * which it is still true after the connection has come back. One frame of a
     * warning about a machine that is answering is small; it is also exactly the
     * kind of stale sentence this screen was rewritten to stop showing, and the
     * guard costs one comparison.
     *
     * `verified` is checked as well as `phase`, because *"Checking"* — a socket
     * this side has cause to doubt — is deliberately not treated as connected
     * anywhere else in the app either.
     */
    func testAStaleNoticeCannotDrawAnOutageOverALiveConnection() {
        let live = ConnectionState(phase: .online, detail: "Connected.", retryAt: nil, attempts: 0)
        XCTAssertNil(CopilotOnServer.wireLine(live, showing: true))

        var doubted = live
        doubted.verified = false
        XCTAssertEqual(CopilotOnServer.wireLine(doubted, showing: true), "Connected.",
                       "an unverified channel is not a connected one")
    }

    /**
     * **A refusal blames what is actually wrong.**
     *
     * `HostLink.createSession` has its own guard and its own sentence — *"cannot
     * start sessions from the phone"* — which is true of a guest and wrong for
     * the case that reaches this screen, because these rows are only drawn for a
     * machine that has already said it can. What can still refuse is a machine
     * that has gone away, and `ConnectionState.detail` is *"always present,
     * always true"* by its own contract, so it explains itself.
     */
    func testARefusalNamesTheOutageRatherThanBlamingThePhone() {
        let gone = ConnectionState(phase: .offline,
                                   detail: "Not connected.",
                                   retryAt: nil,
                                   attempts: 3)
        XCTAssertEqual(CopilotOnServer.refusal(gone, noun: "server"), "Not connected.")

        let live = ConnectionState(phase: .online, detail: "Connected.", retryAt: nil, attempts: 0)
        XCTAssertEqual(CopilotOnServer.refusal(live, noun: "server"),
                       "That server is not sharing a folder with this phone any more.",
                       "the socket is up, so the folders were taken back under the finger")
    }

    // MARK: - Landing

    /**
     * **The tab lands in the agent session that is already there.**
     *
     * > *"copilot page should be always landing in a copilot session according
     * > to the settings of the copilot — either in an existing session if there
     * > is any, or it should start a new."*
     *
     * > *"if there is already a previous session going on it will just continue
     * > from there."*
     *
     * `copilotSession` picks it, so the landing and the *Open* row on the
     * fallback screen are one call and cannot name two different sessions — the
     * failure a second copy of the rule produces is a row that opens one
     * conversation while the tab opens another.
     */
    func testTheTabLandsInTheAgentSessionThatIsAlreadyRunning() {
        let sessions = [Self.session(id: Self.first, provider: "shell", status: "idle"),
                        Self.session(id: Self.second, provider: "claude", status: "working")]

        XCTAssertEqual(Self.landing(sessions), .open(Self.second),
                       "a shell is not a copilot session; the agent beside it is")
        XCTAssertEqual(CopilotOnServer.copilotSession(in: sessions, folder: nil)?.id, Self.second,
                       "and the row that offers the way back in names the same one")
    }

    /**
     * **A machine nobody has set up starts one anyway, in the machine's own
     * folder.**
     *
     * The assertion that was the exact opposite one round ago, and the reason is
     * worth keeping both halves of. It read *a machine nobody has set up never
     * starts anything*, guarding a real danger: a session on a server runs a real
     * agent spending real money, and the Copilot pill is drawn **unconditionally**
     * on a headless host, so the tab is one mis-tap away at all times.
     *
     * He struck it, three times, and the last time named the screen it produced:
     *
     * > *"the copilot page will directly land into some session — not to a
     * > selection and something on the page. It is still not that way… if not
     * > then it should create itself and start from the beginning. I told the
     * > exact same also before."*
     *
     * What makes it safe is not the gate that went but the two things beside it.
     * `nil` is *the machine's own folder* — the same thing a plain `create`
     * resolves to — and `CopilotOnServerView.adopt()` writes down the `cwd` it
     * comes back with the instant the tab lands, so the folder is on the control
     * screen with a picker beside it rather than guessed and silently kept. That
     * was the actual objection; this answers it rather than overriding it.
     */
    func testAMachineNobodyHasSetUpStartsOneInItsOwnFolder() {
        XCTAssertEqual(Self.landing([]), .start(folder: nil),
                       "the tab must never present a question before it works")
        XCTAssertEqual(Self.landing([Self.session(provider: "shell", status: "idle")]),
                       .start(folder: nil),
                       "a machine running only shells has no copilot session to land in")
    }

    /**
     * **The one refusal that survives, and it is the machine's rather than this
     * app's.**
     *
     * A grant list that is **present and empty** is a person having chosen to
     * share nothing with this device, and `create` with no folder is refused in
     * that state every time — `CopilotOnServer.start` and `SessionListView`'s
     * empty state both already keep this rule. Starting anyway would be one
     * refusal per visit forever, so this is the single case where the screen
     * still draws a row, and it draws the *one* row that can work rather than a
     * choice between two.
     *
     * Note which way round the two assertions go: the refusal is keyed on what
     * the **machine** will accept, not on whether this app has been told
     * anything. That is the line between a question and a consequence.
     */
    func testAMachineThatWillRefuseAPlainStartIsNotStartedAnyway() {
        XCTAssertEqual(Self.landing([], plainStartTaken: false), .stay,
                       "every folderless create from a phone shared nothing is refused")
        XCTAssertEqual(Self.landing([], setup: Self.setUp, plainStartTaken: false),
                       .start(folder: "/srv/app"),
                       "but a folder that was chosen is startable in, which is why the "
                       + "one surviving row is the picker")

        // And the rule the row is drawn from is the same one, read the same way.
        let sharedNothing = CopilotOnServer.start(offer: CopilotOnServer.Offer(start: true,
                                                                               pickFolders: true),
                                                  granted: [])
        XCTAssertFalse(sharedNothing.now)
        XCTAssertTrue(sharedNothing.inAFolder)
    }

    /**
     * **Quietening the tab is respected, and it is respected because it is
     * written down.**
     *
     * The switch on the control screen, which is now the off-ramp rather than the
     * on-ramp: an absent record reads as armed, so *off* is the departure from
     * the default and an unwritten one would be undone by the next visit. That
     * would be a switch that springs back, on the one control whose whole job is
     * to stop the tab spending money.
     *
     * A folder is kept through it, so switching back on does not have to
     * rediscover one.
     */
    func testQuieteningTheTabIsRespected() {
        XCTAssertEqual(Self.landing([], setup: CopilotSetupBook.Setup(folder: "/srv/app",
                                                                     startOnOpen: false)),
                       .stay)
        XCTAssertEqual(Self.landing([], setup: CopilotSetupBook.Setup(folder: nil,
                                                                     startOnOpen: false)),
                       .stay,
                       "and with no folder either — off is off, not undecided")
        XCTAssertEqual(Self.landing([], setup: Self.setUp, canStart: false), .stay,
                       "a phone that has been shared nothing has every create refused")
    }

    /**
     * **One start per visit, so a refusal is a sentence rather than a loop.**
     *
     * `land()` runs on every change of a key that includes the session list and
     * the connection. Without the latch a start that produced nothing — a folder
     * taken back at the machine, a `create` that is never answered — would be
     * re-sent on the next redraw, and again, for as long as somebody stood on
     * the screen. What they get instead is `startNeverLanded`, which says
     * plainly that nothing else will be sent, and a row to press.
     */
    func testAFailedStartIsNotRetriedByItself() {
        XCTAssertEqual(Self.landing([], setup: Self.setUp), .start(folder: "/srv/app"))
        XCTAssertEqual(Self.landing([], setup: Self.setUp, attempted: true), .stay,
                       "the second frame must not send a second create")
        XCTAssertTrue(CopilotOnServer.startNeverLanded(noun: "server")
            .contains("Nothing else will be sent"),
                      "and the person is told that, rather than watching a spinner forever")
    }

    /**
     * **Once a folder is chosen, only a session in it is the copilot.**
     *
     * > *"Whatever we set in the settings, that copilot will be always on this
     * > folder."*
     *
     * The failure this prevents is quiet and would be very confusing: an agent
     * running on the same machine for a different project would be landed in
     * under the copilot's name, and — worse — the copilot that was actually
     * asked for would never start, because one would appear to be running
     * already.
     *
     * A trailing separator is the same folder. `/srv/app/` is what a walk that
     * ends at a directory can leave behind, and two records that never match the
     * same `cwd` would mean a machine that starts a fresh session every visit.
     */
    func testOnlyASessionInTheChosenFolderCountsAsTheCopilot() {
        let elsewhere = [Self.session(id: Self.second, provider: "claude",
                                      status: "working", cwd: "/srv/other")]

        XCTAssertNil(CopilotOnServer.copilotSession(in: elsewhere, folder: "/srv/app"),
                     "somebody else's project is not this machine's copilot")
        XCTAssertEqual(Self.landing(elsewhere, setup: Self.setUp), .start(folder: "/srv/app"),
                       "so the copilot is started rather than mistaken for the one running")

        let here = [Self.session(id: Self.second, provider: "claude",
                                 status: "working", cwd: "/srv/app/")]
        XCTAssertEqual(CopilotOnServer.copilotSession(in: here, folder: "/srv/app")?.id, Self.second,
                       "a trailing separator is not a different folder")
    }

    /**
     * **A conversation that is already running is never started over.**
     *
     * This case has outlived two of its own explanations, and the current one is
     * the shortest. It began as *the landing is a one-shot, or popping back out
     * re-pushes it*. Then it was *Back must not be undone*, which was a real
     * defect he recorded — *"I keep going back and it is keep taking me inside
     * the chat box"* — fixed with a clock that told a path SwiftUI had discarded
     * from a person leaving a screen.
     *
     * Both are gone with the navigation they were about. **The tab draws the
     * conversation as its own content**, so there is nothing to push, nothing to
     * re-push, no latch to hold shut and no moment to time. Four cases pinning
     * that clock were deleted here rather than left passing, because a test that
     * still passes over a rule nothing consults is a claim that the rule is
     * load-bearing.
     *
     * What survives is the half that was always about the machine rather than
     * about the stack, and it is the expensive half: a copilot session that is
     * running must never produce a second one. `.open` is now a statement —
     * *this is the copilot* — which `tabSession` turns into the screen somebody
     * is looking at.
     *
     * The second assertion is the sharper one, and it is what `attempted` still
     * guards: a machine whose copilot session has just **exited** falls back to
     * the screen that starts one, and without that latch every redraw would put
     * another `create` on the wire.
     */
    func testARunningConversationIsNamedRatherThanStartedOver() {
        let sessions = [Self.session(provider: "claude", status: "working")]

        XCTAssertEqual(Self.landing(sessions), .open(Self.first),
                       "a running copilot session is what the tab shows, not a reason to start one")
        XCTAssertEqual(Self.landing([], setup: Self.setUp, attempted: true), .stay,
                       "and one start per visit, so a session that exited is not started twice")
    }

    /**
     * **Nothing is pushed, and nothing is started, over a dead socket.**
     *
     * A pushed terminal cannot attach, and `TerminalScreen` will not raise the
     * chat without a live connection either — `showsModeButton` hides the way
     * back to the terminal there, so a forced chat would be a mode with no way
     * out of it. The graced connection line says what is happening instead.
     *
     * The second assertion is the one that makes this a delay rather than a
     * refusal: the same call answers `.open` the moment the wire is back, which
     * is why `land()` watches the connection as well as the session list. The
     * third is what stops a `create` being spent into a socket that will refuse
     * it — and, worse, burning this visit's single attempt on it.
     */
    func testTheLandingWaitsForTheWireRatherThanPushingIntoADeadTerminal() {
        let sessions = [Self.session(provider: "claude", status: "working")]
        let gone = ConnectionState(phase: .waiting,
                                   detail: "Reconnecting to that server.",
                                   retryAt: nil,
                                   attempts: 1)

        XCTAssertEqual(Self.landing(sessions, connection: gone), .stay)
        XCTAssertEqual(Self.landing(sessions), .open(Self.first),
                       "an outage delays the destination; it does not replace it")
        XCTAssertEqual(Self.landing([], connection: gone, setup: Self.setUp), .stay,
                       "and a create into a dead socket would spend this visit's one attempt")
    }

    /**
     * **An unverified channel is not landed into either.**
     *
     * `.online` with `verified == false` is *"Checking"* — a socket this side has
     * cause to doubt, held after a suspension a carrier NAT may already have
     * reclaimed. `ConnectionState.verified` argues at length why that is its own
     * state, and every other screen treats it as unsettled.
     *
     * Here it is `isLive` and therefore landed into, which is deliberate and
     * worth pinning rather than leaving to be discovered: `isLive` is the same
     * question `attach` and `input` are gated on, so a session that can be
     * attached can be opened. The doubt belongs on the wire line above, which
     * `wireLine` draws for exactly this state.
     */
    func testAnUnverifiedChannelStillLandsBecauseItCanStillAttach() {
        var doubted = Self.live
        doubted.verified = false
        let sessions = [Self.session(provider: "claude", status: "working")]

        XCTAssertEqual(Self.landing(sessions, connection: doubted), .open(Self.first))
        XCTAssertEqual(CopilotOnServer.wireLine(doubted, showing: true), "Connected.",
                       "the doubt is said on the line above rather than by refusing to land")
    }

    /// `landing` with the four arguments most cases do not care about defaulted,
    /// so each case above says only what it is about. Written here rather than
    /// given default values on `CopilotOnServer.landing` itself: every one of
    /// them is a decision the screen must make deliberately, and a default on
    /// the real function is how `attempted` comes to be forgotten at a call site
    /// and the loop guard quietly stops existing.
    private static func landing(_ sessions: [RemoteSession],
                                connection: ConnectionState = live,
                                setup: CopilotSetupBook.Setup? = nil,
                                attempted: Bool = false,
                                canStart: Bool = true,
                                plainStartTaken: Bool = true) -> CopilotOnServer.Landing {
        CopilotOnServer.landing(in: sessions,
                                connection: connection,
                                setup: setup,
                                attempted: attempted,
                                canStart: canStart,
                                plainStartTaken: plainStartTaken)
    }

    // MARK: - About the copilot

    /**
     * The controls are reached from **one** place, and it is not this tab.
     *
     * > *"Let's move settings option for copilot to main settings page instead
     * > of inside the copilot page, so we can have three dots in left along with
     * > chat vs terminal switch."*
     *
     * Two cases used to live here, walking every screen the tab can show and
     * asserting each applied the gear. They are gone with the gear: there are no
     * perches to walk, and a modifier applied nowhere cannot drift between
     * files. What replaces them is the smaller claim that still matters — the
     * row on the Menu page and anything pressing it name the same string.
     */
    func testTheControlsAreOneRowOnTheSettingsPage() {
        XCTAssertEqual(CopilotControl.settingsRow, "settings.copilot")
    }

    // MARK: - The controls, per machine

    /**
     * **A server's control screen and a desktop's have almost nothing in
     * common.**
     *
     * Which is the point: a desktop has a copilot with a grant, a run and an
     * action log, and a server has none of the three — its copilot is an agent
     * session, so what can be controlled about it is a session's shape. Every
     * section drawn on the wrong kind would be rows that refuse on every press,
     * which is the exact defect this whole screen was rewritten to stop being.
     *
     * The two they share are the honest overlap: the device roster is a machine
     * fact of either kind, and the reference page describes the product.
     */
    func testAServerAndADesktopGetDifferentControls() {
        let server = CopilotControl.panels(Self.serverControls)
        let desktop = CopilotControl.panels(Self.desktopControls)

        XCTAssertEqual(server, [.whenYouOpen, .agent, .session, .devices, .about])
        XCTAssertEqual(desktop, [.whenYouOpen, .permissions, .run, .history, .devices, .about])

        XCTAssertFalse(server.contains(.permissions),
                       "a server has no copilot grant to show; it has no copilot")
        XCTAssertFalse(desktop.contains(.agent),
                       "agents.defaultProvider decides what a session runs, not what the "
                       + "desktop's own copilot is")
    }

    /**
     * **Nothing is drawn that this phone may not use.**
     *
     * The action log and the session list are both `read` tier — `COPILOT_TIERS`
     * puts `copilot.log` and `copilot.sessions` there — so on a phone that may
     * not watch they would be two rows opening two empty sheets. That is exactly
     * what the overflow menu this screen replaced used to do, and it was caught
     * by looking at the screen rather than by a test; this is that test.
     *
     * The setup switch goes for the neighbouring reason: it arms
     * `copilot.start`, which `CopilotLink.start` refuses without `act`, and
     * arming something that can never fire is a control that cannot act with an
     * extra step in front of it.
     */
    func testAPhoneThatMayNotWatchIsOfferedNoListsAndNoSwitch() {
        let watching = CopilotControl.panels(CopilotControl.Reading(
            kind: .desktop, access: .watch, grant: CopilotGrant(read: true, act: false, alter: false)))
        XCTAssertTrue(watching.contains(.history), "the log and the sessions are read tier")
        XCTAssertFalse(watching.contains(.whenYouOpen),
                       "a phone that may not ask it to work must not arm a start")

        let nothing = CopilotControl.panels(CopilotControl.Reading(kind: .desktop, access: .notGranted))
        XCTAssertFalse(nothing.contains(.history))
        XCTAssertFalse(nothing.contains(.run))
        XCTAssertTrue(nothing.contains(.permissions),
                      "the grant is exactly what somebody in this state came to look at")
    }

    /**
     * **A section with nothing in it is not drawn.**
     *
     * An empty card under a caption is furniture describing nothing. Two of them
     * are conditional on the machine having said something rather than on its
     * kind: the agent chooser needs `settings`, which is withheld from a guest at
     * the source, and the roster needs `devices`, which is withheld from a guest
     * for the same reason. The conversation section needs a conversation.
     */
    func testASectionWithNothingInItIsNotDrawn() {
        let bare = CopilotControl.panels(CopilotControl.Reading(kind: .headless, access: .notOffered))

        XCTAssertEqual(bare, [.whenYouOpen, .about],
                       "a server that has advertised nothing gets the setup and the reference")
    }

    /**
     * **The reference page is last, and it is not the screen.**
     *
     * The whole of the correction, as an assertion. A previous lane made the
     * top-right button open the prose, and he said plainly that is not what he
     * asked for. The writing survives — it is checked against the desktop's own
     * source and none of it was rewritten — but it is one row at the foot, and
     * nothing about the copilot's state or setup is behind it.
     */
    func testTheProseIsTheLastRowAndNeverTheFirst() {
        for reading in [Self.serverControls, Self.desktopControls] {
            let panels = CopilotControl.panels(reading)
            XCTAssertEqual(panels.last, .about)
            XCTAssertNotEqual(panels.first, .about)
        }
    }

    /**
     * **A server's version and a desktop's version answer different questions.**
     *
     * Four passages are about the product and are the same wherever they are
     * read. Two are only answerable once you know which kind of machine this
     * phone is pointed at, and getting those two wrong is the whole failure this
     * screen could have: a paragraph explaining *why there is no copilot here*
     * shown over a machine that has one, or a paragraph about *what this phone
     * may do with the copilot* on a server where there is nothing to do it to.
     *
     * Both are silent — a wrong paragraph looks exactly like a right one — which
     * is why the split is a function returning values rather than an `if` inside
     * a `body`.
     */
    func testTheServerAndDesktopVersionsAnswerDifferentQuestions() {
        let server = AboutCopilot.passages(Self.onAServer).map(\.id)
        let desktop = AboutCopilot.passages(Self.onADesktop).map(\.id)

        XCTAssertEqual(server, ["what", "reach", "tiers", "why", "instead", "yours"])
        XCTAssertEqual(desktop, ["what", "reach", "tiers", "where", "phone", "yours"])

        XCTAssertFalse(desktop.contains("why"),
                       "a desktop has a copilot; explaining why it has none would be flatly wrong")
        XCTAssertFalse(server.contains("phone"),
                       "there is no copilot on a server for a phone to have a grant to")
    }

    /**
     * **What a copilot *is* does not change with the machine it is not on.**
     *
     * The three passages about the product — what it is, what it may do without
     * asking, who it is shared with — are one value each rather than two strings
     * that happen to agree today. The failure a second copy produces is a person
     * who reads this screen on their desktop and again on their server and finds
     * the tiers described two ways, which reads as two different features.
     */
    func testTheProductIsDescribedInTheSameWordsOnBothKindsOfMachine() {
        let server = Dictionary(uniqueKeysWithValues: AboutCopilot.passages(Self.onAServer)
            .map { ($0.id, $0.body) })
        let desktop = Dictionary(uniqueKeysWithValues: AboutCopilot.passages(Self.onADesktop)
            .map { ($0.id, $0.body) })

        for shared in ["what", "tiers", "yours", "reach"] {
            XCTAssertEqual(server[shared], desktop[shared],
                           "\(shared) is a fact about the product, not about this machine")
            XCTAssertFalse(server[shared]?.isEmpty ?? true)
        }
    }

    /**
     * **The tool catalogue is not copied into this app, on either kind of
     * machine.**
     *
     * There are thirty-four tool ids across `src/main/deck-control/`, fifteen of
     * them now held behind `describe-tool.ts` because four lanes in one night
     * took the assembled list to 33 tools and 10,670 estimated tokens — over
     * both of that file's own ceilings. A list moving at that speed, in a lane
     * that is not this one, would be wrong in Swift within a release.
     *
     * And it would be wrong in the most convincing way available: printed as a
     * flat fact, on the one screen in the app whose entire purpose is to be
     * believed. So the tools are described by **what they reach** — a property
     * of the app rather than of the table — and no id is spelled anywhere.
     *
     * Asserted against ids from every family, including the five this screen's
     * brief named from memory. That list was itself wrong, which is the point:
     * `sessions_list`, `sessions_transcript`, `sessions_start`, `sessions_stop`
     * and `git_status` are five of thirty-four, and a screen built on a
     * remembered catalogue would have shipped that as the whole of it.
     */
    func testTheToolCatalogueIsNeverCopiedIntoThisApp() {
        let ids = ["sessions.list", "sessions.get", "sessions.transcript", "sessions.start",
                   "sessions.send", "sessions.stop", "sessions.result", "projects.list",
                   "git.status", "git.diff", "alerts.list", "settings.read", "settings.write",
                   "log.note", "browser.open", "app.where", "tour.play"]

        for reading in [Self.onAServer, Self.onADesktop, Self.onADesktopWithACatalogue] {
            let screen = AboutCopilot.passages(reading).map(\.body).joined(separator: "\n")
            for id in ids {
                XCTAssertFalse(screen.contains(id),
                               "\(id) would be a second copy of a table this app does not own")
            }
        }
    }

    /**
     * **The only number on the screen is the machine's own.**
     *
     * `CopilotState.tools` and `turnTokens` are on the wire because the desktop
     * decided they should be — *"this is the one screen where the size of the
     * thing being spoken to is worth knowing before speaking to it"* — so the
     * count here is a reading rather than a claim, and it cannot go stale
     * against a catalogue that moved.
     *
     * The nil half is the half that matters. A desktop that has not sent its
     * state yet, and every server, get a paragraph with **no digits in it at
     * all** rather than a zero or a remembered number: this app does not know,
     * and a screen that guessed would be inventing the one figure on it a person
     * has no way to check.
     */
    func testTheToolCountIsTheMachinesOwnNumberOrIsNotThere() {
        let told = AboutCopilot.whatItReaches(Self.onADesktopWithACatalogue).body
        XCTAssertTrue(told.contains("20 tools"))
        XCTAssertTrue(told.contains("7900"), "the machine's per-turn figure, not an estimate")

        for silent in [Self.onADesktop, Self.onAServer] {
            let body = AboutCopilot.whatItReaches(silent).body
            XCTAssertNil(body.rangeOfCharacter(from: .decimalDigits),
                         "a machine that has not said carries no figure at all")
        }

        XCTAssertNil(AboutCopilot.catalogueSentence(Self.onAServer),
                     "a server has no copilot to have a catalogue")
    }

    /**
     * **A copilot with no tool surface is silence here and a figure elsewhere.**
     *
     * Zero tools is a real state — the tool endpoint down, which
     * `CopilotRuns.state` reports as `available: false` — and `CopilotView`
     * prints it beside the Start button on purpose, because there it is a
     * diagnosis somebody needs while deciding whether to press.
     *
     * In the middle of a paragraph explaining what the tools are, the same zero
     * reads as a claim that there are none, which is a different and wrong
     * sentence. So this screen goes quiet and the screen with the button on it
     * does not, and that disagreement is deliberate rather than a copy that
     * drifted.
     */
    func testACopilotWithNoToolsIsSilenceOnAReadingScreen() {
        let none = AboutCopilot.Reading(kind: .desktop, platform: .mac, access: .direct,
                                        tools: 0, turnTokens: 0)
        XCTAssertNil(AboutCopilot.catalogueSentence(none))

        let unpriced = AboutCopilot.Reading(kind: .desktop, platform: .mac, access: .direct,
                                            tools: 1, turnTokens: 0)
        XCTAssertEqual(AboutCopilot.catalogueSentence(unpriced), "That Mac's copilot carries 1 tool.",
                       "one tool is singular, and a cost the machine did not send is not invented")
    }

    /**
     * **Every access state has its own sentence, including the ones nobody
     * expects to see.**
     *
     * `CopilotAccess` is `CaseIterable` because *"a state added later and not
     * thought about is a fourth pill appearing or not appearing for it by
     * accident"*. The same hazard lands here as a paragraph that silently
     * describes the wrong state — and this screen is where somebody goes
     * *because* they do not understand what they are looking at, so it is the
     * worst place in the app to be told about a different one.
     *
     * `.notGranted` and `.connecting` are the cases worth walking rather than
     * assuming: neither is something a person can now cause, and both are
     * reachable — one from a machine saying something this build does not
     * expect, one from every phone that has just come out of a tunnel.
     */
    func testEveryAccessStateHasItsOwnSentenceAboutThisPhone() {
        var said: Set<String> = []
        for access in CopilotAccess.allCases {
            let reading = AboutCopilot.Reading(kind: .desktop, platform: .mac, access: access)
            let body = AboutCopilot.whatThisPhoneMayDo(reading).body
            XCTAssertFalse(body.isEmpty, "\(access) has no sentence")
            XCTAssertTrue(said.insert(body).inserted,
                          "\(access) is described in words already used for another state")
        }
    }

    /**
     * **Answering a confirmation is `alter` alone, exactly as the desktop spells
     * it.**
     *
     * `CopilotGrant.canAnswer` is the one place this client does **not** add
     * `read` to the test, *"because the desktop does not"* — `COPILOT_FRAME_TIER`
     * is written that way and writing it differently here would be this end
     * inventing a rule the far end has not got.
     *
     * It shows on this screen as two different sentences under one access state,
     * and it is worth pinning because the wrong one is a promise about where a
     * two-minute question will appear. Told it is answered on the phone, a person
     * puts the phone down; the question expires into a **refusal** at the machine
     * they walked away from.
     */
    func testWhereAConfirmationIsAnsweredFollowsTheGrantAndNotTheAccess() {
        let here = AboutCopilot.Reading(kind: .desktop, platform: .mac, access: .direct,
                                        grant: CopilotGrant(read: true, act: true, alter: true))
        let there = AboutCopilot.Reading(kind: .desktop, platform: .mac, access: .direct,
                                         grant: CopilotGrant(read: true, act: true, alter: false))

        XCTAssertTrue(AboutCopilot.whatThisPhoneMayDo(here).body.contains("on this phone"))
        XCTAssertTrue(AboutCopilot.whatThisPhoneMayDo(there).body.contains("at the machine"))
    }

    /**
     * **A machine too old to have said what it is gets the desktop's version.**
     *
     * `HostKind.unknown` is every host released before the field existed, and
     * `HostKind.noun` reads *"machine"* for it deliberately — *"true of both and
     * singles out neither"*. The screen still has to pick one of two versions,
     * and the two wrong answers are not the same size.
     *
     * The desktop's version describes a copilot that exists and then says
     * plainly what this phone may do with it, which is correct for an old
     * desktop and merely unhelpful over an old server. The server's version
     * **opens by explaining why there is none**, which over a machine that has
     * one is not unhelpful, it is false. So the fallback is the desktop's, and
     * the noun stays neutral inside it.
     */
    func testAHostTooOldToSayWhatItIsGetsTheDesktopsVersion() {
        let old = AboutCopilot.Reading(kind: .unknown, platform: .unknown, access: .notOffered)

        XCTAssertFalse(old.isServer)
        XCTAssertEqual(AboutCopilot.passages(old).map(\.id),
                       ["what", "reach", "tiers", "where", "phone", "yours"])
        XCTAssertEqual(old.noun, "desktop",
                       "the neutral noun for a host that never said, not a guessed Mac")
    }

    /**
     * **A server is called a server, and a Mac is called a Mac.**
     *
     * Two different nouns for two different questions, and taking either from
     * the other reads wrong immediately. `HostKind.noun` is what the rest of this
     * tab calls a headless host and it can only ever say *desktop* for the other
     * kind; `HostPlatform.noun` is what he calls the box — *"Running on the
     * Mac"* — and it has no word for a server at all.
     *
     * It landed as a real defect once, in the sentence this file's neighbour
     * quotes: a phone paired to a Windows PC read *"Running on the Mac"* while
     * looking at that PC's own dev servers.
     */
    func testTheScreenNamesTheMachineTheWayTheRestOfTheAppDoes() {
        XCTAssertEqual(Self.onAServer.noun, "server")
        XCTAssertEqual(Self.onADesktop.noun, "Mac")
        XCTAssertEqual(AboutCopilot.Reading(kind: .desktop, platform: .windows,
                                            access: .direct).noun, "PC")

        XCTAssertTrue(AboutCopilot.whatThisServerHasInstead(Self.onAServer).caption
            .contains("server"))
    }

    // MARK: - Where the setup is kept

    /**
     * **A copilot folder is a fact about one machine, and is keyed as one.**
     *
     * His server's copilot folder is not his Mac's, and a path that exists on one
     * of them very often does not exist on the other — `create` against a `cwd`
     * that cannot be stat'd is a session that will not spawn. So this is keyed on
     * the host id, the same stable string `PortBook` keys its port names by and
     * the same one `DeckEndpoint.hostId` hands out, which is also why a machine
     * re-paired after a revoke keeps its setup.
     */
    func testTheSetupIsKeptPerMachine() {
        let book = scratchBook()
        book.setFolder("/srv/app", host: "server-a")
        book.setFolder("/Users/asad/ClaudeAsad", host: "mac-b")

        XCTAssertEqual(book.folder(host: "server-a"), "/srv/app")
        XCTAssertEqual(book.folder(host: "mac-b"), "/Users/asad/ClaudeAsad")
        XCTAssertNil(book.folder(host: "never-seen"))
        XCTAssertFalse(book.isSetUp(host: "never-seen"),
                       "and a machine nobody has set up is the state that starts nothing")
    }

    /**
     * **Choosing a folder is the setup, and it is the act that arms the tab.**
     *
     * > *"We will first of all do the setup of a copilot just like we do on
     * > desktop application, and then it will be always opening in the same
     * > folder."*
     *
     * So there is no second control to arm it afterwards — that would be the same
     * question asked twice. Changing the folder later does **not** re-arm a tab
     * somebody has deliberately quietened, which is the asymmetry worth pinning:
     * one of the two directions is a convenience and the other would be the app
     * overruling a decision.
     */
    func testChoosingAFolderArmsTheTabAndChangingItDoesNotReArmIt() {
        let book = scratchBook()
        book.setFolder("/srv/app", host: "h")
        XCTAssertTrue(book.isArmed(host: "h"))

        book.setStartOnOpen(false, host: "h")
        book.setFolder("/srv/other", host: "h")
        XCTAssertEqual(book.folder(host: "h"), "/srv/other")
        XCTAssertEqual(book.setup(host: "h")?.startOnOpen, false,
                       "moving the folder must not switch the tab back on behind somebody")
    }

    /**
     * **A desktop's record has no folder, and that is not "unset".**
     *
     * There is nothing for this phone to choose on a desktop: the copilot's
     * folder is `copilot.home`, stored on that machine and deliberately refused
     * by `settings.write` — `copilot-folder.ts` puts it under the `copilot.`
     * prefix so `PROTECTED_SETTING_PREFIXES` catches it, because *"an agent that
     * can point itself at a folder is an agent that can choose its own
     * instructions"* — and the remote wire's `SERVER_SETTINGS` is a two-key
     * allowlist that does not include it either.
     *
     * So the switch alone constitutes a setup there, and `forget` is the only
     * thing that takes it away. *Nothing decided* and *everything undecided* must
     * be the same state rather than two that read alike, which is why forgetting
     * removes the key rather than writing an empty record.
     */
    func testADesktopHasNoFolderToChooseAndIsQuietenedBySwitchAlone() {
        let book = scratchBook()
        XCTAssertTrue(book.isArmed(host: "mac"),
                      "a desktop with no record starts a run when the tab is opened")
        XCTAssertNil(book.folder(host: "mac"), "a desktop's folder never travels")

        book.setStartOnOpen(false, host: "mac")
        XCTAssertFalse(book.isArmed(host: "mac"))

        book.forget(host: "mac")
        XCTAssertFalse(book.isSetUp(host: "mac"))
        XCTAssertNil(book.setup(host: "mac"))
    }

    /**
     * **Off is a written state, because on is the default.**
     *
     * This assertion is the reverse of the one it replaces, and the reverse for a
     * reason rather than a change of taste. While *off* was the state a machine
     * began in, writing it would have made *quietened* and *never opened*
     * indistinguishable — and the second of those was what guarded the mis-tap,
     * so `false` on an absent record was correctly a no-op.
     *
     * `isArmed` now reads an absent record as **yes**, so an unwritten off would
     * be undone by the next visit: a switch that springs back, on the one control
     * whose whole job is to stop the tab spending money on a machine.
     */
    func testQuieteningAMachineThatWasNeverSetUpIsWrittenDown() {
        let store = scratchSuite()
        let book = CopilotSetupBook(defaults: store)
        XCTAssertTrue(book.isArmed(host: "h"), "an absent record means yes")

        book.setStartOnOpen(false, host: "h")
        XCTAssertFalse(book.isArmed(host: "h"))
        XCTAssertTrue(book.isSetUp(host: "h"), "the decision has to survive being made")

        // And it survives a fresh reader over the same store, which is the only
        // thing "written down" actually means to somebody re-opening the app.
        XCTAssertFalse(CopilotSetupBook(defaults: store).isArmed(host: "h"))
    }

    /**
     * **A book written by the build before this one still opens.**
     *
     * The failure this is written against is silent and total. `load()` decodes
     * the whole book in a single `try?`, so one record that will not decode is
     * not one machine lost — it is every machine's folder and switch gone at
     * once, on the launch after an update, with no error anywhere. Swift's
     * synthesised `Decodable` calls `decode` rather than `decodeIfPresent` for a
     * non-optional property and does **not** consult its default value, so adding
     * a field without a hand-written initialiser would do exactly that.
     *
     * The literal below is the shape actually on disk in the simulator this lane
     * tests against, copied rather than invented.
     */
    func testARecordWrittenBeforeAFieldExistedStillLoads() throws {
        let store = scratchSuite()
        let old = #"{"KZ2J9AWGK8BWGQUEZDYKW5RS22":{"folder":"\/home\/asad","startOnOpen":true}}"#
        store.set(Data(old.utf8), forKey: "terminaldeck.copilotSetup.v1")

        let book = CopilotSetupBook(defaults: store)
        XCTAssertEqual(book.folder(host: "KZ2J9AWGK8BWGQUEZDYKW5RS22"), "/home/asad",
                       "the folder somebody chose must survive the update that added a field")
        XCTAssertTrue(book.isArmed(host: "KZ2J9AWGK8BWGQUEZDYKW5RS22"))
    }

    /**
     * **Forgetting a machine puts it back to working the folder out again.**
     *
     * Not *"ask me again"* — nothing asks — but a real thing to want: a copilot
     * pinned to a folder that has since been deleted or renamed would start there
     * and fail every visit, and one press hands the decision back to the
     * machine's own default. The switch goes with it, because a Forget that left
     * a machine quietened would leave a decision behind under a word that
     * promises none.
     */
    func testForgettingAMachinePutsItBackToDiscoveringItsFolder() {
        let book = scratchBook()
        book.setFolder("/srv/app", host: "h")
        book.setStartOnOpen(false, host: "h")

        book.forget(host: "h")
        XCTAssertNil(book.folder(host: "h"))
        XCTAssertFalse(book.isSetUp(host: "h"))
        XCTAssertTrue(book.isArmed(host: "h"), "a forgotten machine is an armed one")
    }

    /**
     * **The folder is discovered by first use: start, land, write it down.**
     *
     * The whole correction as one sequence, walked in the order the screen walks
     * it, because the property that matters is not any single answer but that the
     * three fit together — a tab that started without asking and *did not* record
     * where would be the folder guessed and silently kept, which is the thing the
     * gate existed to prevent.
     *
     * Note the fourth step. Once the folder is written, `copilotSession` matches
     * only sessions in it, so the tab is pinned: a second agent started elsewhere
     * on the same machine cannot become the copilot by being listed first.
     */
    func testTheFolderIsDiscoveredByFirstUseAndThenPinned() {
        let book = scratchBook()

        // 1. Nothing known. It starts, letting the machine choose.
        XCTAssertEqual(Self.landing([], setup: book.setup(host: "h")), .start(folder: nil))

        // 2. The machine made one, somewhere this end had never been told about.
        let made = [Self.session(provider: "claude", status: "working", cwd: "/root/projects/api")]
        XCTAssertEqual(Self.landing(made, setup: book.setup(host: "h")), .open(Self.first))

        // 3. The screen writes down where it actually landed. See `adopt()`.
        book.setFolder(made[0].cwd, host: "h")
        XCTAssertEqual(book.folder(host: "h"), "/root/projects/api")

        // 4. From here the ordinary rules apply, and they are pinned to it.
        let elsewhere = [Self.session(id: Self.second, provider: "claude",
                                      status: "working", cwd: "/root/other")]
        XCTAssertEqual(Self.landing(elsewhere, setup: book.setup(host: "h")),
                       .start(folder: "/root/projects/api"),
                       "somebody else's agent cannot become this machine's copilot")
        XCTAssertEqual(Self.landing(made, setup: book.setup(host: "h")), .open(Self.first))
    }

    /**
     * **What the screen says while it is starting, and it does not name a folder
     * it has not been told.**
     *
     * On a first visit there is genuinely no answer to *where* yet — that is the
     * point of the round — and inventing one for the two seconds before the
     * session reports its `cwd` would be a sentence that is wrong and then
     * quietly becomes right, which is worse than a shorter true one.
     */
    func testTheStartingLineOnlyNamesAFolderItWasGiven() {
        XCTAssertEqual(CopilotOnServer.startingLine(folder: nil), "Starting a session\u{2026}")
        XCTAssertEqual(CopilotOnServer.startingLine(folder: ""), "Starting a session\u{2026}")
        XCTAssertEqual(CopilotOnServer.startingLine(folder: "/root/projects/api"),
                       "Starting it in api\u{2026}")
    }

    /**
     * **A path that cannot be used is not stored.**
     *
     * A relative path resolves against whatever the far process's cwd happens to
     * be, which is not a folder anybody chose — and the failure would be silent
     * and intermittent, because it depends on where that machine's host was
     * started from. The picker only ever produces absolute paths, so a relative
     * one came from an older build or a hand-edited simulator store; either way
     * the honest answer is to have no folder rather than a wrong one.
     *
     * Control characters go because a path is drawn on a row, and a newline in
     * one pushes a card to three lines and shoves what is under it off screen.
     */
    func testAPathThatCannotBeUsedIsNotStored() {
        XCTAssertNil(CopilotSetupBook.cleanFolder("srv/app"), "relative paths do not resolve")
        XCTAssertNil(CopilotSetupBook.cleanFolder(""))
        XCTAssertNil(CopilotSetupBook.cleanFolder(nil))
        XCTAssertEqual(CopilotSetupBook.cleanFolder("  /srv/app  "), "/srv/app")
        XCTAssertEqual(CopilotSetupBook.cleanFolder("/srv/app/"), "/srv/app")
        XCTAssertEqual(CopilotSetupBook.cleanFolder("/"), "/", "the root is not a trailing slash")

        let book = scratchBook()
        book.setFolder("srv/app", host: "h")
        XCTAssertFalse(book.isSetUp(host: "h"),
                       "a folder that cannot be used does not constitute a setup either")
    }

    /**
     * **Two paths are the same folder, or they are not, and case is not the
     * difference.**
     *
     * The far end is Linux as often as it is macOS and `cwd` comes back from that
     * machine's own `spawn`, so lower-casing would call `/srv/API` and `/srv/api`
     * one folder on a filesystem where they are two — and the copilot would land
     * in whichever the machine happened to list first.
     */
    func testOnlyTheTrailingSeparatorIsCosmetic() {
        XCTAssertTrue(CopilotSetupBook.sameFolder("/srv/app", "/srv/app/"))
        XCTAssertFalse(CopilotSetupBook.sameFolder("/srv/API", "/srv/api"))
        XCTAssertFalse(CopilotSetupBook.sameFolder("/srv/app", nil))
        XCTAssertFalse(CopilotSetupBook.sameFolder(nil, nil))
    }

    /**
     * **The folder picker says what pressing it will do.**
     *
     * It said *Start in ClaudeAsad* at every call site, which was true of all of
     * them until the copilot's setup needed the answer without the session. A
     * button that promises a session and stores a preference is the small,
     * confident kind of lie this whole screen was rewritten to remove.
     */
    func testThePickerNamesTheActionItIsBeingUsedFor() {
        XCTAssertEqual(FolderPickerAction.start.label(folder: "app"), "Start in app")
        XCTAssertEqual(FolderPickerAction.choose.label(folder: "app"), "Use app")
        XCTAssertEqual(FolderPickerAction.start.label(folder: ""), "Start here")
        XCTAssertEqual(FolderPickerAction.choose.label(folder: ""), "Use this folder")
    }

    // MARK: - Doubles

    /// A headless host: the machine this file's screen is written for, and the
    /// one that never sends a copilot state because it has no copilot.
    private static let onAServer = AboutCopilot.Reading(kind: .headless,
                                                        platform: .linux,
                                                        access: .notOffered)

    /// One of his own Macs, connected, before the first state frame has landed.
    private static let onADesktop = AboutCopilot.Reading(
        kind: .desktop,
        platform: .mac,
        access: .direct,
        grant: CopilotGrant(read: true, act: true, alter: true)
    )

    /// The same Mac a moment later, having said what its catalogue costs it. The
    /// figures are the ceilings `catalogue.ts` holds itself to — 20 tools, and a
    /// turn's worth of tokens just under 8,000 — so a reader of this file sees
    /// the shape of a real reading rather than a round number.
    private static let onADesktopWithACatalogue = AboutCopilot.Reading(
        kind: .desktop,
        platform: .mac,
        access: .direct,
        grant: CopilotGrant(read: true, act: true, alter: true),
        tools: 20,
        turnTokens: 7900
    )

    /// A set-up server that has advertised everything a server advertises.
    private static let serverControls = CopilotControl.Reading(
        kind: .headless,
        access: .notOffered,
        setUp: true,
        canPickFolders: true,
        settingsOffered: true,
        devicesOffered: true,
        hasCopilotSession: true
    )

    /// One of his own Macs, with the copilot open and every tier granted.
    private static let desktopControls = CopilotControl.Reading(
        kind: .desktop,
        access: .direct,
        grant: CopilotGrant(read: true, act: true, alter: true),
        devicesOffered: true
    )

    private static let live = ConnectionState(phase: .online,
                                              detail: "Connected.",
                                              retryAt: nil,
                                              attempts: 0)

    private static let first = "01J8ZC4T9K5Q2V7XW3NHRF6MBD"
    private static let second = "01J8ZC4T9K5Q2V7XW3NHRF6MBE"

    private static func session(id: String = first,
                                provider: String,
                                status: String,
                                cwd: String = "/srv/app") -> RemoteSession {
        RemoteSession(id: id,
                      title: "app",
                      cwd: cwd,
                      provider: provider,
                      status: status,
                      exitCode: nil)
    }

    /// A machine that has been set up, pointed at the folder `session` uses by
    /// default. Written out rather than defaulted so that a test which cares
    /// about the folder says so in its own body.
    private static let setUp = CopilotSetupBook.Setup(folder: "/srv/app", startOnOpen: true)

    /// A suite nothing else can see, emptied first. Named after the case so two
    /// tests cannot write into one store.
    private func scratchSuite(_ name: String = #function) -> UserDefaults {
        let suite = "terminaldeck.tests.copilotSetup.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    /// A store nothing else can see. `UserDefaults(suiteName:)` rather than
    /// `.standard`, because `CopilotSetupBook` writes on every change and a test
    /// run must not re-point the copilot on the machine it is running from.
    private func scratchBook(_ name: String = #function) -> CopilotSetupBook {
        CopilotSetupBook(defaults: scratchSuite(name))
    }
}
