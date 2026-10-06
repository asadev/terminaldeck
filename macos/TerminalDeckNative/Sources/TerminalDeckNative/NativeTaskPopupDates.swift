import SwiftUI
import TerminalDeckNativeCore

// The popup's Dates cell (src/renderer/crm-task/dates-field.tsx), its panel
// (timeline-field.tsx: Start / Due with times, quick dates, the month, the span)
// and the Recurring panel (routine-panel.tsx).

/// "Today", "Tomorrow", "Yesterday", "7 Oct" (· year when not this year).
func relativeDay(_ ymd: String, today: String = CrmTime.todayYmd()) -> String {
    guard TaskList.isYmd(ymd) else { return ymd }
    switch TaskList.ymdDiff(today, ymd) {
    case 0: return "Today"
    case 1: return "Tomorrow"
    case -1: return "Yesterday"
    default: return shortYmd(ymd)
    }
}

func shortYmd(_ ymd: String) -> String {
    let p = ymd.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3, (1...12).contains(p[1]) else { return ymd }
    let label = "\(p[2]) \(TaskList.monthShort[p[1] - 1])"
    return p[0] == Int(CrmTime.todayYmd().prefix(4)) ? label : "\(label) \(p[0])"
}

/// "7 Oct → 9 Oct", "Due 9 Oct", "From 7 Oct", or nil.
func summariseTimeline(_ start: String, _ due: String) -> String? {
    if !start.isEmpty && !due.isEmpty { return "\(shortYmd(start)) → \(shortYmd(due))" }
    if !due.isEmpty { return "Due \(shortYmd(due))" }
    if !start.isEmpty { return "From \(shortYmd(start))" }
    return nil
}

struct TaskDatesField: View {
    let model: TaskDetailModel
    @State private var open = false
    @State private var hovering = false
    @State private var preview: RoutineRule?

    private var rule: RoutineRule? {
        Routine.normalize(model.routine?.rule, legacy: nil)
    }

    var body: some View {
        let task = model.task
        let today = CrmTime.todayYmd()
        let nowHm = TaskList.hmOf(Date().timeIntervalSince1970 * 1000)
        let done = task.group == "Done"
        let dueTime = model.more?.dueTime, startTime = model.more?.startTime
        let overdue = !done && !task.dueDate.isEmpty
            && (task.dueDate < today || TaskList.isDueTimePassed(task.dueDate, dueTime, today: today, nowHm: nowHm))
        let startWord = task.startDate.isEmpty ? "" : relativeDay(task.startDate) + (startTime.map { ", \(CrmTime.hmLabel($0))" } ?? "")
        let dueWord = task.dueDate.isEmpty ? "" : relativeDay(task.dueDate) + (dueTime.map { ", \(CrmTime.hmLabel($0))" } ?? "")
        let summary = task.startDate.isEmpty && task.dueDate.isEmpty ? "none" : "\(startWord.isEmpty ? "Start" : startWord) → \(dueWord.isEmpty ? "Due" : dueWord)"
        ZStack(alignment: .trailing) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.caption)
                    Text(startWord.isEmpty ? "Start" : startWord).foregroundStyle(task.startDate.isEmpty ? Color.secondary : Color.primary)
                    Text("→").foregroundStyle(.tertiary)
                    Image(systemName: "calendar").font(.caption).foregroundStyle(overdue ? TaskTone.input : Color.secondary)
                    Text(dueWord.isEmpty ? "Due" : dueWord)
                        .fontWeight(overdue ? .medium : .regular)
                        .foregroundStyle(overdue ? TaskTone.input : task.dueDate.isEmpty ? Color.secondary : Color.primary)
                    if task.recurrence != nil { Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary) }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .padding(.trailing, 28)
                .frame(minWidth: 220, minHeight: 32, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(hovering ? 0.2 : 0.12)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change start and due dates")
            .accessibilityLabel("Dates: \(summary)\(task.recurrence.map { ", repeats \($0)" } ?? "")")
            if (!task.startDate.isEmpty || !task.dueDate.isEmpty) && hovering {
                Button { model.saveDates(start: "", due: "") } label: { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
                    .help("Clear dates")
                    .accessibilityLabel("Clear dates")
            }
        }
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            TimelinePanel(model: model, preview: $preview, onPicked: { open = false })
        }
    }
}

