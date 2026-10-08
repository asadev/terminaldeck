import Foundation
import Observation
import TerminalDeckNativeCore

enum NativeGHArea: String, CaseIterable, Identifiable {
    case pulls, issues, actions, repos, inbox
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pulls: "Pull requests"
        case .issues: "Issues"
        case .actions: "Actions"
        case .repos: "Repositories"
        case .inbox: "Inbox"
        }
    }
    var symbol: String {
        switch self {
        case .pulls: "arrow.triangle.pull"
        case .issues: "exclamationmark.circle"
        case .actions: "play.circle"
        case .repos: "shippingbox"
        case .inbox: "tray"
        }
    }
    var operation: String {
        switch self {
        case .pulls: "pulls.list"
        case .issues: "issues.list"
        case .actions: "actions.runs"
        case .repos: "repos.list"
        case .inbox: "notifications.list"
        }
    }
}

struct NativeGHItem: Identifiable, Equatable {
    let raw: CodingAIJSON
    let area: NativeGHArea
    let fallbackRepo: String
    var id: String { raw["id"].ghText ?? raw["node_id"].text ?? raw["full_name"].text ?? "\(repo)#\(number)" }
    var number: Int { raw["number"].ghInt ?? 0 }
    var repo: String {
        if let name = raw["repository"]["full_name"].text ?? raw["full_name"].text { return name }
        if let name = raw["repository"]["nameWithOwner"].text { return name }
        if let url = raw["repository_url"].text, let range = url.range(of: "/repos/") { return String(url[range.upperBound...]) }
        if let url = raw["html_url"].text, let components = URL(string: url)?.pathComponents, components.count >= 3 {
            return "\(components[1])/\(components[2])"
        }
        return fallbackRepo
    }
    var title: String {
        raw["title"].text ?? raw["display_title"].text ?? raw["subject"]["title"].text
            ?? raw["full_name"].text ?? raw["name"].text ?? "GitHub item"
    }
    var subtitle: String {
        var parts: [String] = []
        if number > 0 { parts.append("#\(number)") }
        if area != .repos, !repo.isEmpty { parts.append(repo) }
        if let user = raw["user"]["login"].text ?? raw["actor"]["login"].text { parts.append(user) }
        if area == .repos { parts.append(raw["private"].isTrue ? "Private" : "Public") }
        if let state = raw["conclusion"].text ?? raw["status"].text ?? raw["state"].text { parts.append(state.replacingOccurrences(of: "_", with: " ")) }
        return parts.joined(separator: " · ")
    }
    var url: String? { raw["html_url"].text ?? raw["web_url"].text }
}

extension CodingAIJSON {
    var ghInt: Int? { number.flatMap { Int(exactly: $0) } }
    var ghText: String? { text ?? ghInt.map(String.init) }
    var ghItems: [CodingAIJSON] {
        array ?? self["items"].array ?? self["workflow_runs"].array ?? self["jobs"].array
            ?? self["check_runs"].array ?? self["statuses"].array ?? self["comments"].array ?? []
    }
}

enum NativeGHBridge {
    @MainActor
    static func call(_ operation: String, _ arguments: [String: CodingAIJSON] = [:]) async throws -> CodingAIJSON {
        let payload: [String: Any] = ["operation": operation, "arguments": arguments.mapValues(\.foundation)]
        let answer = CodingAIJSON(try await EngineBridge.shared.invoke("github:workspace", [payload]))
        // Some bridge hosts return an error envelope; never turn that into an empty list.
        if answer["ok"].bool == false || (!answer["error"].isNull && answer["items"].isNull) {
            let message = answer["error"]["message"].text ?? answer["error"].text ?? answer["message"].text ?? "GitHub could not finish this request. Try again."
            throw NativeGHFailure(message: message)
        }
        return answer
    }
}

struct NativeGHFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor @Observable
final class NativeGHWorkspaceModel {
    let cwd: String
    var area = NativeGHArea.pulls
    var repo = ""
    var branch = ""
    var scope = "repo"
    var state = "open"
    var query = ""
    var label = ""
    var assignee = ""
    var items: [NativeGHItem] = []
    var repositories: [NativeGHItem] = []
    var selection: NativeGHItem?
    var loading = false
    var loadingMore = false
    var error: String?
    var notice: String?
    var page = 1
    var hasMore = false
    var draft: NativeGHWriteDraft?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var projectRepo = ""
    @ObservationIgnored private var projectBranch = ""

    init(cwd: String) {
        self.cwd = cwd
        if PanelHandoff.pageFocus == "issues" { area = .issues }
    }

