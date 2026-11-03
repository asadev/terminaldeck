import AppKit
import SwiftUI
import Foundation
import Observation
import TerminalDeckNativeCore

/// AGT: what the Agents page and the sidebar's Agents section read. Profiles come
/// from the one task store (`TasksStore`, TAG's profiles); live activity from the
/// same `agents-watch:list` the "At work" view reads. It listens for the engine's
/// pushes (no polling). Every change is a `tasks:agent-save` of the real profile.
@MainActor
@Observable
final class AGTAgentsStore {
    static let shared = AGTAgentsStore()

    enum Layout: String, CaseIterable { case list, cards }

    /// Live rows, as Agents at work lists them.
    func scopedAgents(projectID: String?) -> [AGTAgent] {
        AGFRAMEPresentation.scopedAgents(agents, projects: NativePROJLabels.shared.projects, projectID: projectID)
    }

    var live: [AWWatchAgent] = []
    var liveLoaded = false
    /// One short line after a refused change (a loop in the chart, a failed save).
    var message: String?
    var busy = false
    var search = ""
    /// The agent whose profile page is open, or nil for the list.
    var openProfile: String?
    var inspectedSession: String?
    var inspectedAgent: String?
    /// Renders and tests set this instead of reading the engine.
    var fixture: TasksState?
    var fixtureAgentSettings: [String: AGSAgentSettings] = [:]
    private var inheritedModels: [String: String] = [:]
    private(set) var modelEpoch = 0
    @ObservationIgnored private var modelEpochs: [String: Int] = [:]

    var layout: Layout = .cards { didSet { remember("agt.layout", layout.rawValue) } }
    var grouping: AGTDirectory.Grouping = .project { didSet { remember("agt.grouping", grouping.rawValue) } }

    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    /// Session status changes and Hoot chat updates arrive many times a second: the list is read at most once per
    /// 1.5 s (the first change after a quiet spell at once, the rest folded into one trailing read), one read at a time.
    @ObservationIgnored private lazy var livePacer = AGTRefreshPacer { [weak self] in await self?.readLive() }
    static let events = ["session:created", "session:status", "session:exit", "session:removed", "session:renamed",
                         "tasks:changed", "ags:changed", "machines:state", "hoot:chat:changed", "agents-watch:changed"]

