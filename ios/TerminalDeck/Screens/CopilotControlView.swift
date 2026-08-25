/**
 * **The copilot's controls** — everything about it a person operates, on the one
 * screen reached from the button in the Copilot tab's top right.
 *
 * ## The correction this file exists for
 *
 * A previous lane read *"here on the right top corner you can give a button for
 * all about copilot"* as a reading page, and built a good one. Asad, looking at
 * it:
 *
 * > *"When I said that you need to add a button which will be all about copilot
 * > in the copilot page, it doesn't mean like information about copilot. I meant
 * > all the control about copilot, all the settings of the copilot, and
 * > everything related to copilot that we need to have as options and control
 * > and settings — whatever, three dots, maybe your settings button, whatever it
 * > is — all the consistent required things, or whatever permanent settings,
 * > folders, everything, instructions, whatever we need for it."*
 *
 * So the button opens a **control panel**. The prose is not thrown away — it is
 * factually checked and well written — it is demoted to the last row, behind a
 * chevron, where somebody who wants it can find it and nobody else meets it.
 *
 * ## The rule this screen is written under
 *
 * **Nothing is drawn that cannot act.** That is the whole of the correction: he
 * asked for controls, and a screen full of controls that do nothing would be
 * worse than the essay, because an essay at least does not lie about what
 * pressing it will do. Every row below either sends a frame this app already
 * sends, writes a record this app already reads, or pushes a screen that
 * already exists. Three things a control panel for a copilot obviously *should*
 * have are missing, and each one is missing because it is not on the wire:
 *
 *  - **Its instructions, and its name.** The desktop keeps both in
 *    `<userData>/copilot-layer/instructions.md` and hands the file to the CLI at
 *    spawn; `shared/copilot-identity.ts` says why there is no `copilot.name`
 *    setting anywhere. Nothing carries that file over the relay — `protocol.ts`
 *    has no `instructions` frame in either direction — so a field here would be
 *    a text box that saves to nothing. It is named in the ⓘ on the setup caption
 *    instead, pointing at where it *is* editable.
 *  - **Its folder, on a desktop.** `copilot-folder.ts` stores it as
 *    `copilot.home`, deliberately under the `copilot.` prefix so that
 *    `PROTECTED_SETTING_PREFIXES` refuses a `settings.write` to it, and the
 *    remote wire's own `SERVER_SETTINGS` is a two-key allowlist that does not
 *    include it. So a desktop's copilot folder cannot be read here, let alone
 *    set. On a **server** there is no `copilot.home` at all — the copilot is an
 *    ordinary agent session — and *which folder it starts in* is this phone's
 *    decision, which is why that row exists there and not here.
 *  - **Model, effort, permission, and the token spend.** `controls.read`,
 *    `controls.apply` and `usage.read` all take a **session id**, and the
 *    copilot's run is registered with `hideSession` — `hidden-sessions.ts` puts
 *    every per-device run in a set that `mayTouch` refuses, so those three
 *    frames answer `unknown-session` for the one session this screen is about.
 *    That is a deliberate boundary (*"a phone that could attach to its own run's
 *    pty would hold `alter` no matter what its grant said"*), not a gap, so the
 *    chips are absent rather than drawn dim. What the machine *does* volunteer
 *    about the cost — `CopilotState.tools` and `turnTokens` — is printed, as a
 *    reading rather than a control.
 *
 * ## Two machines, two screens
 *
 * A desktop has a real copilot with five states (`notOffered`, `connecting`,
 * `notGranted`, `watch`, `direct` — there is no `connected`), a grant with three
 * tiers, an action log and a run this phone can start and stop. A server has
 * **none of that**: no copilot, no grant, no log. Its copilot is an agent
 * session, so its controls are the ones that shape a session — which folder,
 * which agent, and whether to end it. `CopilotControl.panels` decides which
 * sections a machine gets, as a pure function, because the way this screen goes
 * wrong is by showing a desktop's section over a server and refusing on every
 * press.
 *
 * ## No long descriptions, and no tab bar
 *
 * > *"Remove this full shit. I don't want any kind of long descriptions
 * > anywhere. Just if somewhere it's very required, give the i icon."*
 *
 * Every caption on this screen is two or three words and every explanation is
 * behind an `InfoDot`. `DeckChrome.showsTabBar(on: .copilot)` and
 * `showsTabBar(on: .session)` are both false and a view-based push leaves
 * `copilotRoute.last` alone, so no bar floats over this screen from either
 * perch and a `TabBarClearance()` would be reserving room against a control that
 * is not drawn. Checked rather than copied from the settings-stack screens,
 * which do keep the bar — `DeviceRosterView`, pushed from here, carries its own
 * and measures zero on this stack.
 */

import SwiftUI

struct CopilotControlView: View {
    let model: DeckModel
    /// Named rather than read off `model.current`, for the reason every screen
    /// on this tab names its machine: the switcher in the title one level up can
    /// move underneath a pushed view, and a screen that followed it would offer
    /// one machine's controls under another machine's name.
    let hostID: String
    /// The seam the tests use. A default argument on a memberwise initialiser,
    /// which is why `CopilotSetupBook` is not `@MainActor` — see that file.
    var book: CopilotSetupBook = .shared

