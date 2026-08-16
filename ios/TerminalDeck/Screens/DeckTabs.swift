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
 * ## Why three tabs and not five
 *
 * Because there are three things, and inventing a fourth would mean shipping a
 * tab that leads to a placeholder. The desktop's sidebar has ten entries and most
 * of them are a file tree, a diff, a search box or a browser — surfaces that are
 * not written for a phone and would not be honest as an empty screen with an
 * icon on it. He was clear about this on the desktop in the same recording:
 * *"I don't see any kind of files here"*, *"also looking empty"*, *"I don't know
 * what I can search here"*. Copying those onto a phone would be copying the
 * complaint.
 *
 * What is here is what the app can actually do:
 *
 * | Tab | What is on it | Was |
 * |---|---|---|
 * | **Sessions** | the machine's sessions, and its dev servers | the whole app |
 * | **Machines** | every paired machine, live, with rename / forget / pair | four items in the overflow menu |
 * | **Settings** | GitHub, alerts, terminal text size, what the app is | three more items in the same menu |
 *
 * The localhost list stays on Sessions rather than becoming a fourth tab. It is
 * *what is running on this machine* — the same question the session list asks —
 * and it is empty on a machine that is not serving anything, which would make the
 * tab bar's fourth item lead to nothing most of the time.
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
 * ## What did not move
 *
 * The session list's `…` menu still holds **Refresh** and **Reconnect now**,
 * because those act on the list that is on screen. Everything in it that was
 * about a machine or about the app has moved to a tab and is not duplicated
 * there — *"options is having all of the things that we already have here and
 * there. So let's keep everything separate rather than having everything on one
 * page."*
 */

import SwiftUI

struct DeckTabs: View {
    @Bindable var model: DeckModel

    var body: some View {
        TabView(selection: $model.tab) {
            NavigationStack(path: $model.route) {
                SessionListView(model: model)
                    .navigationDestination(for: DeckModel.Route.self) { route in
                        switch route {
                        case let .session(host, id):
                            TerminalScreen(model: model, hostID: host, sessionID: id)
                        }
                    }
            }
            .tabItem { Label("Sessions", systemImage: "terminal") }
            .tag(DeckModel.Tab.sessions)

            NavigationStack {
                MachinesView(model: model)
            }
            .tabItem { Label("Machines", systemImage: "desktopcomputer") }
            .tag(DeckModel.Tab.machines)

            NavigationStack {
                DeckSettingsView(model: model)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(DeckModel.Tab.settings)
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
                    .buttonStyle(MachineRowStyle())
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
                        Text(host.label)
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
                    Label("Forget \(host.label)", systemImage: "minus.circle")
                }
                .accessibilityIdentifier("machine.forget")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.faint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(host.label)")
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

/// The card's press state. `.plain` would leave a row that navigates looking
/// identical before, during and after a press — see `SessionListView`, which
/// makes the same trade for the same reason.
private struct MachineRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
 * Three rows and a paragraph. Asad on the desktop's settings page, in the same
 * recording: *"we don't need this much of big descriptions under each. The whole
 * page is going to be used just because of the big descriptions."* So each row is
 * a line, and the only paragraph on the screen is the one that says what alerts
 * genuinely cannot do — which is the one piece of prose in this app that has
 * repeatedly earned its place, because the alternative is somebody waiting two
 * hours for a buzz that was never coming.
 */
struct DeckSettingsView: View {
    let model: DeckModel

    /// The terminal's point size. Mirrored into `@State` because `TextSize` is a
    /// `UserDefaults` façade rather than an observable object — the same shape
    /// the alert switches use, and for the same reason: the control responds to
    /// the finger rather than to a store round trip.
    @State private var textSize = TextSize.stored

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

/// One tappable row: an icon, a title, what it currently is, and a chevron. The
/// value is the whole point — see `DeckSettingsView.alertsValue`.
private struct SettingsRow: View {
    let title: String
    let value: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
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
        .buttonStyle(.plain)
    }
}
