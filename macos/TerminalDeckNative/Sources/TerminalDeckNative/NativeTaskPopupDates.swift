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

// MARK: - Main

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
            NativeSessionButton { open.toggle() } label: {
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
                NativeSessionButton { model.saveDates(start: "", due: "") } label: { Image(systemName: "xmark").font(.caption2).frame(width: 28, height: 28).contentShape(Rectangle()) }
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
            cursor = Self.monthOf(seed) ?? Self.monthOf(today) ?? cursor
        }
    }
    /// The calendar page a date opens on; nil for a date in another shape or an impossible month (a connected
    /// system's "16/10/2026", a bare year, month 13), so the panel opens on this month instead of crashing.
    static func monthOf(_ ymd: String) -> (year: Int, month: Int)? {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count >= 2, (1...12).contains(p[1]) else { return nil }
        return (p[0], p[1] - 1)
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
                NativeSessionButton {
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
            NativeSessionButton { recurring = true } label: {
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
                NativeSessionButton("Today") { cursor = Self.monthOf(today) ?? cursor }
                .buttonStyle(.plain).font(.caption)
                NativeSessionButton { cursor = cursor.month == 0 ? (cursor.year - 1, 11) : (cursor.year, cursor.month - 1) } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain).accessibilityLabel("Previous month")
                NativeSessionButton { cursor = cursor.month == 11 ? (cursor.year + 1, 0) : (cursor.year, cursor.month + 1) } label: {
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
                    NativeSessionButton { pick(day) } label: {
                        Text("\(Int(day.split(separator: "-")[2]) ?? 0)")
                            .font(.caption.weight(picked || day == today ? .semibold : .regular))
                            .frame(width: 32, height: 32)
                            .foregroundStyle(picked || day == today ? Color.white : other ? Color(nsColor: .tertiaryLabelColor) : .primary)
                            .background(
                                Group {
                                    if picked { Circle().fill(Color.primary) }
                                    else if day == today { Circle().fill(Color(red: 0.94, green: 0.27, blue: 0.37)) }
                                    else if highlight.contains(day) { RoundedRectangle(cornerRadius: 6).fill(TaskTone.accent.opacity(0.18)) }
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
struct DateBox: View {
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
            NativeSessionButton(action: onClick) {
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
                NativeSessionButton(action: onClear) { Image(systemName: "xmark").font(.caption2).frame(width: 28, height: 28).contentShape(Rectangle()) }
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
                    NativeSessionDatePicker("\(label) time", selection: $draft, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(width: 92)
                        .onAppear { draft = Self.date(time) }
                        .onChange(of: draft) { _, new in
                            let hm = TaskList.hmOf(new.timeIntervalSince1970 * 1000)
                            if hm != time { onTime(hm) }
                        }
                    if time != nil {
                        NativeSessionButton {
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
                NativeSessionButton("Add time") { editingTime = true }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(TaskTone.accent)
                    .padding(.leading, 6)
            }
        }
    }

    static func date(_ hm: String?) -> Date {
        let p = (hm ?? "09:00").split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
    }
}
