import SwiftUI
import TerminalDeckNativeCore

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
                        .background(Circle().fill(on ? TaskTone.accent : Color.clear))
                        .overlay(Circle().stroke(on ? TaskTone.accent : Color(nsColor: .separatorColor)))
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
                Button { set { $0.monthly = .day(day) } } label: {
                    Label("On day", systemImage: isNth ? "circle" : "largecircle.fill.circle")
                        .frame(minHeight: 28).contentShape(Rectangle())
                }.buttonStyle(.plain)
                number(day, range: 1...31, label: "Day of the month") { v in set { $0.monthly = .day(v) } }
            }
            HStack(spacing: 8) {
                Button { set { $0.monthly = .nth(min(4, Int((Double(anchorDay) / 7).rounded(.up))), weekday: Routine.weekday(from)) } } label: {
                    Label("On the", systemImage: isNth ? "largecircle.fill.circle" : "circle")
                        .frame(minHeight: 28).contentShape(Rectangle())
                }.buttonStyle(.plain)
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
                        Button { set { $0.ends = .until(untilDefault) } } label: {
                            Label("Until", systemImage: until != nil ? "largecircle.fill.circle" : "circle")
                                .frame(minHeight: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        DatePicker("Recur until", selection: Binding(get: { DayPicker.date(until ?? untilDefault) ?? Date() }, set: { d in
                            set { $0.ends = .until(TaskList.ymdOf(d.timeIntervalSince1970 * 1000)) }
                        }), displayedComponents: .date)
                        .labelsHidden()
                        .disabled(until == nil)
                    }
                    HStack(spacing: 8) {
                        Button { set { $0.ends = .count(10) } } label: {
                            Label("After", systemImage: count != nil ? "largecircle.fill.circle" : "circle")
                                .frame(minHeight: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!ready)
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
        Toggle(isOn: Binding(get: { on }, set: { change($0) })) {
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
