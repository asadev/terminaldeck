/**
 * The copilot, on a phone.
 *
 * Asad, holding the iOS release for this: *"We need to build a copilot in the
 * phone app too, because we need to connect the copilot also and we should be
 * able to control the copilot from the phone also."*
 *
 * ## Where it goes, in three tabs
 *
 * **A pinned row at the top of the Sessions tab, pushing this screen.** Not a
 * fourth pill, not a Settings row, and the reasoning is worth writing down
 * because all three were live options.
 *
 * *Not a fourth tab.* He built up to four in one recording — *"four icons in the
 * pill"* — and then took Machines off the bar a minute later and called the
 * result *"a better design"*. Three is a decision he has already made once,
 * against the same pressure. And the pressure is not really about the copilot:
 * it is that a tab bar is for surfaces you move **between** all day, and this is
 * a surface you go **into** and stay in, like a terminal.
 *
 * *Not inside Settings.* Machines went there because pairing a machine is done
 * once. Asking the copilot what happened overnight is done every morning, and
 * putting it two taps behind a gear would make the phone worse at the one thing
 * he described wanting the phone for.
 *
 * *The Sessions tab, at the top of the list.* Three reasons, in order of weight:
 * the desktop already pins it exactly there — *"Pinned at the top of the
 * sidebar, above the session list"* — and the phone's Sessions tab **is** that
 * list, so the two products stay one product; everything the copilot is good at
 * is a question about the rows underneath it (*which of these is stuck, what
 * happened overnight, summarise that run*), so the answer belongs on the screen
 * holding the question; and it costs no chrome at all — one row, above Resume,
 * on a list that already has a pinned row above the sessions and a rule for what
 * earns that position.
 *
 * The push, rather than a sheet, is the same call `LocalhostListView` had to
 * make and he settled it there: *"it should not come like this up… feels like a
 * browser opens inside. So give it a native feel."* A modal is an interruption;
 * this is where the tap was going. And like a terminal it takes the whole
 * screen and loses the tab bar — see `DeckChrome`, and note that this screen has
 * a text field at the bottom of it, which is the exact frame the pill complaint
 * was about.
 *
 * ## One list: what it said and what it did, interleaved
 *
 * The timeline is chat bubbles and tool rows in arrival order, not a chat pane
 * with an activity pane behind a segment. `CopilotEntry` carries the argument.
 * In short: *"exactly like you are working now for me — but now you are working
 * in folders and files, I don't know which files where and all that stuff. Here
 * I can actually see it."* Two panes would put the answer in one and the
 * machinery in the other and leave a person correlating them by timestamp on a
 * four-inch screen.
 *
 * ## Four states, and none of them is a lie
 *
 * `CopilotAccess` has four cases and this screen draws four different things.
 * The one worth naming here is `.notGranted`: a machine that **has** a copilot
 * and has given this phone none of it. That is not hidden and it is not a
 * disabled composer — it is a screen that says so and names where the switch is,
 * because it is the one state a person can fix and they fix it on the desktop.
 * It is the same call `SessionListView` makes for a machine that granted no
 * folders, and the same call for the same reason.
 *
 * `.notOffered` — a desktop that does not speak `copilot.*` at all, which is
 * every build shipping today — draws **nothing**, not even a row. That is not
 * the same decision: there is no switch on that machine to point at, so a screen
 * explaining where to find one would be sending somebody to look for a control
 * that does not exist.
 */

import SwiftUI

struct CopilotView: View {
    let model: DeckModel
    /// Named rather than taken from `model.current`, for the reason every other
    /// pushed screen here names its machine: the switcher can move underneath a
    /// pushed view, and a copilot screen that followed it would show one
    /// machine's conversation under another machine's name.
    let hostID: String

    /// What is in the composer. Held here rather than on the link, because it is
    /// a half-typed sentence rather than a fact about the machine — and because
    /// it must survive a redraw caused by a tool row arriving, which happens
    /// constantly while somebody is typing.
    @State private var draft = ""
    @FocusState private var composing: Bool

    /// The confirmation being read in full, if any. See `CopilotQuestionSheet`.
    @State private var reading: CopilotQuestion?
    @State private var showingActivity = false
    @State private var showingSessions = false

    private var host: HostLink? { model.host(hostID) }
    private var link: CopilotLink? { host?.copilot }

