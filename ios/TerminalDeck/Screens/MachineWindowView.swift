/**
 * One window of the machine's browser — **the window itself**, with a browser's
 * bar under it and everything else behind its `…`.
 *
 * ## What this screen used to be, and why it is the page now
 *
 * It was a stack of cards: a Live row that pushed a viewer, an address, four
 * page verbs, an isolation control, the session binding, two screenshots and the
 * click recorder. Every one of those is still reachable and only one of them is
 * on this screen. Asad, after the Browser tab was rebuilt:
 *
 * > *"we should be able just to see only the open windows, and then we can just
 * > click on any of them… When we click on three dots then we can see the
 * > settings — per window also, inside the window: settings of per window, how
 * > to connect to it, how to make it shared or isolated, all of these things
 * > should be inside of the window."*
 *
 * Tapping a window gives you the window. Its settings are behind a `…` **on this
 * screen**, which is the sentence's second half — *inside of the window* — and
 * they are `MachineWindowSettingsView`.
 *
 * ## Two shapes, because the two capabilities come apart
 *
 * `browser.control` (drive it) and `watch` (see it) are negotiated in different
 * fields of `RemoteEndpointOptions` and withheld on different grants, so a
 * machine can offer either without the other and this screen has to be honest in
 * both directions:
 *
 *  - **The machine is casting this window** — the body is the live picture,
 *    full-bleed, and the `…` on the bar leads to the settings. This is the
 *    ordinary shape.
 *  - **It is not** — the body *is* the settings, and there is no `…` on the bar,
 *    because a menu leading to the screen you are already looking at is the
 *    worst kind of dead control. A line at the top of it says the machine is not
 *    offering this window for watching, and only when the machine advertises
 *    `watch` at all: on a host that never offered a cast, a sentence about one
 *    is an apology for a feature that was never on the table.
 *
 * The second case is not an error and it is not rare. A server lists a window
 * opened from the Browser tab's `+` under `browser.window.rows` and **not**
 * under `browser.surfaces`: it is minted through `openForSession(NO_SESSION)`
 * and detached in the same breath, so it holds no binding row and `castWindows`
 * cannot see it. `src/headless/host.ts` records that as the honest state — *"a
 * row that refuses when it is tapped"* being the thing it is avoiding.
 *
 * ## Whether it can be watched is an exact id match, never a guess
 *
 * A surface is named by the **shell tab id** — the same string this screen is
 * addressed by, chosen in `screencast-host.ts` so *"the two lists can be joined
 * without a second mapping"*. So the question is asked against what the machine
 * actually listed, and a viewer is never pointed at a name the host does not
 * know (which would be a canvas waiting forever for a frame nobody is sending).
 *
 * ## It holds an id, never a window
 *
 * Every verb on this family answers with the **whole** window list, so a
 * `MachineWindow` captured when this screen was pushed is stale the moment
 * anything on it is pressed. The id is stable and the row is looked up on every
 * redraw, which is also what makes the close case free: the window leaves the
 * list and this screen leaves the stack.
 *
 * ## The address field is seeded, not bound
 *
 * A two-way binding to the window's URL would fight the page: every navigation
 * pushes a new address and would rewrite the field under a thumb mid-word. So it
 * is seeded once and re-seeded on a real navigation **only while nobody is
 * typing**, which is the one rule that makes an address bar over a wire behave
 * like an address bar.
 *
 * ## Why the bar carries the page verbs and the settings screen does not
 *
 * Because they are the same four verbs and drawing them twice is how two screens
 * end up disagreeing. They belong with the address, and the address belongs
 * under the page — that is what a browser is. What is left for the settings is
 * everything that is *about the window* rather than about the page it happens to
 * be showing: the jar its cookies land in, the session that owns it, the picture
 * and the recorder.
 */

import SwiftUI

struct MachineWindowView: View {
    let model: DeckModel

    /// Which window. See the header for why this is an id and not the window.
    let windowID: String

    @State private var address = ""
    /// Whether the field has been filled from the window at least once. A window
    /// whose row has not landed yet has no URL to seed with, and seeding from
    /// the empty string would look like an address bar that cleared itself.
    @State private var seeded = false

    /// Whether the bar is in its other mode: typing **into the page** rather
    /// than into the address. One bar with two jobs rather than two bars, which
    /// over a full-bleed canvas is the difference between a browser and a
    /// control panel.
    @State private var typingIntoPage = false
    @State private var pageText = ""

    /// Whether the window's settings are pushed. A `Bool` rather than a
    /// destination value because there is exactly one thing this screen pushes.
    @State private var showingSettings = false

    @FocusState private var focus: Field?

    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable { case address, page }

    private var host: HostLink? { model.current }
    private var state: MachineBrowserState? { host?.machineBrowser }
    private var window: MachineWindow? { state?.windows.first { $0.id == windowID } }

    /// Whether this machine will cast a window back at all. Asked of the
    /// connection as well as of the welcome, the way `HostLink.canDriveBrowser`
    /// is: a capability from the welcome of a socket that has since gone is a
    /// permission nobody can use.
    private var canWatch: Bool { model.connection.isLive && host?.watch.offered == true }

