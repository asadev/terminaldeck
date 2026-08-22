/**
 * The copilot, on a phone.
 *
 * Asad, holding the iOS release for this: *"We need to build a copilot in the
 * phone app too, because we need to connect the copilot also and we should be
 * able to control the copilot from the phone also."* And, settling the shape of
 * it: *"Phones will have full control over copilot, same as the actual machine
 * app."*
 *
 * That sentence used to end *"but connecting copilot will be a separate
 * connection than the sessions"*, and on 2026-08-19 he took the second half
 * back: *"instead of giving mobile app separate connection for copilot just make
 * it like if we are connecting as my device copilot automatically comes, if we
 * connect as guest then copilot don't come."* So a phone paired as one of his
 * devices arrives on this screen with nothing to do first.
 *
 * ## Where it goes: the leftmost pill
 *
 * **Copilot · Sessions · Localhost · Settings.** Said while looking at the app
 * with the copilot built and reachable, and it settles a question that had been
 * answered twice before in both directions. `DeckModel.Tab` carries the whole
 * argument; the part that belongs here is what it replaced and why the
 * replacement is better rather than merely newer.
 *
 * It was **a pinned row at the top of the Sessions tab**, pushing this screen.
 * The case for that was real: the desktop pins the copilot exactly there —
 * *"Pinned at the top of the sidebar, above the session list"* — and everything
 * the copilot is good at is a question about the rows underneath it. What that
 * argument got wrong is that those questions are asked *while looking at
 * something else*, which is precisely a thing you move between; and a row pinned
 * to one list is reachable from one screen, whereas a pill is reachable from all
 * four and carries its badge everywhere.
 *
 * The row is gone rather than kept beside the pill. Two doors to one screen, one
 * of them permanently taking the top of the list somebody opened to read their
 * sessions, is the duplication he objects to on every other page.
 *
 * ## No tab bar over the composer, and a chevron instead
 *
 * *"If we are on copilot on mobile version, now if we want to type here, the
 * pill is still there. Why is the pill there if we can type here? Either we will
 * type or we will use the pill. So pill should not be inside the chat box —
 * there should be a back button to go back on home."*
 *
 * The bar was here for exactly one reason and he has removed it: a tab that
 * hides its own tab bar has no way out, because there is no chevron over a tab's
 * root and no gesture that pops one. A back button **is** a way out. So the bar
 * goes, the composer gets the bottom of the phone to itself, and this screen
 * draws its own chevron in `.topBarLeading` calling `DeckModel.leaveCopilot()`.
 * The full argument, in the order it was argued, is on `DeckSurface.copilot`.
 *
 * That button is load-bearing in a way an ordinary back button is not: it is the
 * only way off this screen. Anything that removes or conditions it strands
 * somebody here.
 *
 * ## And the pill itself comes and goes with the device
 *
 * *"If the copilot is not connecting, this icon should not be inside the pill —
 * then it will be three icon pill. Otherwise if the copilot is connected, then
 * four icon pill, automatically."* `DeckModel.showsCopilotTab` decides.
 *
 * The consequence for this file used to be that **the connect form moved out of
 * it** — a six-digit code field behind a pill that only exists once you are
 * connected is a door locked from the inside — into a screen under Settings.
 * That screen is now deleted along with the form: there is nothing to connect,
 * so the pill follows the *device kind*, which is decided once at the machine.
 * What is left here is the conversation, plus two short screens for the states
 * either side of it.
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
 * ## Five states, and none of them is a lie
 *
 * `CopilotAccess` has five cases and this screen draws five different things.
 * Two are worth naming here.
 *
 * `.notOffered` — there is no copilot here **for this phone** — is nearly
 * unreachable, because the pill only exists when the copilot does. It is drawn
 * anyway, and it says two things in one sentence on purpose: that machine may be
 * running a build with no copilot in it, or this phone may be paired with it as
 * a guest. This end genuinely cannot tell, by design, and the case block says
 * why.
 *
 * `.notGranted` is *open, and given nothing*. It should not happen — one of his
 * own devices is granted every tier — so it is drawn as what it is: a machine
 * saying something this build did not expect, stated rather than hidden behind a
 * blank screen that would read as a bug here.
 *
 * **Three states went on 2026-08-19**, with the separate copilot connection
 * itself: *"if we are connecting as my device copilot automatically comes, if we
 * connect as guest then copilot don't come — that's all we need to do instead of
 * two different connections."* `.notConnected` was a six-digit field and a
 * sentence about where to get a code; `.credentialLost` was the same field with
 * a different opening line; and the door to both was a Settings screen that is
 * deleted. Nothing replaced them, because there is nothing left to do: the
 * copilot is simply there for one of his own devices and absent for a guest.
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

    /// The question on screen, if any — one to decide or one to go and look at.
    /// See `CopilotPrompt`, which is one type rather than two `@State`s because
    /// two sheets that can both be non-nil is two sheets that fight.
    @State private var prompt: CopilotPrompt?
    @State private var showingActivity = false
    @State private var showingSessions = false

    /// Whether the foot of the conversation is on screen. See the anchor in
    /// `timeline`, and the scroll effect that reads this.
    @State private var atBottom = true

    /// What the scroll watches: how many rows there are, and what the last one
    /// says. Both, because a streaming answer only ever moves the second.
    private var tail: String {
        let rows = link?.timeline ?? []
        guard let last = rows.last else { return "0" }
        return "\(rows.count):\(last.id):\(last.digest)"
    }

    private var host: HostLink? { model.host(hostID) }
    private var link: CopilotLink? { model.host(hostID)?.copilot }

    /// Whether this phone may see anything on this machine's copilot at all —
    /// which is what every control in the toolbar needs, since both of the lists
    /// behind it are read-tier.
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
             * **The way home, and the only one.**
             *
             * *"Pill should not be inside the chat box — there should be a back
             * button to go back on home."* This screen has no tab bar under it,
             * so this chevron is the entire exit: no pill to tap, no chevron
             * supplied by a `NavigationStack` because this is a stack's root,
             * and no pop gesture for the same reason.
             *
             * It is drawn unconditionally, in every access state, for that
             * reason alone. A version of this that appeared only when connected
             * — which is tempting, because the pill itself works that way —
             * would strand somebody on the one screen where being stranded is
             * possible.
             *
             * `leaveCopilot()` goes to whichever tab the copilot was entered
             * from, defaulting to the session list. See `DeckModel.homeTab` for
             * why that is not simply "the sessions": somebody who tapped the
             * pill while reading their ports means Localhost by *home*.
             */
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.leaveCopilot()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("Back")
                .accessibilityIdentifier("copilot.back")
            }
            /*
             * Which machine's copilot, in the slot the other two tabs use for
             * the same question.
             *
             * It arrived with the pill. While this screen was pushed from the
             * session list, the machine was decided one screen back and carried
             * in the route; a tab has no route, so *which machine am I talking
             * to* is exactly as open a question here as *whose ports are these*
             * is on Localhost — and it must not be answered by a screen that
             * cannot be asked. The control is the same one, so the connection
             * pill under it cannot disagree with the pill on the other tabs
             * either.
             *
             * With one machine paired it falls back to the screen's own name
             * rather than the product's, which is what `singleHostTitle` is for.
             */
            ToolbarItem(placement: .principal) {
                HostSwitcher(model: model, singleHostTitle: "Copilot")
            }
            /*
             * No overflow for a phone that may not watch.
             *
             * Both lists on it are `read` — the action log and the sessions the
             * copilot started — so on the not-connected screen they were two
             * taps that could only open an empty sheet. Caught by looking at the
             * screen rather than by a test: the not-granted case renders a
             * sentence explaining that this phone has been given nothing, with a
             * menu beside it offering it two things anyway.
             */
            if isWatching {
                ToolbarItem(placement: .topBarTrailing) { menu }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { banners }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .sheet(item: $prompt) { showing in
            switch showing {
            case let .decide(question):
                CopilotConsentSheet(question: question,
                                    settlement: link?.settlement(for: question.id),
                                    machine: host?.label ?? "that machine",
                                    noun: host?.hostPlatform.noun ?? "desktop",
                                    answer: { approved in
                                        // The sheet stays up until the desktop
                                        // says the question is settled, so the
                                        // person sees where their answer landed
                                        // rather than watching it vanish — and
                                        // it is told whether the frame actually
                                        // went, because a sheet that dimmed its
                                        // buttons over a dead socket would be a
                                        // consent prompt that looks answered and
                                        // is not.
                                        link?.answer(question.id, approved: approved) ?? false
                                    },
                                    dismiss: {
                                        link?.dismissSettled(question.id)
                                        prompt = nil
                                    })
            case let .watch(question):
                CopilotWatchSheet(question: question,
                                  machine: host?.label ?? "that machine",
                                  noun: host?.hostPlatform.noun ?? "desktop") { prompt = nil }
            }
        }
        .sheet(isPresented: $showingActivity) {
            CopilotActivitySheet(model: model, hostID: hostID) { showingActivity = false }
        }
        .sheet(isPresented: $showingSessions) {
            CopilotSessionsSheet(model: model, hostID: hostID) { showingSessions = false }
        }
        /*
         * A confirmation raises itself.
         *
         * It has a two-minute deadline and it expires into a **refusal**, so a
         * question that waited politely behind a row somebody had to notice
         * would be a question that mostly times out. There is no push in this
         * product — `SessionAlerts` says so plainly — which means this frame
         * only ever arrives while the app is open in somebody's hand, and that
         * is exactly the moment putting it in front of them costs nothing.
         *
         * Keyed on the ids rather than the count, so a question replaced by
         * another between two redraws still opens the new one.
         */
        .onChange(of: (link?.asked ?? []).map(\.id).joined(separator: ",")) { _, _ in
            raisePendingDecision()
        }
        .onAppear { raisePendingDecision() }
    }

    /// Put the oldest unanswered question on screen, if nothing else is there.
    /// Nothing is stolen from a sheet already up: interrupting somebody reading
    /// one confirmation with another is how both get answered without being
    /// read.
    private func raisePendingDecision() {
        guard prompt == nil,
              let question = link?.asked.first(where: { link?.settlement(for: $0.id) == nil })
        else { return }
        prompt = .decide(question)
    }

    // MARK: - The body, per access

    @ViewBuilder
    private var content: some View {
        switch host?.copilotAccess ?? .notOffered {
        case .notOffered:
            /*
             * **Two situations, one sentence, on purpose.**
             *
             * This screen is nearly unreachable — the pill only exists when the
             * copilot does — and the way in is the switcher in the title, or a
             * machine taking the copilot away while somebody is standing here.
             * Either way there are two things it can mean and this end cannot
             * tell them apart: that machine's build has no copilot in it, or
             * this phone is paired with it as a **guest**. Both send a
             * capability list without the name and a `welcome` without the
             * field, deliberately — `server.ts` strips it for a guest rather
             * than refusing the verbs, because *"a tab that refuses on every
             * press is a worse answer than a client that never knew."*
             *
             * So it says both, plainly, rather than picking one and being wrong
             * half the time. Naming the guest case is not a hint about how to
             * get around it: changing what kind of device this is happens at the
             * machine, on the approval screen, by the person sitting at it — and
             * *"the copilot is never shared"* is his rule, in his words, printed
             * on that screen.
             */
            ContentUnavailableView {
                Label("No copilot here", systemImage: "sparkles")
            } description: {
                Text("There is no copilot on \(host?.label ?? "that machine") for this phone. "
                     + "Either that \(hostNoun) is running a version of \(Brand.name) without "
                     + "one, or this phone is paired with it as a guest — the copilot is only "
                     + "there for your own devices, and which one this is decided at the machine "
                     + "when the phone was approved.")
            }
            .accessibilityIdentifier("copilot.notOffered")

        case .connecting:
            /*
             * **The conversation survives a reconnect.**
             *
             * `.connecting` is every socket blink — the hello has gone and has
             * not been answered — and this used to replace the whole screen with
             * a spinner. So a phone that lost its network for two seconds in a
             * lift watched the entire conversation disappear and come back,
             * which is the *"the chat blanks"* this pass exists to fix, and it
             * is a lie on top of a flicker: what was said was still said, and a
             * dropped socket does not unsay it.
             *
             * So the spinner is only for a phone that has nothing to show. With
             * a conversation in hand the timeline stays exactly where it is and
             * the reconnect is a strip above it — `reconnecting` — which is
             * where a fact about *now* belongs.
             */
            if (link?.timeline.isEmpty ?? true) {
                connectingScreen
            } else {
                timeline
            }

        case .notGranted:
            notGranted

        case .watch, .direct:
            timeline
        }
    }

    /// The socket is down or the hello is unanswered, said over a conversation
    /// that is still on screen. A line rather than a screen, because nothing
    /// here is lost — only paused.
    private var reconnecting: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Theme.faint)
            Text(model.connection.isLive
                 ? "Opening the copilot again\u{2026}"
                 : "Waiting for \(host?.label ?? "that machine") to come back.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .accessibilityIdentifier("copilot.reconnecting")
    }

    /*
     * **`notConnectedHere(lostCredential:)` used to be here, and both of its
     * states are gone.**
     *
     * It drew *"Copilot not connected — it takes a six-digit code from that
     * desktop"*, with a button pushing the connect form in Settings, and a
     * variant for a phone whose stored key had been lost. Neither can happen
     * now: there is no code, no key, and no state between *paired as his* and
     * *watching the copilot*. A device either has one or it does not, and both
     * answers are drawn by the two cases either side of this note.
     *
     * The observation the block ended on is worth keeping, because it is about
     * SwiftUI rather than about this feature: **naming a `ContentUnavailableView`
     * makes the container an accessibility element and everything inside it
     * stops existing**, for a UI test and for VoiceOver alike — measured on iOS
     * 26.4, where a text field plainly on screen could not be found because the
     * stack around it carried the screen's name. The three states in this file
     * that do carry an identifier get away with it because they hold nothing but
     * words. Anything with a control in it must name the control instead.
     */

    /// The credential is on its way, or the socket is down and it cannot be.
    /// Drawn as a state rather than left as an empty screen, because an empty
    /// screen with no explanation is indistinguishable from a broken one.
    private var connectingScreen: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(Theme.secondary)
            Text(model.connection.isLive
                 ? "Opening the copilot on \(host?.label ?? "that machine")…"
                 : "Waiting for \(host?.label ?? "that machine") to come back.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .accessibilityIdentifier("copilot.connecting")
    }

    /**
     * Open, and granted nothing.
     *
     * **A state nobody should be able to reach.** One of his own devices is
     * given every tier — *"My device — full access, it's you at another
     * keyboard"* — and a guest is never told the copilot exists, so a socket
     * that is *open* with an empty grant is a far end saying something this
     * build does not expect rather than a person having unticked a box. It used
     * to be ordinary: for one day there were three per-device checkboxes beside
     * a copilot connection, and this screen named them.
     *
     * It is drawn rather than hidden, because a blank screen under a pill reads
     * as a bug in this app, and it says the honest thing: the machine is
     * refusing, and the machine is where that is decided. There is deliberately
     * no button — nothing on this phone can widen its own grant, and a control
     * that changes nothing while looking like it does is the exact defect
     * `reachable.test.ts` warns about.
     */
    private var notGranted: some View {
        ContentUnavailableView {
            Label("Nothing granted here", systemImage: "lock")
        } description: {
            Text("This phone reached \(host?.label ?? "that machine")'s copilot and was given "
                 + "nothing it may do. That is unusual — a device paired as your own gets the "
                 + "copilot in full — so it is worth a look at that \(hostNoun).")
        }
        .accessibilityIdentifier("copilot.notGranted")
    }

    /// The conversation and the machinery, plus whatever is waiting.
    private var timeline: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    stateCard

                    if (host?.copilotAccess ?? .notOffered) == .connecting { reconnecting }

                    ForEach(link?.pending ?? []) { question in
                        CopilotQuestionCard(question: question,
                                            noun: host?.hostPlatform.noun ?? "desktop",
                                            // Only for a question this device
                                            // may answer *and* has the full
                                            // request for. See the card.
                                            decidable: decision(for: question) != nil) {
                            if let decision = decision(for: question) {
                                prompt = .decide(decision)
                            } else {
                                prompt = .watch(question)
                            }
                        }
                    }

                    ForEach(link?.timeline ?? []) { entry in
                        switch entry {
                        case let .message(message):
                            CopilotBubble(message: message)
                        case let .action(action):
                            CopilotActionRow(action: action)
                        case let .mine(outgoing):
                            CopilotOutgoingBubble(outgoing: outgoing)
                        }
                    }

                    if (link?.timeline.isEmpty ?? true) { nothingYet }

                    // An anchor rather than "scroll to the last row", because the
                    // last row changes identity as a streaming answer is
                    // replaced, and scrolling to a row that is being rebuilt
                    // fights the layout. A zero-height view at the foot has a
                    // stable id and always means "the bottom".
                    //
                    // It is also how this screen knows whether somebody is
                    // reading the end of the conversation: a `LazyVStack` builds
                    // and tears down its children as they cross the viewport, so
                    // "is the anchor on screen" is exactly "are we at the
                    // bottom" — and that is what stops the view yanking itself
                    // down while a person is scrolled up reading.
                    Color.clear.frame(height: 1).id(Self.bottom)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
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
            /*
             * Follows the conversation down as it **grows**, not only as it
             * lengthens — and stops following when somebody has scrolled up.
             *
             * The comment that used to sit here claimed a count key catches a
             * message being extended. It does not, and that is the exact case a
             * streaming answer is: same id, more text, **same count**. So a
             * reply longer than the screen was written entirely below the fold
             * and the view sat still through all of it. The key is now a digest
             * that moves on both — how many rows, and how long the last one is —
             * which is one integer read per frame and no allocation per token.
             *
             * `atBottom` is the other half and it is not an optimisation: a
             * timeline that jumps to the end on every frame is unusable while an
             * agent is writing and somebody is scrolled up reading what it said
             * a minute ago, which is precisely when a copilot is worth reading.
             */
            /*
             * And **unanimated**, which is the third thing that had to be right.
             *
             * A 0.2s ease on every frame of a streaming answer is an animation
             * restarted many times a second, each one interrupting the last a
             * few milliseconds in; the net movement over a whole reply is close
             * to nothing, which is a list that does not follow. Measured on the
             * Android client, which had the identical construction and the
             * identical symptom.
             *
             * Instant is also honest here: `atBottom` already guarantees the
             * reader is at the end, and staying pinned to the end of text that
             * is growing looks like text growing, because that is what it is.
             */
            .onChange(of: tail) { _, _ in
                guard atBottom else { return }
                scroll.scrollTo(Self.bottom, anchor: .bottom)
            }
            .onAppear {
                atBottom = true
                scroll.scrollTo(Self.bottom, anchor: .bottom)
            }
        }
    }

    /**
     * The full request behind a watch row, when this phone has one.
     *
     * `mine` says the desktop would *accept* an answer from this device. It does
     * not say this phone was ever sent the question, and the two come apart in a
     * case that is not rare: **there is no replay.** A phone that reconnects
     * while a confirmation is outstanding gets the watch row in
     * `copilot.pending` and no `copilot.ask`, so it holds the id and not the
     * request — and answering on an id alone is answering blind, which is the
     * reflex Yes this design exists to refuse. So the Allow button hangs off
     * having the *question*, never off `mine` by itself.
     */
    private func decision(for question: CopilotQuestion) -> CopilotConsentQuestion? {
        guard question.mine, link?.grant.canAnswer == true else { return nil }
        return link?.asked.first { $0.id == question.id }
    }

    /**
     * An empty conversation, said out loud.
     *
     * There was nothing here at all: a state card, a composer, and a screen's
     * height of black between them, which reads as a screen that failed to load
     * rather than one with nothing to show. *"Empty states must say what is
     * true."*
     *
     * Three sentences because there are three different truths, and picking one
     * of them for all three would be the *"Watching"* mistake the Android client
     * made in the same place: a run with nothing said in it is waiting for a
     * question, a machine with no run is waiting for a tap on the button
     * directly below, and a phone that may only watch is waiting for somebody
     * else entirely.
     *
     * Deliberately short. He struck out the paragraph that used to sit under the
     * Start button — *"we are not making this for the dumb people"* — and this
     * is one line, saying the one thing the blackness does not.
     */
    private var nothingYet: some View {
        Text(nothingYetLine)
            .font(.system(size: 13))
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 24)
            .accessibilityIdentifier("copilot.nothingYet")
    }

    private var nothingYetLine: String {
        if link?.state == nil {
            return "\(host?.label ?? "That machine") has not said what its copilot is doing yet."
        }
        if link?.hasRun == true {
            return "Nothing said yet. What it says and what it does both land here, in the order they happen."
        }
        if host?.copilotAccess == .direct {
            return "No conversation on this \(hostNoun) yet."
        }
        return "What the copilot says and what it does will land here, in the order they happen."
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
                VStack(alignment: .leading, spacing: 8) {
                    /*
                     * Two states, side by side, each naming its own subject.
                     *
                     * They were two sentences stacked — *"Not running at the
                     * Mac"* in 15pt semibold over *"This phone has a copilot of
                     * its own running"* — and photographed together they read as
                     * a contradiction. Both were true and about two different
                     * copilots: the one pinned at the machine, and this device's
                     * own run, which is the only one it can speak to.
                     *
                     * A chip says what it is about before it says what it is
                     * doing, so the pair cannot be read as one thing — and
                     * neither of them is a sentence, on a screen that is not
                     * allowed any.
                     */
                    HStack(spacing: 8) {
                        StateChip(subject: hostNoun.capitalized, state: deskWord(state),
                                  tone: state.deskIsRunning ? Theme.positive
                                      : state.deskIsStarting ? Theme.accent : Theme.faint)
                            .accessibilityIdentifier("copilot.status")
                        StateChip(subject: "This phone", state: state.hasRun ? "running" : "none",
                                  tone: state.hasRun ? Theme.positive : Theme.faint)
                            .accessibilityIdentifier("copilot.run")
                        Spacer(minLength: 0)
                    }

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
                    Text(grantLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .accessibilityIdentifier("copilot.grantLine")
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// The copilot at the machine, in one word. `deskIsStopped` rather than
    /// `!deskIsRunning`, because an unrecognised word from a newer desktop is
    /// neither, and printing it is more honest than calling it stopped.
    private func deskWord(_ state: CopilotState) -> String {
        if state.deskIsRunning { return "running" }
        if state.deskIsStarting { return "starting" }
        if state.deskIsStopped { return "stopped" }
        return state.desk
    }

    /**
     * What this connection may do, in outcomes rather than tier names.
     *
     * On the card rather than buried in Settings, because with three tiers the
     * difference between them is now visible in what the screen offers and a
     * person should be able to check their reading of it. The third clause is
     * the one that matters: **a confirmation that would otherwise wait at the
     * machine will appear here instead** is a thing somebody agreed to at the
     * desk, and the phone saying it out loud is how they find out it took.
     */
    private var grantLine: String {
        let grant = link?.grant ?? .none
        var parts = ["Connected"]
        if grant.canWatch { parts.append("watching") }
        if grant.canDirect { parts.append("can ask it to work") }
        if grant.canAnswer { parts.append("answers confirmations here") }
        return parts.joined(separator: " · ")
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
        case .notOffered, .connecting, .notGranted:
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
     * Not a warning and not an error — the read tier is real and it is the one
     * worth having on its own: it shows the state, the log, the sessions and the
     * refusals, and it carries no power at all. So it says what this phone *can*
     * do first.
     *
     * Like `notGranted`, it is a narrower case than it was. His own devices are
     * granted every tier, so a watch-only grant is the machine having decided
     * something this build does not expect — which is why the second sentence
     * names the machine rather than a switch to go and find.
     */
    private var watchingNote: some View {
        Text("This phone can watch the copilot. Talking to it, and letting it start work, "
             + "is something that \(hostNoun) is not allowing.")
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
     * **There was a paragraph here and it is gone.** Four lines explaining what a
     * "run" is: a second copilot process on the machine, same folder, same
     * `memory/`, own conversation. He struck out exactly this shape of writing
     * on 2026-08-20, about every screen in the product:
     *
     *   > *"Every single time you bring some card, you put something new… I said
     *   > to you, don't put any single statement in anywhere… We want simplicity.
     *   > Let the smart people use it. Smart people knows how it works. We are
     *   > not making this for the dumb people."*
     *
     * What survives is the half that is not an explanation but a **fact about
     * the tap**: it runs over there, and it spends money. That is the consent
     * this card exists to take, and two words each is enough to take it — the
     * paragraph was teaching, and nobody reads a lesson attached to a button.
     */
    private var startCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start a copilot for this phone")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text("Runs on the \(hostNoun) · spends money")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
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
     *
     * **There was a fifth item and it is gone.** *"Why do we have Close the
     * copilot here? It doesn't make any sense."* It sent `copilot.bye`, held the
     * connection shut across reconnects, and had a whole access state of its own
     * to draw; its justification was a shared device, and on a phone the thing
     * that keeps somebody else out is the lock screen rather than a menu item
     * three taps in. The two verbs below it are the ones that survive the
     * question *what does a person actually need from a phone here* — Interrupt
     * stops a turn, Stop ends the run that is spending money — and neither of
     * them touches the connection. Ending the connection is done at the machine
     * that granted it. The removal is argued at length on `CopilotLink`, where
     * the flag behind it used to be.
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

/**
 * What is on screen over the conversation: a decision, or a notice.
 *
 * One type rather than two `@State` optionals, because two of those is two
 * sheets that can both be non-nil — and SwiftUI resolves that by showing one of
 * them and quietly dropping the other, which on a consent surface would be a
 * confirmation that never appeared.
 */
private enum CopilotPrompt: Identifiable {
    /// This connection may answer it, and holds the whole request.
    case decide(CopilotConsentQuestion)
    /// Somebody else's question, or one this phone reconnected in the middle of.
    /// Watch-only: there is nothing here that settles it.
    case watch(CopilotQuestion)

    var id: String {
        switch self {
        case let .decide(question): return "d:\(question.id)"
        case let .watch(question): return "w:\(question.id)"
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Where the pinned row went                                                   */
/* -------------------------------------------------------------------------- */

/*
 * `CopilotListRow` used to be here: the copilot pinned above the sessions, with
 * a subtitle naming its state and a badge counting questions waiting on an
 * answer. It is gone, and the two things it carried have gone somewhere better.
 *
 * *"A fourth pill, and the copilot goes leftmost."* With a tab of its own, the
 * row was a second door to one screen, permanently occupying the top of the list
 * somebody opened to read their sessions — the duplication he objects to on
 * every other page of the product. So the door is the pill.
 *
 * The **badge** moved to the pill as well, and is strictly better placed there:
 * a consent question has a two-minute deadline and expires into a refusal, and
 * a badge pinned to the session list could only be seen from the session list.
 * See `DeckTabs`.
 *
 * The **subtitle** — "not connected, get a code at the Mac", "watching only",
 * "3 sessions started" — is not lost either. Every one of those sentences is the
 * screen this file draws, in full, one tap away, with the thing that fixes it
 * underneath. A one-line summary of a screen, on a row that opens that screen,
 * was only ever earning its place while the screen was hard to reach.
 */

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
                // Already stripped of the escape sequences a shell writes into
                // its own transcript — see `CopilotWire.prose`, which does it at
                // the decoder because that is the only place the `ESC` that
                // begins one still exists. Scrubbing here as well would be two
                // regex passes per redraw over the row a streaming answer is
                // extending, for nothing left to find.
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
 * Something this phone said, before the machine has said it back.
 *
 * The **same bubble** as `CopilotBubble` on the same side in the same tint, plus
 * one quiet line of status — because it is not a different message, it is this
 * message drawn early. Anything that made it a visibly different kind of row
 * would trade one confusion for another: a person would see their sentence
 * twice, once faint and once solid, with nothing saying which counted.
 *
 * The second line says *sending* while the wait is running and, when it runs
 * out, says the machine has not echoed it — **not** that it failed. The echo is
 * the agent CLI having taken the turn, not a network acknowledgement, so silence
 * means unaccounted for rather than lost, and the row must not claim a fact this
 * end does not have. What it does claim is worth having on its own: the text is
 * still on screen, selectable, so it can be copied or sent again.
 */
private struct CopilotOutgoingBubble: View {
    let outgoing: CopilotOutgoing

    var body: some View {
        HStack {
            Spacer(minLength: 40)

            VStack(alignment: .leading, spacing: 6) {
                Text(outgoing.text)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                Text(outgoing.unacknowledged
                     ? "That machine has not echoed this back."
                     : "sending\u{2026}")
                    .font(.system(size: 11))
                    .foregroundStyle(outgoing.unacknowledged ? Theme.warning : Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Theme.accent.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(outgoing.unacknowledged
                            ? "You said, not acknowledged: \(outgoing.text)"
                            : "You said, sending: \(outgoing.text)")
        .accessibilityIdentifier("copilot.sending")
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

/**
 * One copilot, and what it is doing.
 *
 * The subject is drawn first, in the quieter ink, because the subject is the
 * whole reason this is a chip rather than a line of prose: two states on one
 * screen are only readable if each says what it is about. Two sentences stacked
 * here — *"Not running at the Mac"* over *"This phone has a copilot of its own
 * running"* — were both true, about two different copilots, and read as a
 * contradiction on the screen he was looking at.
 */
private struct StateChip: View {
    let subject: String
    let state: String
    let tone: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone).frame(width: 7, height: 7)
            Text(subject)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text(state)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.surfaceHigh, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(subject): \(state)")
    }
}
