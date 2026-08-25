/**
 * The settings of one window: whose cookies it gets, which session owns it, what
 * it looks like, and what it recorded.
 *
 * > *"When we click on three dots then we can see the settings — per window
 * > also, inside the window: settings of per window, how to connect to it, how
 * > to make it shared or isolated, all of these things should be inside of the
 * > window."*
 *
 * That sentence is the whole specification of this file. The Browser tab's home
 * lists windows and nothing else; a row's `…` carries only what you do to a
 * window from outside it — close, archive, connect to a session; and everything
 * *about* a window is here, reached from inside the window.
 *
 * ## Two placements, one implementation
 *
 * `pushed` says which. On a window the machine is casting, `MachineWindowView`
 * is the live page and this is a screen behind the `…` on its bar. On a window
 * it will not cast, there is no page to be, so this **is** the body of that
 * screen. The same cards either way — a settings screen that dropped a control
 * because of how it was reached would be two products.
 *
 * The one thing that differs is the line at the top. Where this is the body, it
 * says the machine is not offering this window for watching, because that is why
 * you are looking at cards instead of at a page. Where it is pushed, the page is
 * one Back away and saying so would be noise.
 *
 * And it says it **only when the machine advertises `watch` at all**. A host that
 * never offered a cast — every shipped build before this wave, and the public
 * demo box, which passes no `screencast` engine on purpose — is not withholding
 * anything, and a sentence about a cast there is an apology for a feature that
 * was never on the table.
 *
 * ## What is deliberately not here
 *
 * The address and the four page verbs. They are on `MachineWindowView`'s bar,
 * where a browser keeps them and where the page they act on is. Drawing them
 * here as well would be two sets of the same four buttons on two screens, which
 * is exactly how the Browser tab ended up with two lists of one thing.
 *
 * ## The two screenshots are deliberately not one control
 *
 * > *"creating a screenshot and sending it to the session, whatever session we
 * > want to send."*
 *
 * Photographing a window to **look at it here** and photographing it to **hand
 * it to an agent** are different acts with different outcomes: the first answers
 * with a picture and the second answers with the window list and a notice,
 * because the picture went to the session rather than to the phone. Collapsing
 * them into one button with a destination picker behind it would make the common
 * case — look at it — a two-step, and would hide the fact that the interesting
 * case is the one where this phone receives nothing at all.
 *
 * The session picker is therefore on that card rather than a screen away, which
 * is what his sentence asks for: *whatever session we want to send*.
 *
 * ## It holds an id, never a window
 *
 * Every verb on this family answers with the **whole** window list, so a
 * `MachineWindow` captured when this screen appeared is stale the moment
 * anything on it is pressed — a binding made here would leave the slot badge
 * showing the old answer. The id is stable and the row is looked up on every
 * redraw.
 *
 * Nothing here dismisses itself either, including Close: `MachineWindowView`
 * owns the single watcher that pops the pair of them when the window leaves the
 * machine's list. One watcher, because two would race to pop the same stack.
 */

import SwiftUI
import UIKit

struct MachineWindowSettingsView: View {
    let model: DeckModel
    let windowID: String
    /// Whether this is its own screen, pushed from the `…` on a window that is
    /// being cast — or the body of the window's screen, on one that is not. See
    /// the header.
    let pushed: Bool

    /// The optional line that travels with a screenshot handed to a session.
    /// Cleared on send, unlike an address field: it describes *that* picture, so
    /// leaving it standing would attach last shot's sentence to the next one.
    @State private var shotNote = ""

    /// The decoded picture, held rather than decoded in `body`.
    ///
    /// `UIImage(data:)` on a full-page PNG is milliseconds, and `body` runs on
    /// every keystroke in the note field — so decoding there is a decode per
    /// character for a picture that has not changed. Refreshed from the stamp
    /// below, which is cheap to compare; `MachineShot` is `Equatable` over its
    /// raw `Data`, so watching the value itself would be a byte-for-byte compare
    /// of a megabyte on every redraw.
    @State private var picture: UIImage?

    private var host: HostLink? { model.current }
    private var state: MachineBrowserState? { host?.machineBrowser }
    private var window: MachineWindow? { state?.windows.first { $0.id == windowID } }
    private var sessions: [WindowSession] { state?.sessions ?? [] }
    private var steps: [RecordedStep] { host?.machineSteps[windowID] ?? [] }

