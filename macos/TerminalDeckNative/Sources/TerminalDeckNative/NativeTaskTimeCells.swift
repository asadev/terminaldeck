import AppKit
import SwiftUI
import TerminalDeckNativeCore

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
struct TimePopover: View {
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
                            .background(Circle().fill(running != nil ? Color(red: 0.96, green: 0.25, blue: 0.37) : TaskTone.accent))
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
                .tint(TaskTone.accent)
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
                                if e.billable { Text("$").font(.caption).foregroundStyle(TaskTone.accent) }
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
