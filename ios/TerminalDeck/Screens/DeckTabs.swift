/**
 * The bottom tab bar, and the two screens it opened up room for.
 *
 * Asad, walking the phone app: *"here we need to give a proper menu. Maybe it's
 * super basic currently. Maybe we can have some tab bar and down here like a
 * pill, something, so it's more easy to use… let's make it proper simple with a
 * bit more options. We have a lot of options on the Mac side. Maybe we can bring
 * them here on phone also… just make it more user friendly."*
 *
 * Before this the whole app was one list and one overflow menu. Everything that
 * was not a session — the machine you are typing into, the GitHub account, the
 * alert switches, the terminal's text size — lived behind a `…` in a corner,
 * which is where features go to be undiscovered. Nine items in one menu is not a
 * menu, it is a drawer.
 *
 * ## Which four — and when there are only three
 *
 * | Tab | What is on it |
 * |---|---|
 * | **Copilot** | the conversation with the machine, and what it has been doing |
 * | **Sessions** | the machine's sessions, and nothing else |
 * | **Localhost** | its dev servers, and every port it is already serving |
 * | **Settings** | the copilot's connection, machines, GitHub, alerts, text size |
 *
 * *"A fourth pill, and the copilot goes leftmost: Copilot · Sessions · Localhost
 * · Settings."* Said with the copilot built and in front of him, so it settles a
 * question that had been answered twice before in both directions; the ordering
 * and the reasoning are on `DeckModel.Tab`.
 *
 * The first of those four is **conditional**: *"if the copilot is not
 * connecting, this icon should not be inside the pill — then it will be three
 * icon pill. Otherwise if the copilot is connected, then four icon pill,
 * automatically."* So the bar has two shapes, the machine on screen decides
 * which, and `DeckModel.showsCopilotTab` is the one place that decides. Which is
 * also why connecting the copilot is a row in **Settings** and not a screen
 * behind that pill — a setup form reachable only through the pill that appears
 * once the setup is done is a door locked from the inside.
 *
 * The other two moved in an earlier recording. In short: the localhost list was
 * a second list underneath the sessions — *"no separate two lists already here"*
 * — and is now the subject of its own tab; the Machines screen is *"a section,
 * we click and we reach to this page"* inside Settings, because pairing a
 * machine is something done once and a bottom tab is for the screens somebody
 * moves between all day.
 *
 * What is **not** here is anything the phone cannot do. The desktop's sidebar has
 * ten entries and most of them are a file tree, a diff, a search box or a
 * browser — surfaces that would be an empty screen with an icon on it. He was
 * clear about that on the desktop in the same recording: *"I don't see any kind
 * of files here"*, *"also looking empty"*, *"I don't know what I can search
 * here"*. Copying those onto a phone would be copying the complaint.
 *
 * ## The tab bar is the system's
 *
 * `TabView` with `tabItem`, which on iOS 26 draws itself as the floating pill he
 * described and on iOS 17 and 18 draws the flat bar those releases use. The
 * newer `Tab { }` builder is iOS 18 and up, and the deployment target here is 17
 * — see `project.yml`. Nothing about the appearance is hand-rolled: the design
 * brief's rule for iOS is *native materials for chrome*, and a tab bar is the
 * most native piece of chrome there is.
 *
 * **And the items carry no words** — *"only icons are good enough. I think they
 * can understand from the icons what is what."* That is one change with two
 * halves, and the half that is easy to lose is that each tab is still *named*
 * for VoiceOver and for the twenty-odd UI cases that press a pill by its word.
 * `DeckTabs.pill(_:_:)` has the measurements that decided how.
 *
 * ## What is left of the session list's `…`
 *
 * One item, and it is a place rather than an action: **Archived**. Refresh and
 * Reconnect were in it and both are gone — *"Refresh, what does it actually do?
 * Pull-to-refresh would be the natural gesture. Reconnect, I don't know why we
 * need it… if they are useless and everything is automatically working, we need
 * to remove them."* Both verdicts, and the evidence behind them, are written
 * where the menu is built.
 */

import SwiftUI

struct DeckTabs: View {
    @Bindable var model: DeckModel

