import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckNativeCore

// MARK: - Followers and filter

/// 🔔 n — who hears about this task. Locally there is no following: everyone on the
/// task is notified, and the list is the people on it.
struct FollowersBell: View {
    let model: TaskDetailModel
    @State private var open = false
    @State private var query = ""

    var body: some View {
        let everyone = model.people?.list ?? []
        let n = everyone.count
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = words.isEmpty ? everyone : everyone.filter { $0.name.lowercased().contains(words) }
        Button { open.toggle() } label: {
            HStack(spacing: 2) {
                Image(systemName: "bell")
                Text("\(n)").font(.callout.weight(.medium))
            }
            .foregroundStyle(TaskTone.accent)
            .padding(.horizontal, 6).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(n) \(n == 1 ? "follower" : "followers") will get notified")
        .accessibilityLabel("\(n) \(n == 1 ? "follower" : "followers") will get notified")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Everyone on this task is notified.").font(.caption2).foregroundStyle(TaskTone.waiting)
                Divider()
                TextField("Search Followers...", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Search followers")
                Text("\(n) \(n == 1 ? "follower" : "followers")").font(.caption2).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { p in
                            HStack(spacing: 8) { PersonAvatar(person: p); Text(p.name).lineLimit(1); Spacer() }
                                .font(.callout).padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 224)
            }
            .padding(8)
            .frame(width: 290)
            .onDisappear { query = "" }
        }
    }
}

struct FilterMenu: View {
    @Binding var hidden: Set<FeedCategory>
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hidden.isEmpty ? Color.secondary : TaskTone.accent)
        .help("Filter activity")
        .accessibilityLabel("Filter activity")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Show").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("All") { hidden = [] }.buttonStyle(.link).font(.caption)
                    Button("Comments only") { hidden = Set(FeedCategory.allCases.filter { $0 != .comments }) }.buttonStyle(.link).font(.caption)
                }
                .padding(.bottom, 4)
                ForEach(FeedCategory.allCases, id: \.self) { c in
                    Toggle(c.label, isOn: Binding(get: { !hidden.contains(c) }, set: { on in
                        if on { hidden.remove(c) } else { hidden.insert(c) }
                    }))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                }
            }
            .padding(10)
            .frame(width: 260)
        }
    }
}
