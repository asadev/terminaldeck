import Foundation

/// A stable identity is separate from a project's folder, display name and product name.
public struct PROJProject: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var folders: [String]
    public var icon: String
    public var colour: String
    /// The project's logo: a file name inside the app's own project-logos folder ("" = none,
    /// shown as a letter tile). Never a path into the project.
    public var logo: String
    /// The project's lead (Deck Memory): "" none, `agent:<profile id>` or `session:<session id>`.
    /// Hoot gives the lead goals; the lead runs the project's agents. One per project, changeable.
    public var lead: String
    /// The lead's name when it was chosen: shown when it is not running, and used to find a
    /// restarted lead session again by name.
    public var leadName: String
    public init(id: String, name: String, folders: [String] = [], icon: String = "folder", colour: String = "", logo: String = "",
                lead: String = "", leadName: String = "") {
        self.id = id; self.name = name; self.folders = folders; self.icon = icon; self.colour = colour; self.logo = logo
        self.lead = lead; self.leadName = leadName
    }
    private enum CodingKeys: String, CodingKey { case id, name, folders, icon, colour, logo, lead, leadName }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        name = try fields.decode(String.self, forKey: .name)
        folders = try fields.decodeIfPresent([String].self, forKey: .folders) ?? []
        icon = try fields.decodeIfPresent(String.self, forKey: .icon) ?? "folder"
        colour = try fields.decodeIfPresent(String.self, forKey: .colour) ?? ""
        logo = try fields.decodeIfPresent(String.self, forKey: .logo) ?? ""
        lead = try fields.decodeIfPresent(String.self, forKey: .lead) ?? ""
        leadName = try fields.decodeIfPresent(String.self, forKey: .leadName) ?? ""
    }
    public var wireValue: NativeRPCValue {
        .object([.init("id", .string(id)), .init("name", .string(name)), .init("folders", .array(folders.map(NativeRPCValue.string))), .init("icon", .string(icon)), .init("colour", .string(colour)), .init("logo", .string(logo)),
                 .init("lead", .string(lead)), .init("leadName", .string(leadName))])
    }
}

public enum PROJProjects {
    public static func registeredProjects(_ snapshot: NativeRPCValue) throws -> [PROJProject] {
        guard let rows = snapshot["projects"].elements else {
            throw NativeRPCError.invalidArguments("The project list could not be read.")
        }
        return try rows.map { try JSONDecoder().decode(PROJProject.self, from: $0.encodedJSON()) }
    }

    /// Shared wire identity contract. Display names can use ordinary human text.
    public static func isValidID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        func letterOrDigit(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
        guard let first = bytes.first, letterOrDigit(first) else { return false }
        return bytes.dropFirst().allSatisfy { letterOrDigit($0) || $0 == 45 }
    }

    public static let independentID = "independent"
    public static let colours = ["blue", "purple", "pink", "orange", "yellow", "green", "teal", "graphite"]
    /// The one project every install has: work that belongs to no project.
    public static let independent = PROJProject(id: independentID, name: "Independent", icon: "square.grid.2x2", colour: "graphite")

    /// The person's registered projects, LIVE: the project registry publishes its list here when it loads
    /// and on every change, so every folder match and name in the app follows the person's own projects.
    /// Nothing is built in: a new install has Independent only, until the person adds a project.
    /// (11 Oct, Asad's decision: this used to be a fixed list naming two folders of the builder's own Mac.)
    public static var defaults: [PROJProject] {
        if let scoped = PROJRegisteredProjects.scoped { return scoped }
        return PROJRegisteredProjects.current
    }
    /// Called by the project registry only (load and every save). Independent is always kept.
    public static func publishRegistered(_ projects: [PROJProject]) {
        PROJRegisteredProjects.current = projects.contains { $0.id == independentID } ? projects : projects + [independent]
    }
    /// Explicit IDs survive a temporarily missing registry entry. Older data uses the
    /// longest matching folder, with a path-component boundary, then Independent.
    public static func resolve(projectID: String?, folder: String?, projects: [PROJProject] = defaults) -> String {
        if let id = projectID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
        guard let folder, !folder.isEmpty else { return independentID }
        let path = normalize(folder)
        var bestID = independentID
        var bestLength = -1
        for project in projects {
            for folder in project.folders {
                let candidate = normalize(folder)
                guard !candidate.isEmpty else { continue }
                let prefix = candidate == "/" ? "/" : candidate + "/"
                guard path == candidate || path.hasPrefix(prefix) else { continue }
                let length = candidate.count
                if length > bestLength || (length == bestLength && project.id < bestID) {
                    bestID = project.id; bestLength = length
                }
            }
        }
        return bestID
    }
    public static func name(for id: String, projects: [PROJProject] = defaults) -> String {
        projects.first { $0.id == id }?.name ?? id
    }
    public static func normalize(_ folder: String) -> String {
        guard !folder.isEmpty else { return "" }
        return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
    }
}

/// Holds the live copy behind `PROJProjects.defaults` (one per process; read from any thread).
public enum PROJRegisteredProjects {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: [PROJProject] = [PROJProjects.independent]
    static var current: [PROJProject] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    /// For tests and previews: a list used instead of the live one by this task and the work it starts.
    @TaskLocal public static var scoped: [PROJProject]?
}