    var body: some View {
        TabView(selection: selection) {
            /*
             * The copilot, first, because that is where he put it — **and only
             * when this phone is connected to one.**
             *
             * *"If the copilot is not connecting, this icon should not be inside
             * the pill — then it will be three icon pill. Otherwise if the
             * copilot is connected, then four icon pill, automatically, like
             * that way."* `DeckModel.showsCopilotTab` is the whole rule and
             * argues every case, including the one that is not in that sentence:
             * a disconnect while somebody is standing on this tab leaves the
             * pill where it is, because a tab that disappears underneath a thumb
             * is worse than one that stays and explains.
             *
             * This is the opposite of what was written here yesterday — *"a
             * machine that has no copilot at all still gets the tab… hiding a
             * pill for some machines and not others would make the bar move
             * under a thumb that had learned where things are."* That reasoning
             * was about the bar moving, and it is answered rather than
             * contradicted: the pill is added and removed on the **left**, where
             * the copilot lives, so the three that survive keep their order; the
             * one case where it would move under a live thumb is held open by
             * the clause above; and connecting has somewhere honest to live now,
             * which it did not then.
             *
             * And on 2026-08-19 connecting stopped existing at all: the pill now
             * follows the *device*, because pairing one as **My device** is the
             * copilot's authorisation. A guest never sees a fourth pill; one of
             * his own machines shows it on the first welcome, with nothing to
             * press in between.
             *
             * It reads the *current* machine rather than a machine named in a
             * route, which is the one thing that changed about the screen when
             * it stopped being pushed: a tab has no argument. The switcher in
             * its own title is how the machine is chosen, exactly as on the
             * Sessions and Localhost tabs, and `DeckModel.select` clears
             * anything pushed here that belonged to the machine being left.
             */
            if model.showsCopilotTab {
                NavigationStack(path: $model.copilotRoute) {
                    CopilotTabScreen(model: model)
                        .navigationDestination(for: DeckModel.Route.self) { route in
                            switch route {
                            case let .session(host, id):
                                TerminalScreen(model: model, hostID: host, sessionID: id)
                            }
                        }
                }
                .toolbar(DeckChrome.tabBar(on: model.copilotSurface), for: .tabBar)
                .tabItem { pill("Copilot", "sparkles") }
                /*
                 * The count of questions waiting on an answer, on the pill.
                 *
                 * This is where the badge from the old pinned row went. It is
                 * strictly better placed: a question raised while somebody is
                 * reading a terminal has a two-minute deadline and expires into
                 * a **refusal**, and the row could only be seen by going back to
                 * the list it was pinned to. A tab badge is on screen from every
                 * tab.
                 *
                 * `.badge(0)` draws nothing at all, so there is no empty dot on
                 * a machine with nothing pending and no condition to get wrong
                 * here. A machine this phone is not connected to raises no
                 * questions on it either, so there is no badge stranded on a
                 * pill that is no longer drawn.
                 */
                .badge(model.copilot?.waitingCount ?? 0)
                .tag(DeckModel.Tab.copilot)
            }

            NavigationStack(path: $model.route) {
                SessionListView(model: model)
                    .navigationDestination(for: DeckModel.Route.self) { route in
                        switch route {
                        case let .session(host, id):
                            TerminalScreen(model: model, hostID: host, sessionID: id)
                        }
                    }
            }
            /*
             * The bar's visibility is stated **here**, not on the screen that
             * wants it hidden.
             *
             * `.toolbar(.hidden, for: .tabBar)` written on `TerminalScreen` — the
             * documented way, and the way this was first built — did nothing at
             * all: on iOS 26.5 the pill stayed drawn over the bottom three rows
             * of a live terminal, which is precisely the frame he complained
             * about. The bar is a floating pill belonging to the `TabView` on
             * that release, and this is the level it listens at. `DeckChrome`
             * holds the rule; each tab only has to say what is on top of it.
             */
            .toolbar(DeckChrome.tabBar(on: model.sessionsSurface), for: .tabBar)
            .tabItem { pill("Sessions", "terminal") }
            .tag(DeckModel.Tab.sessions)

            /*
             * Its own stack, so the page opens with a push.
             *
             * The page used to be a `fullScreenCover` raised from the session
             * list, which is exactly what he objected to: *"it should not come
             * like this up. It should just move like this when we click on
             * localhost page. It comes like this, which is a bit different,
             * feels like a browser opens inside. So give it a native feel."* A
             * cover rises from the bottom edge because it is a modal — a thing
             * interrupting you. A page from your own machine is not an
             * interruption, it is where the tap was going.
             */
            NavigationStack {
                MachineBrowserView(model: model)
            }
            // The page is `@State` inside that view rather than a path, so what
            // is on top of this tab is answered by a flag the browser sets. See
            // `DeckModel.localhostPageIsOpen`.
            .toolbar(DeckChrome.tabBar(on: model.localhostSurface), for: .tabBar)
            /*
             * **Browser**, not *Localhost* — and it is one tab now, not a tab
             * and a row in Settings.
             *
             * > *"instead of having local host page on the pill and one separate
             * > feature as watch browser in the settings page, we should have
             * > only one which will be called browser… where we can browse the
             * > localhost, we can type, and we can have all the browser features
             * > also in there in a very simple way instead of having it inside
             * > the settings."*
             *
             * The split was never a user's idea of anything. *Localhost* was a
             * list of ports this machine happens to be serving; *Watch browser*
             * was the machine's own windows, cast back — and it sat three rows
             * deep in Settings, which is where a feature goes to be undiscovered.
             * Both are the same verb: look at a page that lives on that machine.
             * So there is one screen, it is called what it is, and the address
             * bar at the top of it is the thing a browser has.
             */
            .tabItem { pill("Browser", "globe") }
            .tag(DeckModel.Tab.localhost)

            NavigationStack(path: $model.settingsRoute) {
                DeckSettingsView(model: model)
                    .navigationDestination(for: DeckModel.SettingsRoute.self) { route in
                        switch route {
                        case .machines:
                            MachinesView(model: model)
                        case .devices:
                            if let host = model.current {
                                DeviceRosterView(devices: host.devices,
                                                 thisDeviceId: host.thisDeviceId)
                            }
                        case .watch:
                            if let host = model.current {
                                WatchSurfacesView(watch: host.watch)
                            }
                        case let .server(id):
                            ServerDetailView(model: model, serverId: id)
                        case let .machine(id):
                            MachineDetailView(model: model, hostID: id)
                        case .copilot:
                            if let host = model.current {
                                CopilotControlView(model: model, hostID: host.id)
                            }
                        case .appearance:
                            AppearanceView()
                        }
                    }
            }
            // Machines keeps the bar — *"Pill should be on here only on the
            // homepage or machines or settings"* — so this is `.visible` in both
            // states. Stated rather than omitted so the screen has made the
            // decision out loud, and so the rule is not "hidden when pushed".
            .toolbar(DeckChrome.tabBar(on: model.settingsSurface), for: .tabBar)
            /*
             * **Menu**, not Settings.
             *
             * *"we can rename this settings page to menu page and we can have
             * all of these things in the menu page and settings page can be
             * inside the menu page."* The name follows what the screen became:
             * a page whose first section is the machine's own tools and whose
             * settings are one group among several is not a settings screen, and
             * calling it one sends people looking for Files under a gear.
             */
            .tabItem { pill("Menu", "line.3.horizontal") }
            .tag(DeckModel.Tab.settings)
        }
    }

    /**
     * The selection, routed through `DeckModel.show(_:)` rather than bound
     * straight at `model.tab`.
     *
     * The copilot draws no tab bar of its own now, so its Back button is the
     * only way off that screen and it has to know where the person came from.
     * A plain `$model.tab` binding writes the new tab and forgets the old one;
     * this hands the pair to the model, which keeps the one fact the button
     * needs. Everything else about it is a plain binding.
     */
    /**
     * **The pill carries icons and no words — and every tab is still addressable
     * by its name.**
     *
     * > *"And for the pill I think no need to give the titles like Copilot,
     * > Browser, Sessions or Terminal or Menu or things — only icons are good
     * > enough. I think they can understand from the icons what is what."*
     *
     * An `Image` in the `.tabItem` instead of a `Label`, with the name moved onto
     * `.accessibilityLabel`. That is one line per tab and it is the answer only
     * because of what the other route measured out at.
     *
     * ## The route not taken, and the numbers that killed it
     *
     * The safer-looking option is to keep `Label(name, systemImage:)` — so the
     * `UITabBarItem` keeps a real `title`, which is what VoiceOver reads and what
     * every UI suite here presses a tab by — and take the words out of the *ink*
     * with `UITabBarAppearance`: `titleTextAttributes` in `.clear`,
     * `titlePositionAdjustment` pushing the invisible string out of the pill, and
     * `UITabBarItem.appearance().imageInsets` nudging the glyph down into the
     * space it vacated.
     *
     * It was built, run and photographed on iOS 27, and **the last two do
     * nothing at all** on this bar. Measured on the shipped floating pill, from
     * the screenshots rather than from the documentation:
     *
     * | | pill centre | icon centre | icon is high by |
     * |---|---|---|---|
     * | titles cleared, insets set | 2465.5 | 2444.0 | 7.2 pt |
     * | titles cleared, no insets | 2465.5 | 2444.0 | 7.2 pt |
     * | no title at all (this) | 2465.5 | 2465.0 | 0.2 pt |
     *
     * Identical to the pixel with the insets and without them, which is the
     * measurement that settles it: the appearance proxy can still hide the text
     * on iOS 27 but can no longer move anything, and the pill does not shrink
     * when its labels go. So that route buys a title at the price of every glyph
     * sitting seven points above the middle of a sixty-two point pill, with dead
     * space underneath where the words used to be — visible, and exactly the
     * "looks like it failed to load" reading a bar must not have.
     *
     * ## Which is why the accessibility label is not optional here
     *
     * With no `Text` in the item there is no `title`, and a tab with neither is
     * unreachable to VoiceOver **and** to `TabNavigation.swift`, whose four
     * helpers — `openTab`, `openSettingsTab`, `openBrowserTab`, `openCopilotTab`
     * — find a pill with `tabBars.buttons[name]` on behalf of twenty-odd cases.
     * `.accessibilityLabel` inside the `tabItem` closure is what replaces it, and
     * that it survives into the accessibility tree is measured rather than
     * assumed: `SwipeActionsUITests` presses **Menu** and **Sessions** by name
     * against this build, and `testEveryPillIsStillAddressableByItsName` in that
     * suite is the standing guard for all four.
     *
     * The badge on the copilot's pill is untouched by any of this — `.badge()`
     * sets `UITabBarItem.badgeValue`, which has nothing to do with the item's
     * title or its image.
     */
    private func pill(_ name: String, _ symbol: String) -> some View {
        Image(systemName: symbol).accessibilityLabel(name)
    }

    private var selection: Binding<DeckModel.Tab> {
        Binding(get: { model.tab }, set: { model.show($0) })
    }
}

