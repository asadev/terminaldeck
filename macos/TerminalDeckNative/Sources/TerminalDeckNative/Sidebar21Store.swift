import Foundation
import Observation
import TerminalDeckNativeCore

@MainActor @Observable
final class Sidebar21Store {
    static let shared = Sidebar21Store(defaults: .standard)
    static let key = "sidebar.pagePins.v1"
    private(set) var ids: [String]
    private(set) var initialized: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.stringArray(forKey: Self.key)
        ids = saved ?? Sidebar21Pages.defaults
        initialized = saved != nil
    }
    func initialize(existingUser: Bool, pages: [Sidebar21Page]) {
        guard !initialized else { return }
        ids = Sidebar21Pages.unique(existingUser ? Sidebar21Pages.upgradeOrder : Sidebar21Pages.defaults, pages: pages)
        initialized = true; save()
    }
    /// Only old, user-written evidence counts. A newly created data directory does not.
    static func isUpgrade(defaults: UserDefaults, dataRoot: URL, state: SidebarState?) -> Bool {
        let oldChoices = ["session-start.defaults.v1", "session-start.lastFolder.v1", "appAppearance",
                          HootSetupMemory.key, SIDEBARPins.key]
        if oldChoices.contains(where: { defaults.object(forKey: $0) != nil }) { return true }
        if state?.allItems.contains(where: { $0.kind == .session }) == true { return true }
        return ["settings.json", "projects.registry.json"].contains {
            FileManager.default.fileExists(atPath: dataRoot.appendingPathComponent($0).path)
        }
    }
    func isPinned(_ id: String) -> Bool { ids.contains(id) }
    func setPinned(_ id: String, pinned: Bool, pages: [Sidebar21Page]) {
        guard pages.contains(where: { $0.id == id }) else { return }
        if pinned { if !ids.contains(id) { ids.append(id) } }
        else { ids.removeAll { $0 == id } }
        initialized = true; save()
    }
    func toggle(_ id: String, pages: [Sidebar21Page]) { setPinned(id, pinned: !isPinned(id), pages: pages) }
    func reorder(_ order: [String]) -> Bool {
        guard order.count == ids.count, Set(order) == Set(ids) else { return false }
        ids = order; initialized = true; save(); return true
    }
    func move(_ source: String, to target: String) -> Bool {
        guard source != target, let from = ids.firstIndex(of: source), let to = ids.firstIndex(of: target) else { return false }
        var order = ids; order.remove(at: from); order.insert(source, at: to)
        return reorder(order)
    }
    private func save() { defaults.set(ids, forKey: Self.key) }
}
