/**
 * Three screens and the rules for which one is showing.
 *
 * ## Past the gate it is a tab bar, not a list
 *
 * The third of those three used to be a bare `NavigationStack` over the session
 * list, and everything the app could do that was not "open a session" lived
 * behind a `…` in its corner. It is now `DeckTabs` — Sessions, Localhost,
 * Settings — which is where the reasoning about *which* tabs and *why only
 * three* is written down. The gate above it is unchanged: a phone that is not
 * paired, and a first machine that has not been approved, still take the whole
 * window, because a tab bar over a screen that has nothing to list is furniture.
 *
 * ## A phone with a server and no machine is past the gate
 *
 * `!model.isPaired` used to be the whole first test, and it was wrong for
 * exactly the person this product is for. Asad: *"Say no MacBook or Windows
 * exists at all — a user only has a server and a phone."* Such a phone logs in
 * to its server over SSH, which pairs nothing and mints no machine, and it would
 * then have been dropped straight back onto a screen asking it for a six-digit
 * code that no server will ever show it — with the server it had just signed
 * into unreachable behind that screen. So a server counts: one is enough to be
 * past the gate, because there is now something to manage.
 *
 * The order is a state machine, not a preference: an unpaired phone has nothing
 * to list, and a phone waiting for a human to approve it has nothing to list
 * either — the desktop sends an empty session list with the refusal, and a list
 * screen showing "No sessions" over that would describe the Mac as idle when
 * what is actually happening is that this device is not allowed to see it.
 *
 * The session list is the root of the stack rather than a destination, and a
 * deep link pushes onto it, so backing out of a session opened from the desktop
 * still lands somewhere sensible.
 *
 * ## Why the middle test is `awaitingApproval` and not `phase == .pending`
 *
 * Because they are different facts and the screen needs both. `.pending` means
 * the last attempt reached the machine and the machine said "not yet";
 * `awaitingApproval` means this device is unapproved, whether or not the last
 * attempt got anywhere. Routing on the phase alone would drop a phone whose
 * connection is failing into the session list — empty, captioned "No sessions",
 * describing an idle machine when the truth is that nothing has reached it.
 * `PendingApprovalView` handles both and says which is which.
 *
 * ## The approval screen only takes the window when there is nothing else
 *
 * With one machine paired, an unapproved device has nothing to show and the
 * approval screen is the whole app. With several, it must not be: a phone that
 * has a working Mac and has just scanned a code on a Windows PC would otherwise
 * lose the Mac behind a full-screen instruction about the PC, with no way back —
 * which is the multi-host version of "my phone forgot my Mac". Past the first
 * machine the wait is shown where every other per-machine state is shown: the
 * connection pill, the banner, and a dot in the switcher.
 */

import SwiftUI

struct RootView: View {
    @Bindable var model: DeckModel

    /**
     * The terminal's colour schemes, read here for one reason only.
     *
     * A pinned scheme has to reach the **window's** interface style while a
     * session is on screen, because that is what the system draws the status
     * bar's glyphs from and nothing on a pushed screen can state it. See the
     * `.preferredColorScheme` below. Everything else about a scheme is
     * `TerminalChrome`'s and stays there.
     */
    var themes: TerminalThemeStore = .shared

    /**
     * The one place in this app that decides what colour scheme anything is.
     *
     * `@AppStorage` rather than a `@State` mirror of a store, and the difference
     * matters here in a way it does not for `TextSize`: the control that changes
     * this is three levels down a navigation stack inside a tab, and this view
     * is above the `TabView`. `@AppStorage` is a live view of the defaults
     * database, so the picker in Settings writes and this repaints — with no
     * property threaded through four screens that do not otherwise care.
     *
     * It survives a relaunch because `UserDefaults` persists it, and it is read
     * here at first body rather than applied in `onAppear`, so the first frame
     * is already the right scheme rather than a flash of the wrong one.
     *
     * See `Appearance` for why `system` is `nil` and not a third painted value.
     */
    @AppStorage(Appearance.key) private var appearance: Appearance = .system

