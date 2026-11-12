import AppKit
import SwiftUI
import TerminalDeckNativeCore

// MARK: - People

/// A face: the photo, else the initials on the person's colour.
struct PersonAvatar: View {
    let person: CrmPerson
    var size: CGFloat = 20
    private var isAgent: Bool {
        person.id == CrmPeople.hoot || TasksStore.shared.state?.agents.contains { $0.id == person.id } == true
    }

    var body: some View {
        Text(person.initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(isAgent ? CrmColor.avatar(person.color) : Color.white)
            .frame(width: size, height: size)
            .background(Circle().fill(isAgent ? Color.secondary.opacity(0.12) : CrmColor.avatar(person.color)))
            .accessibilityLabel(person.name)
    }
}

/// Search the people a task can name, and pick one (person-search-list.tsx).
struct PersonSearchList<Header: View>: View {
    let team: [CrmPerson]
    var isPicked: (String) -> Bool = { _ in false }
    let onPick: (CrmPerson) -> Void
    @ViewBuilder var header: Header
    @State private var query = ""
    @FocusState private var focused: Bool

    private func matches(_ name: String, _ q: String) -> Bool {
        let n = name.lowercased()
        return n.contains(q) || n.split(whereSeparator: { $0.isWhitespace }).contains { $0.hasPrefix(q) }
    }

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = q.isEmpty ? team : team.filter { matches($0.name, q) }
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                NativeSessionTextField("Search people", text: $query)
                    .sessionFocused($focused)
                    .onSubmit { if let first = rows.first { onPick(first) } }
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text(q.isEmpty ? "No people to show." : "Nobody matches “\(query.trimmingCharacters(in: .whitespaces))”.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                    ForEach(rows) { p in
                        let picked = isPicked(p.id)
                        NativeSessionButton { onPick(p) } label: {
                            HStack(spacing: 8) {
                                PersonAvatar(person: p, size: 24)
                                Text(p.name).lineLimit(1)
                                Spacer()
                                if picked { Text("On task").font(.caption2).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(picked ? Color.secondary.opacity(0.12) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(picked ? "\(p.name) (on task)" : p.name)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 224)
        }
        .onAppear { focused = true }
    }
}

extension PersonSearchList where Header == EmptyView {
    init(team: [CrmPerson], isPicked: @escaping (String) -> Bool = { _ in false }, onPick: @escaping (CrmPerson) -> Void) {
        self.init(team: team, isPicked: isPicked, onPick: onPick) { EmptyView() }
    }
}

/// The Assignees cell: one face and name, or a stack; the picker adds and removes.
struct TaskPeopleField: View {
    let model: TaskDetailModel
    @State private var open = false

    var body: some View {
        if let people = model.people {
            let everyone = people.list
            let personal = everyone.isEmpty || (everyone.count == 1 && everyone[0].id == model.me)
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    if everyone.isEmpty {
                        Text("Empty").foregroundStyle(.tertiary)
                    } else if everyone.count == 1 {
                        PersonAvatar(person: everyone[0])
                        Text(everyone[0].name).lineLimit(1)
                    } else {
                        HStack(spacing: -4) {
                            ForEach(Array(everyone.prefix(3))) { PersonAvatar(person: $0).overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)) }
                            if everyone.count > 3 {
                                Text("+\(everyone.count - 3)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                                    .frame(width: 20, height: 20).background(Circle().fill(Color.gray))
                            }
                        }
                    }
                }
                .font(.system(size: 13))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(personal ? "Personal list — assign someone to share it" : everyone.isEmpty ? "Assign people" : everyone.map(\.name).joined(separator: ", "))
            .accessibilityLabel(personal ? "Personal list — only you. Assign someone else."
                : everyone.isEmpty ? "Assign people" : "People on this task: \(everyone.map(\.name).joined(separator: ", ")). Add or remove.")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                PersonSearchList(team: model.team, isPicked: { people.has($0) }, onPick: { person in
                    if people.has(person.id) { model.changePeople(people.removing(person.id)) }
                    else if personal { model.changePeople(TaskPeople(primary: person)) }
                    else { model.changePeople(people.adding(person)) }
                }) {
                    if !everyone.isEmpty {
                        TasksFlow(spacing: 4, lineSpacing: 4) {
                            ForEach(Array(everyone.enumerated()), id: \.element.id) { i, p in
                                HStack(spacing: 4) {
                                    PersonAvatar(person: p)
                                    Text(p.name).font(.caption).lineLimit(1)
                                    if i == 0 { Text("MAIN").font(.system(size: 9)).foregroundStyle(.tertiary) }
                                    Button { model.changePeople(people.removing(p.id)) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(p.name)")
                                }
                                .padding(.leading, 2).padding(.trailing, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.1)))
                                .overlay(Capsule().stroke(Color(nsColor: .separatorColor)))
                            }
                        }
                        .padding(8)
                        Divider()
                    }
                }
                .frame(width: 300)
            }
        } else {
            // People still loading: the task's main face, and a placeholder seat.
            HStack(spacing: 4) {
                if let a = model.task.assignee { PersonAvatar(person: a) }
                Circle().fill(Color.secondary.opacity(0.15)).frame(width: 20, height: 20)
            }
            .accessibilityLabel("Loading people")
        }
    }
}

/// An item's own person (a subtask, a checklist item): a face, or a dashed seat
/// that falls back to the task's main person.
struct RowAssignButton: View {
    let value: String?
    let people: TaskPeople
    let team: [CrmPerson]
    let what: String
    let onChange: (String?) -> Void
    @State private var open = false

    var body: some View {
        let own = value.flatMap { id in people.list.first { $0.id == id } ?? team.first { $0.id == id } }
        let fallback = people.primary
        Button { open.toggle() } label: {
            if let own {
                PersonAvatar(person: own)
            } else {
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2])).foregroundStyle(.tertiary))
            }
        }
        .buttonStyle(.plain)
        .help(own?.name ?? (fallback.map { "Nobody yet — falls to \($0.name)" } ?? "Assign this to someone"))
        .accessibilityLabel(own.map { "\(what) assigned to \($0.name). Change." } ?? "Assign \(what)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PersonSearchList(team: team, isPicked: { $0 == value }, onPick: { p in
                onChange(p.id == value ? nil : p.id)
                open = false
            }) {
                Button {
                    onChange(nil)
                    open = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.plus").font(.system(size: 9)).foregroundStyle(.tertiary)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2])).foregroundStyle(.tertiary))
                        Text("Same as the task\(fallback.map { " · \($0.name)" } ?? "")").font(.caption).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(value == nil ? Color.secondary.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
            .frame(width: 280)
        }
    }
}
