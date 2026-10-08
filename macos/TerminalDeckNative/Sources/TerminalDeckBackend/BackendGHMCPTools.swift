import Foundation
import TerminalDeckNativeCore

/// All operations enter the same native GitHub service after the existing
/// caller, folder and person-consent gates. This owns no tokens or approval UI.
public enum BackendGHMCPTools {
    public typealias RepoForFolder = @Sendable (String) async throws -> String

    public static func definitions(service: any BackendGHWorkspaceServing,
                                   access: BackendDeckToolsAppAccess,
                                   repoForFolder: RepoForFolder? = nil) throws -> [BackendDeckToolsDefinition] {
        try BackendGHMCPCatalogue.entries().map { entry in
            let spec = try entry.specification()
            return BackendDeckToolsDefinition(spec: spec, title: entry.title, index: entry.description) { context, arguments in
                do {
                    try checkCancellation(context)
                    guard context.allowedTools.contains(spec.id) || context.allowedTools.contains(spec.wireName),
                          context.allowedTiers.contains(spec.tier) else {
                        throw NativeRPCError(code: "not-granted", message: "This caller has not been given access to this GitHub action.")
                    }
                    try validate(entry: entry, arguments: arguments)
                    var prepared = try await scopedArguments(operation: entry.operation, arguments: arguments,
                        context: context, access: access, repoForFolder: repoForFolder)
                    try checkCancellation(context)
                    // The real central gate binds the raw call for its review
                    // preview. These metadata inputs and all result notes omit
                    // comment/review text and identities.
                    let safeArguments = redacted(prepared)
                    try await access.authorize(context, spec.id, safeArguments, spec.tier,
                                               summary(operation: entry.operation, arguments: prepared), entry.operation.isWrite)
                    try checkCancellation(context)
                    // Caller identity, folder grant and repo mapping may have
                    // changed while the person was reviewing the request.
                    prepared = try await scopedArguments(operation: entry.operation, arguments: prepared,
                        context: context, access: access, repoForFolder: repoForFolder)
                    try checkCancellation(context)
                    let rpc = try await access.rpc(context)
                    try checkCancellation(context)
                    let value = try await perform(service: service, operation: entry.operation,
                                                  arguments: prepared, context: context, rpc: rpc)
                    try checkCancellation(context)
                    try await access.record(context, spec.id, safeArguments,
                        resultSummary(operation: entry.operation, arguments: prepared, value: value))
                    return .value(value)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    let failure = NativeRPCError.wrapping(error)
                    return BackendMCPToolReply(content: [.object([.init("type", .string("text")), .init("text", .string(failure.message))])],
                        structuredContent: .object([.init("ok", .bool(false)), .init("error", .string(failure.message)),
                            .init("code", .string(failure.code)), .init("refusal", failure.code.hasPrefix("not-") ? .string(failure.code) : .null)]), isError: true)
                }
            }
        }
    }

    public static func validate(operation: BackendGHOperation, arguments: NativeRPCValue) throws {
        guard let entry = BackendGHMCPCatalogue.entries().first(where: { $0.operation == operation }) else {
            throw NativeRPCError(code: "unavailable", message: "This GitHub action is unavailable.")
        }
        try validate(entry: entry, arguments: arguments)
    }

    /// The composition's core policy can call this before its base-tier
    /// consent prompt; the handler repeats it around approval before effects.
    public static func precheck(operation: BackendGHOperation, arguments: NativeRPCValue,
                                context: BackendMCPCallContext, access: BackendDeckToolsAppAccess,
                                repoForFolder: RepoForFolder? = nil) async throws {
        try checkCancellation(context)
        try validate(operation: operation, arguments: arguments)
        _ = try await scopedArguments(operation: operation, arguments: arguments,
            context: context, access: access, repoForFolder: repoForFolder)
        try checkCancellation(context)
    }

