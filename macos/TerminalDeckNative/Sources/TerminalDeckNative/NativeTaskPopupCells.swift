import AppKit
import SwiftUI
import TerminalDeckNativeCore

// The popup's property cells and people controls, as the CRM page draws them:
// page/property-cells.tsx (Property, Status, Type, Track time, Tags), pill-select.tsx,
// task-people-field.tsx, person-search-list.tsx, people/person-picker.tsx (avatar),
// LocalTaskPopup.tsx (Project folder) and workspace-toggle / workspace-cell.

// MARK: - Colours

enum CrmColor {
    /// The CRM's avatar palette names (`bg-blue-500` …) as colours.
    static func avatar(_ name: String) -> Color {
        switch name {
        case "bg-blue-500": Color(red: 0.23, green: 0.51, blue: 0.96)
        case "bg-violet-500": Color(red: 0.55, green: 0.36, blue: 0.96)
        case "bg-emerald-500": Color(red: 0.06, green: 0.73, blue: 0.51)
        case "bg-amber-500": Color(red: 0.96, green: 0.62, blue: 0.04)
        case "bg-rose-500": Color(red: 0.96, green: 0.25, blue: 0.37)
        case "bg-sky-500": Color(red: 0.05, green: 0.65, blue: 0.91)
        case "bg-indigo-500": Color(red: 0.39, green: 0.40, blue: 0.95)
        case "bg-teal-500": Color(red: 0.08, green: 0.72, blue: 0.65)
        case "bg-orange-500": Color(red: 0.98, green: 0.45, blue: 0.09)
        case "bg-fuchsia-500": Color(red: 0.85, green: 0.27, blue: 0.94)
        default: Color.gray
        }
    }

    /// The status pill's solid colour (pill-select.tsx STATUS_SOLID).
    static func statusSolid(_ status: String) -> Color {
        switch status {
        case "Working on it": Color(red: 0.96, green: 0.62, blue: 0.04)
        case "In Progress": Color(red: 0.49, green: 0.23, blue: 0.93)
        case "Done": Color(red: 0.02, green: 0.59, blue: 0.41)
        case "Stuck": Color(red: 0.88, green: 0.11, blue: 0.28)
        default: Color.secondary.opacity(0.15)
        }
    }

    static func statusInk(_ status: String) -> Color { status == "To-Do" ? Color.primary.opacity(0.75) : .white }

    /// A priority's flag (pill-select.tsx PRIORITY_FLAG).
    static func flag(_ priority: String?) -> Color {
        switch priority {
        case "Critical": Color(red: 0.88, green: 0.11, blue: 0.28)
        case "High": Color(red: 0.96, green: 0.62, blue: 0.04)
        case "Medium": Color(red: 0.15, green: 0.39, blue: 0.92)
        default: Color.secondary
        }
    }

    /// A tag colour (task-more.ts LABEL_TONE) — the swatch, its tint and its ink.
    static func label(_ name: String) -> Color {
        switch name {
        case "red": TaskTone.input
        case "orange": Color.orange
        case "amber", "yellow": TaskTone.waiting
        case "lime", "green": TaskTone.completed
        case "teal": Color.teal
        case "cyan": Color.cyan
        case "blue", "indigo": Color.accentColor
        case "violet", "purple": Color.purple
        case "pink": Color.pink
        default: Color.secondary
        }
    }

    static let labelColors = ["grey", "red", "orange", "amber", "yellow", "lime", "green", "teal", "cyan", "blue", "indigo",
                              "violet", "purple", "pink"]
}

// MARK: - People

/// A face: the photo, else the initials on the person's colour.
struct PersonAvatar: View {
    let person: CrmPerson
    var size: CGFloat = 20