    private init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "agt.layout"), let saved = Layout(rawValue: raw) { layout = saved }
        if let raw = defaults.string(forKey: "agt.grouping"), let saved = AGTDirectory.Grouping(rawValue: raw) { grouping = saved }
    }

    private func remember(_ key: String, _ value: String) {
        guard fixture == nil else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    var tasksState: TasksState? { fixture ?? TasksStore.shared.state }
    var profiles: [AgentProfile] { tasksState?.agents ?? [] }

    /// What the directory is built from. Every input is read on each `agents` read, so a view still
    /// redraws when one changes; unchanged arrays compare by their shared storage, without a walk.
    private struct DirectoryInputs: Equatable {
        var profiles: [AgentProfile], live: [AWWatchAgent], tasks: [TaskRow], sessionSeats: [String: String]
        var projects: [PROJProject], settings: [String: AGSAgentSettings], inherited: [String: String]
    }
    @ObservationIgnored private var directory: (inputs: DirectoryInputs, agents: [AGTAgent])?

    /// Only named profiles and Hoot belong in the directory. Sessions remain on Running.
    /// Built once per change of its inputs (#189): cards, rows, badges and the sidebar read it many times per redraw.
    var agents: [AGTAgent] {
        let inputs = DirectoryInputs(profiles: profiles, live: live, tasks: tasksState?.tasks ?? [],
                                     sessionSeats: AGTHandsStore.shared.sessionSeats, projects: NativePROJLabels.shared.projects,
                                     settings: fixtureAgentSettings, inherited: inheritedModels)
        if let directory, directory.inputs == inputs {
            // Equal but freshly copied: keep the new copy so the next check is the quick one.
            self.directory?.inputs = inputs
            return directory.agents
        }
        let built = AGTDirectory.build(profiles: inputs.profiles.map(AGTProfileInput.init), live: inputs.live,
                                       tasks: inputs.tasks.map(AGTTaskInput.init),
                                       sessionSeats: inputs.sessionSeats, projects: inputs.projects)
            .filter { $0.kind != .session }
            .map { item in
                var next = item
                if next.model == nil, let id = next.profileID {
                    next.model = inputs.settings[id]?.model ?? inputs.inherited[modelKey(next)]
                }
                return next
            }
        directory = (inputs, built)
        return built
    }
    private func modelKey(_ agent: AGTAgent) -> String { (agent.profileID ?? agent.id) + ":" + agent.provider }
    func modelRequestID(_ agent: AGTAgent) -> String { modelKey(agent) + ":" + String(modelEpoch) }
    func resolveInheritedModel(_ agent: AGTAgent) async {
        guard fixture == nil, let id = agent.profileID,
              profiles.first(where: { $0.id == id })?.model == nil else { return }
        let key = modelKey(agent), epoch = modelEpoch
        guard modelEpochs[key] != epoch else { return }
        do {
            let raw = try await EngineBridge.shared.invoke("agopt:profile", [id], timeout: 10)
            let value = try NativeRPCValue.fromFoundation(raw)
            guard !Task.isCancelled, epoch == modelEpoch, let model = value["effective"]["model"].string, !model.isEmpty else { return }
            if inheritedModels[key] != model { inheritedModels[key] = model }
            modelEpochs[key] = epoch
        } catch { /* Keep the last confirmed choice until the next profile/settings change. */ }
    }
    var visible: [AGTAgent] { AGTDirectory.filtered(agents, query: search) }
    func agent(_ id: String?) -> AGTAgent? { id.flatMap { id in agents.first { $0.id == id } } }
    func profile(_ agent: AGTAgent?) -> AgentProfile? { agent?.profileID.flatMap { id in profiles.first { $0.id == id } } }

    /// Agent-created team jobs belong on profiles; a person-started agent session stays in Running.
    var ownedSessionIDs: Set<String> {
        let named = agents.filter { $0.kind == .profile && $0.profileID != nil }
        let profiles = Set(named.compactMap(\.profileID))
        let jobs = AGTTeamChatHistory.shared.rows.filter {
            profiles.contains($0["job"]["agentID"].string ?? "") && $0["job"]["fromID"].string != "hoot"
        }
        return Set(jobs.compactMap { $0["session"]["id"].string })
    }
    func owner(of session: String) -> AGTAgent? {
        let profile = AGTTeamChatHistory.shared.rows.first { $0["session"]["id"].string == session }?["job"]["agentID"].string
        return agents.first { $0.kind == .profile && $0.profileID == profile && profile != nil }
    }

    /// The profile this session speaks as, independent of who started or owns its work.
    func sender(of session: String) -> AGTAgent? {
        if let profile = AGTTeamChatHistory.shared.explicitOwners[session],
           let saved = agents.first(where: { $0.kind == .profile && $0.profileID == profile }) {
            return saved
        }
        return owner(of: session)
    }

    /// For the sidebar's "At work" row.
    var counts: (working: Int, waiting: Int) { AGTDirectory.counts(live) }

    /// Current managers, for refusing loops before anything is sent.
    var managers: [String: String?] {
        Dictionary(profiles.map { ($0.id, $0.reportsTo) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Reading

    func start() {
        guard fixture == nil else { return }
        TasksStore.shared.start()
        AGTHandsStore.shared.start()   // which seat each session sits in (a session working as a lead)
        guard subscriptions.isEmpty else { return }
        for event in Self.events {
            subscriptions.append(EngineBridge.shared.on(event) { args in
                // At work's 2 s resource packets carry the inventory: use it, no extra list read.
                if event == "agents-watch:changed", let raw = args.first,
                   let value = try? NativeRPCValue.fromFoundation(raw), value["metrics"].elements != nil {
                    guard let agents = value["agents"].elements else { return }
                    Task { @MainActor in AGTAgentsStore.shared.adoptLive(agents) }
                    return
                }
                Task { @MainActor in
                    if event == "tasks:changed" || event == "ags:changed" { AGTAgentsStore.shared.modelEpoch &+= 1 }
                    AGTAgentsStore.shared.refreshLive()
                }
            })
        }
        refreshLive()
    }

    func adoptLive(_ agents: [NativeRPCValue]) {
        guard fixture == nil else { return }
        setLive(agents.compactMap(AWWatchAgent.decode))
    }

    /// Ask for a fresh list. Paced: see `livePacer`.
    func refreshLive() {
        guard fixture == nil else { return }
        livePacer.request()
    }

    private func readLive() async {
        guard fixture == nil else { return }
        do {
            let raw = try await EngineBridge.shared.invoke("agents-watch:list", [["limit": 200, "query": ""]])
            let value = try NativeRPCValue.fromFoundation(raw)
            setLive((value["agents"].elements ?? []).compactMap(AWWatchAgent.decode))
        } catch {
            // Not up yet: the next push reads again. Profiles still show.
            if !liveLoaded { liveLoaded = true }
        }
    }

    /// An unchanged list leaves the page alone: no redraw and no directory rebuild.
    private func setLive(_ rows: [AWWatchAgent]) {
        if rows != live { live = rows }
        if !liveLoaded { liveLoaded = true }
    }

    // MARK: Changing

    /// Save the whole real profile with one change, the way the settings form does.
    @discardableResult
    func save(_ profile: AgentProfile) async -> Bool {
        guard fixture == nil else {
            if let index = fixture?.agents.firstIndex(where: { $0.id == profile.id }) { fixture?.agents[index] = profile } else { fixture?.agents.append(profile) }
            return true
        }
        busy = true
        defer { busy = false }
        let result = await TasksStore.shared.call("tasks:agent-save", [profile.wire])
        TasksStore.shared.adopt(result)
        message = result.ok ? nil : (result.message ?? "That did not save.")
        return result.ok
    }

    func setIcon(_ agent: AGTAgent, _ icon: AGTIcon?) async {
        guard var profile = profile(agent) else { message = "Save this agent first to give it an icon."; return }
        profile.icon = icon.map { AGTIcon.raw($0, colour: AGTIcon.colour(profile.icon)) }
        await save(profile)
    }

    /// `boss`: a profile id, Hoot's id, or nil for independent. Loops are refused here
    /// with the same sentence the engine would give.
    @discardableResult
    func setReportsTo(_ agentID: String, _ boss: String?) async -> Bool {
        guard let agent = agent(agentID), var profile = profile(agent) else {
            message = "Only saved agents can have a place in the chart. Open it and choose Save as an agent."
            return false
        }
        let names = Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        if let refusal = AGTOrgChart.refusal(id: profile.id, reportsTo: boss, managers: managers, names: names) {
            message = refusal
            return false
        }
        guard profile.reportsTo != boss else { return true }
        profile.reportsTo = boss
        return await save(profile)
    }

    /// A live session becomes a task agent: its name, coding agent and folder, through the New agent form's rules.
    func saveAsAgent(_ agent: AGTAgent) async -> String? {
        let name = agent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Agent" : agent.name
        var draft = AgentDraft(nil)
        draft.name = AgentForm.uniqueName(name, among: profiles)
        draft.role = "Works in \(NativePROJLabels.shared.name(for: agent.projectID, folder: agent.project))"
        draft.provider = agent.provider
        draft.defaultProject = agent.project
        draft.icon = AGTIcon.raw(agent.icon, colour: agent.iconColour)
        draft.projectID = agent.projectID
        switch AgentForm.payload(draft, agents: profiles) {
        case .failure(let refusal): message = "\(draft.name) was not saved: " + refusal.message; return nil
        case .success(let profile): return await save(profile) ? profile.id : nil
        }
    }

    /// Change the imported agent's own .md (description, model, tools). Only on the owner's yes.
    func writeSource(id: String, description: String?, model: String??, tools: [String]??) async -> Bool {
        guard fixture == nil else { return true }
        var change: [String: Any] = ["id": id]
        if let description { change["description"] = description }
        if let model { change["model"] = model ?? NSNull() }
        if let tools { change["tools"] = tools ?? NSNull() }
        do {
            _ = try await EngineBridge.shared.invoke("agents-directory:write-source", [change])
            return true
        } catch {
            message = "The agent file was not changed: \(error.localizedDescription)"
            return false
        }
    }

    /// The live rows of the sessions working as this agent (its card's "N sessions"), busiest first.
    func liveSessions(of agent: AGTAgent) -> [AWWatchAgent] {
        let ids = Set(agent.sessionIDs)
        var seen = Set<String>()
        return AWWatchProjection.sorted(live.filter { row in
            guard let id = row.sessionID, ids.contains(id), row.state != .offline, row.state != .finished else { return false }
            return seen.insert(id).inserted
        })
    }
    /// Show one session's tab (a session listed on an agent's card or page).
    func openSession(row: AWWatchAgent) {
        guard let id = row.sessionID else { return }
        let target = (row.machineID.isEmpty ? SessionTarget.local(id) : .machine(machineId: row.machineID, sessionId: id)).tabId
        if ownedSessionIDs.contains(id), let agent = owner(of: id) {
            inspectedSession = target; inspectedAgent = agent.id; openProfile = agent.id
            AppModel.shared.select(NativeINT2Navigation.allID)
        } else { AppModel.shared.selectTab(target) }
    }

    func openSession(_ agent: AGTAgent) {
        if agent.kind == .hoot { AppModel.shared.select("hoot"); return }
        guard let row = live.first(where: { agent.liveIDs.contains($0.id) && $0.sessionID != nil && $0.state != .offline }), let id = row.sessionID else { return }
        inspectedSession = (row.machineID.isEmpty ? SessionTarget.local(id) : .machine(machineId: row.machineID, sessionId: id)).tabId
        inspectedAgent = agent.id; openProfile = agent.id
        AppModel.shared.select(NativeINT2Navigation.allID)
    }
}
