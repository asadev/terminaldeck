/**
 * **What a copilot is** — the reference page, at the foot of the copilot's
 * controls.
 *
 * ## This was the screen, and it is now a row
 *
 * It was built as the destination of the button in the Copilot tab's top right,
 * reading *"here on the right top corner you can give a button for all about
 * copilot"* as a page to read. Asad, looking at it:
 *
 * > *"When I said that you need to add a button which will be all about copilot
 * > in the copilot page, it doesn't mean like information about copilot. I meant
 * > all the control about copilot, all the settings of the copilot, and
 * > everything related to copilot that we need to have as options and control
 * > and settings."*
 *
 * So `CopilotControlView` is what that button opens, and this is the last row on
 * it, under *Reference*, behind a chevron. **Nothing here was rewritten.** Every
 * passage is a mirror of something in the desktop's own source, checked when it
 * was written and named in the comment beside it; the writing was never the
 * problem, its position was. A person who wants to know what a copilot is finds
 * it where a person would look; nobody operating one meets it first.
 *
 * ## Why it is still a screen and not a bigger ⓘ
 *
 * His standing rule is the reason:
 *
 * > *"here you have a very long description… Remove this full shit. I don't want
 * > any kind of long descriptions anywhere. Just if somewhere it's very
 * > required, give the i icon."*
 *
 * A popover is exactly the right size for one question and four sentences —
 * `CopilotOnServerView`'s *"It lives in the desktop app."* carries one, and
 * every caption on the control screen carries one. It is the wrong size for
 * *what is a copilot at all*, which is a screen's worth: what it is, what it can
 * reach, what it may do without asking, where it runs, who it is shared with,
 * what a server offers instead. Behind a dot that is a popover somebody has to
 * scroll, which is the long description back on the screen with an extra tap in
 * front of it. So it is a destination, one press from the bottom of the controls,
 * and **nothing about it is on any screen that did not ask for it.**
 *
 * ## Pushed, not a sheet, and the reason is the live chat two screens down
 *
 * The Copilot tab lands somebody **directly in a session in chat mode** when the
 * machine has one to land in. A sheet over a conversation that is *producing
 * output while it is being read* covers it, keeps it alive behind the card, and
 * returns the reader to a transcript that moved while they were away with
 * nothing to say how far. A push replaces it, and the system's own back chevron
 * puts them back. Reading material belongs on a screen of its own.
 *
 * ## No tab bar, and therefore no clearance
 *
 * `DeckChrome.showsTabBar(on: .copilot)` is false and `showsTabBar(on: .session)`
 * is false, and `DeckModel.copilotSurface` answers one of those two whatever is
 * underneath — a view-based link leaves `copilotRoute.last` alone. So there is no
 * floating bar over this screen from any perch, and a `TabBarClearance()` at the
 * foot of it would be reserving room against a control that is not drawn.
 * Checked rather than copied from the neighbouring pushed screens, which are on
 * the settings stack and do keep the bar.
 *
 * ## Nothing here is invented, and the tool list is not copied
 *
 * The one thing deliberately **not** mirrored from the desktop is the catalogue
 * itself. There are thirty-four tool ids across `src/main/deck-control/`, fifteen
 * of them held behind `describe-tool.ts` because the assembled list went over
 * both of its own ceilings on 2026-08-21 — a list that moves that fast, in a lane
 * that is not this one, would be wrong in Swift within a release and would be
 * wrong in the most convincing possible way: printed as fact, on the screen that
 * exists to be believed.
 *
 * So the tools are described by **what they reach**, which is a property of the
 * app rather than of the table, and the only number on the screen is the number
 * the machine itself sent — `CopilotState.tools` and `turnTokens`. A server sends
 * no state, so a server's version of this screen carries no count, which is
 * correct rather than a gap.
 */

import SwiftUI

/**
 * The screen itself: captions and prose, and not one control on it.
 *
 * The only pressable thing is the back chevron the `NavigationStack` supplies,
 * and that is what makes this a *reference* rather than the screen the button
 * opens. Every verb the copilot has is one push back, on `CopilotControlView`,
 * where a person looking for a control is looking. A button here would be a
 * second door to something that already has one, drawn where nobody pressing it
 * would think to look.
 */
