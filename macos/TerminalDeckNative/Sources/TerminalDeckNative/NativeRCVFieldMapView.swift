import SwiftUI
import TerminalDeckNativeCore

/// A source's "What arrives → where it goes" and "Check connection" (Events tab). Generic: works
/// for every source. The preview reads the latest event (or a pasted sample, or the preset's sample)
/// with the mapping being edited, so "Map it" shows its effect at once and saves like any edit.
struct NativeRCVFieldMapSections: View {
    let model: NativeRCVModel
    let source: RCVSource
    @Binding var mapping: RCVMapping
    let working: Bool
    @State private var pasted = ""
    @State private var showPaste = false
    @State private var check: RCVConnectionCheck?
    @State private var checkError: String?
    @State private var checking = false

    private var preview: RCVFieldPreview {
        let pastedText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pastedText.isEmpty { return RCVFieldPreview.build(mapping: mapping, body: Data(pastedText.utf8), basis: "Pasted sample") }
        if let event = model.recentEvents(of: [source.id]).first(where: { $0.raw.count > 2 }) {
            return RCVFieldPreview.build(mapping: mapping, body: event.raw, headers: event.headers,
                                         basis: "Latest event · " + event.receivedAt.formattedClock)
        }
        if let sample = RCVPresets.sample(for: source, custom: model.presets) {
            return RCVFieldPreview.build(mapping: mapping, body: Data(sample.utf8), basis: "Sample — nothing has arrived yet")
        }
        return .nothing("Nothing has arrived from this source yet. Paste a sample to see where each value would go.")
    }

    var body: some View {
        let shown = preview
        Section {
            if let empty = shown.empty { Text(empty).font(.callout).foregroundStyle(.secondary) }
            else {
                Text(shown.basis).font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(shown.rows) { row in
                        GridRow {
                            Text(row.name).font(.system(size: 12, design: .monospaced))
                            Text(row.value.isEmpty ? "—" : row.value).font(.callout).foregroundStyle(row.value.isEmpty ? Color.secondary : Color.primary).lineLimit(2)
                            Text("→ " + row.destination).font(.caption).foregroundStyle(row.onTask ? Color.accentColor : Color.secondary).lineLimit(2)
                        }
                    }
                }.accessibilityElement(children: .contain).accessibilityLabel("Mapped values")
                if !shown.unmapped.isEmpty {
                    Text("Arrives but nothing reads it (\(shown.unmapped.count))").font(.callout.weight(.semibold)).foregroundStyle(.orange).padding(.top, 6)
                    ForEach(shown.unmapped) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.path).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                            Text(item.value).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Button("Map it") { if let next = RCVFieldPreview.mapping(mapping, adding: item.suggestion) { mapping = next } }
                                .buttonStyle(.borderless).disabled(working || mapping.fields.count >= RCVEngine.maxFields)
                                .help("Add the field “\(item.suggestion.name)” = \(item.suggestion.value) → \(item.destination)")
                        }
                    }
                } else {
                    Label("Every value that arrives is read.", systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Paste a sample", isExpanded: $showPaste) {
                TextField("{\"title\": \"…\"}", text: $pasted, axis: .vertical).font(.system(size: 12, design: .monospaced))
                    .lineLimit(3...10).labelsHidden().accessibilityLabel("Sample payload")
            }
        } header: { Text("What arrives → where it goes") } footer: {
            Text("A field named like a task field (status, priority, startDate, dueDate, labels, board, taskType, estimateMinutes) fills it. Any other name becomes a custom field on the task.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Connection") {
            HStack {
                Button(checking ? "Checking…" : "Check connection") { Task { await runCheck() } }.disabled(checking)
                    .help("Show the last event this source received and whether it became a task with its fields. Sends nothing.")
                Spacer()
            }
            if let checkError { Text(checkError).font(.callout).foregroundStyle(.red) }
            if let check {
                Text(check.headline).font(.callout.weight(.semibold))
                    .foregroundStyle(check.verdict == .working ? Color.green : [.nothingYet, .paused].contains(check.verdict) ? Color.secondary : Color.orange)
                ForEach(Array(check.lines.enumerated()), id: \.offset) { Text($0.element).font(.callout).foregroundStyle(.secondary) }
                ForEach(check.landings) { landing in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: landing.landed ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(landing.landed ? Color.green : Color.orange)
                        Text(landing.name).font(.system(size: 12, design: .monospaced))
                        Text("→ " + landing.destination).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(landing.expected).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func runCheck() async {
        checking = true; defer { checking = false }
        let (answer, error) = await model.checkConnection(source.id)
        check = answer; checkError = error
    }
}

private extension Double {
    /// Milliseconds since 1970 as "12 Oct, 09:12".
    var formattedClock: String {
        let formatter = DateFormatter(); formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: self / 1000))
    }
}
