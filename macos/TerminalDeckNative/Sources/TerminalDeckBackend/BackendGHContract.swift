import Foundation
import TerminalDeckNativeCore

/// One native API owner serves the panel and MCP. Credentials never enter
/// arguments or results. Both callers must finish their approval gate first.
public protocol BackendGHWorkspaceServing: Sendable {
    func perform(operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue
}

public enum BackendGHOperation: String, CaseIterable, Sendable {
    case pullsList = "pulls.list", pullsDetail = "pulls.detail", pullsFiles = "pulls.files"
    case pullsChecks = "pulls.checks", pullsComments = "pulls.comments", pullsComment = "pulls.comment"
    case pullsReview = "pulls.review", pullsMerge = "pulls.merge", pullsUpdate = "pulls.update", pullsCreate = "pulls.create"
    case issuesList = "issues.list", issuesDetail = "issues.detail", issuesComments = "issues.comments"
    case issuesComment = "issues.comment", issuesCreate = "issues.create", issuesAssign = "issues.assign"
    case issuesLabels = "issues.labels", issuesUpdate = "issues.update"
    case actionsRuns = "actions.runs", actionsJobs = "actions.jobs", actionsLogs = "actions.logs"
    case actionsRerun = "actions.rerun", actionsCancel = "actions.cancel"
    case reposList = "repos.list", reposBranches = "repos.branches", reposCommits = "repos.commits"
    case reposReleases = "repos.releases", reposDraftRelease = "repos.draftRelease", reposClone = "repos.clone"
    case notificationsList = "notifications.list", notificationsRead = "notifications.read"

    public var isWrite: Bool {
        switch self {
        case .pullsComment, .pullsReview, .pullsMerge, .pullsUpdate, .pullsCreate,
             .issuesComment, .issuesCreate, .issuesAssign, .issuesLabels, .issuesUpdate,
             .actionsRerun, .actionsCancel, .reposDraftRelease, .reposClone, .notificationsRead: true
        default: false
        }
    }
}
