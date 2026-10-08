import Foundation

/// The single spelling of Hoot's app-owned folders. Computing paths performs
/// no I/O. A user-selected workspace remains the caller's separate `home`.
public struct RNMHootPaths: Equatable, Sendable {
    public enum Folder: String, Codable, CaseIterable, Sendable {
        case home = "hoot", layer = "hoot-layer", log = "hoot-log"
        public var legacyName: String {
            switch self {
            case .home: "copilot"
            case .layer: "copilot-layer"
            case .log: "copilot-log"
            }
        }
    }

    public let dataRoot: URL
    // Keep the supplied filesystem spelling. Foundation's standardizedFileURL
    // can turn /private/tmp back into the /tmp symlink, causing the migration's
    // ancestor checks to refuse an otherwise safe kernel path. Resolving here
    // would also hide a caller-supplied symlink ancestor from those checks.
    public init(dataRoot: URL) { self.dataRoot = dataRoot }
    public init(userData: String) { self.init(dataRoot: URL(fileURLWithPath: userData, isDirectory: true)) }
    public func directory(_ folder: Folder) -> URL { dataRoot.appendingPathComponent(folder.rawValue, isDirectory: true) }
    public var home: URL { directory(.home) }
    public var layer: URL { directory(.layer) }
    public var log: URL { directory(.log) }
    public var memory: URL { home.appendingPathComponent("memory", isDirectory: true) }
    public var memoryIndex: URL { memory.appendingPathComponent("MEMORY.md") }
    public var instructions: URL { layer.appendingPathComponent("instructions.md") }
    public var tools: URL { layer.appendingPathComponent("tools.md") }
    // The composed filename is generated, so it can change without moving a
    // person's file; `copilot.md` remains preserved in migrated data.
    public var composed: URL { layer.appendingPathComponent("hoot.md") }
    public var actions: URL { log.appendingPathComponent("actions.jsonl") }
    public var screenshots: URL { home.appendingPathComponent("screenshots", isDirectory: true) }
    public var runs: URL { home.appendingPathComponent("runs", isDirectory: true) }
    public var migrationJournal: URL { dataRoot.appendingPathComponent(".hoot-migration.json") }
    public var migrationLog: URL { dataRoot.appendingPathComponent("hoot-migration.jsonl") }
    public var migrationLock: URL { dataRoot.appendingPathComponent(".hoot-migration.lock") }
    public func legacyDirectory(_ folder: Folder) -> URL { dataRoot.appendingPathComponent(folder.legacyName, isDirectory: true) }
}