    public static func redacted(_ arguments: NativeRPCValue) -> NativeRPCValue {
        var safe = arguments
        for field in ["body", "title", "name"] where arguments.has(field) {
            safe = safe.setting(field, .string("[\(arguments[field].string?.utf16.count ?? 0) characters]"))
        }
        if let comments = arguments["comments"].elements {
            safe = safe.setting("comments", .object([.init("count", .number(Double(comments.count)))]))
        }
        return safe
    }

    public static func summary(operation: BackendGHOperation, arguments: NativeRPCValue) -> String {
        let repo = arguments["repo"].string ?? "GitHub", number = arguments["number"].number.map { String(Int64($0)) } ?? "?"
        switch operation {
        case .pullsComment: return "Post the proposed comment on pull request #\(number) in \(repo)."
        case .pullsReview:
            let action = arguments["event"].string == "APPROVE" ? "Approve" : arguments["event"].string == "REQUEST_CHANGES" ? "Request changes on" : "Review"
            return "\(action) pull request #\(number) in \(repo), with \(arguments["comments"].elements?.count ?? 0) line comments."
        case .pullsMerge: return "Merge pull request #\(number) in \(repo) using \(arguments["mergeMethod"].string ?? "merge")."
        case .pullsUpdate: return "\(stateAction(arguments, noun: "Update")) pull request #\(number) in \(repo)."
        case .pullsCreate: return "Create a pull request in \(repo) from \(arguments["head"].string ?? "?") to \(arguments["base"].string ?? "?")."
        case .issuesComment: return "Post the proposed comment on issue #\(number) in \(repo)."
        case .issuesCreate: return "Create the proposed issue in \(repo)."
        case .issuesAssign: return "Replace the assignees on issue #\(number) in \(repo)."
        case .issuesLabels: return "Replace the labels on issue #\(number) in \(repo)."
        case .issuesUpdate: return "\(stateAction(arguments, noun: "Update")) issue #\(number) in \(repo)."
        case .actionsRerun: return "Rerun failed jobs in CI run \(identifier(arguments, "runId")) in \(repo)."
        case .actionsCancel: return "Cancel CI run \(identifier(arguments, "runId")) in \(repo)."
        case .reposDraftRelease: return "Create a draft release for tag \(arguments["tagName"].string ?? "?") in \(repo)."
        case .reposClone: return "Clone \(repo) into \(arguments["parentPath"].string ?? "?")/\(arguments["directoryName"].string ?? "?") and add it as a project."
        case .notificationsRead: return "Mark GitHub notification \(arguments["threadId"].string ?? "?") read."
        default: return "Read \(operation.rawValue.replacingOccurrences(of: ".", with: " ")) for \(repo)."
        }
    }

