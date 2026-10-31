import SwiftUI
import TerminalDeckNativeCore

/// "Related to" on a connected system's task: the records it is linked to there (a lead,
/// a listing, a person…), each removable, and "Link a record" to search that system and
/// link one. Every change goes back to the system, through the same yes as other changes.
struct ConnectedRelatedCell: View {
    let model: TaskDetailModel
    let related: TaskDetailModel.Related
    @State private var picking = false
    @State private var search: TagSearch?

    var body: some View {
        let editable = model.canEditRow && !related.areas.isEmpty
        TasksFlow(spacing: 6, lineSpacing: 6, fillsWidth: false) {
            ForEach(related.links, id: \.id) { link in
                HStack(spacing: 4) {
                    Text(TaskFields.tagAreaLabel(link.area).uppercased()).font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(link.label).font(.system(size: 12)).lineLimit(1)
                    if model.canEditRow {
                        Button { model.setRelated(related.links.filter { !($0.area == link.area && $0.id == link.id) }) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Unlink \(link.label)")
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
            }
            if related.links.isEmpty && !editable { Text("None").font(.system(size: 13)).foregroundStyle(.tertiary) }
            if editable {
                Button { picking.toggle() } label: {
                    Label(related.links.isEmpty ? "Link a record" : "Link", systemImage: "plus").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .popover(isPresented: $picking, arrowEdge: .bottom) { picker }
            }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if related.areas.count > 1 {
                HStack(spacing: 4) {
                    ForEach(related.areas, id: \.self) { area in
                        let on = (search?.area ?? related.areas.first) == area
                        Button(TaskFields.tagAreaLabel(area)) { search = TagSearch(area: area, model: model) }
                            .buttonStyle(.plain).font(.caption.weight(on ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(on ? Color.accentColor.opacity(0.15) : Color.clear))
                    }
                }
            }
            if let search {
                SearchField(placeholder: "Search \(TaskFields.tagAreaLabel(search.area).lowercased())s…",
                            text: Binding(get: { search.query }, set: { search.query = $0 }), busy: search.busy) { picking = false }
                SearchResults(search: search, none: "Nothing found for", exclude: Set(related.links.map(\.id))) { hit in
                    Button {
                        picking = false
                        model.setRelated(related.links + [hit])
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hit.label).font(.callout).lineLimit(1)
                            if let secondary = hit.secondary { Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .frame(width: 320)
        .onAppear { if search == nil, let first = related.areas.first { search = TagSearch(area: first, model: model) } }
    }
}

/// Chips that wrap onto the next line.