    var body: some View {
        Group {
            /*
             * The gate, and the one clause that keeps it alive long enough to
             * finish what it started.
             *
             * `holdingTheLoginGate` is set the moment **Log in** is pressed and
             * cleared when the person leaves the screen. Without it, succeeding
             * at the login is what destroys the login: it creates a server,
             * `hasServers` flips, and this `if` swaps the whole screen out
             * before the receipt, the Face ID offer or the check-and-install
             * step has drawn a single frame. See `DeckModel.holdingTheLoginGate`
             * — it was photographed, not reasoned about.
             */
            if (!model.isPaired && !model.hasServers) || model.holdingTheLoginGate {
                /*
                 * **The gate is the login, not the pairing code.**
                 *
                 * It was `PairingView`: a headline reading *"Pair with your
                 * Mac"*, a six-digit field, a primary Pair button, and *"Log in
                 * to a server instead"* as a small line underneath. Photographed
                 * and then indefensible — the first thing this app said to
                 * somebody opening it was that they owned a desktop computer.
                 *
                 * > *"Say no MacBook or any Windows exists at all — a user only
                 * > has a server and a phone."*
                 * > *"I want the standard way to sign in used everywhere —
                 * > server address, username, password or key."*
                 *
                 * So the login is the window and pairing is the line underneath
                 * it. Pairing is **not deleted** — it is one tap away in
                 * `ServerLoginView.pairingDoor` and it is still the right door
                 * for a machine with a screen and a person in front of it.
                 */
                ServerLoginView(model: model, isGate: true)
                    .accessibilityIdentifier("root.gate")
            } else if model.hosts.count == 1 && awaitingApproval {
                PendingApprovalView(model: model)
            } else {
                DeckTabs(model: model)
            }
        }
        .animation(.default, value: model.isPaired)
        .animation(.default, value: model.hasServers)
        .tint(Theme.accent)
        /*
         * Stated once, here, for the whole window — including the sheets below.
         *
         * A sheet is presented from this hierarchy, so it inherits the scheme
         * this modifier puts on the window rather than needing one of its own.
         * Every one of them used to carry `.preferredColorScheme(.dark)`
         * anyway, which was harmless while the app was pinned dark in
         * `Info.plist` and would have been eleven silent overrides of this
         * setting the moment that pin came out. Verified by looking: every
         * screen and every sheet was rendered in both schemes.
         */
        /*
         * **And a pinned terminal scheme wins, while a session is on screen.**
         *
         * The one thing `TerminalChrome` cannot reach: the status bar's glyphs
         * are drawn by the system from the **window's** interface style, and a
         * `.preferredColorScheme` on a pushed screen is overruled by this one —
         * measured, along with a `UIViewControllerRepresentable` reaching for
         * the window and being handed `nil` from inside
         * `updateUIViewController`.
         *
         * Three of the four quadrants were already right. The fourth was a light
         * scheme pinned while the app is forced Dark, where the clock stayed
         * white on Solarized Light's `#fdf6e3` at 1.05:1 — invisible, on the one
         * band of a page he asked to be entirely one colour.
         *
         * `model.showingSession` is deliberately a fact about *which screen is
         * up* rather than about the scheme, so this statement moves exactly
         * twice per session — on the push and on the pop — instead of on every
         * redraw. `follow-app` pins nothing, so a session under it keeps
         * `appearance.colorScheme` and the emulator three points below carries
         * on tracking the phone.
         */
        .preferredColorScheme(
            (model.showingSession ? TerminalChrome.pinnedStyle(themes.selected) : nil)
                ?? appearance.colorScheme
        )
        /*
         * Pairing, from wherever it was asked for — the line at the foot of the
         * login screen, or the machines list.
         *
         * Its own **server** door comes back here rather than raising a second
         * login sheet on top of this one. Two `ServerLoginView`s in one
         * hierarchy is exactly the fault this lane exists to remove, and it was
         * not only ugly: with both on screen, `firstMatch` on a segmented
         * control's "Private key" hits the buried one, which is the concrete
         * reason `testTheKeyOptionOffersAPasteRatherThanAOneLineField` failed
         * for five seconds and then gave up.
         */
        .sheet(isPresented: $model.addingHost) {
            PairingView(model: model, adding: true, onServerDoor: {
                model.addingHost = false
                // Past the gate, the login is a sheet and has to be raised. At
                // the gate it is the window underneath this one, so closing is
                // the whole of the move.
                if model.isPaired || model.hasServers { model.loggingIntoServer = true }
            }) {
                model.addingHost = false
            }
        }
        /*
         * Logging in to a server, presented from here and nowhere else.
         *
         * Raised from the machines list and from the pairing sheet, and it must
         * outlive both, because succeeding at it moves a phone from one to the
         * other. See `DeckModel.loggingIntoServer`.
         */
        .sheet(isPresented: $model.loggingIntoServer) {
            ServerLoginView(model: model) { added in
                model.loggingIntoServer = false
                guard let added else { return }
                // Straight to the server, which is where the login was going —
                // *"Then all the server-related stuff comes up."* A phone whose
                // only machine is this server has nothing else to be looking at.
                model.show(.settings)
                // Machines under it, not just the server: Back has to land
                // somewhere that makes sense, and the list this server is now on
                // is that place. A stack of one would send Back to Settings and
                // leave a person hunting for the row they just created.
                model.settingsRoute = [.machines, .server(added.id)]
            }
        }
        .sheet(isPresented: $model.showingAlerts) {
            AlertsView(model: model) { model.showingAlerts = false }
        }
        /*
         * Walking the machine's folders to start a session in one.
         *
         * Here beside the other two rather than on the session list, because it
         * is raised from the New Session menu *and* from the empty state behind
         * it, and a sheet asked for by a view that the presentation itself
         * removes is a sheet that never opens.
         *
         * The session is started by the callback rather than by the picker: the
         * picker's job is to answer *which folder*, and the same answer will be
         * worth having the day something other than a new session needs one.
         */
        .sheet(isPresented: $model.showingFolderPicker) {
            FolderPickerView(model: model) { folder in
                model.createSession(in: folder)
            }
        }
        /*
         * Naming a machine, presented from here rather than from the list.
         *
         * This view is the one thing in the app that is not rebuilt on every
         * model change, and that is the whole reason it is here. On the list it
         * was dismissed within a second of appearing: a computed `Binding` over
         * an optional had its setter run on each rebuild, and with several
         * machines paired something publishes constantly. Both properties are
         * plain and bound through `@Bindable`, exactly like `addingHost` beside
         * it, which never had the problem.
         */
        .alert("Name this machine", isPresented: $model.renamingHost) {
            /*
             * No `.accessibilityIdentifier` here, and it is not an omission.
             *
             * An alert is a `UIAlertController`, and this becomes a UIKit text
             * field made by `addTextField`. SwiftUI carries the placeholder and
             * the text binding across and drops the rest, so an identifier put
             * here is not on anything — measured on iOS 26.5, where the alert's
             * accessibility tree shows this field with its placeholder and no
             * identifier while the Save button below keeps its own. It was here,
             * it matched nothing, and a UI test spent a night looking for it.
             * The placeholder is the handle; see `MultiHostUITests`.
             */
            TextField("MacBook, Work PC…", text: $model.renameText)
            Button("Cancel", role: .cancel) { model.cancelRename() }
            Button("Save") { model.commitRename() }
                .accessibilityIdentifier("rename.save")
        } message: {
            Text("A host id is 26 characters of base32. A name is what you will actually recognise it by.")
        }
    }

    private var awaitingApproval: Bool {
        (model.connection.phase == .pending || model.connection.awaitingApproval) && model.sessions.isEmpty
    }
}
