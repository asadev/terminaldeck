import Foundation
import TerminalDeckNativeCore

/// Credential folder grants remain authoritative, including null = all.
public enum BackendTAGProjectGrant {
    public static func permits(_ folder: String, caller: BackendDeckCoreSecurityCaller, openProjects: [String], allowedFolders: [String], ownedWorkspace: Bool = false) -> Bool {
        guard folder.hasPrefix("/"), !folder.contains("\0") else { return false }
        let wanted = canonical(folder)
        if caller.kind == .key {
            return caller.folders.map { roots in roots.contains { within(wanted, canonical($0)) } } ?? true
        }
        return (openProjects.contains { within(wanted, canonical($0)) } || ownedWorkspace)
            && allowedFolders.contains { within(wanted, canonical($0)) }
    }
    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    private static func within(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
}