    /// The folder picker, presented from here rather than through
    /// `DeckModel.showingFolderPicker`. That flag has exactly one callback, in
    /// `RootView`, and it starts a session; this screen wants the answer to
    /// *which folder* without starting anything, which is the split
    /// `FolderPickerView` already documents about itself.
    @State private var picking = false
    @State private var showingActivity = false
    @State private var showingSessions = false
    @State private var prompt: CopilotPrompt?
    /// A refusal this screen caused and must therefore explain. `HostLink`'s own
    /// `lastError` is `private(set)` and its sentences are written for the
    /// session list.
    @State private var notice: String?

    private var host: HostLink? { model.host(hostID) }
    private var link: CopilotLink? { host?.copilot }

    /// What to call the box on the other end — `server` for a headless host,
    /// the platform's own noun otherwise. `DeckModel.machineNoun` answers this
    /// for `model.current`; this screen names its machine explicitly, so it
    /// asks the same question of that one.
    private var machineNoun: String {
        guard let host else { return "machine" }
        return host.hostKind == .headless ? "server" : host.hostPlatform.noun
    }

    private var reading: CopilotControl.Reading {
        guard let host else {
            return CopilotControl.Reading(kind: .unknown, access: .notOffered)
        }
        return CopilotControl.Reading(
            kind: host.hostKind,
            access: host.copilotAccess,
            grant: host.copilot.grant,
            setUp: book.isSetUp(host: hostID),
            canPickFolders: host.canPickFolders,
            settingsOffered: host.serverSettings.offered,
            devicesOffered: host.devices.offered,
            hasCopilotSession: copilotSession != nil,
            hasRun: host.copilot.hasRun,
            waiting: host.copilot.waitingCount)
    }

    /// The session this machine's copilot **is**, on a server. One reading of
    /// it, shared with the landing — see `CopilotOnServer.copilotSession`, which
    /// is where the rule lives so that this screen and the tab cannot come to
    /// disagree about which session the copilot is.
    private var copilotSession: RemoteSession? {
        guard let host else { return nil }
        return CopilotOnServer.copilotSession(in: host.sessions,
                                              folder: book.folder(host: hostID))
    }

    var body: some View {
        ZStack {
            // Painted here: this screen is pushed and is its own root, so unlike
            // `CopilotOnServerView` there is nothing underneath it to inherit a
            // ground from.
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(CopilotControl.panels(reading)) { panel in
                        section(panel)
                    }
                    if let notice {
                        Text(notice)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                            .padding(.top, 10)
                            .accessibilityIdentifier("copilot.controls.notice")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("Copilot")
        .navigationBarTitleDisplayMode(.inline)
        // The two settings the machine owns are read on arrival rather than by
        // the caller, so every way in lands on a section that is already filling
        // rather than one that needs a second visit. Idempotent — the link
        // refuses a second read on the same connection itself.
        .onAppear { host?.serverSettings.ensureRead() }
        .onChange(of: host?.serverSettings.rows == nil) { _, unknown in
            if unknown { host?.serverSettings.ensureRead() }
        }
        .sheet(isPresented: $picking) {
            FolderPickerView(model: model, action: .choose) { folder in
                book.setFolder(folder, host: hostID)
                notice = nil
            }
        }
        .sheet(isPresented: $showingActivity) {
            CopilotActivitySheet(model: model, hostID: hostID) { showingActivity = false }
        }
        .sheet(isPresented: $showingSessions) {
            CopilotSessionsSheet(model: model, hostID: hostID) { showingSessions = false }
        }
        .sheet(item: $prompt) { showing in
            switch showing {
            case let .decide(question):
                CopilotConsentSheet(question: question,
                                    settlement: link?.settlement(for: question.id),
                                    machine: host?.label ?? "that machine",
                                    noun: machineNoun,
                                    answer: { approved in
                                        link?.answer(question.id, approved: approved) ?? false
                                    },
                                    dismiss: {
                                        link?.dismissSettled(question.id)
                                        prompt = nil
                                    })
            case let .watch(question):
                CopilotWatchSheet(question: question,
                                  machine: host?.label ?? "that machine",
                                  noun: machineNoun) { prompt = nil }
            }
        }
    }

    // MARK: - The sections

    @ViewBuilder
    private func section(_ panel: CopilotControl.Panel) -> some View {
        switch panel {
        case .whenYouOpen: whenYouOpen
        case .agent: agent
        case .session: session
        case .permissions: permissions
        case .run: run
        case .history: history
        case .devices: devices
        case .about: about
        }
    }

    // MARK: - Setup

    /**
     * What the tab does when it opens — which is the setup, and on a server it
     * is the whole of it.
     *
     * > *"We will first of all do the setup of a copilot just like we do on
     * > desktop application, and then it will be always opening in the same
     * > folder."*
     *
     * The desktop's own flow (`copilot-setup-model.ts`) asks four questions:
     * the copilot's name, what it should call you, the folder, and the account.
     * Three of the four are unreachable from a phone — the first two are written
     * into the copilot's instruction file, which has no frame, and the account
     * is chosen from the desk's own logins. The **folder** is the one that
     * crosses, and on a server it is the only one that exists at all. So this is
     * that step, under the same question the desktop asks over it, and the ⓘ
     * says where the other three live rather than drawing them dead.
     *
     * **It is not a flow, and it is not asked before anything works.** That is
     * the correction this section is on the other end of: the Copilot tab used
     * to draw a chooser until a folder had been picked, and he struck it —
     * *"directly land into some session, not to a selection and something on the
     * page."* So the tab starts, records the folder it landed in, and this is
     * where that folder is **shown and changed**. The row is a setting a person
     * comes to when they want it, not a toll on the way in.
     */
    private var whenYouOpen: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("When you open this tab", about: "the copilot's setup", says: Self.aboutSetup)
            card {
                if reading.kind == .headless {
                    folderRow
                    line
                }
                startOnOpenRow
                if reading.setUp {
                    line
                    forgetRow
                }
            }
        }
    }

