import Foundation
import TerminalDeckNativeCore

/// Additive native tools; github.look/github.connect remain owned by their
/// existing source catalogue. No credentials or alternate sign-in are exposed.
public enum BackendGHMCPCatalogue {
    public struct Entry: Sendable {
        public let operation: BackendGHOperation
        public let title: String
        public let description: String
        public let schema: NativeRPCValue
        public var id: String { "github." + operation.rawValue }
        public var tier: BackendMCPTier { operation.isWrite ? .alter : .read }
        public func specification() throws -> BackendMCPTool {
            try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"),
                description: description, inputSchema: schema, tier: tier)
        }
    }

    public static func entries() -> [Entry] {
        let repo = text(201, description: "GitHub repository as owner/name."), body = text(65_536, empty: true)
        let title = text(256), branch = text(256), identifier = integer(1, 9_007_199_254_740_991)
        let state = choice(["open", "closed", "all"]), editableState = choice(["open", "closed"])
        let page: [(String, NativeRPCValue)] = [
            ("page", integer(1, 10_000).setting("default", .number(1))),
            ("perPage", integer(1, 100).setting("default", .number(30)))
        ]
        let numbered: [(String, NativeRPCValue)] = [("repo", repo), ("number", identifier)]
        let names = list(text(100), maximum: 100)
        let comments = list(object([
            ("path", text(4_096)), ("body", text(65_536)), ("line", integer(1, 10_000_000)),
            ("side", choice(["LEFT", "RIGHT"])), ("startLine", integer(1, 10_000_000)),
            ("startSide", choice(["LEFT", "RIGHT"]))
        ], required: ["path", "body", "line", "side"]), maximum: 100)
        func entry(_ operation: BackendGHOperation, _ title: String, _ description: String,
                   _ properties: [(String, NativeRPCValue)], _ required: [String] = []) -> Entry {
            let context = ("projectPath", text(4_096, description: "Project folder from projects.list. Required for session callers; the repo must match this granted project."))
            return Entry(operation: operation, title: title, description: description,
                         schema: object(properties + [context], required: required))
        }
        return [
            entry(.pullsList, "List pull requests", "List your pull requests, requests for your review, or a repository's pull requests. Returns items, page and hasMore; repo scope is the default.", [("repo", repo), ("scope", choice(["repo", "mine", "review-requested"]).setting("default", .string("repo"))), ("state", state)] + page),
            entry(.pullsDetail, "Read a pull request", "Read the pull request's description, branches and merge state inside the app.", numbered, ["repo", "number"]),
            entry(.pullsFiles, "Read changed files", "Read a page of changed files and their available diff patches. GitHub can omit patches for binary or large files.", numbered + page, ["repo", "number"]),
            entry(.pullsChecks, "Read pull request checks", "Read check runs and commit statuses for the pull request's head commit.", numbered + page, ["repo", "number"]),
            entry(.pullsComments, "Read pull request comments", "Read conversation comments, line comments and reviews, with their kind and chronology.", numbered + page, ["repo", "number"]),
            entry(.pullsComment, "Comment on a pull request", "Post a conversation comment. Asks the person first.", numbered + [("body", text(65_536))], ["repo", "number", "body"]),
            entry(.pullsReview, "Review a pull request", "Approve, request changes, or submit a review with optional native line comments. Asks the person first.", numbered + [("event", choice(["APPROVE", "REQUEST_CHANGES", "COMMENT"])), ("body", body), ("comments", comments), ("commitId", text(64))], ["repo", "number", "event"]),
            entry(.pullsMerge, "Merge a pull request", "Merge using merge, squash or rebase. Optionally refuse if the head has changed. Asks the person first.", numbered + [("mergeMethod", choice(["merge", "squash", "rebase"]).setting("default", .string("merge"))), ("expectedHeadSHA", text(64))], ["repo", "number"]),
            entry(.pullsUpdate, "Update a pull request", "Edit its title, description or base branch, or close or reopen it. Supply at least one change. Asks the person first.", numbered + [("title", title), ("body", body), ("state", editableState), ("base", branch)], ["repo", "number"]),
            entry(.pullsCreate, "Create a pull request", "Create a pull request from an existing head branch to a base branch. Asks the person first.", [("repo", repo), ("title", title), ("body", body), ("head", branch), ("base", branch), ("draft", bool())], ["repo", "title", "head", "base"]),
            entry(.issuesList, "List issues", "List and filter repository issues by state, assignee and labels. Search text cannot add scope qualifiers or operators. Pull requests are excluded.", [("repo", repo), ("state", state), ("assignee", text(100)), ("labels", names), ("query", text(500))] + page, ["repo"]),
            entry(.issuesDetail, "Read an issue", "Read an issue's description, assignees, labels and state.", numbered, ["repo", "number"]),
            entry(.issuesComments, "Read issue comments", "Read a page of conversation comments on an issue.", numbered + page, ["repo", "number"]),
            entry(.issuesComment, "Comment on an issue", "Post an issue comment. Asks the person first.", numbered + [("body", text(65_536))], ["repo", "number", "body"]),
            entry(.issuesCreate, "Create an issue", "Create an issue with optional assignees and labels. Asks the person first.", [("repo", repo), ("title", title), ("body", body), ("assignees", list(text(100), maximum: 10)), ("labels", names)], ["repo", "title"]),
            entry(.issuesAssign, "Assign an issue", "Replace an issue's assignees with the supplied list; an empty list removes all assignees. Asks the person first.", numbered + [("assignees", list(text(100), maximum: 10))], ["repo", "number", "assignees"]),
            entry(.issuesLabels, "Set issue labels", "Replace the issue's labels with the supplied list; an empty list removes all labels. Asks the person first.", numbered + [("labels", names)], ["repo", "number", "labels"]),
            entry(.issuesUpdate, "Update an issue", "Edit its title or description, or close or reopen it. Supply at least one change. Asks the person first.", numbered + [("title", title), ("body", body), ("state", editableState)], ["repo", "number"]),
            entry(.actionsRuns, "List CI runs", "List workflow runs for a repository, branch, head commit or pull request; runId refreshes one exact run in a one-item envelope.", [("repo", repo), ("runId", identifier), ("number", identifier), ("branch", branch), ("headSHA", text(64)), ("status", choice(["queued", "in_progress", "completed", "waiting", "requested", "pending", "success", "failure", "neutral", "cancelled", "skipped", "timed_out", "action_required", "stale"]))] + page, ["repo"]),
            entry(.actionsJobs, "Read CI jobs", "Read a page of jobs for one workflow run.", [("repo", repo), ("runId", identifier)] + page, ["repo", "runId"]),
            entry(.actionsLogs, "Read a CI job's logs", "Read plain logs for one job, optionally from a byte cursor. Native screens stream the text; this tool returns one bounded result and a next cursor.", [("repo", repo), ("jobId", identifier), ("cursor", integer(0, 2 * 1024 * 1024))], ["repo", "jobId"]),
            entry(.actionsRerun, "Rerun failed CI jobs", "Rerun the failed jobs in one workflow run. Asks the person first.", [("repo", repo), ("runId", identifier)], ["repo", "runId"]),
            entry(.actionsCancel, "Cancel a CI run", "Cancel one workflow run. Asks the person first.", [("repo", repo), ("runId", identifier)], ["repo", "runId"]),
            entry(.reposList, "List repositories", "List repositories accessible to the app's existing GitHub account. Session callers cannot read this global list.", page),
            entry(.reposBranches, "List branches", "Read a page of branches in a repository.", [("repo", repo)] + page, ["repo"]),
            entry(.reposCommits, "Read recent commits", "Read a page of recent commits, optionally for a branch.", [("repo", repo), ("branch", branch)] + page, ["repo"]),
            entry(.reposReleases, "Read releases", "Read a page of repository releases, including drafts visible to the existing account.", [("repo", repo)] + page, ["repo"]),
            entry(.reposDraftRelease, "Create a draft release", "Create a draft release for a tag or target commit. It remains a draft. Asks the person first.", [("repo", repo), ("tagName", text(256)), ("name", title), ("body", body), ("targetCommitish", branch), ("prerelease", bool())], ["repo", "tagName"]),
            entry(.reposClone, "Clone a repository", "Clone into a new directory beneath an app-granted project folder and add it as a project. Reuses the existing GitHub account and asks the person first. Available to local people and access-key callers.", [("repo", repo), ("parentPath", text(4_096)), ("directoryName", text(128)), ("branch", branch)], ["repo", "parentPath", "directoryName"]),
            entry(.notificationsList, "Read the GitHub inbox", "Read a page of GitHub notifications, optionally for one repository. This global inbox is unavailable to sessions.", [("repo", repo), ("all", bool()), ("participating", bool()), ("since", text(64)), ("before", text(64))] + page),
            entry(.notificationsRead, "Mark a notification read", "Mark one inbox thread read. Asks the person first. This global inbox is unavailable to sessions.", [("threadId", text(100))], ["threadId"])
        ]
    }

    private static func text(_ maximum: Int, empty: Bool = false, description: String? = nil) -> NativeRPCValue {
        var result = NativeRPCValue.object([.init("type", .string("string")), .init("maxLength", .number(Double(maximum)))])
        if !empty { result = result.setting("minLength", .number(1)) }
        if let description { result = result.setting("description", .string(description)) }
        return result
    }
    private static func integer(_ minimum: Int, _ maximum: Int) -> NativeRPCValue {
        .object([.init("type", .string("integer")), .init("minimum", .number(Double(minimum))), .init("maximum", .number(Double(maximum)))])
    }
    private static func bool() -> NativeRPCValue { .object([.init("type", .string("boolean"))]) }
    private static func choice(_ values: [String]) -> NativeRPCValue {
        .object([.init("type", .string("string")), .init("enum", .array(values.map(NativeRPCValue.string)))])
    }
    private static func list(_ items: NativeRPCValue, maximum: Int) -> NativeRPCValue {
        .object([.init("type", .string("array")), .init("items", items), .init("maxItems", .number(Double(maximum)))])
    }
    private static func object(_ properties: [(String, NativeRPCValue)], required: [String]) -> NativeRPCValue {
        .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                 .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
    }
}
