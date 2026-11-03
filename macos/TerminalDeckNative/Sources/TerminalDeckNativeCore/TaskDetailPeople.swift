import Foundation

// MARK: - People

/// One person a task can name: you, Hoot, or one of your task agents.
public struct CrmPerson: Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var initials: String
    /// A palette name (`bg-blue-500` …), as the CRM stores it.
    public var color: String
    public var avatarUrl: String?

    public init(id: String, name: String, initials: String, color: String, avatarUrl: String? = nil) {
        self.id = id
        self.name = name
        self.initials = initials
        self.color = color
        self.avatarUrl = avatarUrl
    }
}

public enum CrmPeople {
    public static let me = "me"
    public static let hoot = "hoot"

    public static let avatarPalette = [
        "bg-blue-500", "bg-violet-500", "bg-emerald-500", "bg-amber-500", "bg-rose-500",
        "bg-sky-500", "bg-indigo-500", "bg-teal-500", "bg-orange-500", "bg-fuchsia-500",
    ]

    /// JavaScript's `(h * 31 + charCode) | 0` over UTF-16, then |h| mod n.
    public static func hashStringToIndex(_ s: String, _ modulo: Int) -> Int {
        var h: Int32 = 0
        for unit in s.utf16 { h = h &* 31 &+ Int32(unit) }
        return Int(abs(Int64(h)) % Int64(modulo))
    }

    public static func deriveInitials(_ name: String?) -> String {
        let safe = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if safe.isEmpty { return "?" }
        let parts = safe.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.isEmpty { return "?" }
        if parts.count == 1 { return String(parts[0].prefix(2)).uppercased() }
        return (String(parts[0].prefix(1)) + String(parts[1].prefix(1))).uppercased()
    }

    public static func person(_ id: String, _ name: String) -> CrmPerson {
        CrmPerson(id: id, name: name, initials: id == me ? "ME" : deriveInitials(name),
                  color: avatarPalette[hashStringToIndex(id, avatarPalette.count)])
    }

    /// Everyone a local task can name: you, Hoot, then your task agents in their own order.
    public static func local(_ agents: [(id: String, name: String)]) -> [CrmPerson] {
        [person(me, "You"), person(hoot, "Hoot")] + agents.map { person($0.id, $0.name) }
    }
}

/// Who is on a task: the main person, then the others.
public struct TaskPeople: Equatable, Sendable {
    public var primary: CrmPerson?
    public var others: [CrmPerson]

    public init(primary: CrmPerson?, others: [CrmPerson] = []) {
        self.primary = primary
        self.others = others
    }

    public var list: [CrmPerson] { (primary.map { [$0] } ?? []) + others }
    public func has(_ id: String) -> Bool { primary?.id == id || others.contains { $0.id == id } }

    public func adding(_ person: CrmPerson) -> TaskPeople {
        if has(person.id) { return self }
        if primary == nil { return TaskPeople(primary: person, others: others) }
        return TaskPeople(primary: primary, others: others + [person])
    }

    /// Taking the main person off promotes the next face.
    public func removing(_ id: String) -> TaskPeople {
        if primary?.id == id { return TaskPeople(primary: others.first, others: Array(others.dropFirst())) }
        return TaskPeople(primary: primary, others: others.filter { $0.id != id })
    }

    /// An item's own person if they are on the task, else the task's main person (inherited).
    public func assignee(for itemAssignee: String?) -> (person: CrmPerson?, inherited: Bool) {
        if let id = itemAssignee, let own = list.first(where: { $0.id == id }) { return (own, false) }
        return (primary, true)
    }
}