    private static let aboutSetup =
        "Where the copilot works, and whether this tab starts one for you. Both are this "
        + "phone's, kept for this machine only. The folder is filled in from the first session "
        + "this tab starts, and can be changed here at any time. Its name and its standing "
        + "instructions live in the desktop app, in the file it is handed every time it "
        + "starts, and are not carried over this connection — edit them there."

    /**
     * Which folder the copilot works in — a server's copilot, which is a
     * session, and therefore a folder this phone genuinely chooses.
     *
     * Pressable only when the machine advertised `folders.pick`. Without it this
     * app cannot list a directory on that machine at all, so a row that opened a
     * picker would open one that cannot fill — which is the dead control this
     * screen is written against. The path is still shown, because a folder
     * chosen while the capability was there is still the folder in use.
     */
    @ViewBuilder
    private var folderRow: some View {
        let folder = book.folder(host: hostID)
        if reading.canPickFolders {
            Button {
                guard host?.id == model.currentHostId else {
                    notice = "Switch to this \(machineNoun) to walk its folders."
                    return
                }
                picking = true
            } label: {
                valueRow(title: "Working folder",
                         // Not "Not chosen": nothing is waiting on a choice. The
                         // tab starts in the machine's own folder and writes down
                         // what that turned out to be, so this fills itself in
                         // within a second of the copilot first being opened.
                         value: folder ?? "Set from the first session it starts",
                         mono: folder != nil,
                         chevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("copilot.controls.folder")
        } else {
            valueRow(title: "Working folder",
                     value: folder ?? "This \(machineNoun) is not sharing its folders",
                     mono: folder != nil,
                     chevron: false)
                .accessibilityIdentifier("copilot.controls.folder.readonly")
        }
    }

    /**
     * The gate on the one behaviour Asad overruled an earlier decision to get.
     *
     * That decision — a `Landing` type with no `.start` case, because *"a tab is
     * reached by accident"* and a session on a server runs a real agent that
     * spends real money — was right about the danger and wrong about the
     * conclusion, and he is entitled to overrule it: once a folder has been
     * chosen on purpose, starting a session there is what he asked the tab to
     * do. So the case exists and **this switch is the only way to reach it**. A
     * machine nobody has set up starts nothing, however reachable it is.
     *
     * **It is on until somebody moves it**, on both kinds of machine, because an
     * absent record means *yes* — see `CopilotSetupBook.isArmed`. So this row is
     * the off-ramp rather than the on-ramp: the one place to say *do not spend
     * money on this machine when I open this tab*, and the decision is written
     * down so it survives the next visit.
     */
    private var startOnOpenRow: some View {
        let on = book.isArmed(host: hostID)
        let what = reading.kind == .headless ? "a session" : "a run"
        return Button {
            book.setStartOnOpen(!on, host: hostID)
            notice = nil
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start \(what) if none is running")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Spends money on this \(machineNoun)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 8)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(on ? Theme.accent : Theme.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("copilot.controls.startOnOpen")
        .accessibilityValue(on ? "On" : "Off")
    }

    /// Forget the folder and the switch, so both are worked out again.
    ///
    /// No longer *"ask me again"* — nothing asks — but still a real thing to
    /// want: a copilot pinned to a folder that has since been deleted or renamed
    /// would start there and fail every visit, and one press puts the machine
    /// back to letting its own default decide. Destructive because the folder
    /// goes with it.
    private var forgetRow: some View {
        Button(role: .destructive) {
            book.forget(host: hostID)
            notice = nil
        } label: {
            HStack {
                Text("Forget this setup")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.critical)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("copilot.controls.forget")
    }

    // MARK: - The agent

    /**
     * Which agent the copilot is, on a server — `agents.defaultProvider`,
     * written with `settings.apply`.
     *
     * This is not the same question the Settings screen asks with the same
     * value. There it is *"Default coding tool"* under *"This server"*, a fact
     * about every session anybody starts. Here it is **which agent your copilot
     * is**, because on a server the copilot *is* a session started with this
     * setting — `host-core.ts` reaches for
     * `input.provider ?? store().getPreferences().defaultProvider` when a
     * `create` names none, and this tab's `create` names none.
     *
     * One value, one write path: both screens hold the same `ServerSettingsLink`
     * off the same `HostLink`, so they cannot disagree about what it currently
     * is. Only the label differs, because only the question does.
     *
     * Absent on a desktop, and that absence is a fact rather than a gap: a
     * desktop's copilot is the desktop app's own Claude CLI over loopback and
     * this setting has no bearing on it. Drawing it there would be a control
     * that acts on something other than what the screen says it acts on, which
     * is the same defect as one that does not act at all.
     */
    @ViewBuilder
    private var agent: some View {
        if let row = host?.serverSettings.rows?.first(where: { $0.key == .defaultProvider }) {
            let working = host?.serverSettings.busy == .defaultProvider
            // The ids this host said it can actually start. If it sent none the
            // current value is still offered, so the control is never empty.
            let ids = (row.options?.isEmpty == false) ? row.options! : [row.value]
            VStack(alignment: .leading, spacing: 0) {
                caption("The agent", about: "the copilot's agent", says: Self.aboutAgent)
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("What a new session runs")
                                .font(.system(size: 16))
                                .foregroundStyle(Theme.primary)
                            Spacer(minLength: 8)
                            if working {
                                Text("Working…")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.faint)
                            }
                        }
                        // Chips at `ServerSettingsSection`'s metrics and with its
                        // colours — a solid accent pill for the chosen one, a
                        // tint plus a hairline for the rest. That section records
                        // why: `Theme.surfaceHigh` on `Theme.background` is a
                        // chip you cannot see on paper, and disabling the chosen
                        // chip dims the one answer on the screen.
                        CopilotChipRow(spacing: 8) {
                            ForEach(ids, id: \.self) { id in
                                let chosen = id == row.value
                                Button {
                                    if !chosen { host?.serverSettings.apply(.defaultProvider, id) }
                                } label: {
                                    Text(ServerSettingsText.providerLabel(id))
                                        .font(.system(size: 14, weight: chosen ? .semibold : .regular))
                                        .foregroundStyle(chosen ? Theme.onAccent : Theme.primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(chosen ? Theme.accent : Theme.pressed)
                                        .clipShape(Capsule())
                                        .overlay(Capsule()
                                            .strokeBorder(chosen ? Color.clear : Theme.hairline,
                                                          lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .disabled(working)
                                .accessibilityAddTraits(chosen ? [.isSelected] : [])
                                // By provider id rather than by label: the id is
                                // what the wire and the machine both use.
                                .accessibilityIdentifier("copilot.controls.provider.\(id)")
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                if let sentence = host?.serverSettings.notice {
                    Text(sentence.text)
                        .font(.system(size: 12))
                        .foregroundStyle(sentence.ok ? Theme.secondary : Theme.critical)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                        .accessibilityIdentifier("copilot.controls.agentNotice")
                }
            }
        }
    }

    private static let aboutAgent =
        "This server owns this one, not this phone — every device that reaches it sees the "
        + "same choice, and it is the same value Settings calls the default coding tool. It "
        + "decides what a session started from here has in it."

    // MARK: - The session (a server's copilot)

    /// What can be done to the copilot's own session, when there is one. Both
    /// rows are verbs this app already sends: `model.open(session:on:)` pushes
    /// the conversation onto this tab's stack, and `closeSession` is the frame
    /// the session list sends, refusable by the machine and never optimistic.
    @ViewBuilder
    private var session: some View {
        if let running = copilotSession {
            VStack(alignment: .leading, spacing: 0) {
                caption("The conversation", about: nil, says: nil)
                card {
                    row(title: "Open it",
                        detail: "\(ServerSettingsText.providerLabel(running.provider)) in "
                            + "\(SessionDetails.folderName(running.cwd)).",
                        icon: "bubble.left.and.bubble.right",
                        id: "open") {
                        model.open(session: running.id, on: hostID)
                    }
                    if host?.canCloseSessions == true {
                        line
                        row(title: "End it",
                            detail: "The next visit starts a new one.",
                            icon: "xmark.circle",
                            id: "end",
                            destructive: true) {
                            host?.closeSession(running.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Permissions

    /**
     * What this phone may do with this machine's copilot, and the one control
     * that changes it.
     *
     * The three tiers are **readings, not switches**, and that is the design
     * rather than a shortcut. Pairing a device as one of his own *is* the
     * copilot's authorisation — the 2026-08-19 change deleted the separate
     * six-digit ceremony and the per-device checkboxes with it — so nothing on
     * this phone can widen its own grant, and a toggle here would be the exact
     * control `CopilotView.notGranted` refuses to draw for the same reason.
     *
     * What *can* act is the device roster: removing a device takes its copilot
     * away, and removing this one signs this phone out. That is the real
     * permission control this product has, so it is the row with the chevron.
     */
    private var permissions: some View {
        let grant = reading.grant
        return VStack(alignment: .leading, spacing: 0) {
            caption("What this phone may do", about: "the copilot's grant", says: Self.aboutGrant)
            card {
                tierRow("Watch it work", on: grant.canWatch, id: "read")
                line
                tierRow("Ask it to work", on: grant.canDirect, id: "act")
                line
                tierRow("Answer its confirmations", on: grant.canAnswer, id: "alter")
                if reading.waiting > 0 {
                    line
                    waitingRow
                }
            }
        }
    }

    private static let aboutGrant =
        "Set by how this phone was paired, at the machine — one of your own devices gets all "
        + "three, a guest is never offered the copilot at all. Nothing here can widen it."

    private func tierRow(_ title: String, on: Bool, id: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 8)
            Image(systemName: on ? "checkmark.circle.fill" : "slash.circle")
                .font(.system(size: 20))
                .foregroundStyle(on ? Theme.positive : Theme.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("copilot.controls.tier.\(id)")
        .accessibilityValue(on ? "Allowed" : "Not allowed")
    }

    /**
     * The confirmations waiting right now, and the way to answer one.
     *
     * Two errands behind one row, decided by the grant rather than by the count.
     * A phone holding `alter` gets the question it may settle; a watching phone
     * gets the one it may look at, which is `CopilotWatchSheet`'s whole purpose.
     * Drawn only when there is something waiting — a row that opened an empty
     * sheet would be furniture.
     */
    private var waitingRow: some View {
        let answerable = link?.answerableCount ?? 0
        let count = reading.waiting
        return Button {
            if let question = link?.asked.first(where: { link?.settlement(for: $0.id) == nil }) {
                prompt = .decide(question)
            } else if let looking = link?.pending.first {
                prompt = .watch(looking)
            } else {
                notice = "That confirmation has already been settled at the \(machineNoun)."
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "1 waiting to be confirmed"
                                    : "\(count) waiting to be confirmed")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.primary)
                    Text(answerable > 0 ? "Decide it here." : "It is being decided at the \(machineNoun).")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("copilot.controls.waiting")
    }

    // MARK: - This phone's run

    /**
     * The run itself: what the machine says about it, and the three verbs that
     * reach it.
     *
     * Two copilots are named separately and always have to be — `desk` is the
     * one the person at the machine is talking to, `run` is this phone's own,
     * and they move independently. `CopilotView.stateCard` got that wrong once
     * by folding them into a sentence, and the two truths read as a
     * contradiction; a chip that names its subject before its state cannot.
     *
     * Start is drawn only when the machine has said a run *can* start.
     * `available` and `reason` are on the wire so that this is a sentence rather
     * than a button that fails — the desktop knows whether the CLI is missing,
     * the account is signed out or the tool endpoint is down, and this end knows
     * none of the three.
     */
    @ViewBuilder
    private var run: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("This phone's run", about: nil, says: nil)
            card {
                if let state = link?.state {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            StateChip(subject: machineNoun.capitalized,
                                      state: CopilotControl.deskWord(state),
                                      tone: state.deskIsRunning ? Theme.positive
                                          : state.deskIsStarting ? Theme.accent : Theme.faint)
                                .accessibilityIdentifier("copilot.controls.desk")
                            StateChip(subject: "This phone",
                                      state: state.hasRun ? "running" : "none",
                                      tone: state.hasRun ? Theme.positive : Theme.faint)
                                .accessibilityIdentifier("copilot.controls.run")
                            Spacer(minLength: 0)
                        }
                        // Only what the machine actually said. A line invented
                        // for an absent field is a line about somebody else's
                        // machine — see `CopilotState`, where every optional is
                        // documented as "the desktop did not say".
                        if let account = CopilotControl.accountLine(state) {
                            Text(account)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.faint)
                                .accessibilityIdentifier("copilot.controls.account")
                        }
                        if let catalogue = CopilotControl.catalogueLine(state) {
                            Text(catalogue)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.faint)
                                .accessibilityIdentifier("copilot.controls.catalogue")
                        }
                        if !state.available, let why = state.reason {
                            Text(why)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("copilot.controls.cannotStart")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    valueRow(title: "State",
                             value: "That \(machineNoun) has not said yet",
                             mono: false,
                             chevron: false)
                }

                if reading.access == .direct {
                    if reading.hasRun {
                        line
                        row(title: "Interrupt this turn",
                            detail: "Stops what it is doing now.",
                            icon: "stop.circle",
                            id: "cancel") { link?.cancel() }
                        line
                        row(title: "Stop this phone's copilot",
                            detail: "Ends this phone's run. The one at the \(machineNoun) keeps going.",
                            icon: "xmark.circle",
                            id: "stop",
                            destructive: true) { link?.stop() }
                    } else if link?.state?.available == true {
                        line
                        row(title: "Start it",
                            detail: "Runs on the \(machineNoun) · spends money",
                            icon: "play.circle",
                            id: "start") { link?.start() }
                    }
                }
            }
        }
    }

    // MARK: - What it did

    /// The two lists that are references rather than places — sheets for the
    /// reason `SessionDetailView` is one. Both are `read` tier, which is why
    /// this whole section is absent for a phone that may not watch: they would
    /// be two taps that can only open an empty sheet.
    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("What it did", about: nil, says: nil)
            card {
                row(title: "Everything it did",
                    detail: "Every tool call, and every refusal.",
                    icon: "list.bullet.rectangle",
                    id: "activity") {
                    showingActivity = true
                    link?.loadLog()
                }
                line
                row(title: CopilotControl.sessionsLabel(link?.sessions.count ?? 0),
                    detail: "Sessions it started on the \(machineNoun).",
                    icon: "terminal",
                    id: "sessions") { showingSessions = true }
            }
        }
    }

    // MARK: - Devices

    /// The roster, pushed rather than sheeted because it is a place with its own
    /// destructive confirmation. It carries a `TabBarClearance()` of its own —
    /// it is written for the settings stack, which draws the bar — and that
    /// measures zero on this stack, where no bar is drawn.
    @ViewBuilder
    private var devices: some View {
        if let host {
            VStack(alignment: .leading, spacing: 0) {
                caption("Who else reaches it", about: nil, says: nil)
                card {
                    NavigationLink {
                        DeviceRosterView(devices: host.devices, thisDeviceId: host.thisDeviceId)
                    } label: {
                        row(title: "Devices",
                            detail: "Every device signed in to this \(machineNoun).",
                            icon: "iphone",
                            id: "devices",
                            asLabel: true) {}
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Devices. Every device signed in to this \(machineNoun).")
                    .accessibilityIdentifier("copilot.controls.devices")
                }
            }
        }
    }

    // MARK: - What it is

    /// The previous lane's writing, in one row at the foot of the screen.
    ///
    /// It is good, it is checked against the desktop's own source, and it is
    /// **not what he asked for** — so it keeps its screen and loses its place.
    /// A person who wants to know what a copilot is finds it exactly where a
    /// person would look for that; nobody operating one meets it first.
    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("Reference", about: nil, says: nil)
            card {
                NavigationLink {
                    AboutCopilotView(model: model, hostID: hostID)
                } label: {
                    row(title: "What a copilot is",
                        detail: "What it reaches, and what it may do without asking.",
                        icon: "info.circle",
                        id: "about",
                        asLabel: true) {}
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What a copilot is. What it reaches, and what it may do "
                                    + "without asking.")
                .accessibilityIdentifier("copilot.controls.about")
            }
        }
    }

    // MARK: - Chrome

    /*
     * Drawn here rather than borrowed, and that is not a preference.
     * `SectionCaption`, `SettingsGroup` and `SettingsDivider` are **private to
     * `DeckTabs.swift`** — a screen that reached for them would have to live in
     * that file, which is the argument `MachineDetailView`, `AppLockScreen` and
     * `CopilotOnServerView` all make about the same three names. These are the
     * same shapes at the same metrics: an 11pt kerned caption, a `Theme.surface`
     * card at radius 20, and a hairline inset to the label rather than to the
     * card's edge.
     */
    private func caption(_ text: String, about: String?, says: String?) -> some View {
        HStack(spacing: 4) {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.faint)
            if let about, let says { InfoDot(about: about, text: says) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    /// A name and what it currently is. Not pressable, and drawn without a
    /// chevron unless it is — in this app a row with a chevron leads somewhere,
    /// and a reading that carried one would be a control that cannot act.
    private func valueRow(title: String, value: String, mono: Bool, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.primary)
                Text(value)
                    .font(.system(size: 12, design: mono ? .monospaced : .default))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /**
     * One thing this screen does.
     *
     * `dead` is the **graced** answer rather than the live one, which is the
     * rule `CopilotOnServerView.act` established on this tab: a row that greyed
     * the instant a socket blinked is the *"consistent connection"* complaint,
     * and a row still lit five seconds into a real outage is a control that
     * cannot act. `ConnectionNotice` is where the app already decides which of
     * those two moments it is in.
     *
     * `asLabel` draws the same row without a button around it, for the two rows
     * that are `NavigationLink`s — nesting a `Button` inside a link makes the
     * link untappable everywhere but its label's own hit area.
     */
    private func row(title: String,
                     detail: String,
                     icon: String,
                     id: String,
                     destructive: Bool = false,
                     asLabel: Bool = false,
                     go: @escaping () -> Void) -> some View {
        let dead = host?.notice.isShowing == true && host?.connection.isLive != true
        let body = HStack(spacing: 12) {
            // Monoline: 19pt light in a 24pt column, the metric every row in the
            // settings surfaces uses. See `SettingsRowBody`.
            Image(systemName: icon)
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(destructive ? Theme.critical : Theme.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(destructive ? Theme.critical : Theme.primary)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())

        return Group {
            if asLabel {
                // No accessibility modifiers here on purpose: this shape is the
                // *label* of a `NavigationLink`, and combining children inside
                // one takes the link's own identifier off the element a UI test
                // would find. The caller names it — see `devices` and `about`.
                body
            } else {
                Button(action: go) { body }
                    .buttonStyle(.plain)
                    // `.plain` does not dim a disabled label, so the dimming is
                    // stated. A row has to *look* unavailable as well as be
                    // unavailable, or a press that does nothing is
                    // indistinguishable from a press that was missed.
                    .opacity(dead ? 0.4 : 1)
                    .disabled(dead)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(title). \(detail)")
                    .accessibilityIdentifier("copilot.controls.\(id)")
            }
        }
    }
}

// MARK: - The button, at every perch

/**
 * The button in the top right, decided once — glyph, placement and identifier.
 *
 * ## Why a gear and not an ⓘ, which is what it was
 *
 * It was `info.circle`, chosen when the screen behind it was a page to read, and
 * it is wrong twice now.
 *
 * It is wrong in meaning: this opens *"all the control about copilot, all the
 * settings of the copilot… whatever, three dots, maybe your settings button"*,
 * and an ⓘ is this app's mark for **an explanation lives behind this** — on every
 * `InfoDot` and on the terminal's chat note. A person who has met one of those
 * has been taught something this button no longer does.
 *
 * And it is wrong in the place it matters most. The landed session is the perch
 * where least is on screen naming what you are talking to, and `TerminalScreen`
 * **already draws an `info.circle`** in the same trailing group whenever chat
 * mode is up — `chat.note`, which explains why an agent's tool calls are not in
 * the transcript. The landed state *is* chat mode, so an ⓘ here would put two
 * identical glyphs side by side on the screen somebody arrives at, which reads as
 * a rendering fault rather than as two controls. Measured by reading that
 * toolbar, not by guessing.
 *
 * A gear collides with nothing in this app and says what it does.
 */
extension View {
    /**
     * - Parameter when: whether this screen is the one drawing it.
     *
     *   Defaulted to true and passed explicitly by exactly one caller —
     *   `CopilotView`, which needs it because **`CopilotOnServerView` is drawn
     *   inside its own `ZStack`**. SwiftUI gathers toolbar items from the whole
     *   hierarchy under a navigation container, so a `CopilotView` that applied
     *   this unconditionally would put **two** gears in the bar of every server: its
     *   own and its child's. Two identically-labelled buttons in one bar is the
     *   sort of thing that reads as a rendering fault rather than as a
     *   duplicate.
     *
     *   The alternative — letting `CopilotView` draw it for both and taking it
     *   off the child — is rejected because it makes the server's fallback
     *   screen depend on a file it does not own for its own chrome. A screen
     *   carries its own.
     */
    func copilotControlsButton(model: DeckModel, hostID: String, when shown: Bool = true) -> some View {
        toolbar {
            if shown {
                ToolbarItem(placement: .topBarTrailing) {
                    /*
                     * A `NavigationLink` rather than a `Button` that sets a flag:
                     * nothing is decided on the way, no frame goes to the
                     * machine, and this screen holds no state that says whether
                     * somebody is still on it.
                     *
                     * A **view-based** destination into a stack that carries a
                     * path, which is a decision this app has already made twice
                     * in the same words. `copilotRoute` is a `[DeckModel.Route]`
                     * and `Route` has one case, `.session`; reaching this screen
                     * by adding a second would mean editing `DeckModel` and
                     * adding an arm to the `navigationDestination` in `DeckTabs`
                     * for a screen nothing deep-links to and nothing restores.
                     * `MachineToolsSection.link` pushes six screens out of the
                     * settings stack exactly this way, and `LocalhostListView`
                     * and `WatchView` do the same.
                     *
                     * The one consequence worth writing down rather than
                     * discovering: a landing can fire while this screen is up.
                     * `CopilotOnServerView.land()` appends a `.session` to
                     * `copilotRoute` the moment the copilot's session appears,
                     * and this screen is not in that path. Whether SwiftUI
                     * stacks the terminal above this screen or pops it on the
                     * way, the person ends in the conversation — which is where
                     * that tab goes, deliberately, and where they would have
                     * ended had they never pressed this. Not silently wrong in
                     * either direction, so it is left alone rather than defended
                     * against with a latch that would have to be unlatched again
                     * on the way back.
                     */
                    NavigationLink {
                        CopilotControlView(model: model, hostID: hostID)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17))
                    }
                    .accessibilityLabel("Copilot controls")
                    .accessibilityIdentifier(CopilotControl.buttonIdentifier)
                }
            }
        }
    }
}

// MARK: - The decisions, with no view in them

/**
 * Which sections a machine gets, and the sentences that are chosen rather than
 * printed.
 *
 * Pure for the reason `CopilotOnServer` is: every way this screen can be wrong
 * is silent and most of them need a machine of a particular kind to be visible
 * at all. A desktop's grant card over a server, a *Start* on a phone that may
 * only watch, an agent chooser over a copilot the setting has no bearing on —
 * none of those crash, none look like a fault, and each is a control that
 * refuses on every press.
 */
enum CopilotControl {

    /// One shared identifier for the button, at every perch. A second spelling
    /// would make *"the button is missing on the landed screen"* and *"the
    /// button is there under another name"* the same failure to a UI test.
    ///
    /// Renamed from `copilot.about` with the screen behind it. The old name
    /// described a reading page and would have gone on describing one from every
    /// UI test and every walk-through after the screen stopped being one.
    static let buttonIdentifier = "copilot.controls"

    /**
     * Every screen the Copilot tab can be showing, and therefore every screen
     * that has to carry the button.
     *
     * Written as an enumerated type for the reason `DeckSurface` is: the rule is
     * otherwise enforced by a modifier applied in each screen, which is
     * invisible in review and checkable only by launching the app onto a real
     * machine of each kind. A screen that quietly lacks the button looks exactly
     * like a screen nobody thought about, and adding a fourth without deciding
     * is how the button comes to be missing from the newest thing.
     */
    enum Perch: String, CaseIterable {
        /// `CopilotOnServerView` — the tab's root on a server that has not been
        /// set up, or one whose copilot cannot be reached right now.
        case fallback
        /// `TerminalScreen`, pushed onto `copilotRoute` by the landing. The
        /// state somebody most often arrives in, and the one where least is on
        /// screen naming what they are talking to.
        case landedSession
        /// `CopilotView` on a desktop: the copilot conversation itself.
        case conversation
    }

    /**
     * The file that applies `copilotControlsButton` for each perch.
     *
     * Not decoration. Two of these three screens are outside the file the button
     * is written in, and naming their owners here is what turns *"the button is
     * missing from the landed state"* from something a person notices on a phone
     * into something a reader of this enum can see.
     */
    static func owner(of perch: Perch) -> String {
        switch perch {
        case .fallback: return "Screens/CopilotOnServerView.swift"
        // The stack's `navigationDestination` rather than `TerminalScreen`
        // itself, and that is the whole point of naming the owner: the same
        // terminal is pushed from the Sessions tab, where it is not a copilot
        // screen and must not carry a button about one. The file that knows
        // *which stack this terminal is on* is the file that applies it.
        case .landedSession: return "Screens/DeckTabs.swift"
        // Applied there with `when:` — see `copilotControlsButton`. That screen
        // renders `CopilotOnServerView` inside itself, so an unguarded
        // application would draw the button twice on every server.
        case .conversation: return "Screens/CopilotView.swift"
        }
    }

    /// The sections, in the order they are drawn.
    enum Panel: String, CaseIterable, Identifiable {
        case whenYouOpen
        case agent
        case session
        case permissions
        case run
        case history
        case devices
        case about

        var id: String { rawValue }
    }

    /**
     * Everything the sections are chosen from.
     *
     * Deliberately not a `HostLink`: the decisions below are about a machine's
     * kind, this phone's grant and what has been set up, and a pure value is
     * what lets every one of them be walked without a socket, a paired machine
     * and a running agent.
     */
    struct Reading: Equatable {
        let kind: HostKind
        let access: CopilotAccess
        let grant: CopilotGrant
        let setUp: Bool
        let canPickFolders: Bool
        let settingsOffered: Bool
        let devicesOffered: Bool
        let hasCopilotSession: Bool
        let hasRun: Bool
        let waiting: Int

        init(kind: HostKind,
             access: CopilotAccess,
             grant: CopilotGrant = .none,
             setUp: Bool = false,
             canPickFolders: Bool = false,
             settingsOffered: Bool = false,
             devicesOffered: Bool = false,
             hasCopilotSession: Bool = false,
             hasRun: Bool = false,
             waiting: Int = 0) {
            self.kind = kind
            self.access = access
            self.grant = grant
            self.setUp = setUp
            self.canPickFolders = canPickFolders
            self.settingsOffered = settingsOffered
            self.devicesOffered = devicesOffered
            self.hasCopilotSession = hasCopilotSession
            self.hasRun = hasRun
            self.waiting = waiting
        }
    }

    /**
     * Which sections this machine gets.
     *
     * The three questions each `if` answers, in the order they matter:
     *
     *  - **Can this section's controls act on this machine at all?** The agent
     *    chooser writes `agents.defaultProvider`, which decides what a *session*
     *    contains — true of a server's copilot, meaningless for a desktop's,
     *    which is the desktop app's own Claude CLI. The grant, the run and the
     *    log are all `copilot.*` frames, which a server does not speak.
     *  - **Has the machine offered the capability?** `settings` and `devices`
     *    are both withheld from a guest at the source, so their absence is a
     *    fact about this pairing rather than about this build.
     *  - **Is there anything in it?** A conversation section over a machine with
     *    no copilot session is an empty card under a caption, which is furniture
     *    describing nothing.
     *
     * `whenYouOpen` is the one section that is nearly unconditional, because it
     * is the setup and a machine that cannot be set up is one where the tab must
     * ask every time. The exception is a desktop this phone may not talk to: the
     * switch there would arm `copilot.start`, which `CopilotLink.start` refuses
     * without `act`, and arming something that can never fire is the dead
     * control this screen is written against.
     */
    static func panels(_ r: Reading) -> [Panel] {
        var panels: [Panel] = []
        let onAServer = r.kind == .headless

        if onAServer || r.access == .direct { panels.append(.whenYouOpen) }
        if onAServer, r.settingsOffered { panels.append(.agent) }
        if onAServer, r.hasCopilotSession { panels.append(.session) }
        if !onAServer, r.access != .notOffered { panels.append(.permissions) }
        if !onAServer, r.access == .watch || r.access == .direct {
            panels.append(.run)
            panels.append(.history)
        }
        if r.devicesOffered { panels.append(.devices) }
        panels.append(.about)
        return panels
    }

    /// The copilot at the machine, in one word. `deskIsStopped` rather than
    /// `!deskIsRunning`, because an unrecognised word from a newer desktop is
    /// neither, and printing it is more honest than calling it stopped.
    static func deskWord(_ state: CopilotState) -> String {
        if state.deskIsRunning { return "running" }
        if state.deskIsStarting { return "starting" }
        if state.deskIsStopped { return "stopped" }
        return state.desk
    }

    /// The account, and whether it is signed in — three answers, because nil is
    /// *not asked* and drawing that as signed out would send somebody to fix an
    /// account that is fine.
    static func accountLine(_ state: CopilotState) -> String? {
        guard let profile = state.profile else {
            return state.signedIn == false ? "Signed out" : nil
        }
        switch state.signedIn {
        case true?: return profile
        case false?: return "\(profile) — signed out"
        default: return profile
        }
    }

    /**
     * What a turn costs it before anybody says anything.
     *
     * The machine's own two numbers and nothing derived from them. The tool
     * **list** is deliberately never copied into this app: there were thirty-four
     * ids across `src/main/deck-control/` on the day this was written, fifteen
     * of them held behind `describe-tool.ts` because the assembled list went over
     * its own ceiling, and a list that moves that fast in a lane that is not this
     * one would be wrong in Swift within a release — printed as fact, on a
     * screen that exists to be believed.
     */
    static func catalogueLine(_ state: CopilotState) -> String? {
        guard state.tools > 0 || state.turnTokens > 0 else { return nil }
        let tools = state.tools == 1 ? "1 tool" : "\(state.tools) tools"
        guard state.turnTokens > 0 else { return tools }
        return "\(tools) · \(state.turnTokens) tokens a turn"
    }

    /// The count is on the label because it is the thing being asked. Zero is
    /// still shown and still opens: an empty list saying *it has not started
    /// anything* answers the question, and a hidden row leaves somebody
    /// wondering where it went.
    static func sessionsLabel(_ count: Int) -> String {
        if count == 0 { return "Sessions it started" }
        return count == 1 ? "1 session it started" : "\(count) sessions it started"
    }
}

/// A minimal wrapping row for the provider chips — a couple of chips that must
/// fall to a second line on a narrow phone rather than clip. `FlowRow` in
/// `ServerSettingsView.swift` is the same layout and is private to that file;
/// this is the same twelve lines rather than a shared type nobody else wants.
private struct CopilotChipRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
