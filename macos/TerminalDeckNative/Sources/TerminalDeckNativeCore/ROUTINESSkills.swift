import Foundation

/// One discovered copy. Names are what the existing task runner puts in its brief;
/// ids distinguish the same named skill installed in different projects.
public struct ROUTINESSkill: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var category: String
    public var projectID: String?
    public var source: String
    public var folder: String
    public var builtIn: Bool
    public var catalogueID: String?
    public init(id: String, name: String, summary: String = "", category: String = "Code", projectID: String? = nil,
                source: String, folder: String, builtIn: Bool = false, catalogueID: String? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.category = category; self.projectID = projectID
        self.source = source; self.folder = folder; self.builtIn = builtIn; self.catalogueID = catalogueID
    }
    public var clash: String? {
        SkillCommandNames.note(name, targets: SkillCommandNames.targets(path: folder))
            ?? SkillCommandNames.note(URL(fileURLWithPath: folder).lastPathComponent, targets: SkillCommandNames.targets(path: folder))
    }
    public var wire: NativeRPCValue {
        .object([.init("id", .string(id)), .init("name", .string(name)), .init("summary", .string(summary)),
                 .init("category", .string(category)), .init("projectID", projectID.map(NativeRPCValue.string) ?? .null),
                 .init("source", .string(source)), .init("folder", .string(folder)), .init("builtIn", .bool(builtIn)),
                 .init("catalogueID", catalogueID.map(NativeRPCValue.string) ?? .null),
                 .init("clash", clash.map(NativeRPCValue.string) ?? .null),
                 .init("suggestedName", .string(SkillCommandNames.suggestion(name)))])
    }
    public static func decode(_ value: NativeRPCValue) -> Self? {
        guard let id = value["id"].string, let name = value["name"].string, !id.isEmpty, !name.isEmpty else { return nil }
        return .init(id: id, name: name, summary: value["summary"].string ?? "", category: value["category"].string ?? "Code",
                     projectID: value["projectID"].string, source: value["source"].string ?? "", folder: value["folder"].string ?? "",
                     builtIn: value["builtIn"].bool == true, catalogueID: value["catalogueID"].string)
    }
}

public enum ROUTINESSkillsRules {
    public static let categories = ["All", "Code", "Data", "Messaging", "Release", "Design"]
    public static func filtered(_ rows: [ROUTINESSkill], projectID: String?, query: String, category: String) -> [ROUTINESSkill] {
        rows.filter { row in
            (projectID == nil || row.projectID == nil || row.projectID == projectID)
                && (category == "All" || row.category.caseInsensitiveCompare(category) == .orderedSame)
                && StoreRules.matchesQuery(.init(id: row.id, name: row.name, summary: row.summary, category: row.category,
                                                categoryName: row.category, tags: [row.source]), query)
        }
    }
    /// Change just the selected skill. The whole saved profile, including future
    /// fields unknown to this view, is returned untouched otherwise.
    public static func changing(_ profile: NativeRPCValue, skill: String, assigned: Bool) -> NativeRPCValue {
        var skills = (profile["skills"].elements ?? []).compactMap(\.string)
        if assigned { if !skills.contains(skill) { skills.append(skill) } } else { skills.removeAll { $0 == skill } }
        return profile.setting("skills", .array(skills.map(NativeRPCValue.string)))
    }
    public static func safeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 80, let first = name.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.allSatisfy(allowed.contains) && name != "." && name != ".."
    }
}
