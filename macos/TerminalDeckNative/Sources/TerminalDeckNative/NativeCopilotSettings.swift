import SwiftUI
import TerminalDeckNativeCore

// Settings → Hoot, drawn in SwiftUI (web: settings/sections/CopilotSection.tsx).
// The data and the words are `CopilotSettingsModel.swift` in Core. The groups, in
// the page's order: its session, its files, while it works, at the top of the
// screen, the action log, what it can reach, its routines.

struct NativeCopilotSettings: View {
    @State private var model = CopilotSettingsPageModel()

    var body: some View {
        // G's page frame, with this section's own line under the title (the page's `BLURB`,
        // not the schema's, as `CopilotSection` heads itself).
        Form {
            Section {
                if let problem = model.problem { NativeCodingAINotice(tone: .error, text: problem) }
                if CopilotState.neverStarted(model.state, model.memory) {
                    NativeCodingAINotice(tone: .info, text: CopilotWords.neverStarted)
                }
            } header: {
                NativeSettingsHead(title: CopilotWords.assistant, blurb: CopilotWords.blurb)
            }
            CopilotSessionGroup(model: model)
            CopilotFilesGroup(model: model)
            CopilotShowingGroup(model: model)
            CopilotMenuBarGroup(model: model)
            CopilotActionsGroup(model: model)
            CopilotReachGroup(model: model)
            CopilotRoutinesGroup(model: model)
            if let status = model.status {
                Section { NativeCodingAINotice(tone: .info, text: status) }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { NativeSettingsFoot() }
        .onAppear { model.load() }
    }
}

// MARK: - The section's state

@MainActor @Observable
final class CopilotSettingsPageModel {
    var state: CopilotState?
    var signIn: CopilotSignIn?
    var memory: CopilotMemoryReport?
    var actions: CopilotActionLog?
    var routines: [CopilotRoutine]?
    var interactive: Bool?
    var identity = CopilotIdentity()
    /// `useCopilotSetup`'s status: whether the questions have been answered once.
    var setUp: Bool?
    var loading = true
    var busy: String?
    var status: String?
    var problem: String?
    @ObservationIgnored private var generation = 0

    func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    /// Read everything again; an answer from an older read is dropped.
    func load() {
        generation += 1
        let mine = generation
        loading = true
        Task {
            async let state = try? call("copilot:state")
            async let memory = try? call("copilot:memory")
            async let actions = try? call("copilot:actions", [200])
            async let routines = try? call("routines:list")
            async let settings = try? call("settings:get")
            async let instructions = try? call("copilot:read-instructions")
            let read = await (state, memory, actions, routines, settings, instructions)
            guard mine == generation else { return }
            if let raw = read.0 { self.state = CopilotState.from(raw) } else {
                problem = "Could not read \(CopilotWords.assistant)’s state."
            }
            self.memory = read.1.flatMap(CopilotMemoryReport.from)
            self.actions = read.2.flatMap(CopilotActionLog.from)
            self.routines = read.3.map(CopilotRoutine.list)
            self.interactive = read.4.map(CopilotShowing.interactive)
            if let raw = read.5 {
                if case .text(let text, _) = CopilotInstructionsRead.from(raw) {
                    let reading = CopilotIdentity.read(text)
                    identity = reading.identity
                    setUp = reading.ran
                } else {
                    identity = CopilotIdentity()
                    setUp = false
                }
            } else {
                setUp = true
            }
            loading = false
        }
    }

    /// `act`: one thing at a time; its sentence is shown, then everything is read again.
    func act(_ key: String, _ work: @escaping @MainActor () async throws -> String?) {
        busy = key
        status = nil
        Task {
            do { status = try await work() } catch { status = CodingAIErrorText.from(error, fallback: "That did not work.") }
            busy = nil
            load()
        }
    }

    func reveal(_ place: String) {
        act("reveal:\(place)") { [self] in CopilotReveal.message(try await call("copilot:reveal", [place])) }
    }

    /// "Set it up…": the main window opens the questions (the page's `set-up-copilot`).
    func setUpCopilot() {
        _ = NativeCodingAIPages.evaluate(CodingAIPageScripts.relay(.object(["type": .string("set-up-copilot")])), in: .settings)
    }
}

// MARK: - Shared parts

/// `Block`: a group's title with its ⓘ, and the one line under it.
struct CopilotBlock<Content: View>: View {
    let title: String
    let says: String
    var more: String?
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            content
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(title)
                    if let more { NativeCodingAIInfo(label: title, text: more) }
                }
                Text(says)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// `settings-badge`: a word beside a row's label; quiet ones are grey.
struct CopilotBadge: View {
    let text: String
    var quiet = false
    var body: some View { NativeCodingAIBadge(text: text, quiet: quiet) }
}

/// `settings-path-row`: label and badges, lines under it, buttons on the right.
struct CopilotPathRow<Main: View, Actions: View>: View {
    @ViewBuilder let main: Main
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) { main }
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) { actions }
                .fixedSize()
        }
    }
}