    var shownItems: [NativeGHItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(needle) || $0.subtitle.localizedCaseInsensitiveContains(needle) }
    }

    func start() async {
        guard !started else { return }
        started = true
        loading = true
        do {
            let raw = try await EngineBridge.shared.invoke("github:auth-status", [cwd])
            let auth = GitHubAuthState(json: raw)
            repo = auth.repo?.ref?.nameWithOwner ?? ""
            branch = auth.branch?.name ?? ""
            projectRepo = repo
            projectBranch = branch
        } catch {
            self.error = CodingAIErrorText.from(error, fallback: "Could not read this project’s repository. Choose one above.")
        }
        async let repos: Void = loadRepositories()
        await reload()
        await repos
    }

    func changeArea(_ next: NativeGHArea) {
        guard next != area else { return }
        area = next
        selection = nil
        query = ""
        items = []
        state = "open"
        Task { await reload() }
    }

    func chooseRepo(_ value: String) {
        let next = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard next != repo || area == .repos else { return }
        repo = next
        branch = next == projectRepo ? projectBranch : ""
        selection = nil
        if area == .repos { area = .pulls }
        Task { await reload() }
    }

    func loadRepositories() async {
        do {
            let answer = try await NativeGHBridge.call("repos.list", ["page": .number(1), "perPage": .number(100)])
            repositories = answer.ghItems.map { NativeGHItem(raw: $0, area: .repos, fallbackRepo: "") }
        } catch { /* The Repositories page owns its own retry and error state. */ }
    }

    func reload(more: Bool = false) async {
        generation += 1
        let ticket = generation
        let askedArea = area
        let askedRepo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsRepo = askedArea == .issues || askedArea == .actions || (askedArea == .pulls && scope == "repo")
        if needsRepo && askedRepo.isEmpty {
            items = []
            loading = false
            error = nil
            hasMore = false
            return
        }
        if more { loadingMore = true } else { loading = true }
        error = nil
        let nextPage = more ? page + 1 : 1
        var arguments: [String: CodingAIJSON] = ["page": .number(Double(nextPage)), "perPage": .number(50)]
        if !askedRepo.isEmpty && askedArea != .repos && askedArea != .inbox && !(askedArea == .pulls && scope != "repo") {
            arguments["repo"] = .string(askedRepo)
        }
        if askedArea == .pulls { arguments["scope"] = .string(scope); arguments["state"] = .string(state) }
        if askedArea == .issues {
            arguments["state"] = .string(state)
            if !label.isEmpty { arguments["labels"] = .string(label) }
            if !assignee.isEmpty { arguments["assignee"] = .string(assignee) }
        }
        if askedArea == .inbox { arguments["all"] = .bool(state == "all") }
        do {
            let answer = try await NativeGHBridge.call(askedArea.operation, arguments)
            guard ticket == generation else { return }
            let incoming = answer.ghItems.map { NativeGHItem(raw: $0, area: askedArea, fallbackRepo: askedRepo) }
            if more {
                let known = Set(items.map(\.id))
                items.append(contentsOf: incoming.filter { !known.contains($0.id) })
            } else { items = incoming }
            page = nextPage
            hasMore = answer["hasMore"].isTrue
            if askedArea == .repos { repositories = items }
            if let selected = selection, let fresh = items.first(where: { $0.id == selected.id }) { selection = fresh }
        } catch {
            guard ticket == generation else { return }
            self.error = CodingAIErrorText.from(error, fallback: "Could not load GitHub. Try again.")
        }
        guard ticket == generation else { return }
        loading = false
        loadingMore = false
    }

    func completed(_ message: String) {
        notice = message
        Task { await reload() }
    }

    func create() {
        guard !repo.isEmpty else { return }
        if area == .pulls {
            let base = repositories.first(where: { $0.repo == repo })?.raw["default_branch"].text ?? ""
            draft = NativeGHWriteDraft(title: "New pull request", action: "Create pull request", operation: "pulls.create", arguments: ["repo": .string(repo)], fields: [
                .text("title", "Title"), .text("head", "From branch", value: branch), .text("base", "Into branch", value: base),
                .body("body", "Description"), .choice("draft", "Ready for review?", choices: [("false", "Ready for review"), ("true", "Draft")], value: "false", kind: .boolean)
            ], message: "This creates a pull request in \(repo). Review the branches and description before confirming.")
        } else if area == .issues {
            draft = NativeGHWriteDraft(title: "New issue", action: "Create issue", operation: "issues.create", arguments: ["repo": .string(repo)], fields: [
                .text("title", "Title"), .body("body", "Description"), .list("assignees", "Assign to", hint: "GitHub names, separated by commas"),
                .list("labels", "Labels", hint: "Existing labels, separated by commas")
            ], message: "This creates an issue in \(repo).")
        }
    }
}

