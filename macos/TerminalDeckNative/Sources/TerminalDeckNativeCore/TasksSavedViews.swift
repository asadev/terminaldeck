import Foundation

public struct TasksSavedView: Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var view: TasksViewState
    public init(id: String = UUID().uuidString.lowercased(), name: String, view: TasksViewState) {
        self.id = id; self.name = name; self.view = view
    }
    public var json: [String: Any] { ["id": id, "name": name, "view": view.json] }
    public static func read(_ raw: Any?) -> [Self] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        var ids = Set<String>()
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
                  let name = row["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Self(id: id, name: name, view: TasksViewState.read(row["view"]))
        }
    }
}

public enum TasksBulkTags {
    public static func apply(_ tags: [String], to existing: [String], mode: String) -> [String] {
        var seen = Set<String>()
        let clean = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let result: [String]
        switch mode {
        case "remove": result = existing.filter { !clean.contains($0) }
        case "replace": result = clean
        case "clear": result = []
        default: result = existing + clean
        }
        return result.filter { seen.insert($0).inserted }
    }
}