    /// Whether this machine will cast a window back at all — a different
    /// capability from the one every control here is gated on, negotiated in a
    /// different field of `RemoteEndpointOptions`. Asked of the connection as
    /// well as of the welcome, the way `HostLink.canDriveBrowser` is.
    private var canWatch: Bool { model.connection.isLive && host?.watch.offered == true }

    /// The last picture, if it is a picture of **this** window. One shot is held
    /// per machine, so a screenshot taken of another window while this screen was
    /// open would otherwise be drawn here under this window's name.
    private var shot: MachineShot? {
        guard let held = host?.machineShot, held.id == windowID else { return nil }
        return held
    }

    /// Identity of the held shot, for change detection. See `picture`.
    private var shotStamp: String? {
        shot.map { "\($0.id)@\($0.at)" }
    }

    var body: some View {
        screen
            .onAppear {
                // Steps have no push and are not carried on the window list, so
                // the only way to know what a recording has collected is to ask.
                // Asked on arrival rather than only when a recording stops,
                // because a window may already have been recording for ten
                // minutes before anybody opened this screen.
                host?.readMachineSteps(windowID)
                refreshPicture()
            }
            /*
             * A recording that has just stopped has steps worth reading, and
             * nothing else will say so: `.record.off` answers with the window
             * list, which carries `recording: false` and not a single step.
             * Watched as a transition rather than polled — the flag going false
             * is the event.
             */
            .onChange(of: window?.recording) { was, now in
                if was == true && now == false { host?.readMachineSteps(windowID) }
            }
            .onChange(of: shotStamp) { _, _ in refreshPicture() }
    }

