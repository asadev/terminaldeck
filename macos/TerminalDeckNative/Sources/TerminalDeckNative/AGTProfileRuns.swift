import AppKit
import SwiftUI
import TerminalDeckNativeCore

struct AGTProfileRunRow: Identifiable {
    let value: NativeRPCValue
    var id: String { value["id"].string ?? value.compact }
    var started: Double { value["startedAt"].number ?? 0 }
    var task: String { value["title"].string ?? "Untitled run" }
    var took: Double { value["durationMs"].number ?? 0 }
    var result: String { value["result"].string ?? "Unknown" }
    var tokens: Double { value["tokens"].number ?? 0 }
    var cost: Double { value["costUSD"].number ?? 0 }
    var location: String { value["sessionName"].string ?? "—" }
    var startedText: String {
        started > 0 ? Date(timeIntervalSince1970: started / 1000).formatted(.dateTime.month(.abbreviated).day().hour().minute()) : "—"
    }
    var tookText: String { value["durationMs"].number.map { "\(max(1, Int($0 / 60_000))) min" } ?? "—" }
    var tokensText: String { value["tokens"].number?.formatted(.number.notation(.compactName)) ?? "—" }
    var costText: String { value["costUSD"].number?.formatted(.currency(code: "USD")) ?? "—" }
}

struct AGTProfileRuns: View {
    private var rows: [AGTProfileRunRow] { model.runs.map(AGTProfileRunRow.init).sorted(using: sort) }
    private func resultTag(_ row: AGTProfileRunRow) -> some View {
        Text(row.result.capitalized).font(.caption).padding(.horizontal, 6).padding(.vertical, 3)
            .background(DeckTokens.selection, in: RoundedRectangle(cornerRadius: 6))
    }
    private var runsTable: some View {
        Table(rows, selection: $selected, sortOrder: $sort) {
            TableColumn("Started", value: \AGTProfileRunRow.started) { (row: AGTProfileRunRow) in Text(row.startedText) }.width(min: 100, ideal: 140)
            TableColumn("Task", value: \AGTProfileRunRow.task).width(min: 160, ideal: 300)
            TableColumn("Took", value: \AGTProfileRunRow.took) { (row: AGTProfileRunRow) in Text(row.tookText) }.width(min: 55, ideal: 70)
            TableColumn("Result", value: \AGTProfileRunRow.result) { (row: AGTProfileRunRow) in resultTag(row) }.width(min: 75, ideal: 100)
            TableColumn("Tokens", value: \AGTProfileRunRow.tokens) { (row: AGTProfileRunRow) in Text(row.tokensText) }.width(min: 60, ideal: 80)
            if model.isAPI {
                TableColumn("Cost", value: \AGTProfileRunRow.cost) { (row: AGTProfileRunRow) in Text(row.costText) }.width(min: 60, ideal: 80)
            }
            TableColumn("Where", value: \AGTProfileRunRow.location).width(min: 90, ideal: 140)
        }
    }

    @Bindable var model: AGOPTProfileModel
    let openRun: (String) -> Void
    let showChange: (String) -> Void
    @State private var selected: String?
    @State private var sort = [KeyPathComparator(\AGTProfileRunRow.started, order: .reverse)]
    var body: some View {
        if model.runs.isEmpty {
            NativePageEmpty(symbol: "clock", title: "No runs yet") { Text("Completed and running work will appear here.") }
        } else {
            Group {
                runsTable
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let row = model.runs.first(where: { $0["id"].string == id }) {
                    Button("Open the run") { openRun(id) }.disabled(row["taskID"].string == nil && row["sessionID"].string == nil)
                    Button("Show the change") { showChange(id) }.disabled(row["changePath"].string == nil)
                    Button("Copy run ID") {
                        guard !model.isFixture else { return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string)
                    }
                }
            } primaryAction: { ids in if let id = ids.first { openRun(id) } }
            .frame(minHeight: 0, maxHeight: .infinity)
        }
    }
}