struct CopilotLabel: View {
    let text: String
    var badges: [(text: String, quiet: Bool)] = []
    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in CopilotBadge(text: badge.text, quiet: badge.quiet) }
        }
    }
}

struct CopilotHelp: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}

struct CopilotPath: View {
    let path: String
    var body: some View {
        Text(path)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(path)
    }
}

// MARK: - 1. Its session

struct CopilotSessionGroup: View {
    let model: CopilotSettingsPageModel

    var body: some View {
        let status = model.state?.status ?? .stopped
        let running = status == .running
        let startBecause: String? = running ? "It is already running." : status == .starting ? "It is starting." : nil
        let stopBecause: String? = running ? nil : "It is not running."
        CopilotBlock(title: "Its session",
                     says: "It runs as an ordinary Terminal Deck session, in a folder of its own, as one of your accounts.",
                     more: "It is a real session, so everything the app can already do to one works on it: a transcript you can read, an account, a working directory, a line in the usage pane. That is why it is a session rather than a chat box built into this app.") {
            CopilotPathRow {
                CopilotLabel(text: "Its name", badges: [(model.identity.name == nil ? "not named" : "you named it", model.identity.name == nil)])
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    CopilotHelp(model.identity.line)
                    NativeCodingAIInfo(label: "its name",
                                       text: "The name is not a setting — it is a sentence in \(CopilotWords.assistant)’s own instructions, which is why there is one copy of it and not two. Running these questions again rewrites that sentence, and so does editing it yourself under Its files.")
                }
            } actions: {
                Button(model.setUp == false ? "Set it up…" : "Set it up again…") { model.setUpCopilot() }
            }

            CopilotPathRow {
                CopilotLabel(text: "Status", badges: [(CopilotWords.statusLabel(status), false)])
                CopilotHelp(statusLine(running))
                if let startBecause { CopilotHelp("Start: \(startBecause)") }
                if let stopBecause { CopilotHelp("Stop: \(stopBecause)") }
            } actions: {
                Button(model.busy == "start" ? "Starting…" : "Start it") {
                    model.act("start") { [model] in
                        let next = CopilotState.from(try await model.call("copilot:ensure"))
                        return next?.status == .running
                            ? "\(CopilotWords.assistant) is running."
                            : (next?.problem ?? "It did not start, and said nothing about why.")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(startBecause != nil || model.busy != nil || model.loading)
                Button("Stop") {
                    model.act("stop") { [model] in
                        _ = try await model.call("copilot:stop")
                        return "Stopped."
                    }
                }
                .disabled(stopBecause != nil || model.busy != nil)
            }

            CopilotPathRow {
                if let signIn = model.signIn {
                    CopilotLabel(text: "Its account", badges: [(signIn.state == .signedIn ? "signed in" : signIn.state == .signedOut ? "signed out" : "unknown",
                                                                signIn.state != .signedIn)])
                } else {
                    CopilotLabel(text: "Its account")
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    CopilotHelp(accountLine)
                    NativeCodingAIInfo(label: "its account",
                                       text: "It resolves an account out of Accounts the same way any session you start in this folder resolves one: the folder’s account if it has been given one, and your default otherwise. There is no separate login anywhere for \(CopilotWords.assistant) and nothing signs in on its behalf.")
                }
                CopilotHelp(runningAsLine)
            } actions: {
                Button(model.busy == "signin" ? "Checking…" : "Check") {
                    model.act("signin") { [model] in
                        let next = CopilotSignIn.from(try await model.call("copilot:signin"))
                        model.signIn = next
                        guard let next else { return "Its login could not be read." }
                        switch next.state {
                        case .signedIn: return "Signed in\(next.account.map { " as \($0)" } ?? "")."
                        case .signedOut: return "\(next.profileName.isEmpty ? "That account" : next.profileName) is signed out. Sign it in under Accounts, the same as any other."
                        case .unknown: return "That account’s sign-in state could not be read."
                        }
                    }
                }
                .disabled(model.busy != nil)
            }

            CopilotFolderRow(model: model)
        }
    }

    private func statusLine(_ running: Bool) -> String {
        guard let state = model.state else { return "Reading…" }
        if running, let startedAt = state.startedAt {
            return "Started \(CopilotWords.when(startedAt))\(state.profile.map { " as \($0.name)" } ?? ""). This app’s routines and its action log are \(state.records.enforced ? "held against it" : "NOT held against it")."
        }
        return state.problem ?? "Nothing is running. Starting it opens a session, which spends."
    }

    private var accountLine: String {
        if let account = model.signIn?.account { return account + (model.signIn?.plan.map { " — \($0)" } ?? "") }
        return "It signs in with you, as one of your accounts — it has no login of its own."
    }

    private var runningAsLine: String {
        guard let signIn = model.signIn else { return "Running as \(model.state?.profile?.name ?? "your default account")." }
        let name = !signIn.profileName.isEmpty ? signIn.profileName : (model.state?.profile?.name ?? "your default account")
        return "Running as \(name). Pin a different one by setting an account for its folder; it takes effect the next time it starts."
    }
}

/// `FolderRow`: where it works — this app's folder or one of yours.
struct CopilotFolderRow: View {
    let model: CopilotSettingsPageModel

