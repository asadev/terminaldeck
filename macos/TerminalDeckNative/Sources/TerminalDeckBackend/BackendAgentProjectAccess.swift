import Foundation
import TerminalDeckNativeCore

/// Project membership is taken from the owner's registry, never a projectId
/// supplied by the caller. The issued root still controls which project it is.
public enum BackendAgentProjectAccess {
    public static func roots(caller: BackendDeckCoreSecurityCaller, cwd: String, projects: [PROJProject] = PROJProjects.defaults) throws -> [String] {
        let issued = try BackendTAGTaskProjectScope.roots(caller: caller, cwd: cwd)
        guard caller.kind == .session else { return issued }
        var roots = issued
        for root in issued {
            let matching = projects.filter { $0.id != PROJProjects.independentID && $0.folders.contains { within(root, $0) } }
            // A nested folder belongs to the most specific registered project.
            let project = matching.max { left, right in
                (left.folders.filter { within(root, $0) }.map { canonical($0).count }.max() ?? 0)
                    < (right.folders.filter { within(root, $0) }.map { canonical($0).count }.max() ?? 0)
            }
            if let project { roots.append(contentsOf: project.folders) }
        }
        return Array(Set(roots.map(canonical))).sorted()
    }
    public static func within(_ path: String, _ root: String) -> Bool {
        let path = canonical(path), root = canonical(root)
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
}
