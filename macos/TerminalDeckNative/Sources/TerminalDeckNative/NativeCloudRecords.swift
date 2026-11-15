import AppKit
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The app's live owners lane A2's two rows read and write (lean scope item 7): the one project registry and the one
/// task configuration (the agent roster), plus the two DISPLAY-ONLY refreshes. Built only when those rows are
/// switched on for an account that is being assembled.
struct NativeCloudRecordsLive: Sendable {
    let registry: BackendPROJRegistry?
    let roster: BackendTaskConfiguration?
    /// This Mac's default AI, as the launcher reads it.
    let defaultProvider: @Sendable () async -> String
    /// Refresh the project list on screen after an import. Display only: nothing is saved or started by it.
    let projectsChanged: @Sendable () async -> Void
    /// Refresh the Agents page after an import. Display only: it never fires the task change hub.
    let agentsChanged: @Sendable () async -> Void
    /// Lane L3: the one task list, the settings file and the app state (tasks I12, settings I21).
    var taskStore: BackendTaskStore? = nil
    var appSettings: BackendAppSettingsStore? = nil
    var state: NativeStateStore? = nil
    /// Refresh the Tasks page after tasks arrived from Cloud. Display only (`displayEvent`), never "tasks:changed".
    var tasksChanged: @Sendable () async -> Void = {}
    /// Tasks everywhere: the connected task systems this Mac reads itself (their connections travel).
    var connectedTasks: BackendConnectedTasksService? = nil
    /// Settings arrived from Cloud: the two existing events "settings:changed" / "prefs:changed", as a change made here.
    var settingsChanged: @Sendable (_ app: Bool, _ preferences: Bool) async -> Void = { _, _ in }
}

@MainActor
enum NativeCloudRecordsOwners {
    /// The app's one task configuration, set by the Tasks composition when it exists (one binding line there). A
    /// reference only: nothing is read from it until an account with lane A2's rows switched on is built.
    static var roster: BackendTaskConfiguration?
    /// Lane L3: the app's one task list, set by the Tasks composition (one binding line there). A reference only.
    static var taskStore: BackendTaskStore?
    /// Tasks everywhere: the app's connected task systems, set by their composition (one binding line there).
    static var connectedTasks: BackendConnectedTasksService?
    static func live(root: BackendCompositionRoot) -> NativeCloudRecordsLive {
        let registry = BackendPROJRegistry.installed, channels = root.registry, state = root.state
        var made = NativeCloudRecordsLive(registry: registry, roster: roster,
            defaultProvider: { await state.getPreferences()["defaultProvider"].string ?? "claude" },
            // Lane A2 review SF4: DISPLAY ONLY. Both publish `BackendCloudLeanRecords.displayEvent`, which only the
            // project list (SIDEBARProjectStore) and the Agents page (AGTAgentsStore) listen to; it never starts work.
            // Never "tasks:changed" or "project-registry:changed": other parts of the app act on those.
            projectsChanged: {
                try? await channels.publish(BackendCloudLeanRecords.displayEvent, arguments: [])
                await NativeCloudRecords.shared.refresh()
            },
            agentsChanged: {
                try? await channels.publish(BackendCloudLeanRecords.displayEvent, arguments: [])
                await NativeCloudRecords.shared.refresh()
            })
        made.taskStore = taskStore
        made.connectedTasks = connectedTasks
        made.appSettings = root.settings
        made.state = state
        // Display only: the Tasks page reloads on `displayEvent` too (NativeTasksModel); no engine listens to it.
        made.tasksChanged = { try? await channels.publish(BackendCloudLeanRecords.displayEvent, arguments: []) }
        let settings = root.settings
        made.settingsChanged = { app, preferences in
            await BackendCloudKindsSettings.announce(app: app, preferences: preferences, settings: settings, state: state,
                publish: { channel, payload in try? await channels.publish(channel, arguments: [payload]) })
        }
        return made
    }
}

/// What the Cloud page and the `cloud.versions` tool know of projects and agents (lane A2) for the signed-in
/// identity. Empty while those rows are not switched on: the summary's row and the tool are then absent.
@MainActor
final class NativeCloudRecords {
    static let shared = NativeCloudRecords()
    static let toolOwner = "cloud-records"
    private(set) var records: BackendCloudLeanRecords?
    private var loading: Task<Void, Never>?
    init() {}

    /// Page-names 2: a project without a folder here is named by its name only, under the summary's one quiet line.
    nonisolated static func needsFolder(_ name: String) -> String { BackendCloudTrustRows.plainName(name) }
    static let folderRefused = "That folder could not be used. Choose a folder that exists on this Mac."

