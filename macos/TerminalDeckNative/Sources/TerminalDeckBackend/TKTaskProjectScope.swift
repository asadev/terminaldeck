import Foundation
import TerminalDeckNativeCore

/// Tasks by project for the agent and Hoot task tools (lane TK, 7 Oct 2026).
/// A task belongs to the project folder it was made in (`project`; "" for none —
/// also what an old record without the field reads as). A listing shows the
/// calling session's project unless it asks for every project (`all_projects`)
/// or names another open folder (`project`); a caller with no project of its
/// own (Hoot, an outside app) sees every project, as before.
public enum BackendTaskProjectScope {
    /// The optional listing argument that asks for every project.
    public static let allProjects = "all_projects"

    /// A folder path as compared here: trimmed, without a trailing slash.
    public static func clean(_ path: String) -> String {
        var out = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// The folder is the project folder itself or inside it.
    public static func within(_ folder: String, _ project: String) -> Bool {
        let folder = clean(folder), project = clean(project)
        guard !folder.isEmpty, !project.isEmpty else { return false }
        return folder == project || folder.hasPrefix(project == "/" ? "/" : project + "/")
    }

    /// The calling session's project: the deepest open project holding its folder.
    public static func owningProject(of folder: String, openProjects: [String]) -> String? {
        openProjects.filter { within(folder, $0) }.max { clean($0).count < clean($1).count }.map(clean)
    }

    /// The calling session's project, for `BackendTaskToolAuthority.callerProject`: a task
    /// agent's is its task's project (it may run in a workspace folder of its own);
    /// any other session's is the open project holding its folder; Hoot and outside
    /// callers have none.
    public static func callerProject(sessionID: String, taskProject: String?, sessionFolder: String?, openProjects: [String]) -> String? {
        guard !sessionID.isEmpty else { return nil }
        if let taskProject, !clean(taskProject).isEmpty { return clean(taskProject) }
        guard let sessionFolder else { return nil }
        return owningProject(of: sessionFolder, openProjects: openProjects)
    }

    /// The project a listing covers; nil means every project.
    public static func listing(_ args: NativeRPCValue, callerProject: String?) -> String? {
        if args[allProjects].bool == true { return nil }
        if let named = args["project"].string, !clean(named).isEmpty { return clean(named) }
        return callerProject.map(clean).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A task shows in a listing of this project (nil: every project).
    public static func includes(_ task: BackendTaskRecord, project: String?) -> Bool {
        guard let project else { return true }
        return within(task.project, project)
    }

    /// A goal shows when it is this project's or has no project at all.
    public static func includes(goal: NativeRPCValue, project: String?) -> Bool {
        guard let project, let own = goal["project"].string, !clean(own).isEmpty else { return true }
        return within(own, project)
    }

    /// A new task made by a tool call gets the calling session's project unless the
    /// call names one (an explicit "" keeps it without a project).
    public static func createPatch(_ patch: NativeRPCValue, callerProject: String?) -> NativeRPCValue {
        guard !patch.has("project"), let home = callerProject.map(clean), !home.isEmpty else { return patch }
        return patch.setting("project", .string(home))
    }
}
