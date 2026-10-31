import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Hoot's profile, shown on the Hoot page in place of the chat (HootProfileRoute). The one place
/// where everything about Hoot is seen and changed: what it is, its brain, its
/// files, its instructions, its tools and skills, its routines and runs. Same page frame and
/// cards as the other agents' profile (DeckPage + GlassSwitch + DeckCard).
struct HootProfileView: View {
    let onBack: () -> Void
    var model: CopilotSettingsPageModel = HootProfileModels.page
    var brain: ROUTINESHootBrainModel = .shared
    var preferences: ROUTINESHootSettingsModel = .shared
    var routines: ROUTINESPageModel = .shared
    var live = true
    @State private var route = HootProfileRoute.shared
    @State private var resetting = false

    private var tabs: [DeckSwitchItem<String>] {
        [.init(id: "overview", title: "Overview"), .init(id: "brain", title: "Brain"), .init(id: "memory", title: "Memory"),
         .init(id: "instructions", title: "Instructions"), .init(id: "runs", title: "Runs")]
    }
    private var running: Bool { model.state?.status == .running }
    private var statusWord: String {
        switch model.state?.status { case .running: "Awake"; case .starting: "Starting…"; default: model.loading ? "Reading…" : "Stopped" }
    }

    var body: some View {
        DeckPage(title: "Hoot", subtitle: statusWord + " · your assistant for every project, on this Mac", scrolls: route.tab == "overview" || route.tab == "runs") {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("Chat") }
                        .font(.callout).foregroundStyle(.secondary).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Back to the chat").keyboardShortcut("[", modifiers: .command)
                HootAvatar(state: running ? .awake : .stopped, size: 30, animated: true, showsStatus: false)
            }
        } switcher: {
            GlassSwitch(selection: $route.tab, items: tabs)
        } actions: {
            lifecycleButtons
        } content: {
            content
        }
        .onAppear {
            guard live else { return }
            model.load(); brain.reload(); preferences.load(); routines.start(); NativeMemoryStore.of(.hoot).start()
        }
        .onDisappear { if live { NativeMemoryStore.stop(.hoot) } }
        // Moved here from the old Settings › Hoot page (SETTINGS-TRUTH row 105): the same action and the same confirm.
        .alert("Reset Hoot?", isPresented: $resetting) {
            Button("Cancel", role: .cancel) { }
            Button("Reset Hoot", role: .destructive) { preferences.reset { model.load() } }
        } message: { Text("This clears Hoot's chat and notes and stops Hoot. Routines and settings stay.") }
    }

    @ViewBuilder private var lifecycleButtons: some View {
        if running {
            Button(model.busy == "restart" ? "Restarting…" : "Restart") { lifecycle("restart") }
            Button(model.busy == "stop" ? "Stopping…" : "Stop") { lifecycle("stop") }
        } else {
            Button(model.busy == "start" ? "Starting…" : "Start Hoot") { lifecycle("start") }.buttonStyle(.borderedProminent)
        }
    }
    private func lifecycle(_ action: String) {
        guard live else { return }
        model.act(action) {
            if action == "stop" || action == "restart" { _ = try await model.call("hoot:stop") }
            if action == "stop" { return "Hoot stopped." }
            guard let next = CopilotState.from(try await model.call("hoot:ensure")), next.status == .running else {
                throw ROUTINESHootFailure("Hoot could not start. Check the selected account in Coding AIs.")
            }
            return action == "restart" ? "Hoot restarted." : "Hoot started."
        }
    }

    @ViewBuilder private var content: some View {
        switch route.tab {
        case "brain": brainTab
        // Hoot's whole memory (the orchestrator seat): card, notes, diary, topics, playbook, board, upkeep, folder.
        case "memory", "files": NativeMemoryArea(owner: .hoot, name: "Hoot")
        case "instructions": Form { CopilotFilesGroup(model: model) }.formStyle(.grouped)
        case "runs": HootRunsTab(routines: routines, model: model, live: live)
        default: overview
        }
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if live { AGTTeamChatHistoryCard(agentID: "hoot") }
            if let status = model.status ?? model.problem ?? preferences.problem ?? preferences.status { Text(status).font(.callout).foregroundStyle(.secondary) }
            DeckCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What Hoot is").font(.headline)
                    Text("Your assistant for every project on this Mac. It follows your sessions and agents, answers questions about them, hands problems to the right agent, runs its routines, and keeps notes it remembers between chats.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DeckCard {
                VStack(spacing: 0) {
                    fact("Status", statusWord, tab: nil)
                    fact("Coding AI", NativeAGSWords.provider(brain.chosenProvider), tab: "brain", image: DeckRowIcon.provider(brain.chosenProvider))
                    fact("Model", brain.modelLabel, tab: "brain")
                    fact("Effort", brain.chatEffort.isEmpty ? "—" : HootBrainRows.effortName(brain.chatEffort), tab: "brain")
                    fact("Before it changes files", permissionWords[brain.permissionWord] ?? "Asks first", tab: "brain")
                    fact("Memory", memoryLine, tab: "memory")
                    fact("Routines", "\(hootRoutines.count)", tab: "runs")
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Who Hoot orchestrates").font(.headline)
                            Text("Each project's lead and the agent seats under it. A vacant seat keeps its memory.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        NativeMemoryTemplatesButton()
                    }
                    if live { AGTLeadTree() }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HootToolsCard(model: model, live: live)
            // Shown only when a real reset owner is connected; never a dead button.
            if preferences.canChange("reset") {
                DeckCard {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start over").font(.headline)
                            Text("Clear the chat and notes. Keep routines and settings.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset Hoot…", role: .destructive) { resetting = true }.disabled(model.busy != nil || preferences.busy)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private var memoryLine: String {
        let store = NativeMemoryStore.of(.hoot)
        guard store.loaded else { return "Card, notes, diary, topics, playbook" }
        return "\(store.notes.count) notes · \(store.topics.filter(\.open).count) open topics"
    }
    private var permissionWords: [String: String] { ["ask": "Asks first", "edit": "Edits on its own", "plan": "Plans only", "bypass": "Bypass permissions"] }
    private var hootRoutines: [ROUTINESRoutine] { routines.routines.filter { $0.agentID == "@hoot" } }
    private func fact(_ label: String, _ value: String, tab: String?, image: NSImage? = nil) -> some View {
        Button { if let tab { route.tab = tab } } label: {
            HStack(spacing: 12) {
                Text(label).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                if let image { Image(nsImage: image) }
                Text(value).lineLimit(1)
                Spacer(minLength: 0)
                if tab != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            }.font(.callout)
        }.buttonStyle(DeckRowStyle()).disabled(tab == nil)
    }

    // MARK: Brain

    private var brainTab: some View {
        Form {
            // Which Coding AI, its account, model, window, effort and permission. "What Hoot may do" is gone (Asad, 12 Oct):
            // Hoot can always run sessions, hand problems out, use simulators and phones, and open any folder.
            Section("Its brain") { HootBrainRows(brain: brain) }
        }.formStyle(.grouped)
    }
}

/// The page model is shared so the profile opens with what it last read.
@MainActor enum HootProfileModels {
    static let page = CopilotSettingsPageModel()
}

/// Tools and skills Hoot has: its generated tool list (what is actually wired) and the installed skills.
private struct HootToolsCard: View {
    let model: CopilotSettingsPageModel
    let live: Bool
    @State private var tools = CopilotFileText()
    @State private var showAll = false
    private var skills: ROUTINESSkillsStore { .shared }
    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Tools and skills").font(.headline)
                    Spacer()
                    Button(showAll ? "Show less" : "Show its tool list") { showAll.toggle() }.buttonStyle(.borderless)
                }
                Text("Written fresh from the tools that are actually wired every time Hoot starts.")
                    .font(.caption).foregroundStyle(.secondary)
                if showAll {
                    ScrollView {
                        Text(tools.text ?? tools.problem ?? "Reading…").font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 260)
                }
                let names = skills.installed.map(\.name)
                Text(names.isEmpty ? "No skills installed." : "Skills: " + names.prefix(12).joined(separator: ", ") + (names.count > 12 ? " and \(names.count - 12) more" : ""))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if live { skills.start() } }
        .onChange(of: showAll) { _, open in
            guard live else { return }
            tools.follow(open: open, key: "contract") {
                let value = try await model.call("hoot:read-contract")
                return (value["text"].string, value["error"].string)
            }
        }
    }
}

/// Hoot's routines and what it has run: each routine run's output, and its action record.
private struct HootRunsTab: View {
    let routines: ROUTINESPageModel
    let model: CopilotSettingsPageModel
    let live: Bool
    @State private var open: String?
    private var mine: [ROUTINESRoutine] { routines.routines.filter { $0.agentID == "@hoot" } }
    private var runs: [ROUTINESRun] { routines.runs.filter { $0.agentID == "@hoot" } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DeckCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Its routines").font(.headline)
                        Spacer()
                        Button("Open in Routines") { if live { HootProfileRoute.close(); AppModel.shared.select(NativeINT2Navigation.routinesID) } }
                            .buttonStyle(.borderless)
                    }
                    if mine.isEmpty { Text(routines.loading ? "Reading…" : "No routines yet.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(mine, id: \.id) { row in
                        HStack(spacing: 10) {
                            StatusLabel(row.failed ? .failed : row.on ? .ready : .paused, text: row.on ? "On" : "Off", fontSize: 12).frame(width: 60, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.routine.name)
                                Text(row.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Run now") { if live { routines.run(row) } }.disabled(routines.busyID == row.id)
                        }
                    }
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Runs").font(.headline)
                    if runs.isEmpty { Text("No runs yet.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(runs.prefix(50), id: \.id) { run in
                        VStack(alignment: .leading, spacing: 6) {
                            Button { open = open == run.id ? nil : run.id } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: run.result == "ok" ? "checkmark.circle" : run.result == "failed" ? "xmark.circle" : "clock")
                                        .foregroundStyle(run.result == "ok" ? DeckTokens.good : run.result == "failed" ? DeckTokens.bad : .secondary)
                                    Text(mine.first { $0.id == run.routineID }?.routine.name ?? run.routineID)
                                    Spacer()
                                    Text(AGTTime.ago(run.when)).font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: open == run.id ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if open == run.id {
                                Text(run.output ?? run.error ?? "This run left no output.")
                                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(DeckTokens.selection, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What Hoot has done").font(.headline)
                    let rows = model.actions?.rows ?? []
                    if rows.isEmpty { Text("Nothing recorded yet.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(rows.prefix(100), id: \.id) { row in
                        HStack(alignment: .top, spacing: 10) {
                            Text(row.at.prefix(16).replacingOccurrences(of: "T", with: " ")).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                            Text(row.action).font(.caption.weight(.medium)).frame(width: 150, alignment: .leading)
                            Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
    }
}
