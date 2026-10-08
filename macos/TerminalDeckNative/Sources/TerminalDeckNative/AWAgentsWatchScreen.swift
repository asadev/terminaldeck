import SwiftUI
import TerminalDeckNativeCore

struct AWAgentsWatchScreen: View {
    @State private var model: AWAgentsWatchModel
    init(sourceEvents: [String]? = nil) {
        _model = State(initialValue: sourceEvents.map { AWAgentsWatchModel(sourceEvents: $0) } ?? AWAgentsWatchModel())
    }
    init(model: AWAgentsWatchModel) { _model = State(initialValue: model) }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                header
                if let error = model.error {
                    HStack { Text(error).foregroundStyle(.secondary); Button("Try again") { model.refresh() } }
                }
                if !model.notices.isEmpty {
                    Text(model.notices.joined(separator: " ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if geometry.size.width >= 760 {
                    HStack(spacing: 16) {
                        roster.frame(width: 280)
                        conversation.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 12) {
                        roster.frame(height: min(220, geometry.size.height * 0.35))
                        conversation.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }.padding(16)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.search) { _, _ in model.refresh() }
        .onChange(of: model.stateFilter) { _, _ in model.refresh() }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Agents at work", systemImage: "person.2").font(.title3.weight(.semibold))
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh agents").accessibilityLabel("Refresh agents")
            }
            HStack(spacing: 8) {
                count("All", state: nil)
                count("Working", state: "working")
                count("Waiting", state: "waiting")
                Spacer(minLength: 0)
            }
            TextField("Find an agent, project or machine", text: $model.search)
                .textFieldStyle(.roundedBorder)
        }
    }
    private func count(_ label: String, state: String?) -> some View {
        let count = model.counts[state ?? "all"] ?? 0
        return Button("\(label) \(count)") { model.stateFilter = state }
            .buttonStyle(.plain).font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(model.stateFilter == state ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityAddTraits(model.stateFilter == state ? .isSelected : [])
            .redacted(reason: model.loading ? .placeholder : []).disabled(model.loading)
    }
    private var roster: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if model.loading { skeleton }
                else if model.visible.isEmpty {
                    Text(model.agents.isEmpty ? "No agents to watch yet." : "No agents match this view.")
                        .foregroundStyle(.secondary).padding(12)
                } else {
                    ForEach(model.visible) { agent in
                        Button { model.select(agent.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Image(systemName: agent.kind == "hoot" ? "bird" : "terminal").foregroundStyle(.secondary)
                                    Text(agent.name).fontWeight(.medium).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if agent.state == .working { ProgressView().controlSize(.mini) }
                                }
                                Text(agent.taskTitle ?? agent.project).lineLimit(2).font(.caption).foregroundStyle(.secondary)
                                Text(agent.action).font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 4) {
                                    Text(agent.provider.capitalized + " · " + agent.machineName).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if let since = agent.since, since > 0 {
                                        Text(Date(timeIntervalSince1970: since / 1000), style: .relative)
                                    }
                                }.font(.caption2).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .background(model.selectedID == agent.id ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("\(agent.name), \(agent.action), \(agent.machineName)")
                    }
                }
            }
        }
    }
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let agent = model.selected {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name).font(.headline)
                        Text(agent.project).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(agent.project)
                    }
                    Spacer()
                    if agent.sessionID != nil || agent.kind == "hoot" {
                        Button("Open session") { model.openSession() }.disabled(agent.state == .offline)
                    }
                }
                HStack {
                    Text("Read-only").font(.caption).foregroundStyle(.secondary)
                    if let at = model.updatedAt, at > 0 {
                        Text("Updated \(Date(timeIntervalSince1970: at / 1000), style: .relative)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Follow live", isOn: $model.follow).toggleStyle(.checkbox).font(.caption)
                }
                if let error = model.conversationError {
                    HStack { Text(error).foregroundStyle(.secondary); Button("Try again") { model.readSelected() } }
                }
                if let notice = model.conversationNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if model.reading && model.entries.isEmpty { skeleton }
                            else if model.entries.isEmpty { Text("No conversation has arrived yet.").foregroundStyle(.secondary).padding(12) }
                            ForEach(model.entries) { entry in entryRow(entry).id(entry.id) }
                            Color.clear.frame(height: 1).id("aw-bottom")
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.entries) { _, _ in
                        if model.follow { scroll.scrollTo("aw-bottom", anchor: .bottom) }
                    }
                    .onChange(of: model.follow) { _, follow in if follow { scroll.scrollTo("aw-bottom", anchor: .bottom) } }
                }
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            } else if model.loading {
                skeleton.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                NativePageEmpty(symbol: "person.2", title: "Watch an agent", message: { Text("Choose an agent to read its conversation and activity.") },
                    hint: { EmptyView() }, extra: { EmptyView() }).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    @ViewBuilder private func entryRow(_ entry: AWWatchEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.speaker).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if entry.at > 0 { Text(Date(timeIntervalSince1970: entry.at / 1000), style: .time).font(.caption2).foregroundStyle(.tertiary) }
            }
            if entry.kind == .tool || entry.kind == .result {
                DisclosureGroup(isExpanded: Binding(get: { model.expandedEntries.contains(entry.id) }, set: { expanded in
                    if expanded { model.expandedEntries.insert(entry.id) } else { model.expandedEntries.remove(entry.id) }
                })) {
                    Text(entry.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label(entry.title, systemImage: entry.failed ? "exclamationmark.circle" : "wrench").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                if !entry.title.isEmpty { Text(entry.title).font(.callout.weight(.medium)) }
                Text(entry.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if let target = entry.targetAgentID, model.agents.contains(where: { $0.id == target }) {
                    Button("Watch this agent") { model.select(target) }.controlSize(.small)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<3) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent reading a project").font(.callout)
                    Text("Working on the current task").font(.caption)
                }.redacted(reason: .placeholder).foregroundStyle(.secondary)
            }
        }.padding(12).accessibilityLabel("Loading agent activity")
    }
}
