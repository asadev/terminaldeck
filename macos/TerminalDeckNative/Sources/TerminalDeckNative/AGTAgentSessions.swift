import SwiftUI
import Observation
import TerminalDeckNativeCore

/// 13 Oct (Asad: "why I see Commander twice"): one card per agent. The sessions working AS an agent (its task runs,
/// a session started as it, one he opened in its project that works as the lead it is) show on that agent's card as
/// "1 session" / "3 sessions" and on its page, never as cards of their own. One session opens straight away; several
/// open from a list.
struct AGTSessionsChip: View {
    let agent: AGTAgent
    private var store: AGTAgentsStore { .shared }

    var body: some View {
        let rows = store.liveSessions(of: agent)
        if rows.count == 1, let row = rows.first {
            Button { store.openSession(row: row) } label: { label(1) }
                .buttonStyle(.plain).help("Open its session: \(row.name)")
        } else if rows.count > 1 {
            Menu {
                ForEach(rows) { row in
                    Button { store.openSession(row: row) } label: { DeckRowLabel(row.name + " · " + row.state.label, image: DeckRowIcon.session(id: row.sessionID ?? row.id)) }
                }
            } label: { label(rows.count) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Its \(rows.count) sessions: pick one to open it")
        }
    }
    private func label(_ count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal").font(.system(size: 10))
            Text(count == 1 ? "1 session" : "\(count) sessions").font(.system(size: 11))
        }
        .foregroundStyle(.secondary).padding(.horizontal, 6).frame(height: 22)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// The sessions working as this agent, on its page: each with its state and an Open button.
struct AGTAgentSessionsCard: View {
    let agentID: String
    private var store: AGTAgentsStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        AGTTeamChatHistoryCard(agentID: store.agent(agentID)?.profileID ?? agentID)
        if let agent = store.agent(agentID) {
            let rows = store.liveSessions(of: agent)
            if !rows.isEmpty {
                AGOPTCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(rows.count == 1 ? "1 session working as \(agent.name)" : "\(rows.count) sessions working as \(agent.name)")
                            .font(.system(size: 13, weight: .semibold))
                        ForEach(rows) { row in
                            HStack(spacing: 8) {
                                let identity = NativeSessionRowIdentity(id: row.sessionID ?? row.id, folder: row.project, provider: row.provider, agent: agent)
                                identity.picture()
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.name).lineLimit(1)
                                    if let subtitle = identity.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(row.state.label).font(.caption).foregroundStyle(.secondary)
                                if let task = row.taskTitle, !task.isEmpty { Text("· " + task).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer(minLength: 8)
                                Button("Open") { store.openSession(row: row) }.controlSize(.small)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
        if store.inspectedAgent == agentID, let session = store.inspectedSession {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Session").font(.headline)
                    Spacer()
                    Button("Close") { store.inspectedSession = nil; store.inspectedAgent = nil }.controlSize(.small)
                }
                NativeTerminalScreen(sessionId: session).frame(height: 440)
            }
        }
        }
    }
}

/// The agent page reads the same job catalogue as MCP. It loads no old conversation into an AI.
@MainActor @Observable
final class AGTTeamChatHistory {
    static let shared = AGTTeamChatHistory()
    var rows: [NativeRPCValue] = []
    var openedByAgent: [String: NativeRPCValue] = [:]
    var explicitOwners: [String: String] = [:]
    /// The agent each session was started as (`explicitOwners`) has been read at least once. Until then a session's
    /// missing owner means "not read yet", never "no agent" (Reviewer 28 Oct: the phones' pictures).
    @ObservationIgnored var ownersLoaded = false
    var problem: String?
    /// Every team-job chat the app knows (running or finished), by session id.
    var jobSessionIDs: Set<String> { Set(rows.compactMap { $0["session"]["id"].string }) }
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var pending = false
    @ObservationIgnored var invoke: @MainActor (String) async throws -> Any = { try await EngineBridge.shared.invoke($0) }
    @ObservationIgnored var reconcileSelection: @MainActor () -> Void = {
        if let screen = AppModel.shared.currentScreen, screen.kind == "session",
           AGTAgentsStore.shared.ownedSessionIDs.contains(screen.id),
           let owner = AGTAgentsStore.shared.owner(of: screen.id) {
            AGTAgentsStore.shared.openProfile = owner.id
            AppModel.shared.select(NativeINT2Navigation.allID)
        }
    }
    func start() async {
        if subscriptions.isEmpty {
            for event in ["session:created", "session:status", "session:removed", "tasks:changed"] {
                subscriptions.append(EngineBridge.shared.on(event) { [weak self] args in
                    // 28 Oct (CPU): a status tick of a session that is not one of these team chats changes nothing here.
                    guard let self, TeamChatListRefresh.wanted(event: event, sessionID: args.first as? String, knownJobs: self.jobSessionIDs) else { return }
                    Task { await self.refresh() }
                })
            }
        }
        await refresh()
    }
    func refresh() async {
        guard !loading else { pending = true; return }
        loading = true
        repeat {
        pending = false
        do {
            let raw = try await invoke("session:team:list")
            rows = try NativeRPCValue.fromFoundation(raw).elements ?? []
            let ownerValues = try NativeRPCValue.fromFoundation(await invoke("session:agent-owners"))
            explicitOwners = Dictionary((ownerValues.fields ?? []).compactMap { field in field.value.string.map { (field.key, $0) } }, uniquingKeysWith: { first, _ in first })
            ownersLoaded = true
            problem = nil
            reconcileSelection()
        } catch { problem = error.localizedDescription }
        } while pending
        loading = false
    }
    func sessions(of agentID: String) -> [NativeRPCValue] {
        rows.filter { $0["job"]["agentID"].string == agentID || $0["job"]["fromID"].string == agentID }
    }
    func delete(_ row: NativeRPCValue) {
        guard let id = row["session"]["id"].string else { return }
        Task {
            do { _ = try await EngineBridge.shared.invoke("session:team:delete", [id]); await refresh() }
            catch { problem = error.localizedDescription }
        }
    }
}

struct AGTTeamChatHistoryCard: View {
    let agentID: String
    private var history: AGTTeamChatHistory { .shared }
    private var storeAgent: AGTAgent? { AGTAgentsStore.shared.agent(agentID) }
    @State private var deleting: NativeRPCValue?
    @State private var stoppingJob: String?
    private var opened: NativeRPCValue? {
        get { history.openedByAgent[agentID] }
        nonmutating set { history.openedByAgent[agentID] = newValue }
    }
    var body: some View {
        let rows = history.sessions(of: agentID)
        VStack(alignment: .leading, spacing: 8) {
            if !rows.isEmpty {
                Text("Team conversations · \(rows.count)").font(.system(size: 13, weight: .semibold))
                ForEach(rows, id: \.compact) { row in
                    HStack(alignment: .top, spacing: 8) {
                        let identity = NativeSessionRowIdentity(id: row["session"]["id"].string ?? "", folder: row["session"]["cwd"].string, provider: row["session"]["provider"].string, chat: true, agent: storeAgent)
                        identity.picture()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row["session"]["title"].string ?? "Conversation").font(.callout)
                            if let subtitle = identity.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                            HStack(spacing: 6) {
                                Text(row["finishedAt"].isNullish ? "Open" : row["failed"].bool == true ? "Finished · Failed" : "Finished")
                                if let at = row["session"]["createdAt"].number { Text(Date(timeIntervalSince1970: at / 1000), style: .date) }
                            }.font(.caption).foregroundStyle(.secondary)
                            if let result = row["result"].string { Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer(minLength: 8)
                        let unread = NativeChatUnreadCounts.shared.counts[row["session"]["id"].string ?? ""] ?? Int(row["unread"]["count"].number ?? 0)
                        if unread > 0 { Text("\(unread) new").font(.caption).foregroundStyle(Color.accentColor) }
                        Button("Open") { opened = row }.controlSize(.small)
                        if row["finishedAt"].isNullish, let id = row["session"]["id"].string {
                            Button {
                                stoppingJob = id
                                Task {
                                    defer { stoppingJob = nil }
                                    do { _ = try await EngineBridge.shared.invoke("session:team:stop", [id]); await history.refresh() }
                                    catch { history.problem = error.localizedDescription }
                                }
                            } label: { Image(systemName: "stop.fill") }.buttonStyle(.plain).help("Stop only this team job").accessibilityLabel("Stop team job")
                                .disabled(stoppingJob != nil)
                        }
                        if !row["finishedAt"].isNullish {
                            Button("Delete", role: .destructive) { deleting = row }.controlSize(.small)
                        }
                    }
                }
            }
            if let opened, let id = opened["session"]["id"].string {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(opened["session"]["title"].string ?? "Conversation").font(.headline)
                        Spacer()
                        Button("Close") { self.opened = nil }.controlSize(.small)
                    }
                    AGTEmbeddedConversation(sessionID: id, name: opened["job"]["agentName"].string ?? "Agent")
                        .frame(height: 440).id(id)
                }
            }
            if let problem = history.problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
        }.task { await history.start() }
        .confirmationDialog("Delete this saved conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete history", role: .destructive) { if let row = deleting { history.delete(row) }; deleting = nil }
        } message: { Text("Its saved chat will be removed. This cannot be undone.") }
    }
}

private struct AGTEmbeddedConversation: View {
    @State private var model: NativeHootChatModel
    init(sessionID: String, name: String) {
        _model = State(initialValue: NativeHootChatModel.forSession(sessionID, name: name))
    }
    var body: some View { NativeHootChat(model: model, compact: true) }
}
