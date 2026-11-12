import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The playbook (Hoot and leads): a real editable table. For each kind of job: which AI, which
/// model (from the live lists), effort, permission and the standing instructions.
struct NativeMemoryPlaybookPart: View {
    let store: NativeMemoryStore
    @State private var rows: [Row] = []
    @State private var preface = ""
    @State private var adoptedAt: Date?
    private var brain: ROUTINESHootBrainModel { .shared }

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var jobKind = "", ai = "", model = "", effort = "", permission = "", instructions = ""
        var saved: DeckMemoryPlaybookRow { .init(jobKind: jobKind.trimmingCharacters(in: .whitespaces), ai: ai, model: model, effort: effort, permission: permission, instructions: instructions) }
        static func == (a: Row, b: Row) -> Bool { a.saved == b.saved }
    }
    static let ais = [("claude", "Claude Code"), ("codex", "Codex"), ("gemini", "Gemini")]
    static let permissions = ["asks first", "edits on its own", "plans only", "bypass"]

    private var savedRows: [DeckMemoryPlaybookRow] { store.playbook?.rows ?? [] }
    private var dirty: Bool { rows.map(\.saved) != savedRows }
    private var problem: String? {
        let kinds = rows.map { $0.jobKind.trimmingCharacters(in: .whitespaces).lowercased() }
        if kinds.contains("") { return "Give every row a job kind." }
        if Set(kinds).count != kinds.count { return "Two rows have the same job kind." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(rows.isEmpty ? "No rows yet" : "\(rows.count) kinds of job").font(.callout).foregroundStyle(.secondary)
                if let problem { Text(problem).font(.callout).foregroundStyle(DeckTokens.warn) }
                else if dirty { Text("Not saved yet").font(.callout).foregroundStyle(DeckTokens.warn) }
                Spacer()
                NativeSessionButton { rows.append(Row(jobKind: rows.isEmpty ? "default" : "")) } label: { Label("Add a row", systemImage: "plus") }
                NativeSessionButton("Revert") { adopt(force: true) }.disabled(!dirty)
                NativeSessionButton("Save playbook") {
                    let next = rows.map(\.saved), owner = store.owner, note = preface
                    store.act("playbook", done: "Playbook saved") { _ = try await $0.savePlaybook(owner, rows: next, preface: note.isEmpty ? nil : note); return nil }
                }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command).disabled(!dirty || problem != nil || store.busy != nil)
            }.padding(.horizontal, 20)
            ScrollView([.vertical, .horizontal]) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        ForEach(["Job kind", "AI", "Model", "Effort", "Permission", "Standing instructions", ""], id: \.self) { title in
                            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellColumns(7)
                    ForEach($rows) { $row in
                        GridRow(alignment: .center) {
                            NativeSessionTextField("e.g. bug fix", text: $row.jobKind).textFieldStyle(.roundedBorder).frame(width: 150)
                            Picker("AI", selection: $row.ai) {
                                Text("Not set").tag("")
                                ForEach(Self.ais, id: \.0) { DeckRowLabel.provider($0.1, id: $0.0).tag($0.0) }
                                if !row.ai.isEmpty, !Self.ais.contains(where: { $0.0 == row.ai }) { Text(row.ai).tag(row.ai) }
                            }.labelsHidden().frame(width: 124)
                            .onChange(of: row.ai) { _, _ in
                                if !row.model.isEmpty, !models(row.ai).contains(where: { $0.id == row.model }) { row.model = "" }
                            }
                            Picker("Model", selection: $row.model) {
                                Text("Not set").tag("")
                                ForEach(models(row.ai), id: \.id) { Text($0.name).tag($0.id) }
                                if !row.model.isEmpty, !models(row.ai).contains(where: { $0.id == row.model }) { Text(row.model).tag(row.model) }
                            }.labelsHidden().frame(width: 170).disabled(row.ai.isEmpty)
                            .help(row.ai.isEmpty ? "Choose the AI first" : "The models this account can use right now")
                            Picker("Effort", selection: $row.effort) {
                                Text("Not set").tag("")
                                ForEach(efforts(row), id: \.self) { Text(HootBrainRows.effortName($0)).tag($0) }
                                if !row.effort.isEmpty, !efforts(row).contains(row.effort) { Text(row.effort).tag(row.effort) }
                            }.labelsHidden().frame(width: 116)
                            Picker("Permission", selection: $row.permission) {
                                Text("Not set").tag("")
                                ForEach(Self.permissions, id: \.self) { Text($0.prefix(1).uppercased() + $0.dropFirst()).tag($0) }
                                if !row.permission.isEmpty, !Self.permissions.contains(row.permission) { Text(row.permission).tag(row.permission) }
                            }.labelsHidden().frame(width: 150)
                            NativeSessionTextField("What it should always do for this kind of job", text: $row.instructions).textFieldStyle(.roundedBorder).frame(minWidth: 260, idealWidth: 340)
                            NativeSessionButton { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Remove this row").accessibilityLabel("Remove row")
                        }
                    }
                }
                .padding(16)
                .background(DeckTokens.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DeckTokens.hairline))
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            HStack(spacing: 10) {
                Text("A row called “default” is used when no other kind fits. Every agent job follows its row first: the row's AI, model, effort and permission win. What a row leaves “Not set” comes from the agent's own settings, then the app defaults.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let path = store.playbook?.path { NativeSessionButton("Show its file") { NativeMemoryFolderPart.reveal(path) }.buttonStyle(.borderless) }
            }.padding(.horizontal, 20).padding(.bottom, 12)
        }
        .onAppear { adopt(force: false); if !store.fixture { brain.load() } }
        .onChange(of: store.playbook?.updatedAt) { _, _ in adopt(force: false) }
    }

    /// Takes the saved table when there is no unsaved edit.
    private func adopt(force: Bool) {
        guard let playbook = store.playbook else { return }
        if force || adoptedAt == nil || !dirty {
            rows = playbook.rows.map { Row(jobKind: $0.jobKind, ai: $0.ai, model: $0.model, effort: $0.effort, permission: $0.permission, instructions: $0.instructions) }
            preface = playbook.preface
        }
        adoptedAt = playbook.updatedAt ?? Date()
    }
    /// The live model list for that AI (the same source as Hoot's own model menu).
    private func models(_ ai: String) -> [ROUTINESHootBrainModel.PickerModel] { brain.catalogs[ai] ?? [] }
    private func efforts(_ row: Row) -> [String] {
        guard !row.ai.isEmpty else { return ["low", "medium", "high"] }
        return models(row.ai).first { $0.id == row.model }.map { $0.efforts.isEmpty ? AGSCapabilities.efforts(provider: row.ai) : $0.efforts } ?? AGSCapabilities.efforts(provider: row.ai)
    }
}
