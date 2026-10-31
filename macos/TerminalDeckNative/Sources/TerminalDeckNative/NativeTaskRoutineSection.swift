import AppKit
import SwiftUI
import TerminalDeckNativeCore

// MARK: - The routine

struct RoutineBlock: View {
    let model: TaskDetailModel
    let routine: RoutineView
    let rule: RoutineRule
    var onOpenRoot: (() -> Void)?
    @State private var all = false
    @State private var arming = false

    private struct Row: Identifiable {
        let id: String, occurrenceDate: String, who: String?, completedBy: String?, completedAt: String?, state: Routine.HistoryState
    }

    var body: some View {
        let today = CrmTime.todayYmd()
        let state = rule.stoppedAt != nil ? "Stopped" : rule.pausedAt != nil ? "Paused" : "Running"
        let rows: [Row] = (routine.history ?? []).compactMap { h in
            guard let o = h.object, let id = o["id"]?.string, let day = o["occurrenceDate"]?.string else { return nil }
            return Row(id: id, occurrenceDate: day, who: o["who"]?.string, completedBy: o["completedBy"]?.string,
                       completedAt: o["completedAt"]?.string,
                       state: Routine.historyState(status: o["status"]?.string ?? "open", completedAt: o["completedAt"]?.string,
                                                   dueDate: o["dueDate"]?.string, occurrenceDate: day, today: today))
        }
        let monthAgo = TaskList.ymdAddDays(today, -30)
        let recent = rows.filter { $0.occurrenceDate >= monthAgo && $0.occurrenceDate <= today }
        let counts = Dictionary(grouping: recent, by: \.state).mapValues(\.count)
        let visible = all ? rows : Array(rows.prefix(14))
        let editable = routine.canEdit && rule.stoppedAt == nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "repeat").foregroundStyle(TaskTone.accent)
                Text("Routine").font(.callout.weight(.medium))
                Text(Routine.summary(Routine.running(rule))).font(.callout).lineLimit(2)
                Text(state).font(.caption2.weight(.medium))
                    .foregroundStyle(state == "Running" ? TaskTone.completed : state == "Paused" ? TaskTone.waiting : Color.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill((state == "Running" ? TaskTone.completed : state == "Paused" ? TaskTone.waiting : Color.secondary).opacity(0.12)))
                if state == "Running", let next = routine.next.first {
                    Text("next \(Routine.shortDay(next))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if editable {
                    Button {
                        model.pauseRoutine(rule.pausedAt == nil)
                    } label: { Label(rule.pausedAt != nil ? "Resume" : "Pause", systemImage: rule.pausedAt != nil ? "play.fill" : "pause.fill") }
                        .controlSize(.small)
                    if !arming {
                        Button { arming = true } label: { Label("Stop recurring", systemImage: "stop.fill").foregroundStyle(TaskTone.input) }
                            .controlSize(.small)
                    } else {
                        HStack(spacing: 8) {
                            Button("Stop recurring?") {
                                arming = false
                                model.stopRoutine()
                            }
                            .buttonStyle(.borderedProminent).tint(TaskTone.input).controlSize(.small)
                            Button("Cancel") { arming = false }.controlSize(.small)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Confirm stop recurring")
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if !routine.isRoot {
                HStack(spacing: 4) {
                    Text("One occurrence of the routine on")
                    if let onOpenRoot {
                        Button(routine.rootTitle, action: onOpenRoot).buttonStyle(.link)
                    } else {
                        Text(routine.rootTitle).fontWeight(.medium)
                    }
                    Text("— changes to the routine are made there.")
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
            if let err = routine.lastError {
                Text("\(err.message) · \(localStamp(err.at))").font(.caption).foregroundStyle(TaskTone.waiting)
                    .padding(.horizontal, 12).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TaskTone.waiting.opacity(0.1))
                Divider()
            }
            if let error = routine.historyError {
                Text("History unavailable: \(error)").font(.caption).foregroundStyle(TaskTone.waiting).padding(12)
            } else if rows.isEmpty {
                Text("No occurrences yet\(routine.next.first.map { " — the first is \(Routine.shortDay($0))" } ?? "").")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            } else {
                Text("Last 30 days: \(counts[.onTime] ?? 0) on time · \(counts[.late] ?? 0) late · \(counts[.missed] ?? 0) missed\((counts[.overdue] ?? 0) > 0 ? " · \(counts[.overdue] ?? 0) overdue" : "")")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 8)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Date"); Text("Who"); Text("Status")
                    }
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(visible) { r in
                        let who = r.who.flatMap { id in model.team.first { $0.id == id } }
                        let by = r.completedBy.flatMap { b in b != r.who ? model.team.first { $0.id == b } : nil }
                        GridRow {
                            Text(Routine.shortDay(r.occurrenceDate))
                            if let who {
                                HStack(spacing: 6) { PersonAvatar(person: who); Text(who.name) }
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                            }
                            HStack(spacing: 6) {
                                Text(r.state.label).font(.caption2.weight(.medium))
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(Capsule().fill(historyTone(r.state).opacity(0.14)))
                                    .foregroundStyle(historyTone(r.state))
                                if (r.state == .onTime || r.state == .late), let at = r.completedAt, let date = CrmTime.date(at) {
                                    Text("\(r.state == .late ? "\(Routine.shortDay(CrmTime.todayYmd(date))) " : "")\(CrmTime.clock(date))\(by.map { " by \($0.name)" } ?? "")")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.system(size: 13))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .accessibilityLabel("Routine history")
                if rows.count > 14 {
                    Button(all ? "Show fewer" : "Show all \(rows.count)") { all.toggle() }
                        .buttonStyle(.link).font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Routine")
    }

    private func historyTone(_ s: Routine.HistoryState) -> Color {
        switch s {
        case .onTime: TaskTone.completed
        case .late: TaskTone.waiting
        case .missed, .overdue: TaskTone.input
        case .open, .skipped: Color.secondary
        }
    }
}

/// "7 Oct 2026, 3:05 pm".
func localStamp(_ iso: String) -> String {
    guard let date = CrmTime.date(iso) else { return "" }
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return "\(c.day ?? 1) \(TaskList.monthShort[(c.month ?? 1) - 1]) \(c.year ?? 1970), \(CrmTime.clock(date))"
}