/**
 * The Copilot tab's root: the conversation on whichever machine is current.
 *
 * A wrapper of four lines, and it exists because `CopilotView` takes a host id
 * and a tab has none to give it. Resolving it here rather than making the id
 * optional inside that screen keeps the screen's own rule intact — *"named
 * rather than taken from `model.current`… the switcher can move underneath a
 * pushed view"* — which is still exactly right for the terminal pushed on top of
 * this stack, and would be wrong to relax for one caller.
 *
 * The id is read on every redraw rather than captured, so switching machines in
 * the title redraws this tab against the new one. That is the same rule every
 * facade on `DeckModel` follows and for the same reason: a screen holding a
 * `HostLink` across a switch is a screen showing one machine under another's
 * name.
 */
private struct CopilotTabScreen: View {
    let model: DeckModel

    var body: some View {
        if let host = model.current {
            if let session = CopilotOnServer.tabSession(for: host) {
                /*
                 * **The Copilot tab is the conversation.**
                 *
                 * > *"This page needs to go. It should directly land in terminal
                 * > or chat mode, and user can set its default from settings."*
                 *
                 * Said over a photograph of the screen this branch replaces: a
                 * headline, and a row reading *Open the conversation*. A tab
                 * whose job is to put somebody in a conversation, offering a
                 * button that puts them in the conversation, had not done its
                 * job — and for two rounds the way it *did* do it was to write a
                 * path onto `copilotRoute` at the moment the tab was still
                 * transitioning on screen, which SwiftUI discards. Everything
                 * built to survive that — a retry loop, a clock that told a
                 * discarded path from a person pressing Back — is deleted with
                 * the push, because the content of a view body is not something
                 * SwiftUI reverts.
                 *
                 * `leaveTab` is the other half. There is no chevron over a tab's
                 * root and no gesture that pops one, so the screen draws its own,
                 * and it goes where the copilot's has always gone:
                 * `DeckModel.leaveCopilot()`, to whichever tab this one was
                 * entered from. **One press, out of the tab** — which is what
                 * Back does at the root of every other tab in the app, and which
                 * is the whole of *"I cannot go back more than that."*
                 *
                 * The gear is applied here for the reason it always was: the same
                 * screen is built from two stacks and only this file knows which.
                 * The folder-recorder beside it is why starting a session unasked
                 * is safe at all — see `CopilotFolderFromItsSession`.
                 */
                TerminalScreen(model: model,
                               hostID: host.id,
                               sessionID: session.id,
                               leaveTab: { model.leaveCopilot() })
                    .copilotFolderFromItsSession(model: model,
                                                 hostID: host.id,
                                                 sessionID: session.id)
            } else {
                // No conversation to show: the copilot's own screen, which on a
                // server is the one that starts one and on a desktop is the
                // copilot itself.
                CopilotView(model: model, hostID: host.id)
            }
        } else {
            // Unreachable while `RootView` gates on `isPaired`, and written out
            // rather than left as an `EmptyView` so that the day something else
            // presents this tab, it says something true instead of drawing a
            // blank screen under a pill.
            ContentUnavailableView {
                Label("No machine", systemImage: "sparkles")
            } description: {
                Text("Pair a machine and its copilot appears here.")
            }
            .accessibilityIdentifier("copilot.noMachine")
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Machines                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Every machine this phone is paired with, on a screen instead of in a menu.
 *
 * The switcher in the navigation title stays — it is the fastest way to change
 * machines while looking at sessions, and it is what a phone paired with three
 * of them needs in the toolbar. This is the other half: the place where a machine
 * is *managed* rather than merely chosen, which a title menu was always a bad
 * shape for. Asad on the desktop's equivalent: *"I am not able to edit the name
 * of this account and I don't know where it belongs to… I should be able to edit
 * the account, delete and add."* Same three verbs, on the phone, in one place.
 *
 * ## It is pushed from Settings now, and it keeps the tab bar
 *
 * *"maybe this machines thing can go inside the settings this page overall…
 * Here we can have a section, we click and we reach to this page and we can
 * connect. This is a better design."* Nothing on the screen changed in the move
 * — the rows, the menu, the pair button and the sentence at the foot are what
 * they were, one row further away.
 *
 * The tab bar stays over it, because he named this as one of the three places
 * the bar belongs: *"Pill should be on here only on the homepage or machines or
 * settings"*. So the rule is not "hidden on anything pushed" — see `DeckChrome`,
 * and `DeckTabs` above for where it is applied.
 *
 * Every row carries what that machine is doing right now, because every host
 * holds its socket from launch whether or not it is on screen — see
 * `DeckModel`'s note on why that is worth one keepalive. A list of machines that
 * could not say which of them was busy would be a list of names.
 */
struct MachinesView: View {
    let model: DeckModel

    /**
     * The machine a Forget is waiting to be confirmed for.
     *
     * A value of its own rather than an id, for the reason `SessionListView`
     * holds a whole `RemoteSession` while its Close is being answered: this list
     * reorders and shrinks by itself — a machine can drop off it while the alert
     * is up, and a name looked up at draw time would put one machine's title over
     * a decision about another. The name is `model.label(for:)` at the moment of
     * the swipe, which is also the name the row and the menu were showing.
     *
     * A struct rather than the `HostLink`, so the question on screen cannot be
     * changed underneath by the object it is about answering a frame from its
     * machine mid-decision.
     */
    @State private var forgetting: Forgetting?

    private struct Forgetting: Identifiable {
        let id: String
        let name: String
    }

    /**
     * The rows, and it is a `List` now rather than a `ScrollView` of a
     * `LazyVStack`.
     *
     * Asad: *"if we click, like we have a list of browsers or sessions, we can
     * swipe them left and right and we can have options there to delete or close
     * the options or archive and things, just like WhatsApp has the chats."*
     * `.swipeActions` exists only inside a `List` — a `ScrollView` compiles the
     * modifier and silently draws nothing, which is the same failure the session
     * list and the localhost list each had to be converted out of, and the reason
     * their UI cases assert on the revealed buttons rather than on a screenshot.
     *
     * Nothing about the screen changes with the container. The cards are painted
     * by `MachineRow` and `RowButtonStyle` rather than by the list, so
     * `plainRow()` — the three modifiers that clear the row background, drop the
     * separator and restate the gutter — is all it takes to keep them. Its five
     * points top and bottom reproduce the `LazyVStack(spacing: 10)` exactly, and
     * the seven points of content margin below make up the difference between
     * those five and the twelve the stack had above its first card. Stated as a
     * margin rather than as a fatter inset on the first row, because an inset
     * that belongs to whichever row happens to be first is a gutter that changes
     * when the list is reordered.
     */
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            List {
                ForEach(model.hosts) { host in
                    MachineRow(host: host,
                               // From the model, not the host: two machines
                               // reporting one hostname drew two identical
                               // rows until the list broke the tie. See
                               // `DeckModel.label(for:)`.
                               name: model.label(for: host),
                               isCurrent: host.id == model.current?.id,
                               select: { model.select(host.id) },
                               about: { open(host) },
                               rename: { beginRename(host) },
                               forget: { askToForget(host) })
                        .plainRow()
                        /*
                         * Rename towards you, Forget away from you — the same
                         * hands the rest of the app already teaches.
                         *
                         * The leading edge carries the harmless verb on every
                         * list in this product: Pin on the sessions, Rename on
                         * the ports, Rename here. The trailing edge carries the
                         * one that takes something away, outermost, so that the
                         * thumb coming off the screen edge lands on the action
                         * that has to be the most deliberate — and that action
                         * asks before it fires.
                         *
                         * `allowsFullSwipe: false` on both edges. A full swipe
                         * fires the first action on release, and the first
                         * action on the trailing edge unpairs a computer.
                         */
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            renameAction(host)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            forgetAction(host)
                            aboutAction(host)
                        }
                }

                Button {
                    model.addingHost = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 18)
                        Text("Pair another machine")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.accent)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("machines.add")
                // Eleven rather than five: the six extra points this row carried
                // as `.padding(.top, 6)` in the stack, so the doors sit slightly
                // apart from the machines they add to.
                .plainRow(top: 11)

                /*
                 * The second door, beside the first rather than behind it.
                 *
                 * A code is read off a machine somebody is standing at. A
                 * server is a machine nobody is standing at — that is what
                 * makes it a server — so it has no screen to show a code on
                 * and nobody to press Approve. Both doors end in a row on
                 * this list, so both belong at the bottom of this list;
                 * putting the server one behind a `…` would be hiding the
                 * only way in for the machines this product is named after.
                 */
                /*
                 * The servers, on the same list as the machines and clearly
                 * not the same thing.
                 *
                 * A server that has been *connected* is in both places at
                 * once — as a machine above, because the host on it became
                 * one, and as a server here, because the SSH login that
                 * manages it is still what installs, starts and stops it.
                 * That is not a duplicate: the two rows do different jobs
                 * and lead to different screens.
                 */
                if !model.serverConnector.servers.isEmpty {
                    Text("Servers")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.faint)
                        .textCase(.uppercase)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Twenty rather than sixteen, which is the four points
                        // this caption had as its own horizontal padding inside
                        // the stack's gutter. The same figure the localhost
                        // list's section headers sit on.
                        .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 2, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    ForEach(model.serverConnector.servers) { server in
                        /*
                         * A button rather than a `NavigationLink`, and it was
                         * one until this screen became a `List`.
                         *
                         * Inside a list a `NavigationLink` draws the system's
                         * own disclosure chevron beside whatever it is given,
                         * and `ServerRow` already draws one — so the row would
                         * come out with two, which is exactly what happened to
                         * the session rows when that screen was converted.
                         * Appending the same route does the same navigation
                         * without the decoration.
                         */
                        Button {
                            model.settingsRoute.append(.server(server.id))
                        } label: {
                            ServerRow(server: server,
                                      isConnected: server.linkedHostId
                                          .flatMap { model.host($0) } != nil)
                        }
                        .buttonStyle(RowButtonStyle())
                        .accessibilityIdentifier("machines.server")
                        .plainRow()
                    }
                }

                Button {
                    // The root presenter, for the reason the pairing screen
                    // gives: one login sheet, owned by the one view that
                    // survives a phone crossing from "no machines" to "one
                    // server". See `DeckModel.loggingIntoServer`.
                    model.loggingIntoServer = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Log in to a server")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Theme.accent)
                            // The one line on this row, and it earns it: it
                            // is the whole difference between the two doors,
                            // and somebody who reads "add a server" without
                            // it will go looking for a code that no server
                            // will ever show them.
                            Text("Its address and the login it already trusts")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("machines.addServer")
                .plainRow()

                if let error = model.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onTapGesture { model.dismissError() }
                        .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                /*
                 * Behind the ⓘ, not under the list.
                 *
                 * > *"here you have a very long description… Remove this
                 * > full shit. I don't want any kind of long descriptions
                 * > anywhere. Just if somewhere it's very required, give the
                 * > i icon."*
                 *
                 * The sentence is still worth having — it is the answer to
                 * *why can this phone see my Mac*, and it is where somebody
                 * looks after unpairing something by accident — so it moves
                 * rather than goes. `InfoDot` is the shape the rest of the
                 * app already uses for exactly this.
                 */
                HStack(spacing: 6) {
                    Text("Forgetting is per machine")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                    InfoDot(
                        about: "Machines",
                        text: "A machine stays on this list until you forget it. "
                            + "Forgetting one leaves every other machine alone."
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The twenty-eight at the foot is the stack's old bottom padding,
                // which the clearance row below does not replace: that one is
                // sized to the floating bar and is zero on a screen without one.
                .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 28, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                // Machines keeps the bar, so it owes it room.
                TabBarClearance()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            // See the header: the seven points that turn `plainRow`'s five into
            // the twelve this screen had above its first card.
            .contentMargins(.top, 7, for: .scrollContent)
            .scrollBounceBehavior(.basedOnSize)
            .refreshable {
                model.refreshAll()
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
        /*
         * The question Forget did not used to ask, in one place for both ways of
         * reaching it.
         *
         * Forget was wired straight to `DeckModel.unpair` from the row's `…`
         * menu — one tap, no question, and the machine was gone. That was
         * survivable while the only way to fire it was to open a menu and read a
         * named item; it is not survivable next to a swipe, which is a gesture a
         * thumb can complete without the eye having caught up. So the
         * confirmation is new, and it is deliberately raised by the row's single
         * `forget` closure rather than by the swipe button — the menu item and
         * the swipe are two doors onto one verb, and a verb that asks through one
         * door and not the other is two different verbs wearing one word.
         *
         * A system alert, for the reasons the session list's Close gives at
         * length: it is modal so it cannot be scrolled away from mid-decision,
         * and iOS draws `.destructive` in the platform's own red at the
         * platform's own weight. The title names the machine so that a phone
         * paired with three of them cannot produce a decision about the wrong
         * one, and the affirmative says *forget* rather than *OK*.
         *
         * The message is the three facts somebody is actually unsure about, and
         * every one of them is a property of `unpair` rather than a reassurance:
         * the sessions do not stop, the pairing has to be made again from
         * scratch, and no other machine is touched.
         */
        .alert("Forget \(forgetting?.name ?? "this machine")?",
               isPresented: Binding(get: { forgetting != nil },
                                    set: { if !$0 { forgetting = nil } }),
               presenting: forgetting) { target in
            Button("Forget", role: .destructive) {
                model.unpair(target.id)
                forgetting = nil
            }
            .accessibilityIdentifier("forget.confirm")
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: { target in
            // The machine is named in the title, so the message does not say it
            // again: rendered against a real hostname the second mention pushed
            // this to six lines and read as though two different machines were
            // involved.
            Text("Its sessions keep running — this phone stops seeing them. "
                 + "Getting back in means pairing again. "
                 + "Every other machine is left alone.")
        }
        .navigationTitle("Machines")
        .navigationBarTitleDisplayMode(.inline)

    }

    // MARK: - The three verbs, said once each

    /**
     * What a row's controls do, written here rather than inside `MachineRow`, so
     * that the `…` menu and the swipe on the same row cannot drift into doing
     * two different things. The row takes closures; this is what they are.
     */

    /// Push the machine's own screen. A route appended rather than a
    /// `NavigationLink` followed — see the ⓘ on `MachineRow` for the chevron that
    /// forced that when this screen became a `List`.
    private func open(_ host: HostLink) {
        model.settingsRoute.append(.machine(host.id))
    }

    /// Raise the rename alert, which `RootView` presents. Deferred by one turn of
    /// the run loop because both callers are inside a gesture handler: presenting
    /// while the row is still animating back leaves the alert with no presenter
    /// and the press does nothing at all — measured on the port list, where the
    /// swipe's Rename silently did nothing until it was deferred.
    private func beginRename(_ host: HostLink) {
        DispatchQueue.main.async { model.beginRename(host.id) }
    }

    /// Raise the confirmation. Nothing is unpaired here — see the alert.
    private func askToForget(_ host: HostLink) {
        let name = model.label(for: host)
        DispatchQueue.main.async { forgetting = Forgetting(id: host.id, name: name) }
    }

    // MARK: - The swipes

    /**
     * The leading swipe: rename, which is the harmless one.
     *
     * `Theme.accent` because that is what the leading Rename on the port list is
     * tinted, and two lists whose same-named action is a different colour is a
     * screen somebody has to read rather than recognise.
     *
     * Not gated on anything, and that is honest rather than lazy: every machine
     * on this list can be renamed — the label is stored on this phone — so a
     * condition here would be a condition on nothing. The rule this app follows
     * is that an action is gated on exactly what its menu counterpart is gated
     * on, and the menu's Rename is gated on nothing either.
     */
    private func renameAction(_ host: HostLink) -> some View {
        Button {
            beginRename(host)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .tint(Theme.accent)
        // Named, because a phone paired with three machines is three identical
        // swipes and VoiceOver reads this one out of the row it belongs to.
        .accessibilityLabel("Rename \(model.label(for: host))")
        .accessibilityIdentifier("machine.swipe.rename.\(host.id)")
    }

    /**
     * The trailing swipe's first action, which is the outermost one drawn.
     *
     * `Theme.critical` and not `Theme.warning`: this app reserves the amber for
     * the reversible thing that changes nothing on the machine — Archive on the
     * session list says exactly that — and the red for the one that takes
     * something away. Forgetting a machine is not reversible from this screen; it
     * needs a fresh pairing code or a server login to undo.
     *
     * Tinted explicitly even though `role: .destructive` is red by default,
     * because a default loses to an ambient tint: the session list's Close came
     * out **blue** the first time it was built, sitting under this app's
     * `.tint(Theme.accent)`, and nothing in the build log said so — it was
     * visible in the first frame the simulator took. The same trap is one
     * ancestor away here.
     *
     * It opens the alert rather than acting. `role: .destructive` on a swipe
     * button is styling, not a confirmation.
     */
    private func forgetAction(_ host: HostLink) -> some View {
        Button(role: .destructive) {
            askToForget(host)
        } label: {
            Label("Forget", systemImage: "minus.circle")
        }
        .tint(Theme.critical)
        .accessibilityLabel("Forget \(model.label(for: host))")
        .accessibilityIdentifier("machine.swipe.forget.\(host.id)")
    }

    /**
     * And the machine's own screen, inside the destructive one.
     *
     * The ⓘ is already on the row, so this is not the only way there. It is the
     * way that does not ask a thumb to find a 40-point glyph wedged between the
     * row's body and its `…`, which is the same argument the session list makes
     * for putting Details on the swipe as well as behind a long press.
     *
     * `Theme.neutralAction`, which is what that Details is tinted, and for the
     * same reason: a reference is neither an action worth the accent nor a risk
     * worth a colour.
     *
     * Inside Forget rather than outside it, so the outermost action on this edge
     * is the deliberate one on every list in the app.
     */
    private func aboutAction(_ host: HostLink) -> some View {
        Button {
            // The row's own ⓘ, deferred: pushing while the row is still animating
            // back is a navigation nobody sees arrive. One function rather than a
            // second `append` here, so the two doors cannot lead to two screens.
            DispatchQueue.main.async { open(host) }
        } label: {
            Label("About", systemImage: "info.circle")
        }
        .tint(Theme.neutralAction)
        .accessibilityLabel("About \(model.label(for: host))")
        .accessibilityIdentifier("machine.swipe.about.\(host.id)")
    }
}

/**
 * One machine.
 *
 * The name leads because it is what somebody is looking for. The endpoint under
 * it is mono and dimmed because it is data — the design brief's rule, and here it
 * is also the answer to *"I don't know where it belongs to"*. The status line is
 * a sentence about the row rather than the row itself, so it is quieter than
 * both.
 *
 * Tapping the row switches to that machine; the `…` beside it renames or forgets
 * it. The two are separated because one of them is a thing people do twenty times
 * a day and the other is a thing they do once and regret.
 *
 * ## Every verb on this row is a closure, and that is what keeps the swipe honest
 *
 * The same three actions are reachable two ways now — from the `…` here and from
 * a swipe on the row, which `MachinesView` attaches because a menu is two taps
 * for something WhatsApp does in one drag. Both doors call the *same* closure, so
 * a Forget that asks before it fires asks from either of them; a swipe wired
 * straight to `unpair` while the menu went through a confirmation would be two
 * verbs sharing one word.
 */
private struct MachineRow: View {
    let host: HostLink
    /// What this row is called *in this list* — see `DeckModel.label(for:)`.
    let name: String
    let isCurrent: Bool
    let select: () -> Void
    /// Push this machine's own screen. See the ⓘ below.
    let about: () -> Void
    let rename: () -> Void
    /// Ask about forgetting it. Nothing is unpaired by calling this — the
    /// confirmation `MachinesView` raises is what unpairs, and it is the only
    /// thing that does.
    let forget: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(alignment: .top, spacing: 12) {
                    // A rented Linux box drawn as an iMac is a row that
                    // contradicts the About section two screens away, which has
                    // named the same machine a *server* since 0.10.0. `hostKind`
                    // is one property access away and this row already holds the
                    // whole `HostLink`.
                    Image(systemName: isCurrent
                          ? "checkmark.circle.fill"
                          : (host.hostKind == .headless ? "server.rack" : "desktopcomputer"))
                        .font(.system(size: 15))
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.secondary)
                        .frame(width: 18)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)

                        /*
                         * Two lines, wrapped, rather than one line truncated.
                         *
                         * Both truncations were rendered and both threw away the
                         * answer to *"I don't know where it belongs to"*, which
                         * is the whole reason this line is on the row. The
                         * summary is a host id, a relay and how it is protected;
                         * cut at the head it read "…minaldeck.dev — end-to-end
                         * sealed" and lost the machine, cut at the tail it read
                         * "M9G95TNJT64Q928VW3HVRYDR8J via re…" and lost the
                         * relay. It fits in two lines at this size, so it gets
                         * two — this is a screen with room, unlike the title
                         * switcher this text also appears in.
                         */
                        Text(host.endpointSummary)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(2)
                            // Both stated, and both because of what the render
                            // showed: without them the wrapped first line came
                            // out centred over the second and neither lined up
                            // with the machine's name above.
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(host.connection.isLive ? Theme.positive : Theme.secondary)
                                .frame(width: 6, height: 6)
                            Text(summary)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                        .padding(.top, 1)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("machine.\(host.id)")

            /*
             * The chevron, and the screen behind it.
             *
             * The row's body **selects** this machine — that is what a tap on a
             * machine in a list of machines means, and it is what the checkmark
             * is about. What it did not do was lead anywhere, so a machine that
             * was not also an SSH server had no page at all: *"before we had a
             * list of connected servers where we could click and go inside
             * server info and settings now its gone."*
             *
             * Two targets on one row, which is worth being careful about: the
             * body switches, this opens. They are drawn apart and labelled
             * apart, the way Mail's list separates a message from its detail
             * disclosure.
             *
             * A `Button` appending the route rather than a `NavigationLink`
             * carrying it, and the reason is the container: this row lives in a
             * `List` since the swipes were added, and a `NavigationLink` inside
             * a list draws the system's own disclosure chevron beside whatever
             * it is given — so this row would end up with a chevron it never
             * asked for, hard against the `…`. The session list hit the same
             * thing when it was converted and answered it the same way.
             */
            Button(action: about) {
                Image(systemName: "info.circle")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(name)")
            .accessibilityIdentifier("machine.about.\(host.id)")

            Menu {
                Button {
                    rename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .accessibilityIdentifier("machine.rename")

                // Asks first, since 0.10.3. It used to be wired straight through
                // to `unpair` — one tap and the machine was gone — which was
                // survivable only while a menu was the sole way to reach it. It
                // is not the sole way any more; see this type's header.
                Button(role: .destructive) {
                    forget()
                } label: {
                    // Named, because this menu is opened on a row and a phone
                    // paired with three machines is three identical menus.
                    Label("Forget \(name)", systemImage: "minus.circle")
                }
                .accessibilityIdentifier("machine.forget")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(name)")
            .accessibilityIdentifier("machine.more.\(host.id)")
            .padding(.trailing, 6)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// What the row says the machine is doing. Sessions while it is up, because
    /// that is the number worth switching for; the connection state when it is
    /// not, because then the session count is history. The same rule the title
    /// switcher uses, so the two never say different things about one machine.
    private var summary: String {
        guard host.connection.isLive else { return host.connection.label.lowercased() }
        let running = host.sessions.filter { $0.status != "exited" }.count
        if running == 0 { return "nothing running" }
        let working = host.sessions.filter { $0.status == "working" }.count
        let sessions = running == 1 ? "1 session" : "\(running) sessions"
        return working > 0 ? "\(sessions), \(working) working" : sessions
    }
}

/* -------------------------------------------------------------------------- */
/* Settings                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * The app's own settings — the things that belong to this phone rather than to a
 * machine.
 *
 * Named `DeckSettingsView` rather than `SettingsView` because `SwiftUI.Settings`
 * exists and a type called `SettingsView` in this module reads as if it might be
 * one; the brand's own prefix is what every other type here would have used.
 *
 * Five rows and a paragraph. Asad on the desktop's settings page, in the same
 * recording: *"we don't need this much of big descriptions under each. The whole
 * page is going to be used just because of the big descriptions."* So each row is
 * a line, and the only paragraph on the screen is the one that says what alerts
 * genuinely cannot do — which is the one piece of prose in this app that has
 * repeatedly earned its place, because the alternative is somebody waiting two
 * hours for a buzz that was never coming.
 *
 * ## Connecting the copilot is here, and it is the second row
 *
 * *"Actually connecting copilot should be in the settings."* The whole reason is
 * on the row itself; the short version is that the Copilot pill now appears only
 * once the copilot is connected, so the connect form could not stay behind it.
 *
 * ## Machines is the first row, and it is the fifth
 *
 * *"maybe this machines thing can go inside the settings this page overall. How
 * many machines we pair can go inside the settings actually, yes."* So the row's
 * value is the count, which is the thing he asked it to say, and it leads the
 * screen because it is the only row here that opens onto a screen of its own
 * rather than a switch. It pushes rather than presenting a sheet — the rest of
 * this app pushes, and a machine list that slid up from the bottom would be the
 * localhost complaint again one screen over.
 */
struct DeckSettingsView: View {
    let model: DeckModel

    /// The phone's terminal colour scheme, read for the Appearance row's value.
    /// Held as a property rather than reached for inside `body`, because
    /// `@Observable` only re-runs a body that read the object — and the row has
    /// to say the new name the moment somebody comes back from the page.
    var themes: TerminalThemeStore = .shared

    /**
     * The terminal text size, read for the same row and by the same rule.
     *
     * `@AppStorage` on `TextSize.key` rather than a read of `TextSize.stored`,
     * and the difference is invalidation rather than value. `TextSize` is a
     * `UserDefaults` façade with nothing observable on it, so a body that read
     * `stored` would be drawn once and never again — the row would go on saying
     * "12 pt" after somebody came back from having changed it, which is the
     * exact class of defect a summary row exists to avoid. Binding the key makes
     * the row a live view of the setting.
     *
     * **The light/dark picker is not here any more.** It was a segmented control
     * inline on this screen, under a caption that said *Appearance*, and it is
     * now the first group on the Appearance page with the size and the colours —
     * *"overall appearance page should be there in the settings and from there we
     * can change colors text size and everything."* See `AppearanceView`.
     */
    @AppStorage(TextSize.key) private var storedTextSize: Double = Double(TextSize.standard)

    /**
     * Bumped when the alerts sheet closes, and read by nothing.
     *
     * `AlertSettings` is a `UserDefaults` façade with no observation on it, so
     * turning a switch off inside the sheet changes no property this view is
     * watching and the row underneath would still read "On" afterwards. Any
     * `@State` write re-evaluates the body, and re-evaluating the body is what
     * re-reads the store — so this counter has no value, only a moment.
     */
    @State private var alertsRevision = 0

    /**
     * The lock on the front door, put into the environment by
     * `TerminalDeckApp` — one instance, because a second would have its own idea
     * of whether this app is locked. Read here rather than threaded through
     * `DeckModel`: the lock knows nothing about machines, sessions or servers,
     * and hanging it off the model would be the first step back towards a lock
     * that belongs to one of them.
     */
    @Environment(AppLock.self) private var lock

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    /*
                     * **The machine's own tools, first — not three taps down.**
                     *
                     * > *"not all the features should be inside the server page…
                     * > they can come in the settings page… we can rename this
                     * > settings page to menu page and we can have all of these
                     * > things in the menu page and settings page can be inside
                     * > the menu page… they are most used things so should not
                     * > be this far, bring them here."*
                     *
                     * They were on `MachineDetailView`, behind Settings →
                     * Machines → ⓘ, which is where a feature goes to be
                     * undiscovered — and worse, it filed *Files* and *Source
                     * control* under a page about SSH administration, which is a
                     * different subject. The server page keeps what is genuinely
                     * about the server: install, start, stop, update, remove.
                     *
                     * **Drawn only when the machine offers them.** A desktop
                     * paired with six digits advertises none of these three
                     * capabilities, so it gets no section at all rather than six
                     * rows that refuse — *"if we don't have access to them they
                     * will not be just simply visible here."*
                     */
                    MachineToolsSection(
                        model: model,
                        path: model.toolsFolder.isEmpty ? nil : model.toolsFolder,
                        filesDestination: { FilesView(model: model, start: model.toolsFolder) },
                        sourceDestination: { SourceControlView(model: model, path: model.toolsFolder) })

                    SectionCaption("This phone")

                    SettingsGroup {
                        /*
                         * A `NavigationLink` rather than a button calling
                         * `showMachines()`, because this is the ordinary case —
                         * somebody is on Settings and taps the row, and the link
                         * pushes onto the stack it is already inside. The method
                         * exists for the other case, where something that is not
                         * this screen wants the machines on screen and has to
                         * move the tab as well.
                         */
                        NavigationLink(value: DeckModel.SettingsRoute.machines) {
                            SettingsRowBody(title: "Machines",
                                            value: machinesValue,
                                            icon: "desktopcomputer")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.machines")

                        SettingsDivider()

                        /*
                         * Every device signed in to the current machine, and the
                         * one verb that removes one. Drawn only over a host that
                         * advertised `devices` — one of the owner's own devices
                         * only, since the host withholds the capability from a
                         * guest at the source. An older desktop, or this phone
                         * connected as a guest, gets no row rather than one that
                         * pushes onto an empty screen. See `DeviceRosterView`.
                         */
                        if model.current?.devices.offered == true {
                            NavigationLink(value: DeckModel.SettingsRoute.devices) {
                                SettingsRowBody(title: "Devices",
                                                value: devicesValue,
                                                icon: "iphone.gen3")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings.devices")

                            SettingsDivider()
                        }

                        /*
                         * **There is no Watch browser row here any more.**
                         *
                         * It pushed a list of the machine's own windows, and it
                         * was the second of two places this app asked somebody to
                         * look at a page on their machine — the Localhost tab
                         * being the first. *"we should have only one which will
                         * be called browser… instead of having it inside the
                         * settings."* Both live on the Browser tab now, which is
                         * one pill away rather than three rows deep in here. See
                         * the tab above.
                         */

                        /*
                         * **There is no Copilot row here, and that is the
                         * change of 2026-08-19.**
                         *
                         * There was one for a day: *"actually connecting copilot
                         * should be in the settings"*, pushing a screen with a
                         * six-digit field on it, because the Copilot pill only
                         * appears once the copilot is connected and a setup form
                         * behind it would have been a door locked from the
                         * inside.
                         *
                         * Then the ceremony itself went — *"if we are connecting
                         * as my device copilot automatically comes, if we
                         * connect as guest then copilot don't come"* — and the
                         * row had nothing left to do. What remains is a status,
                         * and a status is not a row: tapping it would open a
                         * page whose only content is a sentence, and the same
                         * sentence is already on the Copilot tab, one pill away,
                         * with the conversation under it. The pill's own
                         * presence says the same thing faster than any row can.
                         *
                         * Where the answer is changed is the machine, on the
                         * approval screen, by choosing what kind of device this
                         * is. Nothing on a phone can move that, so nothing on a
                         * phone offers to.
                         */

                        /*
                         * **The copilot's settings, on the page that is a list
                         * of settings.**
                         *
                         * > *"Let's move settings option for copilot to main
                         * > settings page instead of inside the copilot page, so
                         * > we can have three dots in left along with chat vs
                         * > terminal switch."*
                         *
                         * Drawn only where there is a copilot to configure — the
                         * same rule every machine-scoped row on this page keeps.
                         * `showsCopilotTab` is that question already answered:
                         * a machine with a copilot pill has a copilot, and one
                         * without has nothing for this screen to set.
                         */
                        if model.showsCopilotTab {
                            SettingsRow(title: "Copilot",
                                        value: model.copilotSettingsValue,
                                        icon: "sparkles") {
                                model.settingsRoute.append(.copilot)
                            }
                            .accessibilityIdentifier("settings.copilot")

                            SettingsDivider()
                        }

                        SettingsRow(title: "GitHub",
                                    value: model.gitHubAccount.map { "@\($0.login)" } ?? "Not connected",
                                    icon: "person.crop.circle") {
                            DispatchQueue.main.async { model.showingGitHub = true }
                        }
                        .accessibilityIdentifier("settings.github")

                        SettingsDivider()

                        SettingsRow(title: "Alerts",
                                    value: alertsValue,
                                    icon: "bell") {
                            DispatchQueue.main.async { model.showingAlerts = true }
                        }
                        .accessibilityIdentifier("settings.alerts")

                        SettingsDivider()

                        /*
                         * **Appearance — one row, and everything about how this
                         * app and its terminals look is behind it.**
                         *
                         * > *"this bigger and smaller should be going to inside
                         * > the settings page for the all of the terminals with
                         * > one setting we can just change this for overall
                         * > appearance page should be there in the settings and
                         * > from there we can change colors text size and
                         * > everything for all of them."*
                         *
                         * He was reading *Bigger text* and *Smaller text* out of
                         * one session's `…` menu. What he asked for was a page,
                         * so this is a row rather than the section of inline
                         * controls that used to sit lower down: the light/dark
                         * picker was here, the terminal colours were one push
                         * away, and the size was in a menu inside a session.
                         * Three places for one question. `AppearanceView` is the
                         * one place now.
                         *
                         * **In *This phone*, and that is not filing convenience.**
                         * Every setting on that page belongs to this handset and
                         * to nothing on the other end of the wire — the app's
                         * light/dark, the terminal's colours, the point size.
                         * Change any of them and the Mac in the other room is
                         * exactly as it was, which is what the note at the foot
                         * of the page says out loud.
                         *
                         * The value is both answers — the same rule Machines and
                         * Alerts follow, a row that pushes says what it would
                         * find — and the **size is first**, which is a
                         * measurement rather than a preference.
                         *
                         * On a 375-point phone, the narrowest this app supports,
                         * the row has about one point to spare against
                         * *"Solarized Light · 22 pt"* and none at all against a
                         * copy of it called *"Solarized Light (yours)"*. So the
                         * order is chosen for what happens when it does not fit:
                         * `SettingsRowBody` clips the tail, and the tail should
                         * be a scheme name that is spelt out in full one tap
                         * away rather than the number he came to this row to
                         * read.
                         */
                        NavigationLink(value: DeckModel.SettingsRoute.appearance) {
                            SettingsRowBody(title: "Appearance",
                                            value: appearanceValue,
                                            icon: "paintbrush")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.appearance")
                    }

                    // The two settings the current machine owns rather than this
                    // phone — the coding tool a fresh session starts with, and
                    // whether the last layout is restored. Draws nothing over a
                    // host that did not advertise `settings`, so an older desktop
                    // or a guest sees exactly what it did before.
                    if let host = model.current {
                        // The noun as well as the link. That section's caption
                        // said "THIS SERVER" over a Mac — see
                        // `DeckModel.machineNoun`, which is the one answer this
                        // app is allowed to give to *what do I call the box on
                        // the other end*.
                        ServerSettingsSection(settings: host.serverSettings,
                                              machineNoun: model.machineNoun)
                    }

                    /*
                     * *"On the main page of settings just give it there, as
                     * optional for the overall application."* Here it is, and
                     * this is the only place in the app that mentions it: one
                     * switch, off until somebody moves it, below the rows about
                     * this phone because it is a fact about getting in rather
                     * than a fact about looking at it. See `AppLockSection` — it
                     * draws its own caption and card so it can sit here as one
                     * line.
                     */
                    AppLockSection(lock: lock)

                    /*
                     * **There is no Appearance section here any more, and no
                     * Terminal row under it.**
                     *
                     * It was a caption with two controls: the app's own
                     * light/dark as a segmented picker, and a *Terminal* row
                     * that pushed the colours and the size. That was already one
                     * consolidation — the size had been a section of its own
                     * three groups further down — and it was still not what he
                     * asked for, because the size was *also* still in every
                     * session's `…` menu:
                     *
                     * > *"overall appearance page should be there in the
                     * > settings and from there we can change colors text size
                     * > and everything for all of them."*
                     *
                     * A page. So all three controls are on one, `AppearanceView`,
                     * reached by the Appearance row in *This phone* above. A
                     * section called Appearance sitting beside a row called
                     * Appearance would have been the two-places-for-one-answer
                     * fault a third time, and this app has now made that mistake
                     * twice in the same corner of the same screen.
                     */

                    SectionCaption("About")

                    SettingsGroup {
                        HStack(spacing: 12) {
                            // The icon is here to hold the text on the same left
                            // edge as the rows above it. Rendered without one,
                            // the About row's name started 68 points to the left
                            // of GitHub's and the two groups read as belonging to
                            // different screens.
                            //
                            // Which means the two numbers have to be `SettingsRowBody`'s
                            // two numbers, not near them. They were 15-in-18
                            // against its 19-light-in-24, so this row's name and
                            // GitHub's were six points apart — a smaller version
                            // of the same fault, and the one the new divider
                            // inset makes visible.
                            Image(systemName: "info.circle")
                                .font(.system(size: 19, weight: .light))
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 24)
                            Text(Brand.name)
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.primary)
                            Spacer(minLength: 8)
                            Text(Brand.version)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(Theme.faint)
                                .accessibilityIdentifier("settings.version")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)

                        /*
                         * What the machine at the other end is running.
                         *
                         * Drawn only when the host said — every desktop before
                         * 0.10.0 sends no version, and absent stays silent rather
                         * than guessing. Display text and nothing to press: there
                         * is no update verb on this wire, so the one honest thing
                         * a phone can say when its own build is ahead is a
                         * sentence, below. `hostKind` names the box — *server* for
                         * a headless host, *desktop* otherwise.
                         */
                        if let host = model.current, let version = host.hostAppVersion {
                            SettingsDivider()
                            HStack(spacing: 12) {
                                Image(systemName: host.hostKind == .headless ? "server.rack" : "desktopcomputer")
                                    .font(.system(size: 19, weight: .light))
                                    .foregroundStyle(Theme.secondary)
                                    .frame(width: 24)
                                Text("This \(host.hostKind.noun)")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.primary)
                                Spacer(minLength: 8)
                                Text(version)
                                    .font(.system(size: 14, design: .monospaced))
                                    .foregroundStyle(Theme.faint)
                                    .accessibilityIdentifier("settings.hostVersion")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                        }
                    }

                    // The one sentence a phone can honestly say when its own build
                    // is ahead of the machine's: there is nothing to press here,
                    // because replacing a host stays on the desktop and SSH plane.
                    if let host = model.current, let version = host.hostAppVersion,
                       versionIsBehind(version, than: Brand.version) {
                        Text("This \(host.hostKind.noun) is running an older build. Update it from a desktop.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                            .padding(.top, 8)
                            .accessibilityIdentifier("settings.hostBehind")
                    }

                    Text("This phone talks to your own machines. There is no notification server "
                         + "in \(Brand.name), so a phone that has been asleep is caught up the next "
                         + "time it connects rather than woken.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                        .accessibilityIdentifier("settings.noPushNote")

                    // And room for the pill that floats over the bottom of this
                    // screen — the one he photographed drawn across the words
                    // "Terminal Deck". See `TabBarClearance`.
                    TabBarClearance()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("Menu")
        .navigationBarTitleDisplayMode(.inline)
        // Permission can be changed in the Settings app while this app is not
        // running, so the Alerts row's value is re-read rather than remembered.
        .task { await model.refreshAlertPermission() }
        .onChange(of: model.showingAlerts) { _, showing in
            if !showing { alertsRevision += 1 }
        }
    }

    /// How many machines this phone is paired with — *"how many machines we pair
    /// can go inside the settings actually"*, which is the sentence that put this
    /// row here. The count rather than the current machine's name, because the
    /// name is already in the title on Sessions and the count is the thing this
    /// screen is being asked.
    private var machinesValue: String {
        model.hosts.count == 1 ? "1 paired" : "\(model.hosts.count) paired"
    }

    /**
     * What the Appearance row says without being opened: the terminal text size
     * and the colour scheme, in that order.
     *
     * *"12 pt · Follow the app"* on a fresh install, *"11 pt · Pure Black"* once
     * somebody has chosen. Both, because the row now stands for a page holding
     * both and a summary that named only one of them would be an invitation to
     * open the page to find out about the other — which is the tap this row
     * exists to save. Size first for what happens when the pair is too wide;
     * the reasoning is on the row itself.
     *
     * The size comes from `storedTextSize`, which is the `@AppStorage` binding
     * rather than `TextSize.stored`, and is put back through `clamp` for the
     * same reason `stored` does it: a value written by a build with different
     * bounds must not be read out raw. `@AppStorage` hands back the declared
     * default when the key is absent, so a fresh install lands on `standard`
     * without a special case.
     */
    private var appearanceValue: String {
        "\(TextSize.label(TextSize.clamp(CGFloat(storedTextSize)))) · \(themes.selectedName)"
    }

    /// The Devices row's summary before it is opened. The count once the roster
    /// has been read on some visit, and nothing before — the row does not poll a
    /// figure it does not have, the same rule the bar keeps for a figure it has
    /// not been told.
    private var devicesValue: String {
        guard let count = model.current?.devices.rows?.count else { return "" }
        return count == 1 ? "1 signed in" : "\(count) signed in"
    }

    /**
     * Whether `host` is an older build than `app`, comparing the release cores
     * numerically. A version this app cannot parse returns false — it claims
     * "behind" only when it is sure, so an unfamiliar version string never puts
     * an "update this" sentence on screen wrongly. A prerelease of the same core
     * (`0.10.0-rc.1`) is behind the release, the same order a tag sorts in.
     */
    private func versionIsBehind(_ host: String, than app: String) -> Bool {
        func parts(_ v: String) -> (core: [Int], pre: Bool)? {
            let core = v.split(separator: "-", maxSplits: 1).first.map(String.init) ?? v
            let nums = core.split(separator: ".").map { Int($0) }
            guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
            return (nums.map { $0! }, v.contains("-"))
        }
        guard let h = parts(host), let a = parts(app) else { return false }
        let width = max(h.core.count, a.core.count)
        for i in 0..<width {
            let hv = i < h.core.count ? h.core[i] : 0
            let av = i < a.core.count ? a.core[i] : 0
            if hv != av { return hv < av }
        }
        // Same core: a prerelease host is behind a release app, not the reverse.
        return h.pre && !a.pre
    }

    /// What the Alerts row says without being opened. A row that always read
    /// "Alerts" would have to be tapped to find out nothing had changed.
    private var alertsValue: String {
        switch model.alertPermission {
        case .none: return ""
        case .notAsked: return "Off"
        case .denied: return "Blocked"
        case .allowed, .other:
            let on = [AlertSettings.needsYou, AlertSettings.finished].filter { $0 }.count
            switch on {
            case 0: return "None"
            case 1: return "1 kind"
            default: return "On"
            }
        }
    }
}

/// A card holding rows. The design brief again: separate with space, then with a
/// tint, and only then with a line — so the group is a fill with a radius and the
/// rows inside it are separated by the one hairline that space genuinely cannot
/// replace, because two rows in one card have no gap between them.
private struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/**
 * The hairline between two rows, inset to the **label's** left edge rather than
 * the card's.
 *
 * That is what both apps Asad put beside this one do, and it is the difference
 * between a stack of rows that reads as one list and a stack that reads as a
 * column of boxes: the line starts where the words start, so the icons sit in a
 * clear gutter of their own.
 *
 * 52 is arithmetic rather than taste — the row is `.padding(.horizontal, 16)`,
 * its icon column is 24 wide and the `HStack` spacing is 12. It was 46, which
 * was the same sum back when the icons were 18 points. The icons grew with the
 * palette and this did not, so every line stopped six points short of the word
 * it was drawn to start under.
 */
private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 52)
    }
}

private struct SectionCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 24)
            .padding(.bottom, 8)
    }
}

/**
 * What a settings row looks like: an icon, a title, what it currently is, and a
 * chevron. The value is the whole point — see `DeckSettingsView.alertsValue`.
 *
 * Split out from `SettingsRow` because two rows on this screen do two different
 * things with the same appearance: most of them raise a sheet and are buttons,
 * and Machines pushes a screen and is a `NavigationLink`. Drawing the row twice
 * is how the pushed one ends up two points taller than its neighbours.
 */
private struct SettingsRowBody: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            /*
             * Monoline, and the two numbers are the whole of it.
             *
             * Both apps Asad pointed at draw row icons as a **consistent thin
             * stroke at about 21 points**. This was regular weight at 15, which
             * is SF Symbols' default and therefore what every iOS app that has
             * not thought about it looks like — the exact complaint. Light
             * weight makes the stroke monoline; the larger size is what stops a
             * thinner stroke reading as faded.
             */
            Image(systemName: icon)
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.secondary)
                .frame(width: 24)
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// One tappable row that raises something.
private struct SettingsRow: View {
    let title: String
    let value: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRowBody(title: title, value: value, icon: icon)
        }
        .buttonStyle(.plain)
    }
}