struct AboutCopilotView: View {
    let model: DeckModel
    /// Named rather than read off `model.current`, for the reason every screen on
    /// this tab names its machine: the switcher in the title one level up can
    /// move underneath a pushed view, and a screen that followed it would explain
    /// one machine's copilot under another machine's name.
    let hostID: String

    private var host: HostLink? { model.host(hostID) }

    /**
     * The facts the words are chosen from, gathered in one place.
     *
     * Read on every redraw rather than captured in `@State`, and that is the
     * opposite of what `CopilotOnServerView` does with its `Offer` — for a
     * reason worth naming, because the two screens sit one push apart. That
     * screen remembers what the machine said because it draws **rows that can be
     * pressed**, and a row that leaves the screen when a phone goes through a
     * tunnel is the *"consistent connection"* complaint. Nothing here is
     * pressable. The worst a dropped socket can do to this screen is take one
     * sentence about this phone's own grant back to `.connecting`, which is the
     * truth at that moment and reads as such.
     */
    private var reading: AboutCopilot.Reading {
        guard let host else {
            return AboutCopilot.Reading(kind: .unknown, platform: .unknown, access: .notOffered)
        }
        let state = host.copilot.state
        return AboutCopilot.Reading(kind: host.hostKind,
                                    platform: host.hostPlatform,
                                    access: host.copilotAccess,
                                    grant: host.copilot.grant,
                                    tools: state?.tools,
                                    turnTokens: state?.turnTokens)
    }

    var body: some View {
        AboutCopilotPage(reading: reading)
    }
}

/**
 * The drawing, given the facts — and the reason it is a second view rather than
 * the body of the first.
 *
 * It is the split `CopilotTabScreen` makes for the same reason one level up:
 * *which machine* and *what is drawn* are two questions, and the one that needs
 * a `DeckModel`, a paired host and a live welcome is the one that makes this
 * screen otherwise unlookable-at. Both versions of it — the server's and the
 * desktop's, with and without a catalogue reading — can be rendered from a
 * `Reading` on a bare simulator with no host, no pairing and no relay, which is
 * how the line length, the caption band and the two-paragraph passages were
 * checked before this shipped rather than after.
 *
 * That was not a hypothetical convenience. Reaching the real thing needs a host
 * whose welcome says `hostKind: headless` **and** carries no copilot: the iOS
 * harness's stand-in cannot claim that — it sends `hostPlatform` and no kind at
 * all — and `live-copilot.sh`, which can, wants `out/headless/host.mjs` and the
 * deployed relay. A screen that can only be looked at by building the desktop
 * app is a screen nobody looks at.
 */
struct AboutCopilotPage: View {
    let reading: AboutCopilot.Reading

