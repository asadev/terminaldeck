import Foundation
import TerminalDeckNativeCore

/// The task project comes from an app-issued session lease, not tool arguments.
/// A task can reach its logical project and the actual workspace it owns.
public enum BackendTAGTaskProjectScope {
    public static func roots(caller: BackendDeckCoreSecurityCaller, cwd: String) throws -> [String] {
        guard let taskProject = caller.taskProject else { return [caller.projectRoot ?? cwd] }
        guard caller.kind == .session, taskProject.hasPrefix("/"), !taskProject.contains("\0"),
              let projectRoot = caller.projectRoot, canonical(projectRoot) == canonical(taskProject), cwd.hasPrefix("/"), !cwd.contains("\0") else {
            throw NativeRPCError(code: "access-denied", message: "The task project does not match this session's issued project grant.")
        }
        return canonical(taskProject) == canonical(cwd) ? [taskProject] : [taskProject, cwd]
    }
    public static func folders(openProjects: [String], caller: BackendDeckCoreSecurityCaller, cwd: String) throws -> [String] {
        let roots = try roots(caller: caller, cwd: cwd)
        var folders = openProjects.filter { folder in roots.contains { BackendCompositionAuthority.within(folder, $0) } }
        if caller.taskProject != nil, !folders.contains(where: { canonical($0) == canonical(cwd) }) { folders.append(cwd) }
        return folders
    }
    public static func isOwnedWorkspace(_ folder: String, caller: BackendDeckCoreSecurityCaller, cwd: String) -> Bool {
        caller.kind == .session && caller.taskProject != nil && (try? roots(caller: caller, cwd: cwd)) != nil && canonical(folder) == canonical(cwd)
    }
    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
}