    /// The cast of *this* window, when the machine is offering one. Derived on
    /// every redraw rather than passed in: `browser.surfaces.rows` is pushed
    /// when the strip moves, and a value captured at push time would go on
    /// saying whatever was true then.
    private var liveSurface: BrowserSurfaceRow? {
        guard canWatch else { return nil }
        return host?.watch.surfaces.first { $0.window == windowID }
    }

    /// The window is gone from a list that **has** landed — closed here, closed
    /// at the machine, or closed by the session that owned it. Nil state is *not
    /// asked yet* and is not the same fact.
    private var closed: Bool { state != nil && window == nil }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // The one outcome no redraw can show: a picture that went to a
                // session rather than to this phone, or an address the machine
                // refused. See `HostLink.shotMachineWindow`.
                if let notice = state?.notice, !notice.isEmpty {
                    Banner(text: notice, tone: .neutral)
                        .accessibilityIdentifier("browser.machine.window.notice")
                }

                stage
            }
        }
        .navigationTitle(window?.label ?? "Window")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bar }
        /*
         * The tab bar's floating pill would sit over the bar below, and over the
         * bottom of the page above it. This is the surface `DeckChrome` calls
         * `localhostPage` — *"a page from the machine"*, the whole thing you came
         * for, full height — and `DeckModel.localhostPageIsOpen` is the flag the
         * `TabView` reads. It exists for exactly this and it is set from the two
         * screens that are that surface: the tunnel page, and this.
         *
         * Cleared on the way out rather than by whoever comes next, so a Back
         * from anywhere — the chevron, the edge swipe, a window closing under us
         * — leaves the tab bar restored.
         */
        .onAppear {
            model.localhostPageIsOpen = true
            seed()
            // The surface list, for the one question this screen is shaped by.
            // `read()` rather than `ensureRead()`: nothing pushes
            // `browser.surfaces` unsolicited — `server.ts` has no
            // `surfacesChanged` — so a once-per-connection ask would answer
            // *this window is not castable* about a window that had become
            // castable since. See `WatchLink.read`.
            host?.watch.read()
        }
        .onDisappear { model.localhostPageIsOpen = false }
        .onChange(of: window?.url) { _, _ in seed() }
        /*
         * Leave when the window does.
         *
         * Not optimistic: nothing is dismissed when Close is *pressed*, only
         * when the list comes back without this window in it. The machine is
         * entitled to refuse — a window a session has taken over, one that had
         * already gone — and a screen that popped on the press would leave
         * somebody looking at a list that still has the window in it, wondering
         * which of the two is right.
         *
         * One watcher for both shapes and for the settings screen too: Close
         * lives over there, and this is what pops the pair of them.
         */
        .onChange(of: closed) { _, gone in
            if gone { dismiss() }
        }
        .navigationDestination(isPresented: $showingSettings) {
            MachineWindowSettingsView(model: model, windowID: windowID, pushed: true)
        }
    }

    // MARK: - What is on the screen

    @ViewBuilder
    private var stage: some View {
        if host?.canDriveBrowser != true {
            /*
             * Reachable, and not a dead end drawn on purpose. The Browser tab
             * pushes this screen only for a machine that advertised
             * `browser.control`; what does happen is a machine dropping off — or
             * coming back as a guest — while the screen is already up.
             */
            note("This machine is not offering its browser.",
                 id: "browser.machine.window.unavailable")
                .padding(.horizontal, 16)
                .padding(.top, 20)
            Spacer(minLength: 0)
        } else if let watch = host?.watch, let surface = liveSurface {
            // The page, at the only size a desktop page is a thing a fingertip
            // can hit. Exactly one canvas exists in this app — `WatchStage`'s
            // header argues why it cannot be two — and this is one of its two
            // mounts.
            WatchStage(watch: watch, window: surface.window)
                .accessibilityIdentifier("browser.machine.window.stage")
        } else if window != nil {
            MachineWindowSettingsView(model: model, windowID: windowID, pushed: false)
        } else {
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("browser.machine.window.loading")
        }
    }

    /**
     * The bar a browser has: where the page is, and the four things you do to
     * it.
     *
     * Under the page rather than over it, because that is where every browser on
     * this phone puts it and because the top of a cast page is the page's own
     * chrome. It is drawn in both shapes of this screen — the address and the
     * page verbs are about the window, and the window exists whether or not the
     * machine will cast it.
     *
     * Absent entirely on a machine that has stopped offering its browser: every
     * control on it is a `browser.control` verb, and a bar of four buttons that
     * would all be refused is the definition of a control that cannot act.
     */
    @ViewBuilder
    private var bar: some View {
        if host?.canDriveBrowser == true {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)

                if typingIntoPage {
                    pageTypingRow
                } else {
                    addressRow
                }

                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)
                    .padding(.leading, 16)

                buttonRow
            }
            .background(Theme.background)
        }
    }

    private var addressRow: some View {
        HStack(spacing: 12) {
            Image(systemName: window?.isolated == true ? "eye.slash" : "globe")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.faint)
                .frame(width: 24, height: 28)
            TextField("Address", text: $address)
                .textFieldStyle(.plain)
                // Each of these is load-bearing: a URL keyboard puts the slash
                // and the dot under a thumb, autocapitalisation would send
                // "Localhost", autocorrect "local host", and the `.URL` content
                // type stops iOS offering a contact's name.
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(go)
                .focused($focus, equals: .address)
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .accessibilityIdentifier("browser.machine.window.address")
            Button(action: go) {
                Text("Go")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(typed.isEmpty ? Theme.faint : Theme.accent)
                    .padding(.leading, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Genuinely disabled rather than hidden: an empty address is not a
            // thing to send, and a button that appears the moment somebody types
            // moves the field's width under their thumb.
            .disabled(typed.isEmpty)
            .accessibilityLabel("Go to this address")
            .accessibilityIdentifier("browser.machine.window.go")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    /**
     * The same row, typing into the **page** instead of into the address.
     *
     * A phone has no hardware keyboard, so a live view you cannot type into is
     * half a browser. What is typed is pasted into the page as one `insertText`
     * and followed by an Enter key — which is what a form on a page wants and
     * what `WatchStage.send` does.
     *
     * It replaces the address row rather than sitting beside it. Two fields
     * eleven points apart, one of which navigates the window and the other of
     * which types into whatever has focus on the page, is a mistake somebody
     * makes once with a password in it.
     */
    private var pageTypingRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 28)
            TextField("Type into the page", text: $pageText)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit(sendIntoPage)
                .focused($focus, equals: .page)
                .font(.system(size: 15))
                .foregroundStyle(Theme.primary)
                .accessibilityIdentifier("browser.machine.window.type")
            Button(action: sendIntoPage) {
                Text("Send")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(pageText.isEmpty ? Theme.faint : Theme.accent)
                    .padding(.leading, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pageText.isEmpty)
            .accessibilityLabel("Send this text into the page")
            .accessibilityIdentifier("browser.machine.window.send")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    /**
     * Back, forward, reload — and, when there is a page to type into and a
     * screen of settings to open, those two as well.
     *
     * The three navigation verbs are never conditional, and that is not the
     * never-dead-click rule being bent. `MachineWindow` carries no `canGoBack`:
     * the desktop's own history state is not on this wire, so a phone that
     * disabled Back would be guessing, and the guess that is wrong in the common
     * direction — a window with history, drawn dead — is the exact defect the
     * tunnel browser's Back had for months. The verbs are all real, the host
     * refuses what it cannot do, and the answer is the list coming back.
     *
     * The other two **are** conditional, and on exactly the thing they need. The
     * keyboard types into a cast page, so it is drawn only where there is one.
     * The `…` opens the settings, which on a window with no cast are already the
     * body of this screen — and a control that leads to where you are standing
     * is worse than no control.
     */
    private var buttonRow: some View {
        HStack(spacing: 0) {
            barButton("Back", "chevron.left", id: "browser.machine.window.back") {
                host?.actOnMachineWindow(windowID, .back)
            }
            barButton("Forward", "chevron.right", id: "browser.machine.window.forward") {
                host?.actOnMachineWindow(windowID, .forward)
            }
            barButton("Reload", "arrow.clockwise", id: "browser.machine.window.reload") {
                host?.actOnMachineWindow(windowID, .reload)
            }
            if liveSurface != nil {
                barButton(typingIntoPage ? "Address" : "Keyboard",
                          typingIntoPage ? "globe" : "keyboard",
                          id: "browser.machine.window.keyboard") {
                    typingIntoPage.toggle()
                    focus = typingIntoPage ? .page : nil
                }
                barButton("More", "ellipsis", id: "browser.machine.window.settings") {
                    showingSettings = true
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func barButton(_ title: String, _ icon: String,
                           id: String, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    // MARK: - Actions

    private var typed: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func go() {
        guard !typed.isEmpty else { return }
        host?.goMachineWindow(windowID, to: typed)
        focus = nil
    }

    private func sendIntoPage() {
        guard let surface = liveSurface, !pageText.isEmpty else { return }
        let text = pageText
        pageText = ""
        WatchStage.send(text, to: surface.window)
    }

    /**
     * Fill the field from the window, unless somebody is using it.
     *
     * The guard is the whole function. Without it, a page that redirects — or a
     * single-page app that rewrites its own URL, which is most of what anybody
     * points this at — rewrites the field mid-word, and the address that gets
     * sent is half of what was typed with half of where the page went.
     */
    private func seed() {
        guard focus != .address else { return }
        guard let url = window?.url, !url.isEmpty else { return }
        guard !seeded || url != address else { return }
        address = url
        seeded = true
    }

    /**
     * A line of prose inside a card of its own, at the insets a row would have.
     *
     * The identifier goes on the **text**, never on the card around it. An
     * `accessibilityIdentifier` on a container makes that container an
     * accessibility element and everything inside it stops existing — measured
     * on iOS 26.4 and written down in `TabNavigation.swift`.
     */
    private func note(_ text: String, id: String) -> some View {
        SchemeGroup {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(id)
        }
    }
}