    var body: some View {
        ZStack {
            // Painted here, unlike `CopilotOnServerView`, which deliberately
            // paints none because `CopilotView` has already laid a ground under
            // it. This screen is pushed and is its own root, so there is nothing
            // underneath it to inherit.
            Theme.background.ignoresSafeArea()
            ScrollView {
                AboutCopilotProse(reading: reading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("About the copilot")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/**
 * The passages themselves, with no scroll view around them — and that boundary
 * was measured rather than chosen for tidiness.
 *
 * `ImageRenderer` draws **nothing at all** inside a `ScrollView`: the whole page
 * came back as an empty `Theme.background` rectangle at every size, because the
 * scroll view's content is laid out against a viewport that does not exist off
 * screen. `UIHostingController` plus `drawHierarchy` was tried next and produced
 * three byte-identical blanks, for the neighbouring reason — a `UIWindow` with
 * no scene never gets a screen update to draw. Rendering the prose on its own
 * works first time, because a `VStack` has an ideal height and needs no viewport.
 *
 * So the split is: this view is **the page**, the one above it is the scroll
 * behaviour and the title. Everything a person actually looks at — the caption
 * band, the card radius, the measure of a fifteen-point line at this width, how
 * a two-paragraph passage sits in a rounded rectangle — is in here and can be
 * photographed on a bare simulator with no host and no pairing.
 */
struct AboutCopilotProse: View {
    let reading: AboutCopilot.Reading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AboutCopilot.passages(reading)) { passage in
                caption(passage.caption)
                card {
                    Text(passage.body)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("copilot.about.\(passage.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Its own chrome

    /*
     * Drawn here rather than borrowed, for the reason `CopilotOnServerView`
     * writes out at length: `SectionCaption` and `SettingsGroup` are **private to
     * `DeckTabs.swift`**, so a screen that reached for them would have to live in
     * that file. These are the same shapes at the same metrics — an 11pt kerned
     * caption, a `Theme.surface` card at radius 20 — which is what keeps this
     * screen looking like the one it was pushed from.
     */
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.faint)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/**
 * What the screen says, as functions with no view in them.
 *
 * Here for the reason `CopilotOnServer` is: the ways a screen of prose can be
 * wrong are all silent. A desktop's paragraph shown over a server, a sentence
 * about this phone's grant that names the wrong tier, a tool count invented on a
 * machine that never sent one — none of those crash, none of them look like a
 * fault, and every one of them is a confident lie on the one screen in the app
 * whose entire job is to be believed.
 *
 * `AboutCopilotTests` — in `CopilotOnServerTests`, beside the rest of this tab —
 * walks them.
 */
enum AboutCopilot {

    /**
     * Everything the words are chosen from.
     *
     * Deliberately not a `HostLink`: the decisions below are about a machine's
     * *kind* and a phone's *grant*, and a pure value is what lets every one of
     * them be walked without a socket, a paired machine and a running agent.
     */
    struct Reading: Equatable {
        let kind: HostKind
        /// Only ever put in a sentence for a desktop — `HostKind.noun` is what a
        /// server is called. `unknown` reads "desktop" here, which is the right
        /// word for the case that produces it: a host too old to have said, on a
        /// screen that has already decided it is not a server.
        let platform: HostPlatform
        let access: CopilotAccess
        let grant: CopilotGrant
        /// What the machine said its copilot's catalogue costs it. Nil is *has
        /// not said* — a server never does, and a desktop has not yet on the
        /// first frame — and nil is drawn as silence rather than as a zero.
        let tools: Int?
        let turnTokens: Int?

        init(kind: HostKind,
             platform: HostPlatform,
             access: CopilotAccess,
             grant: CopilotGrant = .none,
             tools: Int? = nil,
             turnTokens: Int? = nil) {
            self.kind = kind
            self.platform = platform
            self.access = access
            self.grant = grant
            self.tools = tools
            self.turnTokens = turnTokens
        }

        /**
         * Whether this is the server's version of the screen.
         *
         * `.headless` and nothing else. `.unknown` is a host too old to have
         * said what it is, and it gets the desktop's version on purpose: the
         * desktop's version describes a copilot that exists and then says
         * plainly what this phone may do with it, which is true of an old
         * desktop and merely unhelpful about an old server. The server's version
         * opens by explaining why there is none — which, said over a machine
         * that has one, would be flatly wrong.
         */
        var isServer: Bool { kind == .headless }

        /// The noun for the box this is about. `HostKind.noun` for a server,
        /// because *server* is what it is called everywhere else in this app;
        /// the platform's noun for a desktop, because *Mac* and *PC* are what he
        /// calls those and `hostKind.noun` would only ever say "desktop".
        var noun: String { isServer ? kind.noun : platform.noun }
    }

    /// One captioned block of prose. `id` is the accessibility identifier's
    /// suffix as well as the `ForEach` key, so a UI test naming a passage and a
    /// unit test naming one cannot come to mean different blocks.
    struct Passage: Equatable, Identifiable {
        let id: String
        let caption: String
        let body: String
    }

    /**
     * The screen, in order.
     *
     * Four passages are common to both kinds of machine and two are not, and the
     * split is the point rather than an implementation detail: *what a copilot
     * is*, *what it reaches*, *what it may do without asking* and *who it is
     * shared with* are facts about the product, identical on every machine. What
     * differs is the two questions that only have an answer once you know which
     * kind of machine you are pointed at — **why there is none here** and **what
     * this one has instead** on a server; **where it runs** and **what this phone
     * may do with it** on a desktop.
     *
     * The order puts the common ones first on both, so somebody who reads this
     * screen on a desktop and again on a server is reading the same three
     * paragraphs and then a different two, rather than two screens that share
     * their content in the middle.
     */
    static func passages(_ reading: Reading) -> [Passage] {
        var out = [whatItIs, whatItReaches(reading), whatItMayDo]
        if reading.isServer {
            out.append(whyNoneHere)
            out.append(whatThisServerHasInstead(reading))
        } else {
            out.append(whereItRuns(reading))
            out.append(whatThisPhoneMayDo(reading))
        }
        out.append(neverShared)
        return out
    }

    // MARK: - The common three

    /**
     * What the thing is, in terms of what it does to this app.
     *
     * `src/main/deck-control/surface.ts` opens with the sentence this mirrors —
     * *"The copilot is a Claude CLI session with an MCP server attached. That
     * server is the app's own IPC surface, seen from outside the window"* — and
     * the half worth carrying over into a person's words is the **no second
     * backend** half, which that file argues at length: *"Every tool resolves to
     * a function the app already calls from an `ipcMain.handle`… Re-implementing
     * any of them so the copilot could reach it would be two answers to the same
     * question, and the two would drift within a release."*
     *
     * That is not an implementation note here, it is the answer to the question
     * a person actually has, which is *how much can it break*. The answer is:
     * only the things the app can already do to itself.
     */
    static let whatItIs = Passage(
        id: "what",
        caption: "What it is",
        body: "An agent holding this app's own controls, rather than a chat about the app. It runs "
            + "as a Claude CLI session with \(Brand.name)'s own interface handed to it, so it "
            + "answers \"how is that other session doing\" by reading the list the sidebar draws, "
            + "and \"start one in that project\" by calling the thing the New Session button "
            + "calls. There is no second copy of the app behind it, which is also the limit of "
            + "what it can do: only what this app can already do to itself."
    )

    /**
     * What it reaches, by capability rather than by tool id — and the machine's
     * own number when it sent one.
     *
     * See the file header for why the catalogue is not reproduced. What is
     * described here is the set of things the app hands over, which is stable
     * across the releases the table is not: sessions, transcripts, projects,
     * git, alerts, settings, and the browser verbs on a machine that drives one.
     *
     * The count and the per-turn cost are `CopilotState.tools` and
     * `turnTokens`, straight off the wire. `CopilotView` renders the same two
     * numbers as a status chip — *"20 tools · 7900 tokens a turn"* — and the two
     * cannot disagree about the fact because neither of them is the source of
     * it; the desktop is. They are two sentences about one number rather than
     * two numbers.
     */
    static func whatItReaches(_ reading: Reading) -> Passage {
        var body = "The app, not the machine. Its tools are things \(Brand.name) already does: the "
            + "sessions and what is inside them, the projects that are open, a folder's git status "
            + "and its diff, the alerts, the settings — and, on a machine that drives a browser, "
            + "the pages it has open. Nothing reaches a file or spawns a process except through a "
            + "verb this app already had."
        if let line = catalogueSentence(reading) { body += "\n\n" + line }
        return Passage(id: "reach", caption: "What it can reach", body: body)
    }

    /**
     * The size of the catalogue, or nothing at all.
     *
     * Nil in three situations that are one situation: a server, which has no
     * copilot to have a catalogue; a desktop on its first frame, before the
     * state has landed; and a desktop that sent zeroes, which is a copilot with
     * no tool surface running at all. The last is the interesting one and it is
     * still nil here, unlike `CopilotView`'s chip which prints it — because on
     * that screen a zero beside a Start button is a diagnosis somebody needs,
     * and in the middle of a paragraph explaining what tools are it would read
     * as a claim that there are none.
     *
     * The token figure keeps its bare digits — *7900*, not *7,900* — which reads
     * slightly stiff in a sentence and is the right trade anyway. It is the same
     * number `CopilotView`'s chip prints one push away, and a figure spelled two
     * ways on two screens of the same app invites the question of whether they
     * are two figures.
     */
    static func catalogueSentence(_ reading: Reading) -> String? {
        guard let tools = reading.tools, tools > 0 else { return nil }
        let count = tools == 1 ? "1 tool" : "\(tools) tools"
        guard let tokens = reading.turnTokens, tokens > 0 else {
            return "That \(reading.noun)'s copilot carries \(count)."
        }
        return "That \(reading.noun)'s copilot carries \(count), and they cost it about \(tokens) "
            + "tokens of every turn before anybody has said anything."
    }

    /**
     * The three tiers, and the sentence that stops `act` reading as *the safe
     * one*.
     *
     * `src/main/deck-control/surface.ts` holds the table this mirrors, and it
     * says the middle row out loud because the middle row is the one that gets
     * misread: *"`act` is not 'safe'. Starting a session spends money and spawns
     * a process with the user's credentials. It is separated from `alter`
     * because it is visible and undoable… whereas an `alter` call changes state
     * that nothing on screen would announce. A gate that fires on everything is
     * a gate nobody reads, and confirmation fatigue is the failure mode that
     * turns a permission prompt into a rubber stamp."*
     *
     * The escalation is worth its clause: `sessions.send` and `sessions.stop`
     * are `act` against the copilot's own session and are raised to `alter`
     * against anybody else's — which is the rule a person cares about, because
     * it is the one that decides whether their own work can be interrupted
     * without them.
     *
     * The logging sentence goes first rather than last. It is unconditional —
     * `control.ts` writes a row for every call at every tier, inside a `finally`
     * — and stating it after the tiers reads as a property of the last one.
     */
    static let whatItMayDo = Passage(
        id: "tiers",
        caption: "What it may do without asking",
        body: "Every call it makes is written to the action log, whatever tier it is, whether it "
            + "worked or not. Above that there are three tiers. Read — the lists, a transcript, a "
            + "git status — always allowed. Act — start a session, talk to the one it started, "
            + "stop that one — allowed, and never silent. Alter — write a setting, or reach into "
            + "work it did not start — put to a person in a window first, and refused if nobody "
            + "answers.\n\n"
            + "Act is not the safe tier. Starting a session spends money and runs a process as "
            + "you. It sits below Alter because it is visible and undoable — the session appears "
            + "and can be killed — where an Alter call changes something nothing on screen would "
            + "announce. A gate that fires on everything is a gate nobody reads."
    )

    // MARK: - The server's two

    /**
     * Why there is none here, said the way the host itself says it.
     *
     * Two things, and the second is the one people do not guess. The first is
     * `NO_COPILOT_HERE` from `src/headless/cli.ts`, mirrored rather than
     * imported — Swift cannot read that file, so this is its mirror in the same
     * arrangement `Brand` has with `src/shared/brand.ts`.
     *
     * The second is `src/headless/host.ts`'s own reasoning, and it exists here
     * because *"not yet"* is the wrong answer and the obvious one. That file
     * used to decline the copilot because `deck-control` could not be imported
     * into a headless bundle at all; both of those edges have since been cut and
     * the answer did not change. What is left is not an import: `alter` is
     * confirmed by a person in a window, `registerDeckControlIpc` wants an
     * `ipcMain` and an approver `WebContents` to raise that window, and there is
     * no window on a server. Its conclusion is the sentence this passage ends
     * on — *"passing the layer without its tool server would therefore draw a
     * fourth pill on the phone whose every Start button refuses, which is worse
     * than the absence, not better."*
     *
     * The guest question is closed out loud in the first paragraph for the same
     * reason `CopilotOnServerView`'s ⓘ closes it: on a desktop an absent copilot
     * genuinely can mean *you were paired as a guest*, so somebody carrying that
     * explanation over would go and re-pair a phone that was paired correctly.
     */
    static let whyNoneHere = Passage(
        id: "why",
        caption: "Why there is none on this server",
        body: "The copilot's tools are the desktop app's own — its session list, its transcripts, "
            + "its settings — and a server has no app for them to drive. So no copilot appears on "
            + "a device paired to a server, and it is nothing to do with how this phone was "
            + "paired: a server has none for any device, of either kind.\n\n"
            + "It is not a piece somebody forgot either. An Alter call is confirmed by a person "
            + "in a window, and a server has no window — the question would have to be carried "
            + "out to a connected device, and nothing here is wired to carry it. Handing a "
            + "copilot its tools without that would put a fourth pill on this phone whose every "
            + "button refuses, which is worse than the absence rather than better."
    )

    /**
     * The honest offer, and how the tab already behaves.
     *
     * *"An agent running in a session here is the same work at a different
     * surface"* is the line `CopilotOnServerView`'s ⓘ ends on, and this is the
     * long form of it. Three facts, all of them checkable in this app rather
     * than promised:
     *
     *  - The tab **lands** in the conversation. His sentence: *"copilot page
     *    should be always landing in a copilot session according to the settings
     *    of the copilot… But it should be always a chat to land with."*
     *  - It never **starts** one by itself, which is the half of that sentence
     *    `CopilotOnServer.Landing` deliberately has no case for. The reason is
     *    worth repeating on a screen rather than only in a comment, because it
     *    is a promise about somebody's money: the Copilot pill is drawn
     *    unconditionally on a server, so the tab is one mis-tap away at all
     *    times.
     *  - What goes into a new one is the server's own `agents.defaultProvider`,
     *    which is the field `host-core.ts` reaches for when a `create` frame
     *    names no provider. It is named here as *this server's own default*
     *    rather than as an agent, because naming an agent this app has not been
     *    told about is the one thing worse than naming none.
     */
    static func whatThisServerHasInstead(_ reading: Reading) -> Passage {
        Passage(
            id: "instead",
            caption: "What this \(reading.noun) has instead",
            body: "A session with an agent in it — the same work at a different surface. The "
                + "Copilot tab lands you straight in that conversation whenever one is running "
                + "here, as a chat rather than at a prompt, and Back brings you out to the "
                + "screen you came from.\n\n"
                + "It never starts one for you. Choosing a tab is one mis-tap, and a new session "
                + "here runs a real agent spending real money with nothing on this phone to undo "
                + "it — so starting one is a press, and the press both makes the session and "
                + "puts you in it. What goes into it is whatever this \(reading.noun)'s own "
                + "default agent is set to, which is the same setting it reads when anything "
                + "else starts a session without naming one."
        )
    }

    // MARK: - The desktop's two

    /**
     * Where it runs, and the distinction this app makes everywhere else.
     *
     * `CopilotState` names it first because it is *"the field of this frame most
     * likely to be read wrongly"*: `desk` is the copilot pinned in the sidebar
     * at the machine, which this phone watches and can never type into, and
     * `run` is this device's own run, which is the only thing it can talk to.
     * They move independently, and a screen that drew one from the other would
     * get the one control that costs money wrong in both directions.
     *
     * That is a distinction a person meets the first time they watch an answer
     * appear on their phone and cannot reply to it, so it is said here plainly
     * rather than left to be inferred from a greyed composer.
     */
    static func whereItRuns(_ reading: Reading) -> Passage {
        Passage(
            id: "where",
            caption: "Where it runs",
            body: "At the \(reading.noun), in its own window, on that machine's own account. The "
                + "conversation pinned there belongs to whoever is sitting at that keyboard: "
                + "this phone can watch it and can never type into it.\n\n"
                + "What a phone can talk to is a run of its own, started from here. The two are "
                + "counted separately everywhere in this app for that reason — one of them is "
                + "somebody else's conversation."
        )
    }

    /**
     * What this phone may do, in the vocabulary the rest of the tab uses.
     *
     * Every case of `CopilotAccess`, because a state added later and not thought
     * about is a paragraph that silently describes the wrong one — the same
     * argument that enum makes for being `CaseIterable`. The words are lifted
     * from where each state is defined rather than re-invented, so this screen
     * and the screen it was pushed from cannot come to describe the same state
     * two ways.
     *
     * `.direct` splits on `grant.alter`, and it is read as `alter` alone exactly
     * as `CopilotGrant.canAnswer` reads it — *"the one place the client does not
     * add `read` to the test, because the desktop does not."* Writing it the way
     * the far end writes it is what stops this end inventing a rule the machine
     * does not have.
     *
     * `.notOffered` says both of its two meanings rather than picking one,
     * because this end genuinely cannot tell them apart: a build without a
     * copilot and a device approved as a guest send the same absence, which is
     * `server.ts`'s decision and not a gap here.
     */
    static func whatThisPhoneMayDo(_ reading: Reading) -> Passage {
        let body: String
        switch reading.access {
        case .notOffered:
            body = "Nothing: there is no copilot on this \(reading.noun) for this phone. Either "
                + "it is running a version of \(Brand.name) without one, or this phone is paired "
                + "with it as a guest. Which of the two it is was decided at the machine when "
                + "this phone was approved, and cannot be told apart from here."
        case .connecting:
            body = "The hello is on its way, or the socket is down and it cannot be. There is "
                + "nothing to press while that is true. The pill follows the pairing rather than "
                + "the wire, so it stays where it is while a phone goes through a tunnel — it is "
                + "not appearing and disappearing at you."
        case .notGranted:
            body = "Open, and granted nothing. One of your own devices is given every tier, so "
                + "this is that machine saying something this build does not expect rather than "
                + "a switch to go and find. It is shown rather than hidden because a blank "
                + "screen would be indistinguishable from a fault in this app."
        case .watch:
            body = "Watch it: what it is doing, what it started, and what it was refused. No "
                + "composer and no Start — talking to a copilot is an Act, because it spends "
                + "money and causes tool calls, and this phone has been given Read and not that."
        case .direct:
            let answering = reading.grant.canAnswer
                ? "Confirmations for your own run are answered here, on this phone."
                : "Confirmations for your own run are answered at the machine; this phone is "
                    + "shown the question and not the buttons."
            body = "Watch it, start a run of your own, and talk to that run. \(answering) The "
                + "conversation at the machine stays read-only either way — it is somebody "
                + "else's."
        }
        return Passage(id: "phone", caption: "What this phone may do", body: body)
    }

    // MARK: - The one that is his

    /**
     * Who it is shared with, which is the answer he gave before anybody asked.
     *
     * > *"we usually might not give this copilot to others… we don't want to give
     * > this copilot to others to see how we use it. This will be only ours."*
     *
     * The sentence printed on screen is the one **he wrote himself** for the
     * approval card, which `src/main/remote/copilot-access.ts` quotes as the
     * whole of the decision — *"Guest — You choose what they can reach. The
     * copilot is never shared."* Using his printed wording rather than a
     * paraphrase of the recording means the phone and the machine say the same
     * words about the same rule, which is what somebody comparing the two
     * screens is entitled to.
     *
     * The second paragraph is `device-kind.ts`'s property and it is the part
     * that makes the first one hold: a kind is written once and no method
     * overwrites one, so a guest cannot be promoted by a tap. It matters on this
     * screen because it is the natural next question — *can I change it* — and
     * the answer is yes, by pairing again, in front of both people.
     */
    static let neverShared = Passage(
        id: "yours",
        caption: "Only your own devices",
        body: "The copilot is never shared. A device approved as My device reaches it on the "
            + "first connection, with nothing to press in between; a device approved as a guest "
            + "is never offered it at all — not a refused button and not an empty screen, the "
            + "capability is simply absent from what that device is told the machine can do.\n\n"
            + "What a device is cannot be changed afterwards by a tap. It is written once when "
            + "the device is approved, and changing it means pairing again — the same two acts, "
            + "by the same two people."
    )
}