    var body: some View {
        let folder = model.state?.folder
        let chosen = folder != nil && folder?.isDefault == false
        let shown = folder?.home ?? model.state?.paths.root ?? "—"
        CopilotPathRow {
            CopilotLabel(text: "Its folder", badges: folder == nil ? [] : [(chosen ? "yours" : "this app’s", !chosen)])
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CopilotHelp(chosen
                    ? "You pointed it at a folder of your own. It reads that folder’s own instructions and its memory the same way any session you start there would — and this app writes nothing into it."
                    : "A folder this app made for it. Point it at one of your own and it picks up whatever assistant already lives there.")
                NativeCodingAIInfo(label: "choosing a folder", text: CopilotFolderWords.choosing)
            }
            CopilotPath(path: shown)
            if let folder, let problem = folder.problem {
                NativeCodingAINotice(tone: .warn, text: "\(folder.chosen.map { "\($0) — " } ?? "")\(problem) It is running in \(folder.home) instead.")
            }
            if let folder, folder.restartNeeded {
                NativeCodingAINotice(tone: .info, text: "\(CopilotWords.assistant) is still working in \(folder.runningIn ?? "") for now. \(CopilotFolderWords.needsRestart)")
            }
        } actions: {
            Button("Open") { model.reveal("root") }
            Button(model.busy == "folder-pick" ? "Choosing…" : "Choose a folder…") {
                model.act("folder-pick") { [model] in
                    let result = CopilotFolderChange.from(try await model.call("copilot:folder:pick"))
                    if result.cancelled { return nil }
                    if let problem = result.problem { return problem }
                    guard let folder = result.folder else { return "The folder could not be changed." }
                    return "\(CopilotWords.assistant) will start in \(folder.home). \(CopilotFolderWords.needsRestart)"
                }
            }
            .disabled(model.busy != nil || model.loading)
            if chosen {
                Button("Use this app’s folder") {
                    model.act("folder-clear") { [model] in
                        let result = CopilotFolderChange.from(try await model.call("copilot:folder:clear"))
                        guard let folder = result.folder else { return "That did not work." }
                        return "Back to \(folder.home). Nothing was moved out of the folder you had chosen. \(CopilotFolderWords.needsRestart)"
                    }
                }
                .disabled(model.busy != nil)
            }
        }
    }
}
