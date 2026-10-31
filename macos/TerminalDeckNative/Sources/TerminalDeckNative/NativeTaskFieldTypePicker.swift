import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// MARK: - The type picker

/// ClickUp's list: a search box, "All" and the groups, then every type.
struct FieldTypePicker: View {
    let current: FieldKind?
    let onPick: (FieldKind) -> Void
    @State private var query = ""
    @State private var group: FieldGroup?
    @FocusState private var focused: Bool

    var body: some View {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = TaskFields.types.filter { t in
            (group == nil || t.group == group) && (needle.isEmpty || t.name.lowercased().contains(needle) || t.hint.lowercased().contains(needle))
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                TextField("Search…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let first = shown.first { onPick(first.kind) } }
                    .accessibilityLabel("Search field types")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            TasksFlow(spacing: 4, lineSpacing: 4) {
                FieldChipToggle(title: "All", on: group == nil) { group = nil }
                ForEach(FieldGroup.allCases, id: \.self) { g in
                    FieldChipToggle(title: g.label, on: group == g) { group = g }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filter field types")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty {
                        Text("No field type matches “\(query.trimmingCharacters(in: .whitespaces))”.").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    ForEach(shown, id: \.kind) { t in
                        FieldMenuRow(action: { onPick(t.kind) }) {
                            FieldTypeIcon(kind: t.kind)
                            Text(t.name).lineLimit(1)
                            Spacer()
                            if t.kind == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .accessibilityAddTraits(t.kind == current ? .isSelected : [])
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 288)
            .accessibilityLabel("Field types")
        }
        .onAppear { focused = true }
    }
}
