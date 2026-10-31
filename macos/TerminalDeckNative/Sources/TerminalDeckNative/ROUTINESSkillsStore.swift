import Foundation
import Observation
import TerminalDeckNativeCore

@MainActor
@Observable
final class ROUTINESSkillsStore {
    static let shared = ROUTINESSkillsStore()
    enum Tab: String { case installed, getMore }
    var tab: Tab = .installed
    var query = ""
    var category = "All"
    var installed: [ROUTINESSkill] = []
    var catalogue = CommunityView.none
    private var fixtureProfiles: [NativeRPCValue] = []
    var profiles: [NativeRPCValue] {
        get { fixture ? fixtureProfiles : (TasksStore.shared.state?.agents ?? []).compactMap { try? NativeRPCValue.fromFoundation($0.wire) } }
        set { fixtureProfiles = newValue }
    }
    var loading = true
    var catalogueLoading = true
    var problem: String?
    var catalogueProblem: String?
    var warnings: [String] = []
    var pending = Set<String>()
    var preview: NativeRPCValue?
    var newSkill = false
    var fixture = false
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var started = false
    var more: [CommunityItem] { available(projectID: nil) }
    func available(projectID: String?) -> [CommunityItem] {
        catalogue.items.filter { item in
            item.kind == "skill" && !installed.contains { $0.catalogueID == item.id && $0.projectID == projectID }
        }
    }
    var subtitle: String { "\(installed.count) skills installed · \(more.count) more to get" }
    var categories: [String] {
        ROUTINESSkillsRules.categories + Array(Set(installed.map(\.category) + catalogue.items.flatMap(\.tags))).sorted().filter { !ROUTINESSkillsRules.categories.contains($0) }
    }
    func start() {
        guard !fixture, !started else { return }; started = true
        NativePROJLabels.shared.start()
        TasksStore.shared.start()
        for event in ["skills:changed", "project-registry:changed"] {
            subscriptions.append(EngineBridge.shared.on(event) { [weak self] _ in Task { @MainActor in await self?.load() } })
        }
        Task { await load() }
    }
    func load() async {
        guard !fixture else { return }
        generation += 1; let mine = generation
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.generation == mine else { return }
            if self.loading { self.loading = false; self.problem = "Skills took too long to answer. Try again." }
            if self.catalogueLoading { self.catalogueLoading = false; self.catalogueProblem = "The Skills store took too long to answer. Try again." }
            self.generation += 1
        }
        defer { watchdog.cancel() }
        do {
            let value = try NativeRPCValue.fromFoundation(try await EngineBridge.shared.invoke("skills:list", [["installed": true]]))
            guard generation == mine else { return }
            installed = (value["skills"].elements ?? []).compactMap(ROUTINESSkill.decode)
            warnings = (value["warnings"].elements ?? []).compactMap(\.string); problem = nil; loading = false
        } catch { if generation == mine { problem = error.localizedDescription; loading = false } }
        do {
            let value = try NativeRPCValue.fromFoundation(try await EngineBridge.shared.invoke("skills:list", [["installed": false]]))
            guard generation == mine else { return }
            catalogue = CommunityRules.view(value["catalogue"].foundation); catalogueProblem = nil; catalogueLoading = false
        } catch { if generation == mine { catalogueProblem = error.localizedDescription; catalogueLoading = false } }
    }
    @ObservationIgnored var versionInvoker: (@MainActor (String, NativeRPCValue) async throws -> NativeRPCValue)?
    func versionCall(_ channel: String, args: [String: Any]) async throws -> NativeRPCValue {
        let payload = try NativeRPCValue.fromFoundation(args)
        if let versionInvoker { return try await versionInvoker(channel, payload) }
        return try NativeRPCValue.fromFoundation(try await EngineBridge.shared.invoke(channel, [payload.foundation]))
    }
    func refreshPreview(_ skill: String) async {
        guard !fixture else { return }
        do { preview = try await versionCall("skills:preview", args: ["skill": skill]); await load() }
        catch { problem = error.localizedDescription }
    }
    func users(_ row: ROUTINESSkill) -> [NativeRPCValue] { profiles.filter { ($0["skills"].elements ?? []).contains(.string(row.name)) } }
    func project(_ profile: NativeRPCValue) -> String {
        PROJProjects.resolve(projectID: profile["projectId"].string ?? profile["projectID"].string,
                             folder: profile["defaultProject"].string, projects: NativePROJLabels.shared.projects)
    }
    func assigned(_ row: ROUTINESSkill, to id: String) -> Bool { users(row).contains { $0["id"].string == id } }
    @discardableResult
    func action(_ channel: String, args: [String: Any], key: String) async -> Bool {
        guard !pending.contains(key) else { return false }; pending.insert(key); defer { pending.remove(key) }
        guard !fixture else { return true }
        do {
            let result = try NativeRPCValue.fromFoundation(try await EngineBridge.shared.invoke(channel, [args]))
            guard result["ok"].bool == true else { problem = result["message"].string ?? "The change did not save."; return false }
            problem = nil; await load(); TasksStore.shared.reload(); return true
        } catch { problem = error.localizedDescription; return false }
    }
    func assign(_ row: ROUTINESSkill, to id: String, enabled: Bool) async {
        if fixture {
            if let index = profiles.firstIndex(where: { $0["id"].string == id }) { profiles[index] = ROUTINESSkillsRules.changing(profiles[index], skill: row.name, assigned: enabled) }
            return
        }
        _ = await action(enabled ? "skills:assign" : "skills:unassign", args: ["skill": row.id, "agentIds": [id]], key: "assign:" + id)
    }
    /// Another page's "Show the skill" (an agent's Skills tab): opens that skill's preview.
    func open(id: String) async {
        if installed.isEmpty && !fixture { await load() }
        guard let row = installed.first(where: { $0.id == id }) else { problem = "That skill is no longer installed."; return }
        await open(row)
    }
    func open(_ row: ROUTINESSkill) async {
        guard !pending.contains("preview") else { return }; pending.insert("preview"); defer { pending.remove("preview") }
        if fixture { preview = row.wire.setting("markdown", .string("# " + row.name + "\n\n" + row.summary)).setting("files", .array([.string("SKILL.md")])).setting("agents", .array(users(row))); return }
        do { preview = try NativeRPCValue.fromFoundation(try await EngineBridge.shared.invoke("skills:preview", [["skill": row.id]])) }
        catch { problem = error.localizedDescription }
    }
}

extension Notification.Name {
    static let ROUTINESNewSkill = Notification.Name("ROUTINES.newSkill")
}
