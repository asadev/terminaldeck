import AppKit
import SwiftUI
import TerminalDeckNativeCore

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

struct PropertyLabelStyle: LabelStyle {
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
                        HStack(spacing: 5) {
                            Circle().fill(CrmColor.statusSolid(value)).frame(width: 6, height: 6)
                            Text(CrmText.statusWord(value))
                        }
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
                            if id == value { Image(systemName: "checkmark").font(.caption).foregroundStyle(TaskTone.accent) }
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
