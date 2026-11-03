import Foundation
import TerminalDeckNativeCore

/// An agent row's project. Agent folders are imported from the Agents page (Import…) and kept
/// in step by the folder watchers; no folder is imported at start (11 Oct).
public enum PROJAgentProjects {
    public static func projectID(for row: NativeRPCValue) -> String {
        PROJProjects.resolve(projectID: row["projectIdInferred"].bool == true ? nil : row["projectId"].string,
            folder: row["sourceDirectory"].string ?? row["sourceFile"].string ?? row["defaultProject"].string)
    }
}