/// The one shared panel: Start and Due (each with an optional time), what repeats,
/// quick dates or the Recurring panel, and the month.
struct TimelinePanel: View {
    let model: TaskDetailModel
    @Binding var preview: RoutineRule?
    let onPicked: () -> Void
    @State private var active: String = "due"
    @State private var recurring = false
    @State private var cursor: (year: Int, month: Int) = (2026, 1)
    @State private var seeded = false

    private var rule: RoutineRule? { Routine.normalize(model.routine?.rule, legacy: nil) }

    var body: some View {
        let task = model.task
        let today = CrmTime.todayYmd()
        let routineText = rule.map(Routine.summary)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                DateBox(label: "Start date", value: task.startDate, active: active == "start", time: model.more?.startTime,
                        canTime: model.more != nil, onClick: { active = "start" }, onClear: { emit(start: "", due: task.dueDate) },
                        onTime: { model.setTime("start", $0) })
                DateBox(label: "Due date", value: task.dueDate, active: active == "due", time: model.more?.dueTime,
                        canTime: model.more != nil, onClick: { active = "due" }, onClear: { emit(start: task.startDate, due: "") },
                        onTime: { model.setTime("due", $0) })
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 8)
            if routineText != nil || task.recurrence != nil {
                Label(routineText.map { "Repeats: \($0)" } ?? "Repeats \(TaskRecurrence.short(task.recurrence ?? "").lowercased())",
                      systemImage: "repeat")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            if let note = moveNote {
                Text(note).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 4)
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                Group {
                    if recurring {
                        RoutinePanel(model: model, from: task.dueDate.isEmpty ? today : task.dueDate, preview: $preview) {
                            recurring = false
                        }
                        .frame(width: 332)
                    } else {
                        presets(task, routineText: routineText).frame(width: 216)
                    }
                }
                Divider()
                month(task, today: today).frame(width: 7 * 36 + 24)
            }
            if !task.startDate.isEmpty, !task.dueDate.isEmpty {
                Divider()
                let span = TaskList.ymdDiff(task.startDate, task.dueDate) + 1
                Text("\(span) day\(span == 1 ? "" : "s") from start to due")
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            let seed = !task.dueDate.isEmpty ? task.dueDate : !task.startDate.isEmpty ? task.startDate : today
            let p = seed.split(separator: "-").compactMap { Int($0) }
            cursor = (p[0], p[1] - 1)
        }
    }

    private var moveNote: String? {
        if let stuck = model.routine?.stuck { return stuck }
        let task = model.task
        return Routine.dateMoveNote(rule, status: task.group, due: task.dueDate.isEmpty ? nil : task.dueDate,
                                    anchor: model.routine?.anchor, occurrence: model.routine?.occurrence,
                                    today: CrmTime.todayYmd(), datesSoFar: model.routine?.datesSoFar ?? 0,
                                    scheduleNext: model.routine?.next.first)
    }

    /// Start after due swaps them, as the page does.
    private func emit(start: String, due: String) {
        var s = start, d = due
        if !s.isEmpty && !d.isEmpty && s > d { swap(&s, &d) }
        model.saveDates(start: s, due: d)
    }

    private func pick(_ day: String) {
        let task = model.task
        if active == "start" {
            emit(start: task.startDate == day ? "" : day, due: task.dueDate)
            active = "due"
        } else {
            emit(start: task.startDate, due: task.dueDate == day ? "" : day)
        }
    }

    private func presets(_ task: CrmTask, routineText: String?) -> some View {
        let today = CrmTime.todayYmd()
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        func weekdayOf(_ d: String) -> String { weekdays[TaskList.ymdWeekday(d)] }
        let nextMonday: String = {
            let delta = (1 - TaskList.ymdWeekday(today) + 7) % 7
            return TaskList.ymdAddDays(today, delta == 0 ? 7 : delta)
        }()
        let weekend = Routine.nextDayOff(today)
        let list: [(String, String, String)] = [
            ("Today", today, weekdayOf(today)),
            ("Tomorrow", TaskList.ymdAddDays(today, 1), weekdayOf(TaskList.ymdAddDays(today, 1))),
            ("This weekend", weekend, weekdayOf(weekend)),
            ("Next week", nextMonday, weekdayOf(nextMonday)),
            ("Next weekend", TaskList.ymdAddDays(weekend, 7), shortYmd(TaskList.ymdAddDays(weekend, 7))),
            ("2 weeks", TaskList.ymdAddDays(today, 14), shortYmd(TaskList.ymdAddDays(today, 14))),
            ("4 weeks", TaskList.ymdAddDays(today, 28), shortYmd(TaskList.ymdAddDays(today, 28))),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(list, id: \.0) { label, value, hint in
                let on = task.dueDate == value
                Button {
                    emit(start: task.startDate, due: on ? "" : value)
                    if !on { onPicked() }
                } label: {
                    HStack {
                        Text(label)
                        Spacer()
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(on ? Color.secondary.opacity(0.15) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Quick due dates")
            Divider().padding(.horizontal, 12).padding(.vertical, 4)
            Button { recurring = true } label: {
                HStack(spacing: 8) {
                    if routineText != nil || task.recurrence != nil { Image(systemName: "repeat").font(.caption) }
                    Text(routineText ?? (task.recurrence.map { "Repeats \(TaskRecurrence.short($0).lowercased())" } ?? "Set Recurring"))
                        .lineLimit(1)
                        .help(routineText ?? "")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func month(_ task: CrmTask, today: String) -> some View {
        let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                     "November", "December"]
        let first = String(format: "%04d-%02d-01", cursor.year, cursor.month + 1)
        let start = TaskList.ymdAddDays(first, -TaskList.ymdWeekday(first))
        let cells = (0..<42).map { TaskList.ymdAddDays(start, $0) }
        let highlight: [String] = {
            let r = preview ?? (Routine.isActive(rule) ? rule : nil)
            guard let r else { return [] }
            return Routine.upcoming(task.dueDate.isEmpty ? today : task.dueDate, r, count: 3)
        }()
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("\(names[cursor.month]) \(String(cursor.year))").font(.callout.weight(.medium))
                Spacer()
                Button("Today") {
                    let p = today.split(separator: "-").compactMap { Int($0) }
                    cursor = (p[0], p[1] - 1)
                }
                .buttonStyle(.plain).font(.caption)
                Button { cursor = cursor.month == 0 ? (cursor.year - 1, 11) : (cursor.year, cursor.month - 1) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain).accessibilityLabel("Previous month")
                Button { cursor = cursor.month == 11 ? (cursor.year + 1, 0) : (cursor.year, cursor.month + 1) } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain).accessibilityLabel("Next month")
            }
            .frame(height: 28)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 0), count: 7), spacing: 2) {
                ForEach(["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"], id: \.self) {
                    Text($0).font(.caption2).foregroundStyle(.tertiary).padding(.vertical, 4)
                }
                ForEach(cells, id: \.self) { day in
                    let other = Int(day.split(separator: "-")[1]) != cursor.month + 1
                    let picked = day == task.startDate || day == task.dueDate
                    let inRange = !task.startDate.isEmpty && !task.dueDate.isEmpty && day > task.startDate && day < task.dueDate
                    Button { pick(day) } label: {
                        Text("\(Int(day.split(separator: "-")[2]) ?? 0)")
                            .font(.caption.weight(picked || day == today ? .semibold : .regular))
                            .frame(width: 32, height: 32)
                            .foregroundStyle(picked || day == today ? Color.white : other ? Color(nsColor: .tertiaryLabelColor) : .primary)
                            .background(
                                Group {
                                    if picked { Circle().fill(Color.primary) }
                                    else if day == today { Circle().fill(Color(red: 0.94, green: 0.27, blue: 0.37)) }
                                    else if highlight.contains(day) { RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.18)) }
                                    else if inRange { Circle().fill(Color.secondary.opacity(0.15)) }
                                }
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(day)
                    .accessibilityAddTraits(picked ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One of the two date boxes: the day (click to pick it), ×, and its time.
private struct DateBox: View {
    let label: String
    let value: String
    let active: Bool
    let time: String?
    let canTime: Bool
    let onClick: () -> Void
    let onClear: () -> Void
    let onTime: (String?) -> Void
    @State private var editingTime = false
    @State private var draft = Date()

    private func display(_ ymd: String) -> String {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return ymd }
        return String(format: "%02d/%02d/%04d", p[2], p[1], p[0])
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onClick) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.caption).foregroundStyle(.secondary)
                    Text(value.isEmpty ? label : display(value)).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(Color.secondary.opacity(0.12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(value.isEmpty ? label : "\(label): \(display(value))")
            .accessibilityAddTraits(active ? .isSelected : [])
            if !value.isEmpty {
                Button(action: onClear) { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 32)
                    .background(Color.secondary.opacity(0.12))
                    .accessibilityLabel("Clear \(label.lowercased())")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.secondary.opacity(0.5) : .clear, lineWidth: 2))
        if !value.isEmpty && canTime {
            if editingTime || time != nil {
                HStack(spacing: 2) {
                    DatePicker("\(label) time", selection: $draft, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(width: 92)
                        .onAppear { draft = Self.date(time) }
                        .onChange(of: draft) { _, new in
                            let hm = TaskList.hmOf(new.timeIntervalSince1970 * 1000)
                            if hm != time { onTime(hm) }
                        }
                    if time != nil {
                        Button {
                            editingTime = false
                            onTime(nil)
                        } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove time")
                            .accessibilityLabel("Remove \(label.lowercased()) time")
                    }
                }
            } else {
                Button("Add time") { editingTime = true }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.purple)
                    .padding(.leading, 6)
            }
        }
    }

    static func date(_ hm: String?) -> Date {
        let p = (hm ?? "09:00").split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }
}

// MARK: - Recurring (routine-panel.tsx)

struct RoutinePanel: View {
    let model: TaskDetailModel
    let from: String
    @Binding var preview: RoutineRule?
    let onBack: () -> Void
    @State private var r: RoutineRule
    @State private var perTouched: Bool
    @State private var updOn: Bool

    private var rule: RoutineRule? { Routine.normalize(model.routine?.rule, legacy: nil) }

    /// A new routine starts weekly, coming back (not copied), not synced to the due date.
    static var newRoutine: RoutineRule {
        var r = RoutineRule()
        r.frequency = "weekly"
        r.createNew = false
        r.syncToDue = false
        return r
    }

    init(model: TaskDetailModel, from: String, preview: Binding<RoutineRule?>, onBack: @escaping () -> Void) {
        self.model = model
        self.from = from
        _preview = preview
        self.onBack = onBack
        let existing = Routine.normalize(model.routine?.rule, legacy: nil)
        _r = State(initialValue: existing ?? Self.newRoutine)
        _perTouched = State(initialValue: existing != nil)
        _updOn = State(initialValue: existing.map { $0.updateStatusTo != "To-Do" } ?? false)
    }

    private func set(_ change: (inout RoutineRule) -> Void) {
        change(&r)
        preview = r
    }

    private var ready: Bool { model.routine != nil && model.routine?.historyError == nil }
    private var unit: String {
        if r.frequency == "custom" { return r.unit }
        switch r.frequency {
        case "weekly": return "week"
        case "monthly": return "month"
        case "yearly": return "year"
        default: return "day"
        }
    }

    var body: some View {
        let today = CrmTime.todayYmd()
        let untilDefault = Routine.defaultUntil(due: from, today: today)
        let refusal = Routine.refusal(r, today: today)
        let stuck = model.routine?.stuck
        let next = Routine.upcoming(from, r, count: 3)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recurring").font(.callout.weight(.medium))
                        Spacer()
                        if let rule, model.routine?.canEdit == true {
                            Menu {
                                if rule.stoppedAt == nil {
                                    Button(rule.pausedAt != nil ? "Resume" : "Pause") { model.pauseRoutine(rule.pausedAt == nil) }
                                    Button("Stop recurring", role: .destructive) {
                                        model.stopRoutine()
                                        preview = nil
                                        onBack()
                                    }
                                }
                            } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .accessibilityLabel("Recurring options")
                        }
                    }
                    Picker("Frequency", selection: Binding(get: { r.frequency }, set: { f in
                        set { x in
                            x.frequency = f
                            x.interval = 1
                            x.unit = f == "custom" ? x.unit : "day"
                            if !(f == "weekly" || f == "custom") { x.weekdays = [] }
                            if !(f == "monthly" || f == "custom") { x.monthly = nil }
                        }
                    })) {
                        ForEach([("daily", "Daily"), ("weekly", "Weekly"), ("monthly", "Monthly"), ("yearly", "Yearly"),
                                 ("days_after", "Days after"), ("custom", "Custom")], id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    TasksFlow(spacing: 4, lineSpacing: 4) {
                        presetChip("Every working day") { $0.frequency = "daily"; $0.interval = 1; $0.skipWeekends = true; $0.weekdays = []; $0.monthly = nil }
                        presetChip("Mon / Wed / Fri") { $0.frequency = "weekly"; $0.interval = 1; $0.weekdays = [1, 3, 5]; $0.skipWeekends = false; $0.monthly = nil }
                        presetChip("Every 2 weeks") { $0.frequency = "weekly"; $0.interval = 2; $0.weekdays = []; $0.monthly = nil }
                        presetChip("Last Friday") { $0.frequency = "monthly"; $0.interval = 1; $0.weekdays = []; $0.monthly = .nth(-1, weekday: 5) }
                        presetChip("1st of the month") { $0.frequency = "monthly"; $0.interval = 1; $0.weekdays = []; $0.monthly = .day(1) }
                    }
                    interval
                    trigger
                    ends(untilDefault)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("For a team").font(.caption2.weight(.medium)).foregroundStyle(.tertiary).textCase(.uppercase)
                        check("One copy per assignee", hint: "Each person gets their own to mark done", on: r.perAssignee,
                              disabled: !ready || !r.createNew) { v in
                            perTouched = true
                            set { $0.perAssignee = v }
                        }
                        if r.trigger == "schedule" {
                            Text("When the next one arrives, the previous open one is").font(.system(size: 13))
                            Picker("Previous open one", selection: Binding(get: { r.missedPolicy }, set: { v in set { $0.missedPolicy = v } })) {
                                Text("left open (overdue)").tag("leave_open")
                                Text("marked Missed").tag("mark_missed")
                            }
                            .labelsHidden()
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Routine.summary(Routine.running(r))).font(.caption.weight(.medium))
                        if let stuck {
                            HStack(spacing: 6) {
                                Text(stuck).foregroundStyle(TaskTone.waiting)
                                if model.routine?.canRestart == true {
                                    Button("Restart") {
                                        model.restartRoutine()
                                        preview = nil
                                        onBack()
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                            .font(.caption)
                        }
                        if !next.isEmpty && !(stuck != nil && (model.routine?.next.isEmpty ?? true)) {
                            Text("Next: \(next.map(Routine.shortDay).joined(separator: " · "))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                    if rule?.stoppedAt != nil {
                        Text("This routine was stopped. Save starts it again; its history is kept.").font(.caption2).foregroundStyle(.secondary)
                    } else if rule?.pausedAt != nil {
                        Text("Paused. Save resumes it as shown.").font(.caption2).foregroundStyle(TaskTone.waiting)
                    }
                    if !ready, let reason = model.routine?.historyError ?? model.routineError {
                        Text("On a schedule, After N times and One copy per assignee aren't available yet.")
                            .font(.caption2).foregroundStyle(TaskTone.waiting).help(reason)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 420)
            Divider()
            VStack(alignment: .trailing, spacing: 6) {
                if let refusal {
                    Text(refusal).font(.caption2).foregroundStyle(TaskTone.input).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("Cancel") {
                        preview = nil
                        onBack()
                    }
                    .buttonStyle(.borderless)
                    Button(model.routineBusy ? "Saving…" : "Save") {
                        model.saveRoutine(Routine.serialize(r), legacy: Routine.legacy(r))
                        preview = nil
                        onBack()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.routineBusy || refusal != nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func presetChip(_ label: String, _ patch: @escaping (inout RoutineRule) -> Void) -> some View {
        Button(label) { set(patch) }
            .buttonStyle(.plain)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private func number(_ value: Int, range: ClosedRange<Int>, label: String, set apply: @escaping (Int) -> Void) -> some View {
        TextField(label, value: Binding(get: { value }, set: { apply(min(range.upperBound, max(range.lowerBound, $0))) }),
                  format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var interval: some View {
        let n = r.interval
        let units: [(String, String, String)] = [("day", "day", "days"), ("week", "week", "weeks"), ("month", "month", "months"), ("year", "year", "years")]
        VStack(alignment: .leading, spacing: 6) {
            if r.frequency == "days_after" {
                HStack(spacing: 8) {
                    number(n, range: 1...365, label: "Interval") { v in set { $0.interval = v } }
                    Text("\(n == 1 ? "day" : "days") after it is done")
                }
            } else {
                HStack(spacing: 8) {
                    Text("Every")
                    number(n, range: 1...365, label: "Interval") { v in set { $0.interval = v } }
                    if r.frequency == "custom" {
                        Picker("Unit", selection: Binding(get: { r.unit }, set: { v in set { $0.unit = v } })) {
                            ForEach(units, id: \.0) { Text(n == 1 ? $0.1 : $0.2).tag($0.0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        Text(units.first { $0.0 == unit }.map { n == 1 ? $0.1 : $0.2 } ?? "")
                    }
                }
            }
            if unit == "week" && r.frequency != "days_after" {
                let letters = ["S", "M", "T", "W", "T", "F", "S"]
                let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { d in
                        let on = r.weekdays.contains(d)
                        Button(letters[d]) {
                            set { x in x.weekdays = on ? x.weekdays.filter { $0 != d } : (x.weekdays + [d]).sorted() }
                        }
                        .buttonStyle(.plain)
                        .font(.caption2.weight(.medium))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(on ? Color.white : .secondary)
                        .background(Circle().fill(on ? Color.purple : Color.clear))
                        .overlay(Circle().stroke(on ? Color.purple : Color(nsColor: .separatorColor)))
                        .help(names[d])
                        .accessibilityLabel(names[d])
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("On these days")
            }
            if unit == "month" && r.frequency != "days_after" { monthly }
        }
        .font(.system(size: 13))
    }

    @ViewBuilder private var monthly: some View {
        let anchorDay = Int(from.suffix(2)) ?? 1
        let isNth: Bool = { if case .nth = r.monthly { return true } else { return false } }()
        let day: Int = { if case .day(let d)? = r.monthly { return d } else { return anchorDay } }()
        let nth: Int = { if case .nth(let n, _)? = r.monthly { return n } else { return 1 } }()
        let wd: Int = { if case .nth(_, let w)? = r.monthly { return w } else { return Routine.weekday(from) } }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isNth ? "circle" : "largecircle.fill.circle").onTapGesture { set { $0.monthly = .day(day) } }
                Text("On day")
                number(day, range: 1...31, label: "Day of the month") { v in set { $0.monthly = .day(v) } }
            }
            HStack(spacing: 8) {
                Image(systemName: isNth ? "largecircle.fill.circle" : "circle")
                    .onTapGesture { set { $0.monthly = .nth(min(4, Int((Double(anchorDay) / 7).rounded(.up))), weekday: Routine.weekday(from)) } }
                Text("On the")
                Picker("Which week", selection: Binding(get: { nth }, set: { v in set { $0.monthly = .nth(v, weekday: wd) } })) {
                    ForEach([(1, "first"), (2, "second"), (3, "third"), (4, "fourth"), (-1, "last")], id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().fixedSize()
                Picker("Which weekday", selection: Binding(get: { wd }, set: { v in set { $0.monthly = .nth(nth, weekday: v) } })) {
                    ForEach(0..<7, id: \.self) { Text(["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][$0]).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Which day of the month")
    }

    @ViewBuilder private var trigger: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Trigger", selection: Binding(get: { r.trigger }, set: { v in set { $0.trigger = v } })) {
                Text("On status change").tag("status")
                Text("On a schedule\(ready ? "" : " (not available yet)")").tag("schedule").disabled(!ready)
            }
            .labelsHidden()
            if r.trigger == "status" {
                HStack(spacing: 8) {
                    Text("When the status becomes")
                    Picker("Trigger status", selection: Binding(get: { r.triggerStatus }, set: { v in set { $0.triggerStatus = v } })) {
                        ForEach(Routine.statuses, id: \.self) { Text(CrmText.statusWord($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            } else {
                HStack(spacing: 8) {
                    Text("Created at")
                    DatePicker("Time of day", selection: Binding(get: { DateBoxTime.date(r.timeOfDay) }, set: { d in
                        set { $0.timeOfDay = TaskList.hmOf(d.timeIntervalSince1970 * 1000) }
                    }), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    Text("local time — whether or not the last one was finished")
                }
            }
        }
        .font(.system(size: 13))
    }

    @ViewBuilder private func ends(_ untilDefault: String) -> some View {
        let isNever: Bool = { if case .never = r.ends { return true } else { return false } }()
        VStack(alignment: .leading, spacing: 6) {
            check("Recur forever", on: isNever) { v in set { $0.ends = v ? .never : .until(untilDefault) } }
            if !isNever {
                VStack(alignment: .leading, spacing: 6) {
                    let until: String? = { if case .until(let u) = r.ends { return u } else { return nil } }()
                    let count: Int? = { if case .count(let c) = r.ends { return c } else { return nil } }()
                    HStack(spacing: 8) {
                        Image(systemName: until != nil ? "largecircle.fill.circle" : "circle").onTapGesture { set { $0.ends = .until(untilDefault) } }
                        Text("Until")
                        DatePicker("Recur until", selection: Binding(get: { DayPicker.date(until ?? untilDefault) ?? Date() }, set: { d in
                            set { $0.ends = .until(TaskList.ymdOf(d.timeIntervalSince1970 * 1000)) }
                        }), displayedComponents: .date)
                        .labelsHidden()
                        .disabled(until == nil)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: count != nil ? "largecircle.fill.circle" : "circle")
                            .onTapGesture { if ready { set { $0.ends = .count(10) } } }
                        Text("After")
                        number(count ?? 10, range: 1...1000, label: "Number of times") { v in set { $0.ends = .count(v) } }
                            .disabled(!ready || count == nil)
                        Text("times")
                    }
                    .opacity(ready ? 1 : 0.5)
                }
                .padding(.leading, 24)
            }
            check("Create new task", on: r.createNew) { v in
                set { x in
                    x.createNew = v
                    x.perAssignee = v && ready ? (perTouched ? x.perAssignee : (model.routine?.peopleCount ?? 1) > 1) : false
                }
            }
            HStack(spacing: 8) {
                check("Update status to", on: updOn) { v in
                    updOn = v
                    if !v { set { $0.updateStatusTo = "To-Do" } }
                }
                Picker("Update status to", selection: Binding(get: { r.updateStatusTo }, set: { v in set { $0.updateStatusTo = v } })) {
                    ForEach(["To-Do", "Working on it", "In Progress", "Stuck"], id: \.self) { Text(CrmText.statusWord($0)).tag($0) }
                }
                .labelsHidden().fixedSize().disabled(!updOn)
            }
            check("Sync recurrence to due date", on: r.syncToDue, disabled: r.trigger == "schedule" || r.frequency == "days_after") { v in
                set { $0.syncToDue = v }
            }
            check(Routine.skipDaysOffLabel, on: r.skipWeekends) { v in set { $0.skipWeekends = v } }
        }
        .font(.system(size: 13))
    }

    private func check(_ label: String, hint: String? = nil, on: Bool, disabled: Bool = false, _ change: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: change)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                if let hint { Text(hint).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(disabled)
    }
}

enum DateBoxTime {
    static func date(_ hm: String) -> Date {
        let p = hm.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 8, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }
}
