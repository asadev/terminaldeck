import Foundation

extension TaskFields {
    // MARK: Rows

    /// A field from the engine. An unknown kind is dropped, not guessed.
    public static func decode(_ raw: Any?) -> TaskField? {
        guard let o = raw as? [String: Any], let id = o["id"] as? String, let kind = (o["kind"] as? String).flatMap(FieldKind.init(rawValue:)) else {
            return nil
        }
        let config = (try? normaliseConfig(kind, CrmValue(o["config"])).get()) ?? defaultConfig(kind)
        return TaskField(id: id, taskId: o["taskId"] as? String ?? "", label: o["label"] as? String ?? "", kind: kind, config: config,
                         value: CrmValue(o["value"]), sortOrder: (o["sortOrder"] as? NSNumber)?.doubleValue,
                         createdBy: o["createdBy"] as? String, createdAt: o["createdAt"] as? String ?? "", updatedAt: o["updatedAt"] as? String)
    }

    public static func decodeAuto(_ raw: Any?) -> AutoProgress? {
        guard let o = raw as? [String: Any] else { return nil }
        let s = o["subtasks"] as? [String: Any] ?? [:]
        let c = o["checklists"] as? [String: Any] ?? [:]
        func n(_ d: [String: Any], _ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
        return AutoProgress(subtasksDone: n(s, "done"), subtasksTotal: n(s, "total"), checklistsDone: n(c, "done"), checklistsTotal: n(c, "total"))
    }

    /// Sorted as stored: sort order ascending (none last), then oldest first.
    public static func sorted(_ rows: [TaskField]) -> [TaskField] {
        rows.sorted { a, b in
            let x = a.sortOrder ?? 9_007_199_254_740_991
            let y = b.sortOrder ?? 9_007_199_254_740_991
            if x != y { return x < y }
            return a.createdAt < b.createdAt
        }
    }
}

public indirect enum FormulaAst: Equatable, Sendable {
    case num(Double)
    case ref(String)
    case neg(FormulaAst)
    case bin(Character, FormulaAst, FormulaAst)
    case call(String, [FormulaAst])
}