    private static func validate(entry: BackendGHMCPCatalogue.Entry, arguments: NativeRPCValue) throws {
        try BackendDockerMCPArguments.validate(arguments, schema: entry.schema)
        if arguments.has("repo") { _ = try BackendGHAPIValidation.repo(arguments) }
        for field in ["repo", "title", "name", "head", "base", "branch", "tagName", "targetCommitish", "projectPath", "parentPath", "directoryName", "assignee"] {
            if let text = arguments[field].string, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                throw NativeRPCError.invalidArguments("\(field) must not be blank or contain control characters.")
            }
        }
        if entry.operation == .pullsList, (arguments["scope"].string ?? "repo") == "repo", !arguments.has("repo") {
            throw NativeRPCError.invalidArguments("repo is required when listing a repository's pull requests.")
        }
        for field in ["body", "title", "name", "projectPath", "parentPath", "directoryName"] where arguments.has(field) {
            let maximum = field == "body" ? 65_536 : ["projectPath", "parentPath"].contains(field) ? 4_096 : field == "directoryName" ? 128 : 256
            _ = try BackendGHAPIValidation.text(arguments, field, required: field != "body", maximum: maximum)
        }
        if entry.operation == .pullsComment || entry.operation == .issuesComment {
            _ = try BackendGHAPIValidation.text(arguments, "body", required: true)
        }
        for field in ["head", "base", "branch", "tagName", "targetCommitish"] {
            if let ref = arguments[field].string { _ = try BackendGHAPIValidation.ref(ref, allowOwner: field == "head") }
        }
        if entry.operation == .pullsUpdate || entry.operation == .issuesUpdate {
            let changeFields = entry.operation == .pullsUpdate ? ["title", "body", "state", "base"] : ["title", "body", "state"]
            guard changeFields.contains(where: { arguments.has($0) }) else {
                throw NativeRPCError.invalidArguments("Supply at least one change to the title, description, state or base branch.")
            }
        }
        for field in ["labels", "assignees"] {
            if let values = arguments[field].elements {
                _ = try BackendGHAPIValidation.names(arguments, field, maximum: field == "assignees" ? 10 : 100, logins: field == "assignees")
                guard values.allSatisfy({ $0.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && $0.string?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) == false }),
                      Set(values.compactMap(\.string)).count == values.count else {
                    throw NativeRPCError.invalidArguments("\(field) must contain distinct, nonblank names without control characters.")
                }
            }
        }
        for field in ["commitId", "expectedHeadSHA", "headSHA"] {
            if let text = arguments[field].string {
                _ = try BackendGHAPIValidation.sha(text)
            }
        }
        if entry.operation == .pullsReview {
            let hasBody = arguments["body"].string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let comments = arguments["comments"].elements ?? []
            if arguments["event"].string == "REQUEST_CHANGES", !hasBody {
                throw NativeRPCError.invalidArguments("Explain the requested changes in body.")
            }
            if arguments["event"].string == "COMMENT", !hasBody, comments.isEmpty {
                throw NativeRPCError.invalidArguments("A comment review needs body or at least one line comment.")
            }
            for comment in comments {
                let path = comment["path"].string ?? ""
                _ = try BackendGHAPIValidation.relativePath(path)
                _ = try BackendGHAPIValidation.text(comment, "body", required: true)
                if comment.has("startLine") || comment.has("startSide") {
                    guard let start = comment["startLine"].number, let end = comment["line"].number,
                          start <= end, comment["startSide"] == comment["side"] else {
                        throw NativeRPCError.invalidArguments("A multi-line comment needs startLine no later than line, and matching startSide and side.")
                    }
                }
            }
        }
        if entry.operation == .issuesList, let query = arguments["query"].string {
            let words = query.uppercased().split(whereSeparator: { $0.isWhitespace })
            guard !query.contains(":"), !query.contains("\""), !query.contains("\\"),
                  !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !words.contains("OR"), !words.contains("NOT") else {
                throw NativeRPCError.invalidArguments("Issue search takes plain words; repository qualifiers and search operators are unavailable.")
            }
        }
        if entry.operation == .reposClone {
            let directory = arguments["directoryName"].string ?? ""
            let parent = arguments["parentPath"].string ?? ""
            guard BackendGHAPIValidation.matches(directory, #"[A-Za-z0-9][A-Za-z0-9_. -]{0,127}"#),
                  !directory.hasSuffix(" "), !directory.hasSuffix("."), parent.hasPrefix("/"),
                  !parent.split(separator: "/").contains("..") else {
                throw NativeRPCError.invalidArguments("Choose an absolute granted parent folder and one new directory name.")
            }
        }
        if entry.operation == .notificationsRead, let thread = arguments["threadId"].string {
            guard thread.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw NativeRPCError.invalidArguments("threadId must be the numeric notification ID from the GitHub inbox.")
            }
        }
        for field in ["since", "before"] {
            if let date = arguments[field].string {
                guard ISO8601DateFormatter().date(from: date) != nil else {
                    throw NativeRPCError.invalidArguments("\(field) must be an ISO 8601 date and time.")
                }
            }
        }
    }

    private static func scopedArguments(operation: BackendGHOperation, arguments: NativeRPCValue,
                                        context: BackendMCPCallContext, access: BackendDeckToolsAppAccess,
                                        repoForFolder: RepoForFolder?) async throws -> NativeRPCValue {
        let caller = try await access.caller(context)
        try checkCancellation(context)
        var prepared = arguments
        if caller.kind == .session {
            guard ![BackendGHOperation.reposList, .reposClone, .notificationsList, .notificationsRead].contains(operation) else {
                throw NativeRPCError(code: "not-granted", message: "A session can use only the GitHub repository of its granted project. The global inbox, repository list and clone action need the person here or an access key.")
            }
            guard let project = arguments["projectPath"].string, let requestedRepo = arguments["repo"].string,
                  let repoForFolder else {
                throw NativeRPCError(code: "not-granted", message: "This session needs a granted projectPath and its exact repo. Project-to-GitHub access must be supplied by the app.")
            }
            let folder = try await access.knownFolder(context, project)
            try checkCancellation(context)
            let projectRepo = try await repoForFolder(folder)
            try checkCancellation(context)
            guard requestedRepo == projectRepo else {
                throw NativeRPCError(code: "not-granted", message: "This repository does not match the session's granted project.")
            }
            prepared = prepared.setting("projectPath", .string(folder))
        } else {
            try BackendDeckToolsAppKit.hereOnly(caller, "Using GitHub")
            if let project = arguments["projectPath"].string {
                let folder = try await access.knownFolder(context, project)
                prepared = prepared.setting("projectPath", .string(folder))
                if caller.kind == .key, let requestedRepo = arguments["repo"].string {
                    guard let repoForFolder, try await repoForFolder(folder) == requestedRepo else {
                        throw NativeRPCError(code: "not-granted", message: "This repository does not match the access key's granted project.")
                    }
                }
            }
        }
        if operation == .reposClone {
            let folder = try await access.knownFolder(context, arguments["parentPath"].string ?? "")
            try checkCancellation(context)
            prepared = prepared.setting("parentPath", .string(folder))
        }
        return prepared
    }

    private static func perform(service: any BackendGHWorkspaceServing, operation: BackendGHOperation,
                                arguments: NativeRPCValue, context: BackendMCPCallContext,
                                rpc: NativeRPCContext) async throws -> NativeRPCValue {
        let task = Task {
            try Task.checkCancellation()
            return try await NativeCompositionCallContext.$rpc.withValue(rpc) {
                try await service.perform(operation: operation.rawValue, arguments: arguments)
            }
        }
        let observer = context.cancellation.observe { task.cancel() }
        defer { context.cancellation.removeObserver(observer) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }
    private static func checkCancellation(_ context: BackendMCPCallContext) throws {
        try Task.checkCancellation()
        if context.cancellation.isCancelled { throw CancellationError() }
    }
    private static func identifier(_ arguments: NativeRPCValue, _ field: String) -> String {
        arguments[field].number.map { String(Int64($0)) } ?? "?"
    }
    private static func stateAction(_ arguments: NativeRPCValue, noun: String) -> String {
        arguments["state"].string == "closed" ? "Close" : arguments["state"].string == "open" ? "Reopen" : noun
    }
    private static func resultSummary(operation: BackendGHOperation, arguments: NativeRPCValue, value: NativeRPCValue) -> NativeRPCValue {
        var result = NativeRPCValue.object([.init("operation", .string(operation.rawValue)), .init("write", .bool(operation.isWrite))])
        for key in ["repo", "number", "runId", "jobId", "projectPath", "parentPath", "directoryName", "threadId"] where arguments.has(key) {
            result = result.setting(key, arguments[key])
        }
        if let items = value["items"].elements { result = result.setting("returned", .number(Double(items.count))) }
        if value["hasMore"].bool != nil { result = result.setting("hasMore", value["hasMore"]) }
        return result
    }
}