@MainActor @Observable
final class NativeGHDetailModel {
    let item: NativeGHItem
    var detail = CodingAIJSON.null
    var files: [CodingAIJSON] = []
    var comments: [CodingAIJSON] = []
    var checks: [CodingAIJSON] = []
    var branches: [CodingAIJSON] = []
    var commits: [CodingAIJSON] = []
    var commitBranch = ""
    var releases: [CodingAIJSON] = []
    var jobs: [CodingAIJSON] = []
    var loading = true
    var error: String?
    var sectionErrors: [String: String] = [:]
    var sectionPages: [String: Int] = [:]
    var sectionHasMore: [String: Bool] = [:]
    var loadingSections: Set<String> = []
    var revision = 0
    var draft: NativeGHWriteDraft?
    var notice: String?
    @ObservationIgnored private var generation = 0

    init(item: NativeGHItem) { self.item = item; detail = item.raw }

    var currentActionRun: NativeGHItem { NativeGHItem(raw: detail, area: .actions, fallbackRepo: item.repo) }
    var canCancelActionRun: Bool {
        item.area == .actions && !loading && error == nil && detail["status"].text != nil && detail["status"].text != "completed"
    }
    var canRerunFailedActionJobs: Bool {
        guard item.area == .actions, !loading, error == nil, detail["status"].text == "completed" else { return false }
        let failedStates = ["failure", "timed_out", "cancelled"]
        return failedStates.contains(detail["conclusion"].text ?? "") || jobs.contains { failedStates.contains($0["conclusion"].text ?? "") }
    }

    var arguments: [String: CodingAIJSON] {
        var values: [String: CodingAIJSON] = ["repo": .string(item.repo)]
        if item.number > 0 { values["number"] = .number(Double(item.number)) }
        return values
    }

    func load() async {
        generation += 1
        let ticket = generation
        loading = true
        error = nil
        sectionErrors = [:]
        sectionPages = [:]
        sectionHasMore = [:]
        loadingSections = []
        var requests: [(String, String, [String: CodingAIJSON])] = []
        switch item.area {
        case .pulls:
            requests = [("detail", "pulls.detail", arguments), ("files", "pulls.files", arguments), ("checks", "pulls.checks", arguments), ("comments", "pulls.comments", arguments)]
        case .issues:
            requests = [("detail", "issues.detail", arguments), ("comments", "issues.comments", arguments)]
        case .repos:
            var commitArgs = arguments
            if !commitBranch.isEmpty { commitArgs["branch"] = .string(commitBranch) }
            requests = [("branches", "repos.branches", arguments), ("commits", "repos.commits", commitArgs), ("releases", "repos.releases", arguments)]
        case .actions:
            var args = arguments
            args["runId"] = item.raw["id"]
            requests = [("detail", "actions.runs", args), ("jobs", "actions.jobs", args)]
        case .inbox: break
        }
        // Independent reads start together. Each section keeps its own failure,
        // so an unavailable check or comment never hides the description or diff.
        await withTaskGroup(of: (String, CodingAIJSON?, String?).self) { group in
            for (section, operation, args) in requests {
                group.addTask {
                    var paged = args
                    paged["perPage"] = .number(50)
                    do { return (section, try await NativeGHBridge.call(operation, paged), nil) }
                    catch { return (section, nil, CodingAIErrorText.from(error, fallback: "Could not load \(section). Try again.")) }
                }
            }
            for await (section, value, failure) in group {
                guard ticket == generation else { continue }
                if let failure {
                    sectionErrors[section] = failure
                    if section == "detail" { error = failure }
                    continue
                }
                guard let value else { continue }
                accept(value, section: section, more: false, page: 1)
            }
        }
        guard ticket == generation else { return }
        loading = false
        revision += 1
    }

    func completed(_ text: String) { notice = text; Task { await load() } }

    func loadSection(_ section: String, more: Bool = false, branch: String? = nil) async {
        guard !loadingSections.contains(section), let operation = sectionOperation(section) else { return }
        if section == "commits", let branch { commitBranch = branch }
        let ticket = generation
        loadingSections.insert(section)
        sectionErrors[section] = nil
        var args = arguments
        let page = more ? (sectionPages[section] ?? 1) + 1 : 1
        args["page"] = .number(Double(page))
        args["perPage"] = .number(50)
        if item.area == .actions { args["runId"] = item.raw["id"] }
        let requestedBranch = section == "commits" ? commitBranch : branch ?? ""
        if !requestedBranch.isEmpty { args["branch"] = .string(requestedBranch) }
        do {
            let answer = try await NativeGHBridge.call(operation, args)
            guard ticket == generation else { return }
            accept(answer, section: section, more: more, page: page)
        } catch {
            guard ticket == generation else { return }
            sectionErrors[section] = CodingAIErrorText.from(error, fallback: "Could not load \(section). Try again.")
        }
        guard ticket == generation else { return }
        loadingSections.remove(section)
    }

