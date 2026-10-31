import Foundation

/// Page pins are separate from session pins, notifications and Settings.
public struct Sidebar21Page: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public init(_ id: String, _ title: String, _ symbol: String) {
        self.id = id; self.title = title; self.symbol = symbol
    }
    public var item: SidebarItem { .init(id: id, title: title, symbol: symbol, kind: .panel) }
}

public enum Sidebar21Pages {
    public static let projectsID = "sidebar-projects"
    public static let defaults = ["agents-all", "tasks"]
    /// Exactly the previous native rail's drawing order. Projects was a section.
    public static let upgradeOrder = Array(SIDEBARLayout.main.dropFirst()) + [projectsID]
        + SIDEBARLayout.machines + SIDEBARLayout.integrations
    public static let standard: [Sidebar21Page] = [
        .init("agents-all", "Agents", "person.3"),
        .init("tasks", "Tasks", "list.bullet"),
        .init("artifacts", "Artifacts", "doc.richtext"),
        .init(projectsID, "Projects", "folder"),
        .init("servers", "Servers", "server.rack"),
        .init("devices", "Devices", "laptopcomputer.and.iphone"),
        .init("receiver", "Receiver", "antenna.radiowaves.left.and.right"),
        .init("mcp", "MCP servers", "puzzlepiece.extension"),
        .init("store", "Store", "bag"),
        .init("overview", "Overview", "square.grid.2x2")
    ]
    public static func catalogue(_ state: SidebarState?) -> [Sidebar21Page] {
        standard
    }
    public static func unique(_ ids: [String], pages: [Sidebar21Page]) -> [String] {
        let allowed = Set(pages.map(\.id)); var seen = Set<String>()
        return ids.filter { allowed.contains($0) && seen.insert($0).inserted }
    }
    public static func selection(_ id: String?) -> String? {
        // Routines and Skills have their own pins now; they no longer light up Agents.
        ["agents-org", "agents-watch"].contains(id ?? "") ? "agents-all" : id
    }
    public static func stepped(_ selected: String?, delta: Int, pages: [Sidebar21Page]) -> String? {
        guard !pages.isEmpty else { return nil }
        let current = pages.firstIndex { $0.id == selected }
        let next = current.map { min(max($0 + delta, 0), pages.count - 1) } ?? (delta > 0 ? 0 : pages.count - 1)
        return pages[next].id
    }
}
