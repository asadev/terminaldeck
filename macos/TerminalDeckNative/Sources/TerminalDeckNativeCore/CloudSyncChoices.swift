import Foundation

/// Owner, 15 Nov: "how many things we want to keep in sync ... they can choose inside the device. If one device I don't
/// choose it as sync, it will not be sync for that device ... by default it should be always on."
/// One switch per kind, per device. The choice is kept in one small file of this device (`sync-choices.json` in the
/// app's Cloud folder) and never travels. A kind that is off here neither sends nor takes on this device; nothing is
/// deleted anywhere, and no other device waits for it (the account's "I understand" marks keep travelling, see `rows`).
public enum CloudSyncKind: String, CaseIterable, Codable, Sendable {
    case memory, projects, agents, tasks, instructionFiles, settings, cloudFolder, artifacts, secrets, codeBackup
    /// Sessions and chats (lane/mac-chats, 15 Nov): its switch is `NativeCloudChats.sessionsAndChatsInSync`.
    case sessions

    /// His words.
    public var title: String {
        switch self {
        case .memory: return "Memory"
        case .projects: return "Projects"
        case .agents: return "Agents"
        case .tasks: return "Tasks"
        case .instructionFiles: return "Instruction files"
        case .settings: return "Settings"
        case .cloudFolder: return "Cloud folder"
        case .artifacts: return "Artifacts"
        case .secrets: return "Saved passwords and secret files"
        case .codeBackup: return "Code backup"
        case .sessions: return "Sessions and chats"
        }
    }
    /// Whether this build has the kind at all.
    public var exists: Bool { true }
    /// The list as Settings › Cloud shows it.
    public static var shown: [CloudSyncKind] { allCases.filter(\.exists) }

    /// The Cloud's inventory rows of this kind. Memory's I05 (shared memory settings) is NOT memory's here: it carries
    /// the account's "this device understands" marks that every gate reads, so it runs whenever Cloud is used on this
    /// device, and a kind switched off here never holds the other devices back.
    public var rows: Set<String> {
        switch self {
        case .memory: return Set(CloudBrainMemoryFormat.inventoryRows).subtracting([CloudSyncChoices.accountMarksRow])
        case .projects: return ["I11"]
        case .agents: return ["I10"]
        case .instructionFiles: return ["I09"]
        case .tasks: return ["I12"]
        case .settings: return ["I21"]
        case .artifacts: return ["I23"]
        case .cloudFolder: return ["I24"]
        case .secrets, .codeBackup, .sessions: return []
        }
    }
}

public struct CloudSyncChoices: Codable, Equatable, Sendable {
    /// The memory row that carries the account's shared marks; always on while Cloud is used here.
    public static let accountMarksRow = "I05"
    public static let fileName = "sync-choices.json"
    public static let title = "Keep in sync on this Mac"
    /// Posted on the main queue after screens' choices from another device were written here; `userInfo["keys"]` names
    /// them, so a screen that read its choice once at start reads it again (display only).
    public static let choicesArrived = Notification.Name("terminaldeck.cloud.choicesArrived")

    /// The kinds switched off on this device. Empty = everything on (the default).
    public var off: Set<CloudSyncKind>
    public init(off: Set<CloudSyncKind> = []) { self.off = off }

    public func isOn(_ kind: CloudSyncKind) -> Bool { !off.contains(kind) }
    public func setting(_ kind: CloudSyncKind, on: Bool) -> CloudSyncChoices {
        var next = self
        if on { next.off.remove(kind) } else { next.off.insert(kind) }
        return next
    }
    /// The switched-on rows of this run that this device keeps in sync (`enabled` minus the rows of kinds off here).
    public func rows(_ enabled: Set<String>) -> Set<String> {
        var result = enabled
        for kind in off { result.subtract(kind.rows) }
        if enabled.contains(Self.accountMarksRow) { result.insert(Self.accountMarksRow) }
        return result
    }

    /// The file inside the app's Cloud folder (`NativeCloudLaunch.folder(dataRoot)`), outside every account folder:
    /// the choice belongs to this device, whoever is signed in.
    public static func file(cloudFolder: URL) -> URL { cloudFolder.appendingPathComponent(fileName) }
    /// Missing or unreadable = everything on (never a reason to stop syncing).
    public static func load(_ file: URL) -> CloudSyncChoices {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return .init() }
        return .init(off: Set(saved.off.compactMap(CloudSyncKind.init(rawValue:))))
    }
    public func save(_ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Saved(version: 1, off: off.map(\.rawValue).sorted()))
        try data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    /// Unknown kind names from a newer build are kept out, never a reason to fail.
    private struct Saved: Codable { let version: Int; let off: [String] }
}