    var body: some View {
        Text(person.initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(CrmColor.avatar(person.color)))
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
                TextField("Search people", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let first = rows.first { onPick(first) } }
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
                        Button { onPick(p) } label: {
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

// MARK: - The properties grid

/// One row of the grid: an icon and a label, then the cell (36 points tall).
struct PropertyRow<Content: View>: View {
    let icon: String
    let label: String
    var wide = false
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        HStack(alignment: wide ? .top : .center, spacing: 0) {
            Label(label, systemImage: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .labelStyle(PropertyLabelStyle())
                .frame(width: 152, alignment: .leading)
                .frame(minHeight: 36)
            content
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.secondary.opacity(0.08) : .clear))
                .onHover { hovering = $0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

private struct PropertyLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(.tertiary).frame(width: 16)
            configuration.title
        }
    }
}

/// "Unavailable", with the reason on hover.
struct UnavailableCell: View {
    let reason: String
    var body: some View { Text("Unavailable").font(.system(size: 13)).foregroundStyle(.tertiary).help(reason) }
}

/// The status pill (Statuses, then Closed), its ▸ next step, and ✓ Mark complete.
struct StatusCell: View {
    let model: TaskDetailModel
    @State private var open = false

    var body: some View {
        let value = model.task.group
        if !model.canEditRow {
            Text(CrmText.statusWord(value))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CrmColor.statusInk(value))
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 5).fill(CrmColor.statusSolid(value)))
                .help("Only the main assignee or the person who raised this task can change its status")
                .accessibilityLabel("Status: \(value)")
        } else {
            let next = CrmText.nextStatus(value)
            HStack(spacing: 6) {
                HStack(spacing: 0) {
                    Button { open.toggle() } label: {
                        Text(CrmText.statusWord(value))
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.3)
                            .foregroundStyle(CrmColor.statusInk(value))
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5,
                                                               bottomTrailingRadius: next == nil ? 5 : 0, topTrailingRadius: next == nil ? 5 : 0)
                                .fill(CrmColor.statusSolid(value)))
                    }
                    .buttonStyle(.plain)
                    .help("Status")
                    .accessibilityLabel("Status: \(value)")
                    .popover(isPresented: $open, arrowEdge: .bottom) { statusMenu(value) }
                    if let next {
                        Button { model.changeStatus(next) } label: {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(CrmColor.statusInk(value))
                                .frame(width: 20, height: 28)
                                .background(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 5,
                                                                   topTrailingRadius: 5).fill(CrmColor.statusSolid(value).opacity(0.85)))
                        }
                        .buttonStyle(.plain)
                        .help("Move to \(CrmText.statusWord(next))")
                        .accessibilityLabel("Next status: \(CrmText.statusWord(next))")
                    }
                }
                if value != "Done" {
                    Button { model.changeStatus("Done") } label: {
                        Image(systemName: "checkmark").font(.system(size: 12))
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Mark complete")
                    .accessibilityLabel("Mark complete")
                }
            }
        }
    }

    private func statusMenu(_ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Statuses").font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6)
            ForEach(CrmText.statuses.filter { $0 != "Done" }, id: \.self) { option(value, $0) }
            Divider().padding(.vertical, 4)
            Text("Closed").font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 12)
            option(value, "Done")
        }
        .padding(.bottom, 6)
        .frame(width: 220)
    }

    private func option(_ value: String, _ s: String) -> some View {
        Button {
            model.changeStatus(s)
            open = false
        } label: {
            HStack(spacing: 10) {
                Group {
                    if s == "To-Do" {
                        Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [2])).foregroundStyle(.secondary)
                    } else if s == "Done" {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(CrmColor.statusSolid("Done"))
                    } else {
                        Circle().fill(CrmColor.statusSolid(s))
                    }
                }
                .frame(width: 12, height: 12)
                .frame(width: 16)
                Text(s)
                Spacer()
                if s == value { Image(systemName: "checkmark").font(.caption).foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(s == value ? Color.secondary.opacity(0.12) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(s == value ? .isSelected : [])
    }
}

/// The Priority cell: the flag and its word, or "Empty"; a list, Critical first, and Clear.
struct PriorityCell: View {
    let value: String?
    let onChange: (String?) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            if let value {
                HStack(spacing: 6) {
                    Image(systemName: "flag.fill").foregroundStyle(CrmColor.flag(value))
                    Text(value)
                }
                .font(.system(size: 13))
            } else {
                Text("Empty").font(.system(size: 13)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .help("Change priority")
        .accessibilityLabel(value.map { "Priority: \($0)" } ?? "Priority")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Priority").font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6)
                ForEach(CrmText.priorities.reversed(), id: \.self) { p in
                    Button {
                        onChange(p)
                        open = false
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "flag.fill").font(.caption).foregroundStyle(CrmColor.flag(p)).frame(width: 16)
                            Text(p)
                            Spacer()
                            if p == value { Image(systemName: "checkmark").font(.caption).foregroundStyle(Color.accentColor) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(p == value ? Color.secondary.opacity(0.12) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(p) priority")
                    .accessibilityAddTraits(p == value ? .isSelected : [])
                }
                if value != nil {
                    Divider()
                    Button {
                        onChange(nil)
                        open = false
                    } label: {
                        Text("Clear").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 6)
            .frame(width: 200)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Choose a priority")
        }
    }
}

/// "Task ⌄" / "Milestone ⌄" at the top of the page.
struct TypePill: View {
    let value: String
    let canEdit: Bool
    let onChange: (String) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: value == "milestone" ? "diamond" : "smallcircle.filled.circle").font(.caption).foregroundStyle(.secondary)
                Text(value == "milestone" ? "Milestone" : "Task")
                if canEdit { Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(!canEdit)
        .accessibilityLabel("Task type: \(value == "milestone" ? "Milestone" : "Task")")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Task type").font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6)
                ForEach([("task", "Task", "smallcircle.filled.circle"), ("milestone", "Milestone", "diamond")], id: \.0) { id, label, icon in
                    Button {
                        open = false
                        if id != value { onChange(id) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
                            Text(label)
                            Spacer()
                            if id == value { Image(systemName: "checkmark").font(.caption).foregroundStyle(Color.purple) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 6)
            .frame(width: 200)
        }
    }
}

// MARK: - Track time

struct TrackTimeCell: View {
    let model: TaskDetailModel
    let extras: TaskPageExtras
    @State private var open = false
    @State private var now = Date()

    var body: some View {
        let me = model.meperson
        let running = extras.timeEntries.first { $0.userId == me?.id && $0.endedAt == nil }
        let total = CrmTime.totalTracked(extras.timeEntries, now: now)
        let elapsed = running.flatMap { CrmTime.date($0.startedAt) }.map { max(0, now.timeIntervalSince($0).rounded(.down)) } ?? 0
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                if running != nil {
                    Image(systemName: "stop.fill").font(.system(size: 7)).foregroundStyle(.white)
                        .frame(width: 16, height: 16).background(Circle().fill(Color(red: 0.96, green: 0.25, blue: 0.37)))
                    Text(CrmTime.clockDuration(elapsed)).monospacedDigit()
                } else {
                    Image(systemName: "play.fill").font(.system(size: 7))
                        .foregroundStyle(total > 0 ? Color.white : Color.secondary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(total > 0 ? Color.primary.opacity(0.75) : .clear))
                        .overlay(Circle().stroke(total > 0 ? .clear : Color.secondary))
                    Text(total > 0 ? CrmTime.duration(total) : "Start").foregroundStyle(total > 0 ? Color.primary : Color.secondary)
                }
                if let est = extras.estimateMinutes {
                    Text("/ \(CrmTime.duration(est * 60))").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(running != nil ? "Track time: running \(CrmTime.clockDuration(elapsed))"
            : total > 0 ? "Track time: \(CrmTime.duration(total))" : "Track time")
        .popover(isPresented: $open, arrowEdge: .bottom) { TimePopover(model: model) }
        .task(id: running?.id) {
            now = Date()
            guard running != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                now = Date()
            }
        }
    }
}

/// "Time on this task": enter a time or start the timer, the day, notes, tags,
/// billable, Save; the entries; the estimate.
private struct TimePopover: View {
    let model: TaskDetailModel
    @State private var text = ""
    @State private var date = Date()
    @State private var note = ""
    @State private var billable = false
    @State private var newTags: [String] = []
    @State private var tagText = ""
    @State private var busy = false
    @State private var error: String?
    @State private var estimate = ""
    @State private var hovered: String?

    var body: some View {
        let extras = model.extras
        let entries = extras?.timeEntries ?? []
        let me = model.meperson
        let running = entries.first { $0.userId == me?.id && $0.endedAt == nil }
        let parsed = CrmTime.parseDuration(text)
        let tagsOn = model.more != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Time on this task").font(.callout.weight(.semibold))
                Spacer()
                Text(CrmTime.duration(CrmTime.totalTracked(entries))).monospacedDigit().foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if let me { PersonAvatar(person: me) }
                    Text(me?.name ?? "You")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                HStack(spacing: 8) {
                    TextField("Enter time (ex: 3h 20m) or start timer", text: $text)
                        .textFieldStyle(.plain)
                        .onSubmit { if let parsed, !busy { add(parsed) } }
                        .accessibilityLabel("Enter time")
                    Button {
                        run { running != nil ? await model.timeStop() : await model.timeStart() }
                    } label: {
                        Image(systemName: running != nil ? "stop.fill" : "play.fill").font(.system(size: 11)).foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(running != nil ? Color(red: 0.96, green: 0.25, blue: 0.37) : Color.purple))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityLabel(running != nil ? "Stop timer" : "Start timer")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "calendar").foregroundStyle(.tertiary)
                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date).labelsHidden()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.alignleft").foregroundStyle(.tertiary)
                    TextField("Notes", text: Binding(get: { note }, set: { note = String($0.prefix(2000)) }), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                if tagsOn {
                    Divider()
                    HStack(spacing: 6) {
                        Image(systemName: "tag").foregroundStyle(.tertiary)
                        ForEach(newTags, id: \.self) { t in
                            HStack(spacing: 2) {
                                Text(t).font(.caption)
                                Button { newTags.removeAll { $0 == t } } label: { Image(systemName: "xmark").font(.system(size: 8)) }
                                    .buttonStyle(.plain).accessibilityLabel("Remove time tag \(t)")
                            }
                            .padding(.horizontal, 6).background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                        }
                        TextField("Add tags", text: $tagText)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                let t = String(tagText.trimmingCharacters(in: .whitespaces).prefix(40))
                                if !t.isEmpty && !newTags.contains(t) && newTags.count < 10 { newTags.append(t) }
                                tagText = ""
                            }
                            .accessibilityLabel("Add time tags")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            HStack(spacing: 8) {
                Toggle("Billable", isOn: $billable).toggleStyle(.switch).controlSize(.mini).labelsHidden().accessibilityLabel("Billable")
                Text("Billable").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let parsed { add(parsed, clearAll: true) }
                } label: {
                    HStack(spacing: 4) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(parsed == nil || busy)
            }
            if !text.isEmpty && parsed == nil {
                Text("Type a time like 1h 30m, 45m or 2h.").font(.caption).foregroundStyle(TaskTone.waiting)
            }
            if let error { Text(error).font(.caption).foregroundStyle(TaskTone.input) }
            if !entries.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(entries.reversed()) { e in
                            let who = model.team.first { $0.id == e.userId }
                            HStack(spacing: 8) {
                                if let who { PersonAvatar(person: who) } else { Color.clear.frame(width: 20, height: 20) }
                                Text(e.endedAt != nil ? CrmTime.duration(e.seconds ?? 0) : "running").monospacedDigit().frame(width: 64, alignment: .leading)
                                Text(CrmTime.ymdMonthDay(entryDay(e))).font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 4) {
                                    Text(e.note ?? "").lineLimit(1)
                                    ForEach(model.more?.entryTags[e.id] ?? [], id: \.self) { t in
                                        Text(t).font(.system(size: 10)).padding(.horizontal, 4)
                                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if e.billable { Text("$").font(.caption).foregroundStyle(Color.purple) }
                                if e.userId == me?.id && e.endedAt != nil {
                                    Button { run { await model.timeDelete(e.id) } } label: { Image(systemName: "xmark").font(.caption2) }
                                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                                        .opacity(hovered == e.id ? 1 : 0)
                                        .accessibilityLabel("Remove time entry")
                                }
                            }
                            .onHover { hovered = $0 ? e.id : nil }
                        }
                    }
                }
                .frame(maxHeight: 160)
                .accessibilityLabel("Time entries")
            }
            Divider()
            HStack {
                Text("Time estimate").foregroundStyle(.secondary)
                Spacer()
                if model.canEditRow {
                    TextField("e.g. 2h", text: $estimate)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)
                        .onSubmit(saveEstimate)
                        .accessibilityLabel("Time estimate")
                } else {
                    Text(extras?.estimateMinutes.map { CrmTime.duration($0 * 60) } ?? "—").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(width: 486)
        .onAppear { estimate = model.extras?.estimateMinutes.map { CrmTime.duration($0 * 60) } ?? "" }
        .onDisappear { if model.canEditRow { saveEstimate() } }
    }

    private func entryDay(_ e: TimeEntry) -> String {
        CrmTime.date(e.endedAt ?? e.startedAt).map { CrmTime.todayYmd($0) } ?? ""
    }

    private func saveEstimate() {
        let raw = estimate.trimmingCharacters(in: .whitespaces)
        let secs = raw.isEmpty ? nil : CrmTime.parseDuration(raw)
        if !raw.isEmpty && secs == nil { return }
        let mins = secs.map { ($0 / 60).rounded() }
        if mins != model.extras?.estimateMinutes { run { await model.timeEstimate(mins) } }
    }

    private func add(_ seconds: Double, clearAll: Bool = false) {
        let day = TaskList.ymdOf(date.timeIntervalSince1970 * 1000)
        let tags = newTags
        run({ await model.timeAdd(seconds: seconds, date: day, note: note, billable: billable, tags: tags) }) {
            text = ""
            if clearAll {
                note = ""
                newTags = []
            }
        }
    }

    private func run(_ work: @escaping () async -> String?, after: (() -> Void)? = nil) {
        busy = true
        error = nil
        Task {
            let err = await work()
            busy = false
            if let err { error = err } else { after?() }
        }
    }
}

// MARK: - Tags

struct TagsCell: View {
    let model: TaskDetailModel
    let labels: [String]
    @State private var open = false
    @State private var query = ""
    @State private var menuFor: String?
    @State private var confirmDelete = false

    private func colorName(_ l: String) -> String { model.more?.labelColors[l.lowercased()] ?? "grey" }

    var body: some View {
        Button { open.toggle() } label: {
            if labels.isEmpty {
                Text("Empty").font(.system(size: 13)).foregroundStyle(.tertiary)
            } else {
                TasksFlow(spacing: 4, lineSpacing: 4) {
                    ForEach(labels, id: \.self) { tag($0) }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.canEditRow)
        .accessibilityLabel(labels.isEmpty ? "Tags" : "Tags: \(labels.joined(separator: ", "))")
        .popover(isPresented: $open, arrowEdge: .bottom) { editor }
    }

    private func tag(_ l: String) -> some View {
        let c = CrmColor.label(colorName(l))
        return Text(l).font(.caption.weight(.medium)).foregroundStyle(c).padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(c.opacity(0.16)))
    }

    private var editor: some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let exists = labels.contains { $0.lowercased() == trimmed.lowercased() }
        let canColor = model.more?.canColorTags == true
        let canDelete = model.more != nil
        return VStack(alignment: .leading, spacing: 8) {
            TasksFlow(spacing: 4, lineSpacing: 4) {
                ForEach(labels, id: \.self) { l in
                    let c = CrmColor.label(colorName(l))
                    HStack(spacing: 2) {
                        Text(l).font(.caption)
                        if canColor || canDelete {
                            Button {
                                menuFor = menuFor == l ? nil : l
                                confirmDelete = false
                            } label: { Image(systemName: "ellipsis").font(.system(size: 9)) }
                                .buttonStyle(.plain).accessibilityLabel("Tag options: \(l)")
                        }
                        Button { model.changeLabels(labels.filter { $0 != l }) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).accessibilityLabel("Remove tag \(l)")
                    }
                    .foregroundStyle(c)
                    .padding(.leading, 8).padding(.trailing, 4).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 4).fill(c.opacity(0.16)))
                }
                TextField("Search or add tags...", text: Binding(get: { query }, set: { query = String($0.prefix(40)) }))
                    .textFieldStyle(.plain)
                    .frame(minWidth: 128)
                    .onSubmit(add)
                    .onKeyPress(.delete) {
                        if query.isEmpty, !labels.isEmpty {
                            model.changeLabels(Array(labels.dropLast()))
                            return .handled
                        }
                        return .ignored
                    }
                    .accessibilityLabel("Search or add tags")
            }
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            if let menuFor {
                VStack(alignment: .leading, spacing: 6) {
                    if canColor {
                        Text("Add color").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        TasksFlow(spacing: 6, lineSpacing: 6) {
                            ForEach(CrmColor.labelColors, id: \.self) { c in
                                let on = colorName(menuFor) == c
                                Button { model.setLabelColor(menuFor, c) } label: {
                                    Circle().fill(CrmColor.label(c)).frame(width: 20, height: 20)
                                        .overlay(Circle().stroke(Color.primary.opacity(on ? 0.6 : 0), lineWidth: 2).padding(-2))
                                }
                                .buttonStyle(.plain)
                                .help(c == "grey" ? "Light Grey" : c)
                                .accessibilityLabel("Colour \(c == "grey" ? "Light Grey" : c)")
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                    if canDelete {
                        if !confirmDelete {
                            Button { confirmDelete = true } label: { Label("Delete", systemImage: "trash").foregroundStyle(TaskTone.input) }
                                .buttonStyle(.plain)
                        } else {
                            Text("Are you sure you want to delete the **\(menuFor)** tag everywhere? It comes off every task you can change.")
                                .font(.caption)
                            HStack {
                                Button("Delete", role: .destructive) {
                                    let t = menuFor
                                    self.menuFor = nil
                                    confirmDelete = false
                                    model.deleteLabelEverywhere(t)
                                }
                                .buttonStyle(.borderedProminent).tint(TaskTone.input).controlSize(.small)
                                Button("Cancel") { confirmDelete = false }.controlSize(.small)
                            }
                        }
                    }
                }
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .onExitCommand {
                    self.menuFor = nil
                    confirmDelete = false
                }
            }
            Text(labels.isEmpty ? "Select an option" : "On this task").font(.caption2).foregroundStyle(.secondary)
            if !trimmed.isEmpty && !exists {
                Button(action: add) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.caption).foregroundStyle(.tertiary)
                        Text("Create")
                        Text(trimmed).font(.caption.weight(.medium)).padding(.horizontal, 6)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12)))
                        Spacer()
                        Text("⏎").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(labels.count >= 20)
            } else if labels.isEmpty {
                Text("No tags created").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(width: 280)
    }

    private func add() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !labels.contains(where: { $0.lowercased() == trimmed.lowercased() }), labels.count < 20 else { return }
        model.changeLabels(CrmText.normalizeLabels(labels + [trimmed]))
        query = ""
    }
}

// MARK: - Local rows: the project folder and the workspace

/// The folder an agent works in: click to type it, or choose it in the Mac's folder chooser.
struct ProjectCell: View {
    let model: TaskDetailModel
    @State private var editing = false
    @State private var draft = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        let project = model.row.project
        HStack(spacing: 8) {
            if editing {
                TextField("/Users/you/Projects/app", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .onAppear { focused = true }
                    .onSubmit(save)
                    .onChange(of: focused) { _, now in if !now { save() } }
                    .onExitCommand {
                        draft = project
                        editing = false
                    }
                    .accessibilityLabel("Project folder")
            } else {
                Button {
                    draft = project
                    editing = true
                } label: {
                    Text(project.isEmpty ? "Empty" : project)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(project.isEmpty ? Color(nsColor: .tertiaryLabelColor) : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(project.isEmpty ? "Needed before Hoot or an agent can work on it" : project)
            }
            Button("Choose…") {
                Task {
                    let result = await model.chooseProject()
                    if let chosen = result.project {
                        draft = chosen
                        problem = nil
                    } else if let message = result.problem {
                        problem = message
                    }
                }
            }
            .controlSize(.small)
            if let problem { Text(problem).font(.caption).foregroundStyle(TaskTone.input).lineLimit(1).help(problem) }
        }
        .font(.system(size: 13))
    }

    private func save() {
        guard editing else { return }
        editing = false
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != model.row.project else { return }
        Task {
            if let message = await model.setProject(value) {
                problem = message
                draft = model.row.project
            } else {
                problem = nil
            }
        }
    }
}

/// "Own workspace", then the workspace itself once there is one.
struct WorkspaceField: View {
    let model: TaskDetailModel
    @State private var on = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("Own workspace", isOn: Binding(get: { on }, set: { next in
                    on = next
                    problem = nil
                    Task {
                        if let message = await model.setUseWorkspace(next) {
                            on = !next
                            problem = message
                        }
                    }
                }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("The agent works in a separate copy of the project (a git worktree on its own branch), from its next start.")
                if let problem { Text(problem).font(.caption).foregroundStyle(TaskTone.input).lineLimit(1).help(problem) }
            }
            if model.showsWorkspace, let view = model.workspace { workspaceCell(view) }
        }
        .padding(.vertical, 8)
        .onAppear { on = model.row.useWorkspace }
        .onChange(of: model.row.useWorkspace) { _, value in on = value }
    }

    @ViewBuilder private func workspaceCell(_ view: TaskDetailModel.WorkspaceView) -> some View {
        if let w = view.workspace {
            let there = w.state != "removed"
            let below = model.workspaceNote ?? w.reason.map { (w.state != "kept", $0) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(w.branch).font(.caption.monospaced()).lineLimit(1).help("Branch \(w.branch) in \(w.repo)")
                    Text(w.state == "active" ? "Active" : w.state == "kept" ? "Kept" : "Removed")
                        .font(.caption).foregroundStyle(w.state == "kept" ? TaskTone.waiting : Color.secondary)
                    if there {
                        Button("Open folder") { model.openWorkspace() }.controlSize(.small)
                        Button(model.workspaceBusy ? "Removing…" : "Remove when clean") { model.removeWorkspace() }
                            .controlSize(.small)
                            .disabled(model.workspaceBusy)
                            .help("Removes the folder only if it has no uncommitted changes and nothing is running in it. The branch stays.")
                    }
                }
                Text(w.folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(w.folder)
                if let below {
                    Text(below.1).font(.caption).foregroundStyle(below.0 ? Color.secondary : TaskTone.waiting)
                }
            }
        } else {
            Text("None. \(view.refusal ?? "")").font(.caption).foregroundStyle(.secondary)
        }
    }
}