    /// The title belongs to whichever screen this is. Pushed, it names what is
    /// behind the `…`; inline, `MachineWindowView` has already named the window
    /// and a second title would overwrite it with a less useful one.
    @ViewBuilder
    private var screen: some View {
        if pushed {
            /*
             * The machine's last word, and it is drawn **only here** when this
             * is a screen of its own.
             *
             * The one outcome no redraw can show is a picture that went to a
             * session rather than to this phone — and the control that does that
             * is on this screen, so the sentence has to be on this screen too.
             * Pushed over the live page, the window's own banner is underneath
             * and invisible; inline, that banner is directly above these cards
             * and a second copy would be the same line twice.
             */
            VStack(spacing: 0) {
                if let notice = state?.notice, !notice.isEmpty {
                    Banner(text: notice, tone: .neutral)
                        .accessibilityIdentifier("browser.machine.window.settingsNotice")
                }
                content
            }
            .background(Theme.background)
            .navigationTitle("Window settings")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cards
                TabBarClearance()
            }
            .padding(.horizontal, 16)
            .padding(.top, pushed ? 12 : 4)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var cards: some View {
        if let window {
            notWatchable
            isolationCard(window)
            sessionCard(window)
            screenshotCard
            recordingCard(window)
            closeCard(window)
        } else {
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .accessibilityIdentifier("browser.machine.window.settingsLoading")
        }
    }

    /* ---- why there is no picture, when there is a reason ------------------- */

    /**
     * One line, drawn only where it answers a question somebody is holding.
     *
     * The question is *why am I looking at settings instead of at the page*, and
     * it only exists in the inline shape on a machine that does cast other
     * windows. See the file header for the two conditions and why each is
     * separate.
     *
     * A sentence rather than a disabled Watch row. It is a real state and not a
     * fault — a server lists a window opened from the phone's own `+` under
     * `browser.window.rows` and not under `browser.surfaces` — and the ⓘ carries
     * the why, so the line itself stays one line.
     */
    @ViewBuilder
    private var notWatchable: some View {
        if !pushed && canWatch {
            SchemeSectionCaption(
                "Live",
                about: "watching a window",
                info: "The machine streams a page as pictures and sends your taps, swipes and typing "
                    + "back to it. Not every window can be streamed: a server offers its own front "
                    + "tab and the windows its sessions hold, and one opened from the + here can be "
                    + "driven without being watched.")

            SchemeGroup {
                plainNote("This machine is not offering this window for watching.",
                          id: "browser.machine.window.notWatchable")
            }
        }
    }

    /* ---- shared or its own jar --------------------------------------------- */

    /**
     * Which jar this window's cookies land in, and the one control that moves it.
     *
     * *"Making a browsing session into an isolated or shared one."* It is
     * convertible in both directions and the word on the button is the
     * destination rather than the state, because the state is already the line
     * beside it — a button saying "Isolated" next to a label saying "Shared" is
     * two readings of the same word and somebody will press it to find out.
     *
     * The choice is also offered at the moment a window is opened, on the
     * Browser tab's `+`, and that is not a duplicate control: a login typed into
     * a window that turned out to be shared is already in the machine's jar by
     * the time anybody thinks to convert it, so the choice has to exist before
     * the window does *and* after.
     */
    @ViewBuilder
    private func isolationCard(_ window: MachineWindow) -> some View {
        SchemeSectionCaption(
            "Isolation",
            about: "isolated windows",
            info: "A shared window uses the machine's own profile — its cookies and whatever it is "
                + "signed into. An isolated one gets a partition of its own, and that partition is "
                + "thrown away when the window closes.")

        SchemeGroup {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(window.isolated ? "Isolated" : "Shared")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                    if let profile = window.profile, !profile.isEmpty, !window.isolated {
                        Text(profile)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    host?.actOnMachineWindow(windowID, window.isolated ? .share : .isolate)
                } label: {
                    Text(window.isolated ? "Make shared" : "Make isolated")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("browser.machine.window.isolation")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }

    /* ---- which session owns it --------------------------------------------- */

    /**
     * *"How to connect to it"* — the headline of this screen, and the reason
     * this family exists at all.
     *
     * > *"We don't have an option to connect any browsing window to any session,
     * > so the session knows which browsing window it is working on."*
     *
     * The desktop has had this since `src/main/browser-binding.ts`; what the
     * phone lacked was a way to press it. A bound window gets a slot name — `B1`,
     * `B2` — and the session's tools address it by that name, which is why the
     * slot is drawn as an identifier rather than as a status: it is the word
     * appearing in that agent's transcript.
     *
     * It is also on the row's `…` on the home, deliberately, because attaching is
     * one of the three things he named as a thing you do to a window *from the
     * outside*. Both reach the same verb with the same picker.
     */
    @ViewBuilder
    private func sessionCard(_ window: MachineWindow) -> some View {
        SchemeSectionCaption(
            "Session",
            about: "window binding",
            info: "A bound window gets a slot name — B1, B2 — and the session's tools address it by "
                + "that name. A session that already holds three windows names the next one B4.")

        SchemeGroup {
            if let slot = window.slot {
                HStack(spacing: 10) {
                    MachineWindowMark(text: slot, tone: Theme.accent)
                    Text(MachineBrowserText.owner(window) ?? "A session")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button {
                        host?.bindMachineWindow(windowID, to: nil)
                    } label: {
                        Text("Detach")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.critical)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("The session stops being able to reach this window")
                    .accessibilityIdentifier("browser.machine.window.detach")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }

            if !sessions.isEmpty {
                if window.isBound { rowDivider(inset: 16) }
                Menu {
                    ForEach(sessions) { session in
                        Button {
                            host?.bindMachineWindow(windowID, to: session.id)
                        } label: {
                            Label(MachineBrowserText.sessionRow(session),
                                  systemImage: session.id == window.session ? "checkmark" : "terminal")
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.system(size: 17, weight: .light))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24)
                        Text(window.isBound ? "Attach to another session" : "Attach to a session")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("browser.machine.window.attach")
            } else if !window.isBound {
                // No control at all rather than a picker with nothing in it: a
                // machine running no sessions has nowhere to bind, and the fix
                // is a session rather than anything on this screen.
                plainNote("No sessions on the machine.", id: "browser.machine.window.noSessions")
            }
        }
    }

    /* ---- what it looks like ------------------------------------------------ */

    /**
     * Photograph it, and choose who gets the photograph.
     *
     * Two controls, because they have two outcomes — see the file header. The
     * note travels only with the second, so it is drawn only when there is a
     * session to send to; a field whose contents can never leave the phone is a
     * control that cannot act.
     */
    @ViewBuilder
    private var screenshotCard: some View {
        SchemeSectionCaption("Screenshot")

        SchemeGroup {
            if !sessions.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 24, height: 26)
                    TextField("Note for the session (optional)", text: $shotNote)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.primary)
                        .submitLabel(.done)
                        .accessibilityIdentifier("browser.machine.window.shotNote")
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 10)

                rowDivider(inset: 16)
            }

            HStack(spacing: 0) {
                Button {
                    host?.shotMachineWindow(windowID)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "camera")
                            .font(.system(size: 17, weight: .medium))
                        Text("Screenshot")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Takes a picture of this window and shows it here")
                .accessibilityIdentifier("browser.machine.window.shot")

                if !sessions.isEmpty {
                    Menu {
                        ForEach(sessions) { session in
                            Button {
                                send(to: session.id)
                            } label: {
                                Label(MachineBrowserText.sessionRow(session), systemImage: "terminal")
                            }
                        }
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "paperplane")
                                .font(.system(size: 17, weight: .medium))
                            Text("Send to a session")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Send a screenshot to a session")
                    .accessibilityIdentifier("browser.machine.window.shotTo")
                }
            }
            .padding(.vertical, 12)

            if let picture {
                rowDivider(inset: 16)
                VStack(alignment: .leading, spacing: 8) {
                    /*
                     * Drawn at whatever width the card gives it, aspect kept.
                     *
                     * A machine's window is far wider than a phone, so this is a
                     * thumbnail of a desktop page and it is deliberately not
                     * zoomable: the point of looking at it here is *did the page
                     * do the thing*, and the point of the control beside it is
                     * that the agent gets the full-size picture rather than this
                     * phone squinting at one.
                     */
                    Image(uiImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.hairline))
                        .accessibilityLabel("Screenshot of \(window?.label ?? "this window")")
                        .accessibilityIdentifier("browser.machine.window.picture")

                    if let line = SessionDetails.activityLine(shot?.at) {
                        Text("Taken \(line)")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
        }
    }

    /* ---- what it recorded -------------------------------------------------- */

    /**
     * The click flow, and the fact that it is running.
     *
     * *"Recording the clicks flow"* is the one control on this screen with a
     * state somebody can walk away from, so it says so twice — the word on the
     * button changes, and a red mark sits beside it — and the row on the Browser
     * tab's home says it a third time. A page quietly collecting every
     * interaction is not something to learn about by opening a screen.
     *
     * `readMachineSteps` is the only way to see what was collected: the steps are
     * not on the window list and there is no push for them. So they are asked for
     * on arrival, again the moment a recording stops, and on the control beside
     * the toggle — which is the honest answer for a flow that is still growing
     * while somebody is looking at it.
     */
    @ViewBuilder
    private func recordingCard(_ window: MachineWindow) -> some View {
        SchemeSectionCaption("Click flow")

        SchemeGroup {
            HStack(spacing: 12) {
                Button {
                    host?.actOnMachineWindow(windowID, window.recording ? .recordOff : .recordOn)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: window.recording ? "stop.circle" : "record.circle")
                            .font(.system(size: 19, weight: .light))
                            .frame(width: 24)
                        Text(window.recording ? "Stop recording" : "Record the click flow")
                            .font(.system(size: 16))
                    }
                    .foregroundStyle(window.recording ? Theme.critical : Theme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("browser.machine.window.record")

                Spacer(minLength: 8)

                if window.recording {
                    MachineWindowMark(text: "Recording", tone: Theme.critical)
                        .accessibilityHidden(true)
                }

                Button {
                    host?.readMachineSteps(windowID)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 34, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Read the steps again")
                .accessibilityIdentifier("browser.machine.window.steps.refresh")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !steps.isEmpty {
                let first = steps.first?.at ?? 0
                ForEach(steps) { step in
                    rowDivider(inset: 16)
                    stepRow(step, from: first)
                }
            } else if window.recording {
                rowDivider(inset: 16)
                plainNote("Nothing yet.", id: "browser.machine.window.noSteps")
            }
        }

        /*
         * The cut, for the same reason and with the same limit as the window
         * list's: `WireCodec.recordedSteps` takes a `prefix` and keeps no record
         * of what it dropped, so this can say there may be more and cannot say
         * how many. The host caps its own side as well — see `MAX_STEPS` in
         * `src/main/browser-steps.ts` — which is the cap somebody would actually
         * hit first.
         */
        if steps.count >= MachineBrowserWire.maxSteps {
            HStack(spacing: 6) {
                Text("Showing the first \(MachineBrowserWire.maxSteps)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                InfoDot(
                    about: "the step limit",
                    text: "This phone draws \(MachineBrowserWire.maxSteps) steps of a flow. The "
                        + "recording on the machine is not truncated by what is shown here.")
            }
            .padding(.top, 12)
            .padding(.leading, 4)
            .accessibilityIdentifier("browser.machine.window.stepsCapped")
        }
    }

    /**
     * One step: when, what, and to what.
     *
     * The offset is relative to the first step rather than a clock time, because
     * a flow is read as a sequence — *click, type, click, submit* — and the
     * useful question about step nine is how long after step one it happened.
     * `at` is the machine's main-process clock in epoch milliseconds, stamped
     * there rather than by the page: *"the page never gets to stamp its own
     * steps"* (`src/main/browser-steps.ts`).
     */
    private func stepRow(_ step: RecordedStep, from first: Double) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(offset(step, from: first))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.faint)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    MachineWindowMark(text: step.kind, tone: Theme.secondary)
                    if let detail = step.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if let value = step.value, !value.isEmpty {
                    Text(value)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                if let selector = step.selector, !selector.isEmpty {
                    // Truncated in the middle: a selector's two ends are the tag
                    // and the thing that makes it unique, and the wrapper chain
                    // between them is the part nobody reads on a phone.
                    Text(selector)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("browser.machine.window.step.\(step.index)")
    }

    /* ---- and the end of it ------------------------------------------------- */

    /**
     * Close the window, from inside it.
     *
     * Last, alone, and away from everything else on the screen, because it is
     * the one control here that ends something. It is also on the home's row —
     * on the `…` and on the swipe — which is not a duplicate: closing a window
     * you are looking at and closing one from a list are two different moments,
     * and the list's whole point is not having to open a window to deal with it.
     *
     * Nothing is dismissed on the press. `MachineWindowView` watches for the
     * window leaving the machine's list and pops both screens then — see this
     * file's header on why that watcher is not also here.
     */
    @ViewBuilder
    private func closeCard(_ window: MachineWindow) -> some View {
        SchemeSectionCaption("Window")

        SchemeGroup {
            Button {
                host?.actOnMachineWindow(windowID, .close)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 19, weight: .light))
                        .frame(width: 24)
                    Text("Close this window")
                        .font(.system(size: 16))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.critical)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Closes \(window.label) in \(model.theMachine)'s browser")
            .accessibilityIdentifier("browser.machine.window.close")
        }
    }

    /// `+1.2s` from the start of the flow, and nothing at all when either stamp
    /// is missing — a step drawn as `+0.0s` because the machine sent no time is
    /// a number somebody would read as a fact.
    private func offset(_ step: RecordedStep, from first: Double) -> String {
        guard step.at > 0, first > 0, step.at >= first else { return "" }
        let seconds = (step.at - first) / 1000
        guard seconds.isFinite else { return "" }
        return seconds < 10 ? String(format: "+%.1fs", seconds) : "+\(Int(seconds))s"
    }

    // MARK: - Actions

    private func send(to session: String) {
        let line = shotNote.trimmingCharacters(in: .whitespacesAndNewlines)
        host?.shotMachineWindow(windowID, to: session, note: line.isEmpty ? nil : line)
        shotNote = ""
    }

    private func refreshPicture() {
        guard let data = shot?.png, !data.isEmpty else {
            picture = nil
            return
        }
        picture = UIImage(data: data)
    }

    // MARK: - Chrome

    /**
     * A line of prose as a row inside a card.
     *
     * The identifier goes on the **text**, never on the card around it: an
     * `accessibilityIdentifier` on a container makes that container an
     * accessibility element and everything inside it stops existing — measured
     * on iOS 26.4, and written down in `TabNavigation.swift`.
     */
    private func plainNote(_ text: String, id: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(id)
    }

    /// 16 rather than a list row's 52: the rows in these cards have no icon
    /// column to line a divider up under.
    private func rowDivider(inset: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}
