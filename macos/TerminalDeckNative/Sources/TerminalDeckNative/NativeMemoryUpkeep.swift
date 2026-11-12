import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// One labelled row: the words on the left, the control on the right.
private struct NativeMemoryRow<Control: View>: View {
    let label: String
    let help: String
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }.padding(.vertical, 6)
    }
}

// MARK: Last runs and the app-wide switches (M2's flow)

/// The flow's last runs of one kind: when, for whom, what it wrote, what it cost.
private struct NativeMemoryRunsCard: View {
    let kind: DeckMemoryFlowJob.Kind
    let fixture: Bool
    @State private var status: DeckMemoryFlowStatus?
    private var runs: [DeckMemoryFlowRun] { (status?.lastRuns ?? []).filter { $0.kind == kind }.sorted { $0.at > $1.at }.prefix(12).map { $0 } }
    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Last runs").font(.headline)
                    Spacer()
                    if let status, kind == .turn, !status.waiting.isEmpty || !status.runningJobs.isEmpty {
                        Text("\(status.runningJobs.count) running · \(status.waiting.count) waiting").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let problem = status?.problem, !problem.isEmpty { Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary) }
                if runs.isEmpty {
                    Text(status == nil ? "Reading…" : "No runs yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(runs) { run in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: run.ok ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(run.ok ? DeckTokens.good : DeckTokens.warn).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(run.title.isEmpty ? Self.seat(run.subject) : run.title).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(NativeMemoryStore.when(Date(timeIntervalSince1970: run.at / 1000))).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(run.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text(Self.cost(run)).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    if run.id != runs.last?.id { Divider() }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: .deckMemoryFlowChanged)) { _ in Task { await load() } }
    }
    private func load() async { if !fixture { status = await DeckMemoryFlow.status() } }
    static func seat(_ key: String) -> String {
        guard let owner = DeckMemoryOwner(key: key) else { return key }
        if owner == .hoot { return "Hoot" }
        let project = NativePROJLabels.shared.projects.first { $0.id == owner.projectID }?.name ?? owner.projectID ?? ""
        return [project, owner.roleID ?? (owner.category == .lead ? "lead" : nil)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    static func cost(_ run: DeckMemoryFlowRun) -> String {
        var parts: [String] = []
        // A run that never asked an AI (nothing new to read) reports no tokens and no time.
        if run.ai.isEmpty || (run.inputTokens == nil && run.outputTokens == nil && run.milliseconds < 1) { return "No AI needed" }
        parts.append((NativeMemoryPlaybookPart.ais.first { $0.0 == run.ai }?.1 ?? run.ai) + (run.model.isEmpty ? "" : " " + run.model))
        if let read = run.inputTokens, let wrote = run.outputTokens { parts.append("\(read.formatted()) tokens read, \(wrote.formatted()) written") }
        else { parts.append("token use not reported") }
        if run.milliseconds > 0 { parts.append(String(format: "%.1f s", run.milliseconds / 1000)) }
        return parts.joined(separator: " · ")
    }
}

/// One app-wide switch of the flow ("0" = off), saved at once. It never shows what it does not
/// know: no position until the saved value is read, and a flip moves it only when the save was taken.
@MainActor @Observable
final class NativeMemoryFlowSwitchModel {
    let key: String
    /// nil until the saved value has been read.
    private(set) var on: Bool?
    private(set) var unreadable: String?
    @ObservationIgnored private let read: @MainActor (String) async throws -> String?

    init(key: String, fixture: Bool = false,
         read: @escaping @MainActor (String) async throws -> String? = { try await DeckMemory.ready().value($0, owner: nil) }) {
        self.key = key; self.on = fixture ? true : nil; self.read = read
    }

    /// Not while its value is unknown, nor while another memory change (a "Run now") still runs:
    /// that change would refuse the save and the switch would show a state that was never saved.
    func canFlip(_ store: NativeMemoryStore) -> Bool { !store.fixture && on != nil && store.busy == nil }

    func reread() async {
        do { on = try await read(key) != "0"; unreadable = nil }
        catch { unreadable = "Its saved value could not be read: " + error.localizedDescription }
    }

    func flip(to next: Bool, in store: NativeMemoryStore) {
        guard canFlip(store) else { return }
        let key = key
        let taken = store.act("flow-switch") {
            try await $0.setValue(next ? "1" : "0", key: key, owner: nil)
            await DeckMemoryFlow.settingsChanged()
            return nil
        }
        if taken { on = next }
    }
}

private struct NativeMemoryFlowSwitch: View {
    let store: NativeMemoryStore
    @State private var model: NativeMemoryFlowSwitchModel
    init(key: String, store: NativeMemoryStore) {
        self.store = store
        _model = State(initialValue: NativeMemoryFlowSwitchModel(key: key, fixture: store.fixture))
    }
    var body: some View {
        HStack(spacing: 8) {
            if let unreadable = model.unreadable {
                Text("Not read").font(.caption).foregroundStyle(DeckTokens.warn).help(unreadable)
            }
            Toggle("On", isOn: Binding(get: { model.on ?? false }, set: { model.flip(to: $0, in: store) }))
                .labelsHidden().toggleStyle(.switch).disabled(!model.canFlip(store))
        }
        // Read when shown and again after every memory change ends (its own save, a "Run now"),
        // so it always shows what is saved.
        .task(id: store.busy) {
            guard !store.fixture, store.busy == nil else { return }
            await model.reread()
        }
    }
}

// MARK: Helper

struct NativeMemoryHelperPart: View {
    let store: NativeMemoryStore
    @State private var correction = ""
    private func sendCorrection() {
        let words = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        correction = ""
        DeckMemoryFlowInbox.correction(words, ownerKey: store.owner.key)
        store.status = "Added to the checklist for \(store.owner.category?.everyone.lowercased() ?? "everyone")."
    }
    private var aiName: String {
        let ai = store.template?.helperAI ?? "claude"
        return NativeMemoryPlaybookPart.ais.first { $0.0 == ai }?.1 ?? ai
    }
    var body: some View {
        NativeMemoryColumn(width: 760) {
            DeckCard {
                VStack(spacing: 0) {
                    NativeMemoryRow(label: "Memory helper", help: "For the whole app, every seat. Off: the diary and the board still fill, but no notes are written.") {
                        NativeMemoryFlowSwitch(key: DeckMemoryFlowKeys.helperOn, store: store)
                    }
                    Divider()
                    NativeMemoryRow(label: "AI and model", help: "The small AI job that reads each finished turn and writes the notes. Set once for \(store.owner.category?.everyone ?? "everyone") in the template.") {
                        HStack(spacing: 8) {
                            Text(aiName + ((store.template?.helperModel ?? "").isEmpty ? "" : " · " + (store.template?.helperModel ?? ""))).foregroundStyle(.secondary)
                            if let category = store.owner.category { NativeMemoryTemplatesButton(title: "Edit template…", category: category) }
                        }
                    }
                    Divider()
                    NativeMemoryRow(label: "Last run", help: "For this seat.") {
                        Text(NativeMemoryStore.stamp(store.settings[DeckMemoryKeys.helperLastRun])).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                    }
                    if let run = NativeMemoryActions.runHelper {
                        Divider()
                        NativeMemoryRow(label: "Run now", help: "Read what is new and write the notes now.") {
                            NativeSessionButton(store.busy == "run-helper" ? "Running…" : "Run now") {
                                let key = store.owner.key
                                store.act("run-helper") { _ in try await run(key) }
                            }.buttonStyle(.borderedProminent).disabled(store.busy != nil)
                        }
                    }
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Its checklist").font(.headline)
                            Text("What it looks for in every turn. Shared by \(store.owner.category?.everyone ?? "everyone"); your corrections are added to it.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let category = store.owner.category { NativeMemoryTemplatesButton(title: "Edit template…", category: category) }
                    }
                    ScrollView {
                        Text((store.template?.checklist ?? store.checklist).isEmpty ? "No checklist yet." : (store.template?.checklist ?? store.checklist))
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 180)
                    Divider()
                    Text("\(store.owner == .hoot ? "Hoot" : "It") should have noted this").font(.subheadline.weight(.medium))
                    HStack(spacing: 8) {
                        NativeSessionTextField("For example: note it whenever I pick between two designs", text: $correction)
                            .textFieldStyle(.roundedBorder).onSubmit { sendCorrection() }
                        NativeSessionButton("Add to checklist") { sendCorrection() }
                            .disabled(correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.fixture)
                    }
                    Text("Added to the checklist above, so the helper looks for it from now on.").font(.caption).foregroundStyle(.secondary)
                }
            }
            NativeMemoryRunsCard(kind: .turn, fixture: store.fixture)
        }
    }
}

// MARK: Tidy-up

struct NativeMemoryTidyPart: View {
    let store: NativeMemoryStore
    @State private var answers: [Int64: String] = [:]
    @State private var showAnswered = false
    private var mine: [DeckMemoryQuestion] { store.questions.filter { store.owner == .hoot || $0.owner == store.owner || $0.owner.projectID != nil && $0.owner.projectID == store.owner.projectID } }
    private var open: [DeckMemoryQuestion] { mine.filter(\.isOpen) }
    private var answered: [DeckMemoryQuestion] { mine.filter { !$0.isOpen && !$0.isDismissed } }
    private var dismissed: [DeckMemoryQuestion] { mine.filter(\.isDismissed) }
    @State private var showDismissed = false
    var body: some View {
        NativeMemoryColumn(width: 760) {
            DeckCard {
                VStack(spacing: 0) {
                    NativeMemoryRow(label: "Nightly tidy-up", help: "For the whole app, every seat.") {
                        NativeMemoryFlowSwitch(key: DeckMemoryFlowKeys.tidyOn, store: store)
                    }
                    Divider()
                    NativeMemoryRow(label: "Last tidy-up", help: "It runs by itself when the app is idle. It never deletes: old notes are archived.") {
                        Text(NativeMemoryStore.stamp(store.settings[DeckMemoryKeys.tidyLastRun])).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                    }
                    if let run = NativeMemoryActions.runTidy {
                        Divider()
                        NativeMemoryRow(label: "Run now", help: "Merge today's duplicates, settle contradictions and keep the card short.") {
                            NativeSessionButton(store.busy == "run-tidy" ? "Tidying…" : "Run now") {
                                let key = store.owner.key
                                store.act("run-tidy") { _ in try await run(key) }
                            }.buttonStyle(.borderedProminent).disabled(store.busy != nil)
                        }
                    }
                }
            }
            HStack {
                Text("Questions for you").font(.headline)
                if !open.isEmpty { NativeMemoryTag(text: "\(open.count) open", color: .orange) }
                Spacer()
                if !answered.isEmpty { Toggle("Show answered", isOn: $showAnswered).toggleStyle(.switch) }
                if !dismissed.isEmpty { Toggle("Show dismissed (\(dismissed.count))", isOn: $showDismissed).toggleStyle(.switch) }
            }.padding(.top, 6)
            if open.isEmpty && !(showAnswered && !answered.isEmpty) && !(showDismissed && !dismissed.isEmpty) {
                DeckCard { Text("Nothing to answer. When the tidy-up is unsure, it keeps both notes and asks here.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
            }
            ForEach(open) { question in
                DeckCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question.text).fixedSize(horizontal: false, vertical: true)
                        if !question.context.isEmpty { Text(question.context).font(.callout).foregroundStyle(.secondary).lineLimit(4) }
                        HStack(spacing: 8) {
                            ForEach(Self.quickAnswers(question), id: \.self) { quick in
                                NativeSessionButton(quick) { answer(question, quick) }
                            }
                            NativeSessionTextField("Or say it your way", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }))
                                .textFieldStyle(.roundedBorder).onSubmit { answer(question, answers[question.id] ?? "") }
                            NativeSessionButton("Answer") { answer(question, answers[question.id] ?? "") }
                                .buttonStyle(.borderedProminent).disabled((answers[question.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                            NativeSessionButton("Dismiss") {
                                store.act("dismiss", done: "Dismissed. It will not be asked again.") { _ = try await $0.dismissQuestion(id: question.id); return nil }
                            }.help("Wave this question away. It is kept under Dismissed and never asked again for this seat.").disabled(store.busy != nil)
                        }
                        Text("Asked " + NativeMemoryStore.when(question.askedAt)).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            if showAnswered {
                ForEach(answered) { question in
                    DeckCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(question.text).foregroundStyle(.secondary)
                            Label(question.answer ?? "", systemImage: "checkmark").font(.callout)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if showDismissed && !dismissed.isEmpty {
                Text("Dismissed").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(dismissed) { question in
                    DeckCard {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(question.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                if let at = question.dismissedAt { Text("Dismissed " + NativeMemoryStore.when(at)).font(.caption).foregroundStyle(.tertiary) }
                            }
                            Spacer(minLength: 8)
                            NativeSessionButton("Ask again") {
                                store.act("reopen", done: "Back in Questions for you") { _ = try await $0.reopenQuestion(id: question.id); return nil }
                            }.disabled(store.busy != nil)
                        }
                    }
                }
            }
            NativeMemoryRunsCard(kind: .tidy, fixture: store.fixture)
        }
    }
    /// M13b: quick answers that fit the question. Two notes that disagree get the note choices;
    /// a yes/no question gets Yes and No; anything else is answered in words.
    static func quickAnswers(_ question: DeckMemoryQuestion) -> [String] {
        // The wording decides, not the note refs: every tidy-up question carries two refs (retest, 11 Oct).
        let words = question.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aboutNotes = ["disagree", "contradict", "which one holds", "which one is right", "keep the newer", "keep both", "duplicate", "same thing twice"]
        if aboutNotes.contains(where: { words.contains($0) }) { return ["Keep the newer one", "Keep both", "Keep the older one"] }
        let openers = ["should ", "is ", "are ", "can ", "do ", "does ", "did ", "will ", "would ", "shall ", "has ", "have ", "was ", "were "]
        if words.contains("?"), openers.contains(where: { words.hasPrefix($0) }) { return ["Yes", "No"] }
        return []
    }
    private func answer(_ question: DeckMemoryQuestion, _ text: String) {
        let reply = text.trimmingCharacters(in: .whitespaces)
        guard !reply.isEmpty else { return }
        answers[question.id] = nil
        store.act("answer", done: "Answer saved") { _ = try await $0.answerQuestion(id: question.id, answer: reply); return nil }
    }
}

// MARK: Folder

struct NativeMemoryFolderPart: View {
    let store: NativeMemoryStore
    /// Show one memory file (a path inside the memory folder, or a full path) in Finder.
    static func reveal(_ path: String) {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : DeckMemory.root.appendingPathComponent(path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    private var root: URL { store.location?.root ?? DeckMemory.root }
    var body: some View {
        NativeMemoryColumn(width: 760) {
            DeckCard {
                VStack(spacing: 0) {
                    NativeMemoryRow(label: "Where the memory lives", help: root.path) {
                        HStack {
                            NativeSessionButton("Show in Finder") { if !store.fixture { NSWorkspace.shared.activateFileViewerSelecting([root]) } }
                            NativeSessionButton("Move…") { move() }.disabled(store.busy != nil)
                        }
                    }
                    Divider()
                    NativeMemoryRow(label: "This owner's part", help: store.owner.folder + "/  ·  plain text files you can open in any editor") {
                        NativeSessionButton("Show in Finder") { if !store.fixture { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(store.owner.folder)]) } }
                    }
                    Divider()
                    NativeMemoryRow(label: "Import", help: "Copy a Claude Code or Codex memory folder into this owner's notes. The original is never changed.") {
                        NativeMemoryImportButton(owner: store.owner)
                    }
                    Divider()
                    NativeMemoryRow(label: "Search index", help: "Rebuilt from the files. Use it after editing many files by hand.") {
                        HStack {
                            NativeSessionButton("Rebuild") { store.act("reindex") { let r = try await $0.reindex(); return "Read \(r.scanned) files: \(r.added) new, \(r.changed) changed." } }
                            NativeSessionButton("Back up now") { store.act("backup") { "Backup saved: " + (try await $0.backup()).lastPathComponent } }
                        }.disabled(store.busy != nil)
                    }
                }
            }
            if let previous = store.location?.previousRoots, !previous.isEmpty {
                DeckCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Earlier places").font(.headline)
                        Text("Kept as they were when the memory moved.").font(.caption).foregroundStyle(.secondary)
                        ForEach(previous, id: \.self) { url in
                            HStack { Text(url.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle); Spacer(); NativeSessionButton("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.borderless) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private func move() {
        guard !store.fixture else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Move here"; panel.message = "Choose the folder that will hold the memory. Everything is copied and checked; the old folder stays."
        guard panel.runModal() == .OK, let url = panel.url else { return } // front-ok: the person's button
        store.act("move") {
            let report = try await $0.move(to: url)
            return report.verified ? "Moved \(report.files) files to \(report.to.lastPathComponent)." : "Copied, but the check did not pass. The memory stays where it was."
        }
    }
}

/// "Import…": pick a Claude Code / Codex memory folder (the ones the app already finds, or any
/// folder) and copy it into this owner's notes. Usable from any profile.
struct NativeMemoryImportButton: View {
    let owner: DeckMemoryOwner
    @State private var spaces: [(label: String, root: String, kind: String)] = []
    @State private var message: String?
    @State private var busy = false
    init(owner: DeckMemoryOwner) { self.owner = owner }
    init(ownerKey: String) { owner = DeckMemoryOwner(ownerKey) ?? .hoot }
    var body: some View {
        HStack(spacing: 8) {
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            Menu(busy ? "Importing…" : "Import…") {
                if spaces.isEmpty { Text("No Claude Code or Codex memory found on this Mac") }
                ForEach(Array(spaces.enumerated()), id: \.offset) { _, space in
                    NativeSessionButton(space.label) { run(URL(fileURLWithPath: space.root), label: space.label) }
                }
                Divider()
                NativeSessionButton("Choose a folder…") { choose() }
            }.fixedSize().disabled(busy)
        }
        .task {
            guard spaces.isEmpty, let value = try? await EngineBridge.shared.invoke("memory:spaces"),
                  let found = (try? NativeRPCValue.fromFoundation(value))?["spaces"].elements else { return }
            spaces = found.compactMap { row in
                guard let root = row["root"].string, row["kind"].string != "hoot" else { return nil }
                return (row["label"].string ?? URL(fileURLWithPath: root).lastPathComponent, root, row["kind"].string ?? "")
            }
        }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.showsHiddenFiles = true
        panel.prompt = "Import"; panel.message = "Choose a memory folder. Its files are copied; the folder is not changed."
        guard panel.runModal() == .OK, let url = panel.url else { return } // front-ok: the person's button
        run(url, label: url.lastPathComponent)
    }
    private func run(_ source: URL, label: String) {
        busy = true; message = nil
        Task {
            defer { busy = false }
            do {
                let report = try await DeckMemory.ready().importFolder(source, into: owner, label: label)
                message = "Copied \(report.imported) new, \(report.updated) changed, \(report.unchanged) already here" + (report.skipped.isEmpty ? "." : "; \(report.skipped.count) skipped.")
            } catch { message = error.localizedDescription }
        }
    }
}