    func attach(_ made: BackendCloudLeanRecords) {
        records = made
        // "Choose folder…" on the Cloud page: the person picks the folder in this Mac's own window; never a tool.
        NativeCloudFeatureParts.shared.chooseFolder = { [weak self] projectId in self?.chooseFolder(projectId) }
        // Review B-M3: nothing is read yet, so the row says "Checking…", never "nothing waits".
        NativeCloudFeatureParts.shared.projects = .notReadYet
        refresh()
    }
    func detach(_ made: BackendCloudLeanRecords) {
        guard let current = records, current.activation === made.activation else { return }
        loading?.cancel(); loading = nil
        records = nil
        NativeCloudFeatureParts.shared.chooseFolder = nil
        NativeCloudFeatureParts.shared.projects = nil
    }
    /// Reads what waits again: projects without a folder here, and how many changes from other devices are held.
    func refresh() {
        guard let records else { return }
        loading?.cancel()
        loading = Task { [weak self] in
            let part = await Self.part(records)
            guard !Task.isCancelled, let self, let current = self.records, current.activation === records.activation else { return }
            NativeCloudFeatureParts.shared.projects = part
        }
    }
    /// The summary's part for projects and agents, in plain words. Names are another device's text: filtered.
    /// Review B-M3: a list that cannot be read is "could not check" with Check again, never "nothing waits".
    nonisolated static func part(_ records: BackendCloudLeanRecords) async -> BackendCloudOverviewInput.Feature {
        var waiting: [BackendCloudOverview.Waiting] = []
        var notes: [String] = []
        var later: [BackendCloudOverview.Waiting] = []
        var held = 0
        do {
            // Page-names 2 (owner: "needs you" is only what blocks his work and only he can do): a project without a
            // folder here is not a task. Memory and agents arrive without it; it is listed by name, to do when he wants.
            if let projects = records.projects {
                let need = try await projects.needingFolder()
                for project in need {
                    later.append(.init(id: "project:" + project.id, text: needsFolder(project.name), action: .chooseFolder(projectId: project.id)))
                }
            }
            let counts = try await records.tools.counts()
            held = counts.waiting
            if counts.kept > 0 { notes.append(BackendCloudLeanTools.keptSentence(counts.kept)) }
        } catch {
            return .unreadable
        }
        return BackendCloudOverviewInput.Feature(waiting: waiting, notes: notes, later: later, heldChanges: held)
    }
    /// Page-names 2 (owner: count what he would count): the projects and agents of his ACCOUNT, as this Mac's record
    /// store knows them: the ones on this Mac (a stored value) and the ones that arrived and are not on this Mac yet
    /// (waiting here). The Independent project that every install has is not a record and is not counted. nil while
    /// those rows are not switched on or cannot be read. Read only.
    struct AccountCounts: Sendable, Equatable {
        var projectsHere = 0, projectsArriving = 0, agentsHere = 0, agentsArriving = 0
    }
    nonisolated static func accountCounts(_ records: BackendCloudLeanRecords) async -> AccountCounts? {
        let store = records.store
        let stored = await Task.detached { () -> (projects: Set<String>, agents: Set<String>)? in
            guard let projects = try? store.storedEntities(domain: BackendCloudLeanProjects.domain),
                  let agents = try? store.storedEntities(domain: BackendCloudLeanAgents.domain) else { return nil }
            return (Set(projects.compactMap { BackendCloudLeanProjects.kind.id(of: $0) }),
                    Set(agents.compactMap { BackendCloudLeanAgents.agentKind.id(of: $0) }))
        }.value
        guard let stored else { return nil }
        var waitingProjects: Set<String> = [], waitingAgents: Set<String> = []
        for adapter in records.adapters {
            guard let listing = try? await adapter.listing() else { return nil }
            for item in listing.waiting {
                if let id = BackendCloudLeanProjects.kind.id(of: item.record), !stored.projects.contains(id) { waitingProjects.insert(id) }
                if let id = BackendCloudLeanAgents.agentKind.id(of: item.record), !stored.agents.contains(id) { waitingAgents.insert(id) }
                // An agent's instruction text arrived before the agent itself: that agent is arriving too.
                if let id = BackendCloudLeanAgents.instructionKind.id(of: item.record), !stored.agents.contains(id) { waitingAgents.insert(id) }
            }
        }
        var made = AccountCounts()
        if records.projects != nil { made.projectsHere = stored.projects.count; made.projectsArriving = waitingProjects.count }
        if records.agents != nil { made.agentsHere = stored.agents.count; made.agentsArriving = waitingAgents.count }
        return made
    }
    private func chooseFolder(_ projectId: String) {
        guard let projects = records?.projects else { return }
        // Proof 3 (13 Nov): the picker was decided later, in the task, when the press was no longer the current event,
        // and opened as a free panel: with the Settings window not the main one, nothing came forward. Both are taken
        // here, at the press, and the picker opens as a sheet on the window that was clicked.
        let window = NativeCompositionFolderPicker.pressWindow(event: NSApp.currentEvent?.window, key: NSApp.keyWindow)
        let acting = NativeFront.personActing
        Task { [weak self] in
            guard let picked = try? await NativeCompositionFolderPicker.pick(nil, on: window, acting: acting) else { return }
            do { _ = try await projects.chooseFolder(projectID: projectId, folder: picked) }
            catch { NativeCloudAccount.shared.say(Self.folderRefused) }
            self?.refresh()
        }
    }
    /// The one read-only tool of lane A2 (`cloud.versions`), registered beside the account's tools only while
    /// these rows are built. It lists; it chooses, approves and changes nothing.
    func toolEntries(visible: @escaping @Sendable () async -> Bool) async throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        guard let records, await visible(), let definition = BackendCloudLeanTools.contribution.tools.first else { return [] }
        let tools = records.tools
        let spec = try BackendMCPTool(id: definition.id, wireName: definition.id.replacingOccurrences(of: ".", with: "_"),
                                      description: definition.description, inputSchema: definition.inputSchema.raw, tier: .read)
        return [(spec, { _, arguments in
            guard await visible() else { throw CloudFailure.gateClosed }
            let answer = try await tools.invoke(definition.id, arguments: CloudValue(arguments))
            return .value(answer.raw)
        })]
    }
}
