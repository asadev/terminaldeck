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
                .tabItem { Label("Copilot", systemImage: "sparkles") }
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
            .tabItem { Label("Sessions", systemImage: "terminal") }
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
                LocalhostListView(model: model)
            }
            // The page is `@State` inside that view rather than a path, so what
            // is on top of this tab is answered by a flag the browser sets. See
            // `DeckModel.localhostPageIsOpen`.
            .toolbar(DeckChrome.tabBar(on: model.localhostSurface), for: .tabBar)
            .tabItem { Label("Localhost", systemImage: "globe") }
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
                        }
                    }
            }
            // Machines keeps the bar — *"Pill should be on here only on the
            // homepage or machines or settings"* — so this is `.visible` in both
            // states. Stated rather than omitted so the screen has made the
            // decision out loud, and so the rule is not "hidden when pushed".
            .toolbar(DeckChrome.tabBar(on: model.settingsSurface), for: .tabBar)
            .tabItem { Label("Settings", systemImage: "gearshape") }
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
            CopilotView(model: model, hostID: host.id)
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

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.hosts) { host in
                        MachineRow(host: host,
                                   // From the model, not the host: two machines
                                   // reporting one hostname drew two identical
                                   // rows until the list broke the tie. See
                                   // `DeckModel.label(for:)`.
                                   name: model.label(for: host),
                                   isCurrent: host.id == model.current?.id,
                                   select: { model.select(host.id) },
                                   rename: { DispatchQueue.main.async { model.beginRename(host.id) } },
                                   forget: { model.unpair(host.id) })
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
                    .padding(.top, 6)
                    .accessibilityIdentifier("machines.add")

                    if let error = model.lastError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .padding(.top, 14)
                            .onTapGesture { model.dismissError() }
                    }

                    // The one sentence on this screen, and it earns its place:
                    // it is the answer to "why can this phone see my Mac", and
                    // it is where somebody looks after unpairing something by
                    // accident.
                    Text("A machine stays on this list until you forget it. Forgetting one leaves "
                         + "every other machine alone.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 18)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .scrollBounceBehavior(.basedOnSize)
            .refreshable {
                model.refreshAll()
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
        .navigationTitle("Machines")
        .navigationBarTitleDisplayMode(.inline)
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
 */
private struct MachineRow: View {
    let host: HostLink
    /// What this row is called *in this list* — see `DeckModel.label(for:)`.
    let name: String
    let isCurrent: Bool
    let select: () -> Void
    let rename: () -> Void
    let forget: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "desktopcomputer")
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

            Menu {
                Button {
                    rename()
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .accessibilityIdentifier("machine.rename")

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
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    /// The terminal's point size. Mirrored into `@State` because `TextSize` is a
    /// `UserDefaults` façade rather than an observable object — the same shape
    /// the alert switches use, and for the same reason: the control responds to
    /// the finger rather than to a store round trip.
    @State private var textSize = TextSize.stored

    /**
     * Light, dark, or the phone's own setting.
     *
     * `@AppStorage` rather than the `@State`-mirror shape the row above uses,
     * and the difference is which way the value has to travel. Text size is read
     * by the terminal when a session opens, so a store write is enough. This one
     * has to reach `RootView` — three screens up, above the `TabView` — on the
     * same frame as the tap, and `@AppStorage` on both ends is a live view of
     * the same defaults key rather than a binding threaded through four screens
     * that do not care.
     */
    @AppStorage(Appearance.key) private var appearance: Appearance = .system

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

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
                         * The machine's own browser, live: watch one of its
                         * windows and drive it with a finger. Drawn only over a
                         * host that advertised `watch` — withheld from a guest at
                         * the source, because watching a signed-in browser is an
                         * owner act. See `WatchSurfacesView`.
                         */
                        if model.current?.watch.offered == true {
                            NavigationLink(value: DeckModel.SettingsRoute.watch) {
                                SettingsRowBody(title: "Watch browser",
                                                value: "",
                                                icon: "macwindow.on.rectangle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings.watch")

                            SettingsDivider()
                        }

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
                    }

                    // The two settings the current machine owns rather than this
                    // phone — the coding tool a fresh session starts with, and
                    // whether the last layout is restored. Draws nothing over a
                    // host that did not advertise `settings`, so an older desktop
                    // or a guest sees exactly what it did before.
                    if let host = model.current {
                        ServerSettingsSection(settings: host.serverSettings)
                    }

                    SectionCaption("Appearance")

                    SettingsGroup {
                        /*
                         * Three segments rather than a switch, because there are
                         * three answers and one of them is the important one:
                         * *System*, which is the default and the only choice
                         * that keeps tracking the phone after it is made. A
                         * two-state control would have had to drop it, and an
                         * app that cannot follow the phone's own setting is an
                         * app that comes up white at midnight.
                         *
                         * The picker takes the whole width on its own line
                         * rather than sitting beside a title. Rendered the other
                         * way at 375 points — the narrowest phone this app
                         * supports — the three segments were 190 points between
                         * them and "System" was clipped to "Syste".
                         *
                         * Writing to it writes the defaults key, which is the
                         * same key `RootView` reads, so the window repaints on
                         * the same frame and the choice is already saved. There
                         * is no Apply and nothing to confirm.
                         */
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Image(systemName: "circle.lefthalf.filled")
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.secondary)
                                    .frame(width: 18)
                                Text("Theme")
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.primary)
                                Spacer(minLength: 8)
                            }

                            Picker("Theme", selection: $appearance) {
                                ForEach(Appearance.allCases) { choice in
                                    Text(choice.label).tag(choice)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .accessibilityIdentifier("settings.appearance")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    SectionCaption("Terminal")

                    SettingsGroup {
                        /*
                         * The same setting the pinch and the session menu change,
                         * read and written through `TextSize`, which is where the
                         * clamping and the whole-point rounding live. It is here
                         * as well as in the terminal because it is a property of
                         * the person's eyes rather than of one session — see
                         * `TextSize` — and because a setting you can only reach
                         * by opening a session is a setting somebody with a
                         * nine-point terminal cannot read well enough to find.
                         */
                        HStack(spacing: 12) {
                            Image(systemName: "textformat.size")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 18)
                            Text("Text size")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.primary)
                            Spacer(minLength: 8)
                            Text(TextSize.label(textSize))
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(Theme.faint)
                            Stepper("Text size", value: $textSize,
                                    in: TextSize.minimum...TextSize.maximum,
                                    step: TextSize.step)
                                .labelsHidden()
                                .onChange(of: textSize) { _, size in TextSize.save(size) }
                                .accessibilityIdentifier("settings.textSize")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    Text("A session already open picks this up the next time you open it — the "
                         + "column count is the font, so changing it resizes the session on the "
                         + "machine.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)

                    SectionCaption("About")

                    SettingsGroup {
                        HStack(spacing: 12) {
                            // The icon is here to hold the text on the same left
                            // edge as the rows above it. Rendered without one,
                            // the About row's name started 68 points to the left
                            // of GitHub's and the two groups read as belonging to
                            // different screens.
                            Image(systemName: "info.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.secondary)
                                .frame(width: 18)
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
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.secondary)
                                    .frame(width: 18)
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
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("Settings")
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
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 46)
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
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .frame(width: 18)
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