    /// Whether this phone may see anything on this machine's copilot at all —
    /// which is what every control in the toolbar needs, since both of them are
    /// read-tier lists.
    private var isWatching: Bool {
        let access = host?.copilotAccess ?? .notOffered
        return access == .watch || access == .direct
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle("Copilot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            /*
             * No overflow for a phone that may not watch.
             *
             * Both items on it are `read` — the action log and the sessions the
             * copilot started — so on the not-granted screen they were two taps
             * that could only open an empty sheet. Caught by looking at the
             * screen rather than by a test: the not-granted case renders a
             * sentence explaining that this phone has been given nothing, with a
             * menu beside it offering it two things anyway.
             *
             * `isWatching` and not `!= .notGranted`, so the notOffered screen
             * loses it too. There is even less behind it there.
             */
            if isWatching {
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .sheet(item: $reading) { question in
            CopilotQuestionSheet(question: question,
                                 machine: host?.label ?? "that machine",
                                 noun: host?.hostPlatform.noun ?? "desktop") { reading = nil }
        }
        .sheet(isPresented: $showingActivity) {
            CopilotActivitySheet(model: model, hostID: hostID) { showingActivity = false }
        }
        .sheet(isPresented: $showingSessions) {
            CopilotSessionsSheet(model: model, hostID: hostID) { showingSessions = false }
        }
    }

    // MARK: - The body, per access

    @ViewBuilder
    private var content: some View {
        switch host?.copilotAccess ?? .notOffered {
        case .notOffered:
            /*
             * Reachable only by a route that outlived its machine — the row that
             * pushes this screen is not drawn for a desktop that never offered
             * the capability, and a `copilot.grant` cannot take the *capability*
             * away. So this is the honest thing to say when the machine turned
             * out not to have one after all, rather than a state anybody
             * navigates to on purpose.
             */
            ContentUnavailableView {
                Label("No copilot here", systemImage: "sparkles")
            } description: {
                Text("\(host?.label ?? "That machine") is running a version of \(Brand.name) "
                     + "without a copilot in it. Update the \(host?.hostPlatform.noun ?? "desktop") "
                     + "and it will appear here.")
            }
            .accessibilityIdentifier("copilot.notOffered")

        case .notGranted:
            notGranted

        case .watch, .direct:
            timeline
        }
    }

    /**
     * The machine has a copilot and this phone has not been given any of it.
     *
     * Every word here is doing one of two jobs: saying what is true, and saying
     * where the fix is. It names the machine, because a phone paired with three
     * of them needs to know which one to walk to; it names the screen on the
     * desktop, because *"go and change a setting"* with no address is how
     * somebody concludes the feature is broken; and it says the grant is per
     * device and off by default, because the natural assumption on finding a
     * feature switched off is that it failed rather than that it was never
     * turned on.
     *
     * There is deliberately no button. Nothing on this phone can grant this —
     * `settings.write` refuses the `copilot.` prefix, there is no frame that
     * edits a grant, and the panel on the desktop is the only door. A control
     * here would be the exact defect `reachable.test.ts` warns about: a
     * permission control that changes nothing, believed by the person who
     * pressed it.
     */
    private var notGranted: some View {
        ContentUnavailableView {
            Label("Not shared with this phone", systemImage: "lock")
        } description: {
            Text("\(host?.label ?? "That machine") has a copilot, and this phone has not been "
                 + "given access to it. Copilot access is off for every device until somebody "
                 + "turns it on at the \(host?.hostPlatform.noun ?? "desktop") — it is in "
                 + "Settings, under Remote, on this phone's own card.")
        }
        .accessibilityIdentifier("copilot.notGranted")
    }

    /// The conversation and the machinery, plus whatever is waiting at the desk.
    private var timeline: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    stateCard

                    ForEach(link?.pending ?? []) { question in
                        CopilotQuestionCard(question: question,
                                            noun: host?.hostPlatform.noun ?? "desktop") {
                            reading = question
                        }
                    }

                    ForEach(link?.timeline ?? []) { entry in
                        switch entry {
                        case let .message(message):
                            CopilotBubble(message: message)
                        case let .action(action):
                            CopilotActionRow(action: action)
                        }
                    }

                    // An anchor rather than "scroll to the last row", because the
                    // last row changes identity as a streaming answer is
                    // replaced, and scrolling to a row that is being rebuilt
                    // fights the layout. A zero-height view at the foot has a
                    // stable id and always means "the bottom".
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                host?.copilot.refresh()
                try? await Task.sleep(for: .milliseconds(450))
            }
            // Follows the conversation down as it grows. Keyed on the count
            // rather than on the array so a message being *extended* — the
            // normal shape of a streaming answer, same id, more text — also
            // moves the view, which is the case a value-equality trigger would
            // miss on every frame but the first.
            .onChange(of: link?.timeline.count ?? 0) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onAppear { scroll.scrollTo(Self.bottom, anchor: .bottom) }
        }
    }

    private static let bottom = "copilot.bottom"

    // MARK: - Pieces

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if model.showsConnectionNotice {
                Banner(text: model.connection.detail, tone: .warning)
            }
            if let error = model.lastError {
                Banner(text: error, tone: .warning)
                    .onTapGesture { model.dismissError() }
                    .accessibilityIdentifier("copilot.error")
            }
        }
    }

    /**
     * What the copilot is, in one card.
     *
     * Drawn only when the machine has said something. A card reading "Not
     * running" over a machine that has simply not answered yet would be this
     * phone inventing a fact about somebody else's Mac.
     *
     * **Two lines because there are two copilots**, and this screen got that
     * wrong once by folding them into one sentence. `desk` is the copilot the
     * person at the machine is talking to; `run` is this phone's own. They move
     * independently — the desk's can be running while this phone has none, which
     * is the ordinary case — and the Start button below is drawn from the second
     * only.
     */
    @ViewBuilder
    private var stateCard: some View {
        if let state = link?.state {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(state.deskIsRunning ? Theme.positive : Theme.secondary)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 4) {
                    Text(deskLine(state))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .accessibilityIdentifier("copilot.status")

                    Text(runLine(state))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("copilot.run")

                    // Only what the machine actually said. Each of these is
                    // absent on a desktop that did not mention it, and a line
                    // invented for an absent field is a line about somebody
                    // else's machine.
                    if let account = accountLine(state) {
                        Text(account)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.faint)
                    }
                    if let catalogue = catalogueLine(state) {
                        Text(catalogue)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                    }
                    if let reason = state.reason {
                        Text(reason)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// The copilot at the machine. `deskIsStopped` rather than `!deskIsRunning`,
    /// because an unrecognised word from a newer desktop is neither, and
    /// printing it is more honest than calling it stopped.
    private func deskLine(_ state: CopilotState) -> String {
        if state.deskIsRunning { return "Running at the \(hostNoun)" }
        if state.deskIsStarting { return "Starting at the \(hostNoun)…" }
        if state.deskIsStopped { return "Not running at the \(hostNoun)" }
        return state.desk
    }

    /// And this phone's own, which is the only one it can speak to. Said even
    /// when there is none, because "you have no run" is the fact the composer's
    /// absence is explained by.
    private func runLine(_ state: CopilotState) -> String {
        state.hasRun ? "This phone has a copilot of its own running"
                     : "No copilot running for this phone"
    }

    /// The account, and whether it is signed in — three answers, because nil is
    /// "not asked" and drawing it as signed out would send somebody to fix an
    /// account that is fine.
    private func accountLine(_ state: CopilotState) -> String? {
        guard let profile = state.profile else {
            return state.signedIn == false ? "Signed out" : nil
        }
        switch state.signedIn {
        case true?: return profile
        case false?: return "\(profile) — signed out"
        default: return profile
        }
    }

    /// What a turn costs it before anybody says anything. Only when the machine
    /// gave a number; zero tools is a copilot with no tool surface at all, which
    /// is worth seeing rather than hiding.
    private func catalogueLine(_ state: CopilotState) -> String? {
        guard state.tools > 0 || state.turnTokens > 0 else { return nil }
        let tools = state.tools == 1 ? "1 tool" : "\(state.tools) tools"
        guard state.turnTokens > 0 else { return tools }
        return "\(tools) · \(state.turnTokens) tokens a turn"
    }

    private var hostNoun: String { host?.hostPlatform.noun ?? "desktop" }

    /**
     * The bottom of the screen: a composer, an offer to start one, or a sentence.
     *
     * Three states and no fourth. A **disabled** composer was the obvious fourth
     * and is refused for the reason this app refuses a disabled New Session
     * button: a control drawn for something the far end will never allow is a
     * smaller lie, not a smaller feature. A watching phone gets a sentence that
     * says what it can do and what the second switch would add.
     */
    @ViewBuilder
    private var footer: some View {
        switch host?.copilotAccess ?? .notOffered {
        case .notOffered, .notGranted:
            EmptyView()
        case .watch:
            watchingNote
        case .direct:
            if link?.hasRun == true {
                composer
            } else if link?.state?.available == true {
                startCard
            } else {
                cannotStart
            }
        }
    }

    /**
     * The machine says a run cannot start here, in its own words.
     *
     * `available` and `reason` are on the wire precisely so this is a sentence
     * rather than a button — the desktop's own note about the pair is that
     * *false with a reason beats a Start button that fails*. It knows whether
     * the Claude CLI is missing, the account is signed out or the tool endpoint
     * is down; this end knows none of the three, so it prints and does not
     * guess.
     *
     * Also the answer for a state this phone has not received yet, which is why
     * it is written as "has not said" rather than as a failure: a machine that
     * has not answered is not a machine that refused.
     */
    private var cannotStart: some View {
        Text(link?.state.flatMap(\.reason)
             ?? "The \(hostNoun) has not said whether a copilot can start here.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
            .accessibilityIdentifier("copilot.cannotStart")
    }

    /**
     * What a watching phone is told, where the composer would be.
     *
     * Not a warning and not an error — nothing is wrong. This is a grant working
     * exactly as intended, and the read tier is the one worth handing out: it
     * shows the fleet, the log, the sessions and the refusals, and it carries no
     * power at all. So it says what this phone *can* do first, and names the
     * second switch second.
     */
    private var watchingNote: some View {
        Text("This phone can watch the copilot. Talking to it, and letting it start work, "
             + "is a second switch at the \(hostNoun).")
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
            .accessibilityIdentifier("copilot.watchingOnly")
    }

    /**
     * Starting a run. **The tap is the consent, and it is a consent about money.**
     *
     * This is the one decision on this screen that genuinely belongs to the
     * person holding the phone, so it is the one thing drawn as a button — and
     * it says what it costs rather than being a play triangle. `copilot.start`
     * is deliberately not folded into `copilot.attach` for exactly this reason:
     * a screen that started a second Claude process because somebody looked at
     * it would be a screen with a bill attached to opening it.
     *
     * The sentence explains what a "run" is, because the word is meaningless
     * otherwise and the thing it names is genuinely unusual: a second copilot
     * process on the machine, sharing the same folder, the same `CLAUDE.md`, the
     * same `memory/` and the same action log as the one at the desk, with its
     * own conversation. Somebody who thought this was going to appear in the
     * chat on their Mac would be surprised by it later, and being surprised by
     * an agent later is the thing this whole feature is built to avoid.
     */
    private var startCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start a copilot for this phone")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text("It runs on the \(hostNoun), in the copilot's own folder, sharing its memory and "
                 + "its action log with the one at your desk — and it has its own conversation, so "
                 + "what you ask here does not appear there. It spends money while it works.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                link?.start()
            } label: {
                Text("Start")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .accessibilityIdentifier("copilot.start")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    /**
     * The composer.
     *
     * A **wrapping** field, because the question this screen exists for — *"what
     * happened overnight"* — is often followed by a sentence of context, and a
     * single-line field on a phone turns that into a horizontal scroll. Send is
     * a button rather than a `submitLabel` of `.send`, which on an agent prompt
     * is one thumb-slip away from asking a question that was half typed.
     *
     * **Wrapping, but not multi-line, and the difference is the far end's.** The
     * desktop refuses a `copilot.say` carrying any control byte, a newline
     * included, because the text lands in a pty holding a Claude CLI where a
     * newline submits — so a two-line message is not a longer message, it is a
     * refused one. `CopilotLink.oneUtterance` carries the argument. Here the
     * substitution happens as the field is typed into, so a Return is visibly a
     * space rather than something that looks accepted and is thrown away at the
     * moment of sending.
     *
     * The draft is cleared **only when the frame was accepted**. A message that
     * vanished out of the field because a socket was down would be a message
     * somebody has to retype, and they would not know they had to until the
     * answer never came.
     */
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask the copilot…", text: $draft, axis: .vertical)
                .lineLimit(1 ... 5)
                .font(.system(size: 16))
                .foregroundStyle(Theme.primary)
                .textInputAutocapitalization(.sentences)
                .focused($composing)
                .onChange(of: draft) { _, typed in
                    let flattened = CopilotLink.oneUtterance(typed)
                    // Compared before assigning, and the trailing space is why:
                    // `oneUtterance` trims, so assigning unconditionally would
                    // eat the space a person types between two words the instant
                    // they type it.
                    if flattened != typed.trimmingCharacters(in: .whitespacesAndNewlines) {
                        draft = flattened
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityIdentifier("copilot.composer")

            Button {
                if link?.say(draft) == true { draft = "" }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Theme.accent : Theme.faint)
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("copilot.send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    /// Disabled on an empty field only. Not on the connection: `Transport.send`
    /// refuses rather than queues, so a press over a dead socket answers *"Not
    /// connected — that was not sent"* and keeps the text, which tells somebody
    /// more than a greyed button ever does.
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /**
     * The overflow menu: the two lists that are references rather than places,
     * and the two verbs that act on this phone's own run.
     *
     * Activity and the session list are sheets rather than pushes for the reason
     * `SessionDetailView` is one — *"a reference somebody opens, reads and
     * closes, not a place they are going"* — and because pushing them would put
     * two more screens on a stack whose back button was fixed last week.
     */
    private var menu: some View {
        Menu {
            Button {
                showingActivity = true
                host?.copilot.loadLog()
            } label: {
                Label("Everything it did", systemImage: "list.bullet.rectangle")
            }
            .accessibilityIdentifier("copilot.activity")

            Button {
                showingSessions = true
            } label: {
                Label(sessionsLabel, systemImage: "terminal")
            }
            .accessibilityIdentifier("copilot.sessions")

            // Only for a phone that has a run of its own. Both verbs reach that
            // run and nothing else — a phone cannot interrupt or stop the
            // copilot somebody is working in at the desk, because runs are keyed
            // by device.
            if host?.copilotAccess == .direct && link?.hasRun == true {
                Divider()
                Button {
                    link?.cancel()
                } label: {
                    Label("Interrupt this turn", systemImage: "stop.circle")
                }
                .accessibilityIdentifier("copilot.cancel")

                Button(role: .destructive) {
                    link?.stop()
                } label: {
                    Label("Stop this phone's copilot", systemImage: "xmark.circle")
                }
                .accessibilityIdentifier("copilot.stop")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("copilot.more")
    }

    /// The count is on the label because it is the thing being asked. Zero is
    /// still shown and still opens: an empty list saying "it has not started
    /// anything" answers the question, and a hidden item leaves somebody
    /// wondering where it went.
    private var sessionsLabel: String {
        let count = link?.sessions.count ?? 0
        if count == 0 { return "Sessions it started" }
        return count == 1 ? "1 session it started" : "\(count) sessions it started"
    }
}

/* -------------------------------------------------------------------------- */
/* The row on the session list                                                 */
/* -------------------------------------------------------------------------- */

/**
 * The copilot, pinned above the sessions.
 *
 * Above Resume, and that ordering is a claim worth defending: Resume is *where
 * you were*, and the copilot is *what to ask before you go anywhere*. On the
 * morning this feature exists for, the first thing wanted is not the session
 * that was open last night — it is a sentence about all of them.
 *
 * It is a plain card rather than a tinted one. Resume owns the accent on this
 * screen, and the design rule is that a screen where two things are blue has no
 * accent at all. What earns attention here instead is the badge, and only when
 * there is genuinely something waiting at the desk.
 *
 * **Absent when the machine does not offer a copilot** — every desktop shipping
 * today. Present and honest when it does and this phone was granted nothing;
 * see `CopilotView.notGranted` for why that case is drawn rather than hidden.
 */
struct CopilotListRow: View {
    let host: HostLink
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17))
                    .foregroundStyle(host.copilotAccess == .notGranted ? Theme.faint : Theme.primary)
                    .frame(width: 22)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Copilot")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if host.copilot.waitingCount > 0 {
                    // The one thing on this row that is allowed to shout, and it
                    // shouts about the one thing that has a two-minute deadline
                    // on it. See `CopilotQuestionCard`.
                    Text("\(host.copilot.waitingCount)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.warning, in: Capsule())
                        .accessibilityLabel("\(host.copilot.waitingCount) waiting for you at the machine")
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityIdentifier("copilot.row")
    }

    /**
     * One line about what the copilot is doing, or about why this phone cannot
     * see.
     *
     * The `notGranted` wording names the machine's own settings rather than
     * saying "no access", because a row that only reports a refusal is a row
     * people tap twice and then stop tapping.
     */
    private var subtitle: String {
        switch host.copilotAccess {
        case .notOffered:
            // Not drawn — `SessionListView` leaves the row out entirely for a
            // machine with no copilot, because there is no switch on it to point
            // at. Written out rather than folded into the case below so that the
            // day somebody draws this row unconditionally, the sentence under it
            // is true instead of sending them to a screen that does not exist.
            return "Not on this \(host.hostPlatform.noun) yet"
        case .notGranted:
            return "Not shared with this phone — turn it on at the \(host.hostPlatform.noun)"
        case .watch, .direct:
            var parts: [String] = []
            if let state = host.copilot.state {
                // The copilot **at the machine**, which is what the read tier is
                // for. This phone's own run is not on this row: it is the thing
                // the screen behind it is about, and a row that said "running"
                // for a run only this phone has would read, on the session list,
                // as a claim about the Mac.
                if state.deskIsRunning {
                    parts.append("running")
                } else if state.deskIsStarting {
                    parts.append("starting")
                } else if state.deskIsStopped {
                    parts.append("not running")
                } else {
                    parts.append(state.desk)
                }
            }
            let started = host.copilot.sessions.count
            if started > 0 { parts.append(started == 1 ? "1 session started" : "\(started) sessions started") }
            if host.copilotAccess == .watch { parts.append("watching only") }
            // Nothing invented for a machine that has not answered yet. The row
            // still draws and still opens — the screen behind it says more.
            return parts.isEmpty ? "Ask it what happened" : parts.joined(separator: " · ")
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Rows in the timeline                                                        */
/* -------------------------------------------------------------------------- */

/// One turn of the conversation.
///
/// The person's own words are tinted and pushed right; the agent's are a card on
/// the left. That is the one place on this screen the accent is spent, and it is
/// spent on the cheapest possible question — *which of these did I say* — which
/// on a small screen full of tool rows is genuinely hard to answer from
/// indentation alone.
private struct CopilotBubble: View {
    let message: CopilotChatMessage

    var body: some View {
        HStack {
            if message.role == .you { Spacer(minLength: 40) }

            VStack(alignment: .leading, spacing: 6) {
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // Somebody who asked what happened overnight will want to
                    // paste the answer somewhere. A chat bubble that cannot be
                    // copied is a chat bubble that has to be retyped.
                    .textSelection(.enabled)

                if message.truncated {
                    // Said, because a bubble that was shortened and does not say
                    // so misquotes an agent — and the full text is still on the
                    // machine, where the transcript viewer can show all of it.
                    Text("Shortened to fit — the whole message is in the transcript on the machine.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(message.role == .you ? Theme.accent.opacity(0.14) : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if message.role == .agent { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.role == .you ? "You said: \(message.text)"
                                                 : "Copilot said: \(message.text)")
    }
}

/**
 * One thing the copilot did, inline in the conversation.
 *
 * A dot, the tool's name and the sentence the tool wrote. That is the *"here I
 * can actually see it"* half of this screen — Asad's own words about the whole
 * feature were *"you are working in folders and files, I don't know which files
 * where and all that stuff; here I can actually see it"* — and it is why the
 * machinery is interleaved with the conversation rather than filed behind a
 * segmented control.
 *
 * **Not tappable, because there is nothing behind it.** An earlier draft opened
 * each row to show the call's arguments, and the arguments are not on this wire
 * and are not coming: `CopilotActionRow` on the desktop says why, in the same
 * breath as saying the row is rebuilt field by field rather than passed through
 * — *even scrubbed they are the text of what was typed into somebody's
 * sessions*. A chevron over nothing is worse than no chevron, because it makes a
 * person tap twice before concluding the app is broken.
 *
 * A **refused** row is drawn differently on purpose, and it is the row that
 * carries the most information on the whole screen: it is what a permission
 * boundary looks like from the outside. The refusal reason is the desktop's own
 * word — `not-granted`, `declined`, `timeout` — printed rather than translated,
 * because this end does not know which of the tiers or which of the gates
 * produced it and a guess would be a phone explaining somebody's security model
 * to them incorrectly.
 */
private struct CopilotActionRow: View {
    let action: CopilotAction

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tone)
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(action.tool)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                    if let line = SessionDetails.activityLine(action.at) {
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.faint)
                    }
                }
                Text(action.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let refusal = action.refusal {
                    Text("Refused — \(refusal)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("copilot.action.\(action.id)")
    }

    /// Green for a call that happened, amber for one a rule stopped, red for one
    /// that broke. The same three meanings the rest of the app spends these
    /// colours on, so a person does not have to learn a second vocabulary for
    /// this screen.
    private var tone: Color {
        if action.wasRefused { return Theme.warning }
        if action.failed { return Theme.critical }
        return Theme.positive
    }
}
