import Foundation
import TerminalDeckNativeCore

public struct BackendGHCloneRequest: Sendable {
    public let repo: String, host: String, parentPath: String, directoryName: String
    public let branch: String?
    public init(repo: String, host: String, parentPath: String, directoryName: String, branch: String?) {
        self.repo = repo; self.host = host; self.parentPath = parentPath; self.directoryName = directoryName; self.branch = branch
    }
}

/// Native GitHub API owner. Caller approval and project scope remain in the
/// channel/MCP adapters; this actor never treats argument flags as authority.
public actor BackendGHWorkspaceService: BackendGHWorkspaceServing, BackendGHJobLogStreaming {
    public typealias Clone = @Sendable (BackendGHCloneRequest) async throws -> NativeRPCValue
    private let authenticator: BackendGitHubAuthenticator
    private let http: any BackendGitHubHTTPFetching
    private let tools: any BackendGitHubToolRunning
    private let environment: [String: String]
    private let clone: Clone?
    private let now: @Sendable () -> Double
    public init(authenticator: BackendGitHubAuthenticator, tools: any BackendGitHubToolRunning,
                http: any BackendGitHubHTTPFetching = BackendGHHTTP(), environment: [String: String] = [:],
                clone: Clone? = nil, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.authenticator = authenticator; self.tools = tools; self.http = http; self.environment = environment; self.clone = clone; self.now = now
    }

    public func perform(operation: String, arguments args: NativeRPCValue) async throws -> NativeRPCValue {
        _ = try args.requireObject("GitHub arguments")
        guard let operation = BackendGHOperation(rawValue: operation) else { throw NativeRPCError(code: "unavailable", message: "This GitHub action is not available in this build.") }
        try Task.checkCancellation()
        let host = try BackendGHAPIValidation.host(authenticator.host)
        var secrets = await authenticator.secrets()
        do {
            if operation == .reposClone { return BackendGHAPIValidation.scrub(try await cloneRepository(args, host: host), secrets: secrets) }
            let token = try await credential(host: host)
            secrets.append(token)
            let result = try await perform(operation, args: args, host: host, token: token)
            return BackendGHAPIValidation.scrub(result, secrets: secrets)
        } catch is CancellationError { throw CancellationError() }
        catch let error as NativeRPCError {
            throw NativeRPCError(code: error.code, message: BackendGHAPIValidation.scrub(error.message, secrets: secrets), details: BackendGHAPIValidation.scrub(error.details, secrets: secrets))
        } catch {
            throw NativeRPCError(code: "github-error", message: "The GitHub action could not finish. Refresh and try again.")
        }
    }

    public nonisolated func streamJobLogs(arguments: NativeRPCValue) -> AsyncThrowingStream<NativeRPCValue, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let bytes = try await self.streamSnapshot(arguments)
                    var cursor = 0
                    repeat {
                        try Task.checkCancellation()
                        let chunk = try Self.logChunk(bytes, cursor: cursor)
                        continuation.yield(chunk)
                        cursor = Int(chunk["cursor"].number!)
                        await Task.yield()
                    } while cursor < bytes.count
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    private func streamSnapshot(_ args: NativeRPCValue) async throws -> Data {
        _ = try args.requireObject("GitHub log arguments")
        let host = try BackendGHAPIValidation.host(authenticator.host)
        let token = try await credential(host: host)
        do { return try await logSnapshot(args, host: host, token: token) }
        catch is CancellationError { throw CancellationError() }
        catch let error as NativeRPCError {
            let secrets = await authenticator.secrets() + [token]
            throw NativeRPCError(code: error.code, message: BackendGHAPIValidation.scrub(error.message, secrets: secrets), details: BackendGHAPIValidation.scrub(error.details, secrets: secrets))
        } catch { throw NativeRPCError(code: "github-error", message: "The job logs could not be loaded. Refresh and try again.") }
    }

    private func credential(host: String) async throws -> String {
        if let credential = await authenticator.gitCredential() { return try checkedToken(credential.password) }
        let response: BackendGitOutcome
        do {
            response = try await tools.run(tool: "gh", arguments: ["auth", "token", "--hostname", host], cwd: nil,
                environment: BackendGitHubAuthenticator.probeEnvironment(environment), timeoutMilliseconds: 10_000, maximumBytes: 8192)
        } catch is CancellationError { throw CancellationError() }
        catch { throw NativeRPCError(code: "auth-unavailable", message: "The existing GitHub sign-in could not be read. Check the GitHub account in Settings.") }
        try Task.checkCancellation()
        guard response.ok else {
            throw NativeRPCError(code: "auth-required", message: response.missing ? "Connect your GitHub account in Settings before using this view." : "No existing GitHub sign-in is available. Connect your account in Settings.")
        }
        return try checkedToken(response.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private func checkedToken(_ token: String) throws -> String {
        guard !token.isEmpty, token.utf8.count <= 4096, !token.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }) else {
            throw NativeRPCError(code: "auth-required", message: "The existing GitHub sign-in could not be used. Check the account in Settings.")
        }; return token
    }
    private func endpoint(_ path: String, host: String, query: [(String, String)] = []) throws -> String {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains(".."), var components = URLComponents(string: BackendGitHubRepositories.apiRoot(host) + path) else { throw NativeRPCError.invalidArguments("The GitHub API path is invalid.") }
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        guard let value = components.url?.absoluteString else { throw NativeRPCError.invalidArguments("The GitHub API query is invalid.") }; return value
    }
    private func response(_ path: String, host: String, token: String, method: String = "GET", query: [(String, String)] = [], body: NativeRPCValue = .missing) async throws -> BackendGitHubHTTPResponse {
        let url = try endpoint(path, host: host, query: query)
        var headers = BackendGitHubRepositories.headers(token: token)
        if !body.isNullish { headers["Content-Type"] = "application/json" }
        let encoded = body.isNullish ? nil : String(decoding: try body.encodedJSON(), as: UTF8.self)
        let answer: BackendGitHubHTTPResponse
        do { answer = try await http.fetch(url: url, method: method, headers: headers, body: encoded, timeoutMilliseconds: 20_000) }
        catch is CancellationError { throw CancellationError() }
        catch let error as NativeRPCError { throw error }
        catch { throw NativeRPCError(code: "network-down", message: "Could not reach GitHub. Check your connection, then try again.") }
        try Task.checkCancellation()
        guard answer.body.utf8.count <= BackendGHAPIValidation.maximumJSONBytes else { throw NativeRPCError(code: "response-too-large", message: "GitHub returned more data than this view can show. Use a smaller page.") }
        return answer
    }
    private func request(_ path: String, host: String, token: String, method: String = "GET", query: [(String, String)] = [], body: NativeRPCValue = .missing) async throws -> (NativeRPCValue, BackendGitHubHTTPResponse) {
        let answer = try await response(path, host: host, token: token, method: method, query: query, body: body)
        guard answer.ok else { throw await refusal(answer, token: token) }
        if answer.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (BackendGHAPIValidation.object([("ok", .bool(true))]), answer) }
        do { return (try NativeRPCValue.parseJSON(Data(answer.body.utf8), maximumBytes: BackendGHAPIValidation.maximumJSONBytes), answer) }
        catch { throw NativeRPCError(code: "malformed", message: "GitHub returned data this view could not read. Refresh and try again.") }
    }
    private func refusal(_ response: BackendGitHubHTTPResponse, token: String) async -> NativeRPCError {
        let secrets = await authenticator.secrets() + [token]
        let detail = BackendGHAPIValidation.scrub(String(response.body.prefix(4096)), secrets: secrets)
        let details = BackendGHAPIValidation.object([("status", .number(Double(response.status))), ("detail", .string(BackendGitHubSecretRedaction.redact(detail)))])
        if response.status == 401 { return NativeRPCError(code: "auth-expired", message: "GitHub no longer accepts this sign-in. Reconnect the account in Settings.", details: details) }
        if response.status == 429 || (response.status == 403 && (response.header("x-ratelimit-remaining") == "0" || response.header("retry-after") != nil || response.body.lowercased().contains("rate limit"))) {
            let reported = Double(response.header("retry-after") ?? "") ?? Double(response.header("x-ratelimit-reset") ?? "").map { max(1, $0 - now()) }
            let seconds = reported.flatMap { $0.isFinite ? min(86_400, max(1, $0)) : nil }
            let wait = seconds.map { "Try again in about \(max(1, Int(ceil($0 / 60)))) minute\(Int(ceil($0 / 60)) == 1 ? "" : "s")." } ?? "Wait a little, then try again."
            return NativeRPCError(code: "rate-limited", message: "GitHub is limiting requests. \(wait)", details: details)
        }
        if response.status == 403 { return NativeRPCError(code: "no-access", message: "This GitHub account cannot do that here. Check the repository access and account permissions.", details: details) }
        if response.status == 404 { return NativeRPCError(code: "not-found", message: "GitHub could not find that item, or this account cannot see it. Refresh the list and check repository access.", details: details) }
        if response.status == 409 { return NativeRPCError(code: "conflict", message: "The item changed or GitHub cannot complete the action yet. Refresh it, then try again.", details: details) }
        if response.status == 405 { return NativeRPCError(code: "merge-refused", message: "GitHub cannot merge this pull request yet. Check required reviews, checks, branch conflicts and the allowed merge methods.", details: details) }
        if response.status == 422 { return NativeRPCError(code: "validation-failed", message: "GitHub could not accept these details. Check the title, branch, labels or review lines and try again.", details: details) }
        if (300..<400).contains(response.status) { return NativeRPCError(code: "redirect-refused", message: "GitHub moved this API request. Refresh the repository details before trying again.", details: details) }
        return NativeRPCError(code: "github-error", message: "GitHub could not finish the action (HTTP \(response.status)). Try again shortly.", details: details)
    }
    private func page(_ args: NativeRPCValue) throws -> (Int, [(String, String)]) {
        let page = try BackendGHAPIValidation.integer(args, "page", default: 1, range: 1...100_000)
        let size = try BackendGHAPIValidation.integer(args, "perPage", default: 30, range: 1...100)
        return (page, [("page", String(page)), ("per_page", String(size))])
    }
    private func paged(_ value: NativeRPCValue, answer: BackendGitHubHTTPResponse, page: Int, key: String? = nil) throws -> NativeRPCValue {
        guard let items = (key.map { value[$0] } ?? value).elements else { throw NativeRPCError(code: "malformed", message: "GitHub returned a list this view could not read.") }
        let hasMore = (answer.header("link") ?? "").range(of: #"rel\s*=\s*\"?next\"?"#, options: .regularExpression) != nil
        var result = BackendGHAPIValidation.object([("items", .array(items)), ("page", .number(Double(page))), ("hasMore", .bool(hasMore))])
        if let total = value["total_count"].number { result = result.setting("total", .number(total)) }
        if let incomplete = value["incomplete_results"].bool { result = result.setting("incomplete", .bool(incomplete)) }
        return result
    }
    private func list(_ path: String, args: NativeRPCValue, host: String, token: String, query: [(String, String)] = [], key: String? = nil) async throws -> NativeRPCValue {
        let (number, paging) = try page(args)
        let (value, answer) = try await request(path, host: host, token: token, query: query + paging)
        return try paged(value, answer: answer, page: number, key: key)
    }
    private func login(host: String, token: String) async throws -> String {
        let (user, _) = try await request("/user", host: host, token: token)
        guard let login = user["login"].string, BackendGHAPIValidation.matches(login, #"[A-Za-z0-9][A-Za-z0-9-]{0,99}"#) else { throw NativeRPCError(code: "malformed", message: "GitHub did not identify the connected account.") }; return login
    }
    private func repoPath(_ args: NativeRPCValue) throws -> String { "/repos/" + (try BackendGHAPIValidation.repo(args))! }
    private func issuePath(_ args: NativeRPCValue) throws -> String { try repoPath(args) + "/issues/" + String(BackendGHAPIValidation.integer(args, "number")) }
    private func pullPath(_ args: NativeRPCValue) throws -> String { try repoPath(args) + "/pulls/" + String(BackendGHAPIValidation.integer(args, "number")) }
    private func write(_ path: String, method: String, body: NativeRPCValue = .missing, host: String, token: String) async throws -> NativeRPCValue { try await request(path, host: host, token: token, method: method, body: body).0 }

    private func perform(_ op: BackendGHOperation, args: NativeRPCValue, host: String, token: String) async throws -> NativeRPCValue {
        switch op {
        case .pullsList:
            var scope = try BackendGHAPIValidation.choice(args, "scope", values: ["repo", "mine", "review-requested", "reviewRequested"], default: args["repo"].isNullish ? "mine" : "repo")!
            if scope == "reviewRequested" { scope = "review-requested" }
            let state = try BackendGHAPIValidation.choice(args, "state", values: ["open", "closed", "all"], default: "open")!
            if scope == "repo" { return try await list(try repoPath(args) + "/pulls", args: args, host: host, token: token, query: [("state", state), ("sort", "updated"), ("direction", "desc")]) }
            let user = try await login(host: host, token: token)
            var query = "is:pr \(scope == "mine" ? "author" : "review-requested"):\(user)"
            if state != "all" { query += " is:\(state)" }
            if let repo = try BackendGHAPIValidation.repo(args, required: false) { query += " repo:\(repo)" }
            return try await list("/search/issues", args: args, host: host, token: token, query: [("q", query), ("sort", "updated"), ("order", "desc")], key: "items")
        case .pullsDetail: return try await request(try pullPath(args), host: host, token: token).0
        case .pullsFiles: return try await list(try pullPath(args) + "/files", args: args, host: host, token: token)
        case .pullsChecks: return try await checks(args, host: host, token: token)
        case .pullsComments: return try await pullComments(args, host: host, token: token)
        case .pullsComment, .issuesComment:
            let body = try BackendGHAPIValidation.text(args, "body", required: true)!
            return try await write(try issuePath(args) + "/comments", method: "POST", body: BackendGHAPIValidation.object([("body", .string(body))]), host: host, token: token)
        case .pullsReview: return try await write(try pullPath(args) + "/reviews", method: "POST", body: try review(args), host: host, token: token)
        case .pullsMerge:
            var body = BackendGHAPIValidation.object([("merge_method", .string(try BackendGHAPIValidation.choice(args, "mergeMethod", values: ["merge", "squash", "rebase"], default: "merge")!))])
            if let sha = try BackendGHAPIValidation.text(args, "expectedHeadSHA", alias: "expectedHeadSha") { body = body.setting("sha", .string(try BackendGHAPIValidation.sha(sha))) }
            let result = try await write(try pullPath(args) + "/merge", method: "PUT", body: body, host: host, token: token)
            guard result["merged"].bool == true else { throw NativeRPCError(code: "merge-refused", message: "GitHub did not merge this pull request. Refresh its checks and resolve any conflicts.") }; return result
        case .pullsUpdate: return try await write(try pullPath(args), method: "PATCH", body: try update(args, pull: true), host: host, token: token)
        case .pullsCreate:
            var body = try creation(args)
            body = body.setting("head", .string(try BackendGHAPIValidation.ref(BackendGHAPIValidation.text(args, "head", required: true)!, allowOwner: true)))
                .setting("base", .string(try BackendGHAPIValidation.ref(BackendGHAPIValidation.text(args, "base", required: true)!)))
                .setting("draft", .bool(try BackendGHAPIValidation.boolean(args, "draft")))
            return try await write(try repoPath(args) + "/pulls", method: "POST", body: body, host: host, token: token)
        case .issuesList: return try await issues(args, host: host, token: token)
        case .issuesDetail: return try await request(try issuePath(args), host: host, token: token).0
        case .issuesComments: return try await list(try issuePath(args) + "/comments", args: args, host: host, token: token)
        case .issuesCreate:
            var body = try creation(args)
            if args.has("assignees") { body = body.setting("assignees", .array(try BackendGHAPIValidation.names(args, "assignees", logins: true).map(NativeRPCValue.string))) }
            if args.has("labels") { body = body.setting("labels", .array(try BackendGHAPIValidation.names(args, "labels").map(NativeRPCValue.string))) }
            return try await write(try repoPath(args) + "/issues", method: "POST", body: body, host: host, token: token)
        case .issuesAssign:
            let names = try BackendGHAPIValidation.names(args, "assignees", maximum: 10, logins: true)
            return try await write(try issuePath(args), method: "PATCH", body: BackendGHAPIValidation.object([("assignees", .array(names.map(NativeRPCValue.string)))]), host: host, token: token)
        case .issuesLabels:
            let labels = try BackendGHAPIValidation.names(args, "labels")
            return try await write(try issuePath(args) + "/labels", method: "PUT", body: BackendGHAPIValidation.object([("labels", .array(labels.map(NativeRPCValue.string)))]), host: host, token: token)
        case .issuesUpdate: return try await write(try issuePath(args), method: "PATCH", body: try update(args, pull: false), host: host, token: token)
        case .actionsRuns:
            if args.has("runId") {
                let id = try BackendGHAPIValidation.integer(args, "runId")
                let run = try await request(try repoPath(args) + "/actions/runs/\(id)", host: host, token: token).0
                return BackendGHAPIValidation.object([("items", .array([run])), ("page", .number(1)), ("hasMore", .bool(false))])
            }
            var query: [(String, String)] = []
            if let sha = try BackendGHAPIValidation.text(args, "headSHA", alias: "headSha") { query.append(("head_sha", try BackendGHAPIValidation.sha(sha))) }
            else if args.has("number") {
                let (pull, _) = try await request(try pullPath(args), host: host, token: token)
                guard let sha = pull["head"]["sha"].string else { throw NativeRPCError(code: "malformed", message: "GitHub did not name the pull request's commit.") }
                query.append(("head_sha", try BackendGHAPIValidation.sha(sha)))
            }
            if let branch = try BackendGHAPIValidation.text(args, "branch") { query.append(("branch", try BackendGHAPIValidation.ref(branch))) }
            if let status = try BackendGHAPIValidation.choice(args, "status", values: ["completed", "action_required", "cancelled", "failure", "neutral", "skipped", "stale", "success", "timed_out", "in_progress", "queued", "requested", "waiting", "pending"]) { query.append(("status", status)) }
            return try await list(try repoPath(args) + "/actions/runs", args: args, host: host, token: token, query: query, key: "workflow_runs")
        case .actionsJobs:
            let run = try BackendGHAPIValidation.integer(args, "runId", alias: "runID")
            return try await list(try repoPath(args) + "/actions/runs/\(run)/jobs", args: args, host: host, token: token, query: [("filter", "latest")], key: "jobs")
        case .actionsLogs: return try await logs(args, host: host, token: token)
        case .actionsRerun, .actionsCancel:
            let run = try BackendGHAPIValidation.integer(args, "runId", alias: "runID")
            return try await write(try repoPath(args) + "/actions/runs/\(run)/\(op == .actionsRerun ? "rerun-failed-jobs" : "cancel")", method: "POST", host: host, token: token)
        case .reposList:
            return try await list("/user/repos", args: args, host: host, token: token, query: [("sort", "pushed"), ("affiliation", "owner,collaborator,organization_member")])
        case .reposBranches: return try await list(try repoPath(args) + "/branches", args: args, host: host, token: token)
        case .reposCommits:
            let branch = try BackendGHAPIValidation.text(args, "branch")
            let query = try branch.map { [("sha", try BackendGHAPIValidation.ref($0))] } ?? []
            return try await list(try repoPath(args) + "/commits", args: args, host: host, token: token, query: query)
        case .reposReleases: return try await list(try repoPath(args) + "/releases", args: args, host: host, token: token)
        case .reposDraftRelease:
            var body = BackendGHAPIValidation.object([("tag_name", .string(try BackendGHAPIValidation.ref(BackendGHAPIValidation.text(args, "tagName", required: true)!))), ("draft", .bool(true)), ("prerelease", .bool(try BackendGHAPIValidation.boolean(args, "prerelease")))])
            if let name = try BackendGHAPIValidation.text(args, "name", maximum: 256) { body = body.setting("name", .string(name)) }
            if let text = try BackendGHAPIValidation.text(args, "body") { body = body.setting("body", .string(text)) }
            if let target = try BackendGHAPIValidation.text(args, "targetCommitish") { body = body.setting("target_commitish", .string(try BackendGHAPIValidation.ref(target))) }
            return try await write(try repoPath(args) + "/releases", method: "POST", body: body, host: host, token: token)
        case .notificationsList:
            let repo = try BackendGHAPIValidation.repo(args, required: false)
            var query = [("all", String(try BackendGHAPIValidation.boolean(args, "all"))), ("participating", String(try BackendGHAPIValidation.boolean(args, "participating")))]
            for key in ["since", "before"] { if let date = try BackendGHAPIValidation.date(args, key) { query.append((key, date)) } }
            return try await list(repo.map { "/repos/" + $0 + "/notifications" } ?? "/notifications", args: args, host: host, token: token, query: query)
        case .notificationsRead:
            let thread = try BackendGHAPIValidation.identifier(args, "threadId", alias: "threadID")
            return try await write("/notifications/threads/\(thread)", method: "PATCH", host: host, token: token)
        case .reposClone: throw NativeRPCError(code: "unavailable", message: "The native clone integration is not connected.")
        }
    }

    private func creation(_ args: NativeRPCValue) throws -> NativeRPCValue {
        var body = BackendGHAPIValidation.object([("title", .string(try BackendGHAPIValidation.text(args, "title", required: true, maximum: 256)!))])
        if let text = try BackendGHAPIValidation.text(args, "body") { body = body.setting("body", .string(text)) }; return body
    }
    private func update(_ args: NativeRPCValue, pull: Bool) throws -> NativeRPCValue {
        var body = NativeRPCValue.object([])
        if let state = try BackendGHAPIValidation.choice(args, "state", values: ["open", "closed"]) { body = body.setting("state", .string(state)) }
        if let title = try BackendGHAPIValidation.text(args, "title", required: args.has("title"), maximum: 256) { body = body.setting("title", .string(title)) }
        if let text = try BackendGHAPIValidation.text(args, "body") { body = body.setting("body", .string(text)) }
        if pull, let base = try BackendGHAPIValidation.text(args, "base") { body = body.setting("base", .string(try BackendGHAPIValidation.ref(base))) }
        guard body.fields?.isEmpty == false else { throw NativeRPCError.invalidArguments("Choose what to change before saving.") }; return body
    }
    private func review(_ args: NativeRPCValue) throws -> NativeRPCValue {
        let event = try BackendGHAPIValidation.choice(args, "event", values: ["APPROVE", "REQUEST_CHANGES", "COMMENT"])
        guard let event else { throw NativeRPCError.invalidArguments("Choose whether to approve, request changes or comment.") }
        var body = BackendGHAPIValidation.object([("event", .string(event))])
        let lineOnly = event == "COMMENT" && args["comments"].elements?.isEmpty == false
        let rawBody = try BackendGHAPIValidation.text(args, "body", required: event == "REQUEST_CHANGES" || (event == "COMMENT" && !lineOnly))
        if lineOnly && (rawBody?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { body = body.setting("body", .string("Review comments")) }
        else if let rawBody { body = body.setting("body", .string(rawBody)) }
        if let sha = try BackendGHAPIValidation.text(args, "commitId", alias: "commitID") { body = body.setting("commit_id", .string(try BackendGHAPIValidation.sha(sha))) }
        if args.has("comments") {
            guard let rows = args["comments"].elements, rows.count <= 100 else { throw NativeRPCError.invalidArguments("A review can contain at most 100 line comments.") }
            let comments = try rows.map { row -> NativeRPCValue in
                _ = try row.requireObject("Review line")
                var result = BackendGHAPIValidation.object([
                    ("path", .string(try BackendGHAPIValidation.relativePath(BackendGHAPIValidation.text(row, "path", required: true, maximum: 4096)!))),
                    ("body", .string(try BackendGHAPIValidation.text(row, "body", required: true)!)),
                    ("line", .number(Double(try BackendGHAPIValidation.integer(row, "line", range: 1...10_000_000)))),
                    ("side", .string(try BackendGHAPIValidation.choice(row, "side", values: ["LEFT", "RIGHT"], default: "RIGHT")!))])
                if row.has("startLine") || row.has("start_line") {
                    let start = try BackendGHAPIValidation.integer(row, "startLine", alias: "start_line", range: 1...10_000_000)
                    guard start <= Int(result["line"].number!) else { throw NativeRPCError.invalidArguments("A review's first line must come before its last line.") }
                    result = result.setting("start_line", .number(Double(start))).setting("start_side", .string(try BackendGHAPIValidation.choice(row, "startSide", values: ["LEFT", "RIGHT"], default: result["side"].string, alias: "start_side")!))
                }
                return result
            }
            body = body.setting("comments", .array(comments))
        }
        return body
    }
    private func issues(_ args: NativeRPCValue, host: String, token: String) async throws -> NativeRPCValue {
        let state = try BackendGHAPIValidation.choice(args, "state", values: ["open", "closed", "all"], default: "open")!
        var query = "is:issue"
        if let repo = try BackendGHAPIValidation.repo(args, required: false) { query += " repo:\(repo)" }
        else { query += " involves:\(try await login(host: host, token: token))" }
        if state != "all" { query += " is:\(state)" }
        if let assignee = try BackendGHAPIValidation.text(args, "assignee", maximum: 100) {
            guard BackendGHAPIValidation.matches(assignee, #"[A-Za-z0-9][A-Za-z0-9-]{0,99}"#) else { throw NativeRPCError.invalidArguments("Choose a valid assignee.") }; query += " assignee:\(assignee)"
        }
        if args.has("labels") {
            let labels: [String]
            if let text = args["labels"].string { labels = text.components(separatedBy: ",") }
            else { labels = try BackendGHAPIValidation.names(args, "labels") }
            guard labels.count <= 100 else { throw NativeRPCError.invalidArguments("Choose at most 100 labels.") }
            for label in labels {
                guard !label.isEmpty, label.utf8.count <= 100, !label.contains(where: { $0 == "\"" || $0 == "\\" || $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else { throw NativeRPCError.invalidArguments("A label filter contains invalid text.") }
                query += " label:\"\(label)\""
            }
        }
        if let text = try BackendGHAPIValidation.text(args, "query", maximum: 500), !text.isEmpty {
            let operators = text.uppercased().split(whereSeparator: { $0.isWhitespace })
            guard !text.contains(where: { ":\"\\".contains($0) || $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }), !operators.contains("OR"), !operators.contains("NOT") else { throw NativeRPCError.invalidArguments("Search with plain words. Use the repository, state, label and assignee filters to change scope.") }
            query += " \(text)"
        }
        return try await list("/search/issues", args: args, host: host, token: token, query: [("q", query), ("sort", "updated"), ("order", "desc")], key: "items")
    }
    private func checks(_ args: NativeRPCValue, host: String, token: String) async throws -> NativeRPCValue {
        let (pull, _) = try await request(try pullPath(args), host: host, token: token)
        guard let raw = pull["head"]["sha"].string else { throw NativeRPCError(code: "malformed", message: "GitHub did not name this pull request's commit.") }
        let sha = try BackendGHAPIValidation.sha(raw), path = try repoPath(args) + "/commits/" + sha
        let checkRuns = try await list(path + "/check-runs", args: args, host: host, token: token, key: "check_runs")
        let (_, paging) = try page(args)
        let (status, answer) = try await request(path + "/status", host: host, token: token, query: paging)
        let statuses = (status["statuses"].elements ?? []).map { $0.setting("kind", .string("status")) }
        let runs = (checkRuns["items"].elements ?? []).map { $0.setting("kind", .string("check-run")) }
        let moreStatuses = (answer.header("link") ?? "").range(of: #"rel\s*=\s*\"?next\"?"#, options: .regularExpression) != nil
        return checkRuns.setting("items", .array(runs + statuses))
            .setting("hasMore", .bool(checkRuns["hasMore"].bool == true || moreStatuses))
            .setting("checkRuns", .array(runs)).setting("statuses", .array(statuses)).setting("status", status.setting("statuses", .array(statuses)))
    }
    private func pullComments(_ args: NativeRPCValue, host: String, token: String) async throws -> NativeRPCValue {
        let conversation = try await list(try issuePath(args) + "/comments", args: args, host: host, token: token)
        let lines = try await list(try pullPath(args) + "/comments", args: args, host: host, token: token)
        let reviews = try await list(try pullPath(args) + "/reviews", args: args, host: host, token: token)
        var items: [NativeRPCValue] = []
        for (value, kind) in [(conversation, "conversation"), (lines, "line"), (reviews, "review")] {
            items += (value["items"].elements ?? []).map { $0.setting("kind", .string(kind)) }
        }
        items.sort { ($0["created_at"].string ?? $0["submitted_at"].string ?? "") < ($1["created_at"].string ?? $1["submitted_at"].string ?? "") }
        return conversation.setting("items", .array(items)).setting("hasMore", .bool([conversation, lines, reviews].contains { $0["hasMore"].bool == true }))
            .setting("conversationComments", conversation["items"]).setting("reviewComments", lines["items"]).setting("reviews", reviews["items"])
    }
    private func logs(_ args: NativeRPCValue, host: String, token: String) async throws -> NativeRPCValue {
        let cursor = try BackendGHAPIValidation.integer(args, "cursor", default: 0, range: 0...BackendGHAPIValidation.maximumLogBytes)
        return try Self.logChunk(try await logSnapshot(args, host: host, token: token), cursor: cursor)
    }
    private func logSnapshot(_ args: NativeRPCValue, host: String, token: String) async throws -> Data {
        let job = try BackendGHAPIValidation.integer(args, "jobId", alias: "jobID")
        let answer = try await response(try repoPath(args) + "/actions/jobs/\(job)/logs", host: host, token: token)
        if answer.status == 404 { throw NativeRPCError(code: "log-not-ready", message: "GitHub has not made this job's logs available yet. Refresh after the job finishes.") }
        var content = answer
        if answer.status == 302 {
            guard let location = answer.header("location"), let url = URL(string: location), url.scheme == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443, let logHost = url.host?.lowercased(),
                  logHost == host || logHost == "github.com" || logHost.hasSuffix(".githubusercontent.com") || logHost.hasSuffix(".blob.core.windows.net") else {
                throw NativeRPCError(code: "redirect-refused", message: "GitHub returned a log download address this app cannot safely use.")
            }
            do { content = try await http.fetch(url: location, method: "GET", headers: ["Accept": "text/plain", "User-Agent": "terminaldeck"], body: nil, timeoutMilliseconds: 20_000) }
            catch is CancellationError { throw CancellationError() }
            catch let error as NativeRPCError { throw error }
            catch { throw NativeRPCError(code: "network-down", message: "The job logs could not be downloaded. Refresh and try again.") }
        }
        try Task.checkCancellation()
        guard content.ok else { throw await refusal(content, token: token) }
        guard content.body.utf8.count <= BackendGHAPIValidation.maximumLogBytes else { throw NativeRPCError(code: "response-too-large", message: "This job's logs are larger than 2 MB. Download the full log from the secondary GitHub link.") }
        let secrets = await authenticator.secrets() + [token]
        let text = BackendGitHubSecretRedaction.redact(BackendGHAPIValidation.scrub(content.body, secrets: secrets))
        return Data(text.utf8)
    }
    private nonisolated static func logChunk(_ bytes: Data, cursor: Int) throws -> NativeRPCValue {
        let reset = cursor > bytes.count
        let start = reset ? 0 : cursor
        guard start == bytes.count || bytes[start] & 0xC0 != 0x80 else { throw NativeRPCError.invalidArguments("The log cursor is invalid. Start again from the beginning.") }
        var end = min(bytes.count, start + 65_536)
        while end < bytes.count && bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return BackendGHAPIValidation.object([("text", .string(String(decoding: bytes[start..<end], as: UTF8.self))), ("cursor", .number(Double(end))), ("complete", .bool(end == bytes.count)), ("truncated", .bool(false)), ("reset", .bool(reset)), ("source", .string("job-log-snapshot"))])
    }
    private func cloneRepository(_ args: NativeRPCValue, host: String) async throws -> NativeRPCValue {
        let repo = try BackendGHAPIValidation.repo(args)!
        let parent = try BackendGHAPIValidation.text(args, "parentPath", required: true, maximum: 4096)!
        let name = try BackendGHAPIValidation.text(args, "directoryName", required: true, maximum: 255)!
        guard parent.hasPrefix("/"), !parent.contains(where: { $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }),
              !parent.split(separator: "/").contains(".."), BackendGHAPIValidation.matches(name, #"[A-Za-z0-9][A-Za-z0-9_. -]{0,254}"#), name != ".", name != "..", !name.hasSuffix(" "), !name.hasSuffix(".") else {
            throw NativeRPCError.invalidArguments("Choose an absolute parent folder and a new folder name inside it.")
        }
        let branch = try BackendGHAPIValidation.text(args, "branch").map { try BackendGHAPIValidation.ref($0) }
        guard let clone else { throw NativeRPCError(code: "unavailable", message: "The native GitHub clone credential connection is not wired in this build. Connect the host clone adapter before cloning.") }
        return try await clone(.init(repo: repo, host: host, parentPath: parent, directoryName: name, branch: branch))
    }
}
