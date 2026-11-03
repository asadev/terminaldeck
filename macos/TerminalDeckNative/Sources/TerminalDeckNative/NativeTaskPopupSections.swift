import AppKit
import SwiftUI
import TerminalDeckNativeCore

// The popup's sections, in the CRM's order: subtasks (page/subtasks-table.tsx),
// relationships (dependencies-section.tsx), checklists (page/checklists-block.tsx),
// files (detail-attachments.tsx, attachment-chips.tsx, attach-button.tsx, the
// lightbox), then the routine (page/routine-block.tsx) and description history.

// MARK: - Record search (use-tag-search.ts → searchTags)

struct TagHit: Identifiable, Equatable {
    let area: String
    let id: String
    let label: String
    let secondary: String?
    let status: String?
    var href: String = ""
}

/// The CRM's record search, answered from your tasks, people and files: at least two
/// characters, a quarter of a second after typing stops.
@MainActor
@Observable
final class TagSearch {
    let area: String
    private(set) var hits: [TagHit]?
    private(set) var failed: String?
    private(set) var busy = false
    var query = "" { didSet { schedule() } }
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private weak var model: TaskDetailModel?

    init(area: String, model: TaskDetailModel) {
        self.area = area
        self.model = model
    }

    var tooShort: Bool { query.trimmingCharacters(in: .whitespaces).count < 2 }

    private func schedule() {
        pending?.cancel()
        hits = nil
        failed = nil
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            busy = false
            return
        }
        busy = true
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let model = self.model else { return }
            let result = await model.call("searchTags", [self.area, q])
            guard !Task.isCancelled else { return }
            self.busy = false
            switch result {
            case .failure: self.failed = "Could not search just now. Try again."
            case .success(let r):
                self.hits = (r["hits"] as? [Any] ?? []).compactMap { raw in
                    guard let h = raw as? [String: Any], let id = h["id"] as? String else { return nil }
                    return TagHit(area: h["area"] as? String ?? self.area, id: id, label: h["label"] as? String ?? id,
                                  secondary: h["secondary"] as? String, status: h["status"] as? String,
                                  href: h["href"] as? String ?? "")
                }
            }
        }
    }
}

/// The search results' states: too short, searching, none, or the hits.
struct SearchResults<Row: View>: View {
    let search: TagSearch
    let none: String
    var exclude: Set<String> = []
    @ViewBuilder let row: (TagHit) -> Row

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let failed = search.failed {
                    note(failed, TaskTone.input)
                } else if search.tooShort {
                    note("Type at least 2 characters.")
                } else if let found = search.hits {
                    let hits = found.filter { !exclude.contains($0.id) }
                    if hits.isEmpty { note("\(none) “\(search.query.trimmingCharacters(in: .whitespaces))”.") }
                    ForEach(hits) { row($0) }
                } else {
                    note("Searching…")
                }
            }
            .padding(4)
        }
        .frame(maxHeight: 176)
    }

    private func note(_ text: String, _ color: Color = .secondary) -> some View {
        Text(text).font(.caption).foregroundStyle(color).frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}

/// A search box with its magnifier and spinner.
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    let busy: Bool
    var onEscape: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear { focused = true }
                .onExitCommand { onEscape?() }
                .accessibilityLabel(placeholder)
            if busy { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
