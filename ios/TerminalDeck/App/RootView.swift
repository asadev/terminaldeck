/**
 * Three screens and the rules for which one is showing.
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

    var body: some View {
        Group {
            if !model.isPaired {
                PairingView(model: model)
            } else if model.hosts.count == 1 && awaitingApproval {
                PendingApprovalView(model: model)
            } else {
                NavigationStack(path: $model.route) {
                    SessionListView(model: model)
                        .navigationDestination(for: DeckModel.Route.self) { route in
                            switch route {
                            case let .session(host, id):
                                TerminalScreen(model: model, hostID: host, sessionID: id)
                            }
                        }
                }
            }
        }
        .animation(.default, value: model.isPaired)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.addingHost) {
            PairingView(model: model, adding: true) { model.addingHost = false }
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $model.showingGitHub) {
            GitHubAccountView(model: model) { model.showingGitHub = false }
        }
        .sheet(isPresented: $model.showingAlerts) {
            AlertsView(model: model) { model.showingAlerts = false }
        }
        /*
         * A machine asking this phone for a GitHub login.
         *
         * Armed only while nothing is covering the session list. The localhost
         * browser is a `fullScreenCover` presented from inside this stack, and a
         * sheet asked for by an ancestor of a cover has nothing to present from
         * — so that screen carries its own copy of this modifier and this one
         * stands down while it is up. Exactly one is armed at a time, which is
         * what stops the same question being presented twice.
         */
        .credentialPrompt(model, armed: !model.covered)
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
            Button("Cancel", role: .cancel) { model.renamingHost = false }
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