    private func sectionOperation(_ section: String) -> String? {
        switch section {
        case "files": "pulls.files"
        case "comments": item.area == .pulls ? "pulls.comments" : "issues.comments"
        case "checks": "pulls.checks"
        case "branches": "repos.branches"
        case "commits": "repos.commits"
        case "releases": "repos.releases"
        case "jobs": "actions.jobs"
        default: nil
        }
    }

    private func accept(_ value: CodingAIJSON, section: String, more: Bool, page: Int) {
        if section == "detail" {
            if item.area == .actions {
                guard let run = value.ghItems.first else {
                    error = "GitHub did not return this run. Refresh the details and try again."
                    return
                }
                detail = run
            } else { detail = value }
            return
        }
        var incoming = value.ghItems
        if section == "checks" {
            if value["items"].array == nil {
                incoming = value["checkRuns"].array ?? value["check_runs"].array ?? []
                incoming += value["status"]["statuses"].array ?? value["statuses"].array ?? []
            }
        }
        func merge(_ previous: [CodingAIJSON]) -> [CodingAIJSON] {
            var seen: Set<String> = []
            return (more ? previous + incoming : incoming).filter { item in
                let key = "\(item["kind"].text ?? ""):\(item["id"].ghText ?? item["sha"].text ?? item["filename"].text ?? item["name"].text ?? item.jsonText)"
                return seen.insert(key).inserted
            }
        }
        switch section {
        case "files": files = merge(files)
        case "comments": comments = merge(comments).sorted { ($0["created_at"].text ?? $0["submitted_at"].text ?? "") < ($1["created_at"].text ?? $1["submitted_at"].text ?? "") }
        case "checks": checks = merge(checks)
        case "branches": branches = merge(branches)
        case "commits": commits = merge(commits)
        case "releases": releases = merge(releases)
        case "jobs": jobs = merge(jobs)
        default: break
        }
        sectionPages[section] = page
        sectionHasMore[section] = value["hasMore"].isTrue
    }

    func comment() {
        draft = NativeGHWriteDraft(title: "Add a comment", action: "Post comment", operation: item.area == .pulls ? "pulls.comment" : "issues.comment", arguments: arguments,
                                  fields: [.body("body", "Comment", required: true)], message: "Your comment will be posted on \(item.repo) #\(item.number).")
    }

    func changeState() {
        let next = detail["state"].text == "open" ? "closed" : "open"
        let verb = next == "closed" ? "Close" : "Reopen"
        var args = arguments
        args["state"] = .string(next)
        draft = NativeGHWriteDraft(title: "\(verb) #\(item.number)", action: "\(verb) \(item.area == .pulls ? "pull request" : "issue")", operation: item.area == .pulls ? "pulls.update" : "issues.update", arguments: args,
                                  fields: [], message: "\(verb) “\(detail["title"].text ?? item.title)” in \(item.repo).")
    }

    func review(_ event: String) {
        var args = arguments
        args["event"] = .string(event)
        if let sha = detail["head"]["sha"].text { args["commitId"] = .string(sha) }
        let verb = event == "APPROVE" ? "Approve" : "Request changes"
        draft = NativeGHWriteDraft(title: "\(verb) #\(item.number)", action: "Submit review", operation: "pulls.review", arguments: args,
                                  fields: [.body("body", "Review", required: event == "REQUEST_CHANGES")], message: "This submits a \(event == "APPROVE" ? "review approving" : "review requesting changes to") this pull request in \(item.repo).")
    }

    func lineComment(path: String, line: Int, side: String) {
        var args = arguments
        args["event"] = .string("COMMENT")
        args["body"] = .string("Review comments")
        if let sha = detail["head"]["sha"].text { args["commitId"] = .string(sha) }
        let comment: CodingAIJSON = .object(["path": .string(path), "line": .number(Double(line)), "side": .string(side)])
        args["comments"] = .array([comment])
        draft = NativeGHWriteDraft(title: "Comment on line \(line)", action: "Post line comment", operation: "pulls.review", arguments: args,
                                  fields: [.body("lineCommentBody", "Comment", required: true)], message: "This posts a review comment on \(path), line \(line) (\(side == "LEFT" ? "previous version" : "new version")) in \(item.repo) #\(item.number).")
    }
}
