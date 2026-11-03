import AppKit
import SwiftUI
import TerminalDeckNativeCore

// MARK: - Dependencies

struct DependenciesSection: View {
    let model: TaskDetailModel
    let rows: [TaskDependency]
    @State private var kind: DependencyKind
    @State private var adding: Bool
    @State private var search: TagSearch
    @State private var hovered: String?

    init(model: TaskDetailModel, rows: [TaskDependency], justAdded: Bool, initialKind: DependencyKind?) {
        self.model = model
        self.rows = rows
        _kind = State(initialValue: initialKind ?? .blockedBy)
        _adding = State(initialValue: initialKind != nil || (justAdded && rows.isEmpty))
        _search = State(initialValue: TagSearch(area: "task", model: model))
    }

    var body: some View {
        let taken = Set(rows.map(\.id))
        CrmSectionBox(title: "Dependencies", aside: rows.isEmpty ? nil : String(rows.count)) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { r in
                    HStack(spacing: 8) {
                        Text(r.kind.label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.4)
                            .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                        Text(r.otherTitle).lineLimit(1).strikethrough(r.otherDone)
                            .foregroundStyle(r.otherDone ? Color(nsColor: .tertiaryLabelColor) : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.removeDependency(r) } label: { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 28, height: 28).contentShape(Rectangle()) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).opacity(hovered == r.id ? 1 : 0)
                            .accessibilityLabel("Remove dependency on \"\(r.otherTitle)\"")
                    }
                    .font(.callout)
                    .padding(4)
                    .onHover { hovered = $0 ? r.id : nil }
                }
                if !adding {
                    Button { adding = true } label: { Label("Add dependency", systemImage: "link").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            ForEach(DependencyKind.allCases, id: \.self) { k in
                                Button(k.label) { kind = k }
                                    .buttonStyle(.plain)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .foregroundStyle(kind == k ? Color(nsColor: .windowBackgroundColor) : .secondary)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(kind == k ? Color.primary : .clear))
                                    .accessibilityAddTraits(kind == k ? .isSelected : [])
                            }
                            Spacer()
                            Button {
                                adding = false
                                search.query = ""
                            } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Stop adding dependencies")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        Divider()
                        SearchField(placeholder: "Search your tasks", text: $search.query, busy: search.busy)
                        Divider()
                        SearchResults(search: search, none: "No task matches") { h in
                            let already = taken.contains("\(kind.rawValue):\(h.id)")
                            Button { model.addDependency(kind, otherId: h.id, otherTitle: h.label) } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(h.label).lineLimit(1)
                                        if let s = h.secondary { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer()
                                    if let status = h.status {
                                        Text(status).font(.system(size: 10)).padding(.horizontal, 6)
                                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                                    }
                                    if already { Text("Added").font(.system(size: 10)).foregroundStyle(.secondary) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(already)
                            .opacity(already ? 0.45 : 1)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                }
            }
        }
    }
}

/// A bordered section with a small title and a counter (section-shell.tsx).
struct CrmSectionBox<Content: View>: View {
    let title: String
    var aside: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                if let aside { Text(aside).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            content.padding(.horizontal, 8).padding(.vertical, 6)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
