import Foundation
import Observation
import TerminalDeckNativeCore

/// Shares the project registry and session events; no additional polling.
@MainActor @Observable
final class SIDEBARProjectStore {
    static let shared = SIDEBARProjectStore()
    private static let removedKey = "sidebar.removedFolders"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var removedFolders: Set<String>
    private(set) var openFolders: Set<String>?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        removedFolders = Set(defaults.stringArray(forKey: Self.removedKey) ?? [])
    }
    func folderIsRemoved(_ path: String) -> Bool { removedFolders.contains(PROJProjects.normalize(path)) }
    func hideFolder(_ path: String) {
        guard path.hasPrefix("/") else { return }
        saveRemoved(removedFolders.union([PROJProjects.normalize(path)]))
    }
    func updateOpenFolders(_ paths: Set<String>) {
        let next = Set(paths.map(PROJProjects.normalize))
        let closed = openFolders.map { $0.subtracting(next) } ?? []
        saveRemoved(removedFolders.union(closed).subtracting(next))
        openFolders = next
    }
    private func saveRemoved(_ paths: Set<String>) {
        guard paths != removedFolders else { return }
        removedFolders = paths
        defaults.set(paths.sorted(), forKey: Self.removedKey)
    }
    var projects: [PROJProject] = []
    var liveIDs: Set<String>?
    var started: [String: Double] = [:]
    /// Each session's project, from `session:list` (its own project id, else its folder): the side panel draws
    /// the project's logo before every session that belongs to one (Asad, 11 Oct).
    var sessionProjects: [String: (projectID: String?, cwd: String?)] = [:]
    /// Each session's own name and AI, from the same `session:list` rows the paired phones are sent: the side panel's
    /// rows show them as the phones do ("Deck Dev", "Decker · Claude"; Asad, 29 Oct), never the page's "Session 2".
    var sessionTitles: [String: String] = [:]
    var sessionProviders: [String: String] = [:]
    var sessionChats: Set<String> = []
    var error: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []

    func start() {
        guard subscriptions.isEmpty else { return }
        for event in ["project-registry:changed", "session:created", "session:exit", "session:removed", "session:renamed"] {
            subscriptions.append(EngineBridge.shared.on(event) { [weak self] _ in self?.refresh() })
        }
        refresh()
    }
    func refresh() {
        generation += 1
        let mine = generation
        Task {
            do {
                let raw = try await EngineBridge.shared.invoke("project-registry:list", [])
                guard mine == generation else { return }
                projects = try PROJProjects.registeredProjects(NativeRPCValue.fromFoundation(raw))
                error = nil
            } catch { if mine == generation { self.error = "Couldn’t read project colours." } }
            if let raw = try? await EngineBridge.shared.invoke("session:list", []), let rows = raw as? [[String: Any]] {
                guard mine == generation else { return }
                liveIDs = Set(rows.filter { $0["exitCode"] is NSNull || $0["exitCode"] == nil }.compactMap { $0["id"] as? String })
                started = Dictionary(rows.compactMap { row -> (String, Double)? in
                    guard let id = row["id"] as? String else { return nil }
                    return (id, row["createdAt"] as? Double ?? 0)
                }, uniquingKeysWith: { _, latest in latest })
                sessionProjects = Dictionary(rows.compactMap { row -> (String, (projectID: String?, cwd: String?))? in
                    guard let id = row["id"] as? String else { return nil }
                    return (id, (row["projectId"] as? String, row["cwd"] as? String))
                }, uniquingKeysWith: { _, latest in latest })
                sessionTitles = Dictionary(rows.compactMap { row in (row["id"] as? String).flatMap { id in (row["title"] as? String).map { (id, $0) } } },
                                           uniquingKeysWith: { _, latest in latest })
                sessionChats = Set(rows.filter { $0["chat"] as? Bool == true }.compactMap { $0["id"] as? String })
                sessionProviders = Dictionary(rows.compactMap { row in (row["id"] as? String).flatMap { id in (row["provider"] as? String).map { (id, $0) } } },
                                              uniquingKeysWith: { _, latest in latest })
            }
            if let rows = try? await EngineBridge.shared.invoke("projects:list", []) as? [[String: Any]], mine == generation {
                updateOpenFolders(Set(rows.compactMap { $0["path"] as? String }))
            }
        }
    }
    func changeColour(_ hex: String, project: SidebarProject) {
        Task {
            do {
                let resolved = PROJProjects.resolve(projectID: nil, folder: project.id, projects: projects)
                let existing = projects.first { $0.id == resolved && resolved != PROJProjects.independentID }
                var item = existing ?? PROJProject(id: project.id, name: project.title, folders: [project.id])
                item.colour = hex
                let args = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
                _ = try await EngineBridge.shared.invoke("project-registry:save", [args])
                refresh()
            } catch { self.error = "Couldn’t change the project colour." }
        }
    }
    /// "Choose logo…" in the side panel: the picked image becomes the project's logo, as on its page.
    func changeLogo(_ url: URL, project: PROJProject) {
        Task {
            var item = projects.first { $0.id == project.id } ?? project
            let old = item.logo
            do {
                item.logo = try ProjectLogos.adopt(url, projectID: item.id)
                let args = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
                _ = try await EngineBridge.shared.invoke("project-registry:save", [args])
                if !old.isEmpty, old != item.logo { ProjectLogos.discard(old) }
                refresh()
            } catch { AppModel.shared.buttonActions.problem = "The project logo could not be set." }
        }
    }
}
