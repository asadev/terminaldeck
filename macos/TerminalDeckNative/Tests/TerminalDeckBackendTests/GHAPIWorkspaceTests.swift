import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@MainActor
final class GHAPIWorkspaceTests: XCTestCase {
    private let token = "gho_fixtureCredentialOnly12345678901234567890"
    private func value(_ text: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(text.utf8)) }
    private func args(_ fields: [(String, NativeRPCValue)] = []) -> NativeRPCValue { BackendGHAPIValidation.object([("repo", .string("owner/project"))] + fields) }
    private func make(_ http: GHAPIHTTP, token: String? = "fixture-token-only", tools: GHAPITools = GHAPITools(), clone: BackendGHWorkspaceService.Clone? = nil) throws -> BackendGHWorkspaceService {
        let environment = token.map { ["GH_TOKEN": $0] } ?? [:]
        let auth = try BackendGitHubAuthenticator(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("GHAPI-unused-" + UUID().uuidString), environment: environment, http: http, tools: tools, resolveRepo: { _ in .null })
        return BackendGHWorkspaceService(authenticator: auth, tools: tools, http: http, environment: environment, clone: clone, now: { 1_000 })
    }
    private func expectError(_ code: String, service: BackendGHWorkspaceService, operation: String, arguments: NativeRPCValue) async {
        do { _ = try await service.perform(operation: operation, arguments: arguments); XCTFail("Expected \(code)") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, code) }
        catch { XCTFail("Unexpected error \(error)") }
    }
    func testExactRunRefreshReadsTheCurrentState() async throws {
        let http = GHAPIHTTP { _ in .init(status: 200, body: #"{"id":7,"status":"completed","conclusion":"failure"}"#) }
        let service = try make(http)
        let result = try await service.perform(operation: "actions.runs", arguments: args([("runId", .number(7))]))
        XCTAssertEqual(result["items"].elements?.first?["status"].string, "completed")
        XCTAssertEqual(result["hasMore"].bool, false)
        let calls = await http.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].url.contains("/actions/runs/7"))
    }
    func testReadEndpointsAndPaginationKeepRawRecords() async throws {
        let routes: [(String, String, String, NativeRPCValue)] = [
            ("pulls.list", "/repos/owner/project/pulls", #"[{"number":7,"title":"Pull"}]"#, args([("scope", .string("repo"))])),
            ("pulls.files", "/repos/owner/project/pulls/7/files", #"[{"filename":"a.swift","patch":"@@ -1 +1 @@\n-old\n+new"}]"#, args([("number", .number(7))])),
            ("issues.comments", "/repos/owner/project/issues/7/comments", #"[{"id":1,"body":"Comment"}]"#, args([("number", .number(7))])),
            ("actions.runs", "/repos/owner/project/actions/runs", #"{"workflow_runs":[{"id":1}],"total_count":1}"#, args()),
            ("actions.jobs", "/repos/owner/project/actions/runs/7/jobs", #"{"jobs":[{"id":2}],"total_count":1}"#, args([("runId", .number(7))])),
            ("repos.list", "/user/repos", #"[{"full_name":"owner/project"}]"#, args()),
            ("repos.branches", "/repos/owner/project/branches", #"[{"name":"main"}]"#, args()),
            ("repos.commits", "/repos/owner/project/commits", #"[{"sha":"abcdef123456"}]"#, args()),
            ("repos.releases", "/repos/owner/project/releases", #"[{"tag_name":"v1","body":"Notes"}]"#, args()),
            ("notifications.list", "/notifications", #"[{"id":"2","subject":{"title":"Review"}}]"#, .object([]))
        ]
        for (operation, path, body, parameters) in routes {
            let http = GHAPIHTTP { _ in .init(status: 200, body: body, headers: ["Link": "<https://api.github.com\(path)?page=3>; rel=\"next\""]) }
            let service = try make(http)
            let result = try await service.perform(operation: operation, arguments: parameters.setting("page", .number(2)))
            XCTAssertEqual(result["page"].number, 2); XCTAssertEqual(result["hasMore"].bool, true); XCTAssertEqual(result["items"].elements?.count, 1)
            let calls = await http.calls()
            XCTAssertEqual(URL(string: calls[0].url)?.path, path); XCTAssertTrue(calls[0].url.contains("page=2")); XCTAssertTrue(calls[0].url.contains("per_page=30"))
        }
    }
    func testDetailKeepsDescriptionAndCommitIdentity() async throws {
        let sha = String(repeating: "ab123def", count: 5)
        let http = GHAPIHTTP { _ in .init(status: 200, body: "{\"number\":7,\"body\":\"Description\",\"head\":{\"sha\":\"\(sha)\"}}") }
        let result = try await make(http).perform(operation: "pulls.detail", arguments: args([("number", .number(7))]))
        XCTAssertEqual(result["body"].string, "Description"); XCTAssertEqual(result["head"]["sha"].string, sha)
    }
    func testMineAndReviewSearchAlwaysRetainExactRepositoryScope() async throws {
        let http = GHAPIHTTP { call in .init(status: 200, body: URL(string: call.url)?.path == "/user" ? #"{"login":"fixture-user"}"# : #"{"items":[],"total_count":0}"#) }
        let service = try make(http)
        for scope in ["mine", "review-requested"] { _ = try await service.perform(operation: "pulls.list", arguments: args([("scope", .string(scope))])) }
        let calls = await http.calls()
        let queries = calls.filter { URL(string: $0.url)?.path == "/search/issues" }.map { URLComponents(string: $0.url)?.queryItems?.first(where: { $0.name == "q" })?.value ?? "" }
        XCTAssertEqual(queries, ["is:pr author:fixture-user is:open repo:owner/project", "is:pr review-requested:fixture-user is:open repo:owner/project"])
    }
    func testIssueSearchExcludesPullRequestsAndRefusesWiderScope() async throws {
        let http = GHAPIHTTP { _ in .init(status: 200, body: #"{"items":[{"number":1}],"total_count":1}"#) }
        let service = try make(http)
        _ = try await service.perform(operation: "issues.list", arguments: args([("query", .string("crash on launch")), ("labels", .array([.string("needs fix")]))]))
        let calls = await http.calls()
        let query = URLComponents(string: calls[0].url)?.queryItems?.first(where: { $0.name == "q" })?.value
        XCTAssertEqual(query, "is:issue repo:owner/project is:open label:\"needs fix\" crash on launch")
        for text in ["repo:other/private", "foo OR bar", "\" repo:other/private", "NOT repo:owner/project"] {
            await expectError("invalid-arguments", service: service, operation: "issues.list", arguments: args([("query", .string(text))]))
        }
        let after = await http.calls(); XCTAssertEqual(after.count, 1)
    }
    func testWriteMethodsBodiesAndEmptyResponses() async throws {
        let fixtures: [(String, String, String, NativeRPCValue, String)] = [
            ("pulls.comment", "POST", "/repos/owner/project/issues/7/comments", args([("number", .number(7)), ("body", .string("Hello"))]), #"{"body":"Hello"}"#),
            ("issues.comment", "POST", "/repos/owner/project/issues/7/comments", args([("number", .number(7)), ("body", .string("Hello"))]), #"{"body":"Hello"}"#),
            ("pulls.update", "PATCH", "/repos/owner/project/pulls/7", args([("number", .number(7)), ("state", .string("closed"))]), #"{"state":"closed"}"#),
            ("issues.update", "PATCH", "/repos/owner/project/issues/7", args([("number", .number(7)), ("state", .string("open"))]), #"{"state":"open"}"#),
            ("issues.assign", "PATCH", "/repos/owner/project/issues/7", args([("number", .number(7)), ("assignees", .array([.string("octocat")]))]), #"{"assignees":["octocat"]}"#),
            ("issues.labels", "PUT", "/repos/owner/project/issues/7/labels", args([("number", .number(7)), ("labels", .array([.string("bug")]))]), #"{"labels":["bug"]}"#),
            ("actions.rerun", "POST", "/repos/owner/project/actions/runs/7/rerun-failed-jobs", args([("runId", .number(7))]), "null"),
            ("actions.cancel", "POST", "/repos/owner/project/actions/runs/7/cancel", args([("runId", .number(7))]), "null"),
            ("notifications.read", "PATCH", "/notifications/threads/7", args([("threadId", .number(7))]), "null")
        ]
        for (operation, method, path, input, expected) in fixtures {
            let http = GHAPIHTTP { _ in .init(status: 204, body: "") }, service = try make(http)
            let result = try await service.perform(operation: operation, arguments: input), calls = await http.calls()
            XCTAssertEqual(result["ok"].bool, true); XCTAssertEqual(calls[0].method, method); XCTAssertEqual(URL(string: calls[0].url)?.path, path)
            XCTAssertEqual(try value(calls[0].body ?? "null"), try value(expected))
        }
    }
    func testReviewCreatesLineCommentsAndRejectsInvalidLines() async throws {
        let http = GHAPIHTTP { _ in .init(status: 200, body: #"{"id":1,"state":"APPROVED"}"#) }, service = try make(http)
        let comment = BackendGHAPIValidation.object([("path", .string("Sources/File.swift")), ("body", .string("Use a guard")), ("line", .number(12)), ("side", .string("RIGHT")), ("startLine", .number(10))])
        _ = try await service.perform(operation: "pulls.review", arguments: args([("number", .number(7)), ("event", .string("APPROVE")), ("comments", .array([comment]))]))
        let calls = await http.calls(), body = try value(calls[0].body!)
        XCTAssertEqual(body["event"].string, "APPROVE"); XCTAssertEqual(body["comments"].elements?[0]["start_line"].number, 10); XCTAssertEqual(body["comments"].elements?[0]["start_side"].string, "RIGHT")
        await expectError("invalid-arguments", service: service, operation: "pulls.review", arguments: args([("number", .number(7)), ("event", .string("REQUEST_CHANGES"))]))
        await expectError("invalid-arguments", service: service, operation: "pulls.review", arguments: args([("number", .number(7)), ("event", .string("APPROVE")), ("comments", .array([comment.setting("path", .string("../outside"))]))]))
        let after = await http.calls(); XCTAssertEqual(after.count, 1)
    }
    func testCreatePullIssueAndDraftRelease() async throws {
        let http = GHAPIHTTP { _ in .init(status: 201, body: #"{"id":1}"#) }, service = try make(http)
        _ = try await service.perform(operation: "pulls.create", arguments: args([("title", .string("Feature")), ("head", .string("fork:feature/native")), ("base", .string("main")), ("body", .string("Native work")), ("draft", .bool(true))]))
        _ = try await service.perform(operation: "issues.create", arguments: args([("title", .string("Bug")), ("body", .string("Steps"))]))
        _ = try await service.perform(operation: "repos.draftRelease", arguments: args([("tagName", .string("v1.2.3")), ("name", .string("Release")), ("body", .string("Notes")), ("targetCommitish", .string("main")), ("draft", .bool(false))]))
        let calls = await http.calls()
        XCTAssertEqual(try value(calls[0].body!)["head"].string, "fork:feature/native"); XCTAssertEqual(try value(calls[0].body!)["draft"].bool, true)
        XCTAssertEqual(URL(string: calls[1].url)?.path, "/repos/owner/project/issues")
        XCTAssertEqual(try value(calls[2].body!)["draft"].bool, true); XCTAssertEqual(try value(calls[2].body!)["target_commitish"].string, "main")
    }
    func testMergePinsHeadAndNeverClaimsFalseMerge() async throws {
        let http = GHAPIHTTP { call in .init(status: 200, body: call.body?.contains("squash") == true ? #"{"merged":true,"sha":"abc1234"}"# : #"{"merged":false,"message":"Blocked"}"#) }, service = try make(http)
        let result = try await service.perform(operation: "pulls.merge", arguments: args([("number", .number(7)), ("mergeMethod", .string("squash")), ("expectedHeadSHA", .string("abc1234"))]))
        XCTAssertEqual(result["merged"].bool, true)
        let calls = await http.calls(), body = try value(calls[0].body!)
        XCTAssertEqual(body["sha"].string, "abc1234"); XCTAssertEqual(calls[0].method, "PUT")
        await expectError("merge-refused", service: service, operation: "pulls.merge", arguments: args([("number", .number(7))]))
    }
    func testChecksIncludeLegacyStatusAndPRRunsUseHeadSHA() async throws {
        let http = GHAPIHTTP { call in
            let path = URL(string: call.url)?.path ?? ""
            if path.hasSuffix("/pulls/7") { return .init(status: 200, body: #"{"head":{"sha":"abc1234"}}"#) }
            if path.hasSuffix("/check-runs") { return .init(status: 200, body: #"{"check_runs":[{"name":"Build","conclusion":"success"}]}"#) }
            if path.hasSuffix("/status") { return .init(status: 200, body: #"{"state":"pending","statuses":[{"context":"Legacy"}]}"#) }
            return .init(status: 200, body: #"{"workflow_runs":[]}"#)
        }, service = try make(http)
        let checks = try await service.perform(operation: "pulls.checks", arguments: args([("number", .number(7))]))
        XCTAssertEqual(checks["checkRuns"].elements?.first?["name"].string, "Build"); XCTAssertEqual(checks["status"]["state"].string, "pending")
        XCTAssertEqual(checks["items"].elements?.count, 2); XCTAssertEqual(checks["statuses"].elements?.first?["context"].string, "Legacy")
        _ = try await service.perform(operation: "actions.runs", arguments: args([("number", .number(7))]))
        let calls = await http.calls(); XCTAssertTrue(calls.last?.url.contains("head_sha=abc1234") == true)
    }
    func testCommentsIncludeConversationReviewsAndLines() async throws {
        let http = GHAPIHTTP { call in
            if URL(string: call.url)?.path.contains("/issues/") == true { return .init(status: 200, body: #"[{"id":1,"body":"Conversation","created_at":"2026-01-01"}]"#) }
            if URL(string: call.url)?.path.hasSuffix("/reviews") == true { return .init(status: 200, body: #"[{"id":2,"body":"Review","submitted_at":"2026-01-03"}]"#) }
            return .init(status: 200, body: #"[{"id":3,"body":"Line","created_at":"2026-01-02"}]"#)
        }
        let result = try await make(http).perform(operation: "pulls.comments", arguments: args([("number", .number(7))]))
        XCTAssertEqual(result["items"].elements?.map { $0["kind"].string }, ["conversation", "line", "review"])
    }
    func testRateErrorsAndResponseStringsNeverReturnToken() async throws {
        let token = self.token
        let http = GHAPIHTTP { _ in .init(status: 403, body: "API rate limit \(token)", headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1120"]) }, service = try make(http, token: token)
        do { _ = try await service.perform(operation: "repos.list", arguments: args()); XCTFail("Expected rate limit") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "rate-limited"); XCTAssertTrue(error.message.contains("2 minutes")); XCTAssertFalse(error.wireValue.compact.contains(token)) }
        let echoed = GHAPIHTTP { _ in .init(status: 200, body: "{\"body\":\"\(token)\",\"access_token\":\"other\"}") }
        let result = try await make(echoed, token: token).perform(operation: "issues.detail", arguments: args([("number", .number(7))]))
        XCTAssertFalse(result.compact.contains(token)); XCTAssertEqual(result["access_token"].string, "[redacted]")
    }
    func testExistingCLIAuthFallbackStaysInternal() async throws {
        let token = self.token, tools = GHAPITools(result: .init(ok: true, stdout: self.token + "\n", stderr: "", missing: false, exitCode: 0, timedOut: false))
        let http = GHAPIHTTP { _ in .init(status: 200, body: "[]") }, service = try make(http, token: nil, tools: tools)
        let result = try await service.perform(operation: "repos.list", arguments: args()), calls = await http.calls(), toolCalls = await tools.calls()
        XCTAssertEqual(toolCalls[0].arguments, ["auth", "token", "--hostname", "github.com"]); XCTAssertNil(toolCalls[0].environment["GH_TOKEN"])
        XCTAssertEqual(calls[0].headers["Authorization"], "Bearer " + token); XCTAssertFalse(result.compact.contains(token))
    }
    func testLogsDownloadNeverReceivesAuthorizationAndChunksUTF8() async throws {
        let token = self.token, log = String(repeating: "a", count: 65_535) + "🙂 done " + self.token
        let http = GHAPIHTTP { call in
            if URL(string: call.url)?.host == "api.github.com" { return .init(status: 302, body: "", headers: ["Location": "https://production.blob.core.windows.net/fixture/job?sig=fixture-signed-link"]) }
            return .init(status: 200, body: log)
        }, service = try make(http, token: token)
        let first = try await service.perform(operation: "actions.logs", arguments: args([("jobId", .number(7))]))
        let second = try await service.perform(operation: "actions.logs", arguments: args([("jobId", .number(7)), ("cursor", first["cursor"])]))
        XCTAssertEqual(first["complete"].bool, false); XCTAssertEqual(second["complete"].bool, true)
        XCTAssertTrue(second["text"].string?.contains("🙂") == true); XCTAssertFalse(second.compact.contains(token))
        let calls = await http.calls(); XCTAssertNil(calls[1].headers["Authorization"]); XCTAssertNil(calls[3].headers["Authorization"])
        XCTAssertFalse(first.compact.contains("fixture-signed-link"))
    }
    func testUntrustedRedirectAndMissingLogsFailClearly() async throws {
        let redirect = GHAPIHTTP { _ in .init(status: 302, body: "", headers: ["Location": "https://attacker.example/logs"]) }, service = try make(redirect)
        await expectError("redirect-refused", service: service, operation: "actions.logs", arguments: args([("jobId", .number(7))]))
        let calls = await redirect.calls(); XCTAssertEqual(calls.count, 1)
        let missing = GHAPIHTTP { _ in .init(status: 404, body: "Not found") }
        await expectError("log-not-ready", service: try make(missing), operation: "actions.logs", arguments: args([("jobId", .number(7))]))
    }
    func testInvalidIDsRepoAndRefsDoNotReachHTTP() async throws {
        let http = GHAPIHTTP { _ in .init(status: 200, body: "[]") }, service = try make(http)
        await expectError("invalid-arguments", service: service, operation: "pulls.detail", arguments: args([("number", .number(1.2))]))
        await expectError("invalid-arguments", service: service, operation: "pulls.detail", arguments: args([("number", .number(1))]).setting("repo", .string("owner/../private")))
        await expectError("invalid-arguments", service: service, operation: "repos.commits", arguments: args([("branch", .string("main?secret"))]))
        await expectError("invalid-arguments", service: service, operation: "repos.list", arguments: args([("perPage", .number(101))]))
        await expectError("unavailable", service: service, operation: "made.up", arguments: args())
        let calls = await http.calls(); XCTAssertTrue(calls.isEmpty)
    }
    func testOversizedAndMalformedResponsesFail() async throws {
        let huge = GHAPIHTTP { _ in .init(status: 200, body: String(repeating: "a", count: BackendGHAPIValidation.maximumJSONBytes + 1)) }
        await expectError("response-too-large", service: try make(huge), operation: "repos.list", arguments: args())
        let malformed = GHAPIHTTP { _ in .init(status: 200, body: "not JSON") }
        await expectError("malformed", service: try make(malformed), operation: "repos.list", arguments: args())
    }
    func testCloneCallbackReceivesOnlyValidatedDestination() async throws {
        let http = GHAPIHTTP { _ in throw NativeRPCError(code: "unexpected", message: "Clone uses no REST") }, recorder = GHAPICloneRecorder()
        let service = try make(http, clone: { request in await recorder.record(request); return BackendGHAPIValidation.object([("ok", .bool(true)), ("folder", .string(request.parentPath + "/" + request.directoryName))]) })
        let input = args([("parentPath", .string("/tmp/projects")), ("directoryName", .string("Native Project")), ("branch", .string("feature/native"))])
        let result = try await service.perform(operation: "repos.clone", arguments: input)
        XCTAssertEqual(result["folder"].string, "/tmp/projects/Native Project")
        let requests = await recorder.requests(); XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests[0].repo, "owner/project"); XCTAssertEqual(requests[0].host, "github.com")
        await expectError("invalid-arguments", service: service, operation: "repos.clone", arguments: input.setting("directoryName", .string("../outside")))
        await expectError("unavailable", service: try make(http), operation: "repos.clone", arguments: input)
    }
    func testStringNotificationIDRepoInboxAndDates() async throws {
        let http = GHAPIHTTP { _ in .init(status: 205, body: "") }, service = try make(http)
        _ = try await service.perform(operation: "notifications.read", arguments: args([("threadId", .string("18446744073709551615"))]))
        let calls = await http.calls(); XCTAssertEqual(URL(string: calls[0].url)?.path, "/notifications/threads/18446744073709551615")
        await expectError("invalid-arguments", service: service, operation: "notifications.read", arguments: args([("threadId", .string("7/../../other"))]))
        let inbox = GHAPIHTTP { _ in .init(status: 200, body: "[]") }, inboxService = try make(inbox)
        _ = try await inboxService.perform(operation: "notifications.list", arguments: args([("since", .string("2026-10-08T00:00:00Z")), ("before", .string("2026-10-08T01:00:00Z"))]))
        let inboxCalls = await inbox.calls(), components = URLComponents(string: inboxCalls[0].url)
        XCTAssertEqual(components?.path, "/repos/owner/project/notifications")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "since" })?.value, "2026-10-08T00:00:00Z")
        await expectError("invalid-arguments", service: inboxService, operation: "notifications.list", arguments: args([("since", .string("tomorrow"))]))
    }
    func testLineOnlyCommentHasApprovedDefaultAndReleaseIsPrereleaseDraft() async throws {
        let http = GHAPIHTTP { _ in .init(status: 201, body: #"{"id":1}"#) }, service = try make(http)
        let comment = BackendGHAPIValidation.object([("path", .string("README.md")), ("line", .number(1)), ("side", .string("LEFT")), ("body", .string("Needs detail"))])
        _ = try await service.perform(operation: "pulls.review", arguments: args([("number", .number(7)), ("event", .string("COMMENT")), ("comments", .array([comment]))]))
        _ = try await service.perform(operation: "repos.draftRelease", arguments: args([("tagName", .string("v2-beta")), ("prerelease", .bool(true))]))
        let calls = await http.calls()
        XCTAssertEqual(try value(calls[0].body!)["body"].string, "Review comments")
        XCTAssertEqual(try value(calls[1].body!)["prerelease"].bool, true); XCTAssertEqual(try value(calls[1].body!)["draft"].bool, true)
    }
    func testNonfiniteRateHeaderAndAuthenticatedRedirectFailSafely() async throws {
        let rate = GHAPIHTTP { _ in .init(status: 429, body: "Limited", headers: ["Retry-After": "NaN"]) }
        await expectError("rate-limited", service: try make(rate), operation: "repos.list", arguments: args())
        let moved = GHAPIHTTP { _ in .init(status: 307, body: "", headers: ["Location": "https://attacker.example/repos"]) }
        await expectError("redirect-refused", service: try make(moved), operation: "repos.list", arguments: args())
        let calls = await moved.calls(); XCTAssertEqual(calls.count, 1)
    }
    func testBinaryFileAndThreeCommentListsKeepPaginationHonest() async throws {
        let http = GHAPIHTTP { call in
            if URL(string: call.url)?.path.hasSuffix("/files") == true { return .init(status: 200, body: #"[{"filename":"image.png","status":"modified"}]"#) }
            return .init(status: 200, body: "[]", headers: call.url.contains("/reviews?") ? ["Link": "<https://api.github.com/next?page=2>; rel=\"next\""] : [:])
        }, service = try make(http)
        let files = try await service.perform(operation: "pulls.files", arguments: args([("number", .number(7))]))
        XCTAssertTrue(files["items"].elements?.first?["patch"].isNullish == true)
        let comments = try await service.perform(operation: "pulls.comments", arguments: args([("number", .number(7))]))
        XCTAssertEqual(comments["hasMore"].bool, true); XCTAssertEqual(comments["page"].number, 1)
    }
    func testLogStreamDownloadsOnceAndKeepsUTF8AndRedaction() async throws {
        let token = self.token, log = String(repeating: "x", count: 65_535) + "🙂 " + self.token + String(repeating: "z", count: 80_000)
        let http = GHAPIHTTP { call in
            if URL(string: call.url)?.host == "api.github.com" { return .init(status: 302, body: "", headers: ["Location": "https://production.blob.core.windows.net/job"]) }
            return .init(status: 200, body: log)
        }, service = try make(http, token: token)
        var chunks: [NativeRPCValue] = []
        for try await chunk in service.streamJobLogs(arguments: args([("jobId", .number(7))])) { chunks.append(chunk) }
        XCTAssertEqual(chunks.count, 3); XCTAssertEqual(chunks.last?["complete"].bool, true)
        let text = chunks.compactMap { $0["text"].string }.joined()
        XCTAssertTrue(text.contains("🙂")); XCTAssertFalse(text.contains("�")); XCTAssertFalse(text.contains(token))
        let calls = await http.calls(); XCTAssertEqual(calls.count, 2); XCTAssertNil(calls[1].headers["Authorization"])
    }
    func testCancelLogConsumerCancelsPendingDownload() async throws {
        let gate = GHAPILogGate()
        let http = GHAPIHTTP { _ in
            await gate.started()
            do { try await Task.sleep(for: .seconds(30)); return .init(status: 200, body: "late") }
            catch { await gate.cancelled(); throw error }
        }, service = try make(http)
        let stream = service.streamJobLogs(arguments: args([("jobId", .number(7))]))
        let consumer = Task { for try await _ in stream {} }
        await gate.waitForStart()
        consumer.cancel()
        _ = await consumer.result
        for _ in 0..<100 { if await gate.didCancel() { break }; try await Task.sleep(for: .milliseconds(10)) }
        let cancelled = await gate.didCancel(); XCTAssertTrue(cancelled)
        let calls = await http.calls(); XCTAssertEqual(calls.count, 1)
    }
    func testCheckAndLegacyStatusWithSameIDKeepSeparateIdentityAndPagination() async throws {
        let http = GHAPIHTTP { call in
            let path = URL(string: call.url)?.path ?? ""
            if path.hasSuffix("/pulls/7") { return .init(status: 200, body: #"{"head":{"sha":"abc1234"}}"#) }
            if path.hasSuffix("/check-runs") { return .init(status: 200, body: #"{"check_runs":[{"id":42,"name":"Build","conclusion":"success"}]}"#) }
            return .init(status: 200, body: #"{"state":"failure","statuses":[{"id":42,"context":"Legacy deploy","state":"failure"}]}"#, headers: ["Link": "<https://api.github.com/next?page=3>; rel=\"next\""])
        }, service = try make(http)
        let result = try await service.perform(operation: "pulls.checks", arguments: args([("number", .number(7)), ("page", .number(2)), ("perPage", .number(10))]))
        XCTAssertEqual(result["items"].elements?.map { $0["kind"].string }, ["check-run", "status"])
        XCTAssertEqual(result["hasMore"].bool, true); XCTAssertEqual(result["status"]["state"].string, "failure")
        let keys = Set((result["items"].elements ?? []).map { "\($0["kind"].string ?? ""):\($0["id"].number ?? 0)" })
        XCTAssertEqual(keys.count, 2)
        let calls = await http.calls(); XCTAssertTrue(calls.suffix(2).allSatisfy { $0.url.contains("page=2") && $0.url.contains("per_page=10") })
    }
    func testBlockedAndChangedHeadMergeResponsesGiveNextSteps() async throws {
        for (status, code, phrase) in [(405, "merge-refused", "required reviews"), (409, "conflict", "Refresh")] {
            let http = GHAPIHTTP { _ in .init(status: status, body: #"{"message":"Merge blocked"}"#) }, service = try make(http)
            do {
                _ = try await service.perform(operation: "pulls.merge", arguments: args([("number", .number(7)), ("mergeMethod", .string("squash")), ("expectedHeadSHA", .string("abc1234"))]))
                XCTFail("Expected a refused merge")
            } catch let error as NativeRPCError { XCTAssertEqual(error.code, code); XCTAssertTrue(error.message.contains(phrase)) }
        }
    }
}

actor GHAPIHTTP: BackendGitHubHTTPFetching {
    struct Call: Sendable { let url: String, method: String; let headers: [String: String]; let body: String? }
    private var values: [Call] = []
    private let handler: @Sendable (Call) async throws -> BackendGitHubHTTPResponse
    init(_ handler: @escaping @Sendable (Call) async throws -> BackendGitHubHTTPResponse) { self.handler = handler }
    func fetch(url: String, method: String, headers: [String: String], body: String?, timeoutMilliseconds: Int) async throws -> BackendGitHubHTTPResponse {
        let call = Call(url: url, method: method, headers: headers, body: body); values.append(call); return try await handler(call)
    }
    func calls() -> [Call] { values }
}
actor GHAPITools: BackendGitHubToolRunning {
    struct Call: Sendable { let arguments: [String]; let environment: [String: String] }
    private var values: [Call] = []
    private let result: BackendGitOutcome
    init(result: BackendGitOutcome = .init(ok: false, stdout: "", stderr: "No fixture login", missing: true, exitCode: 127, timedOut: false)) { self.result = result }
    func run(tool: String, arguments: [String], cwd: String?, environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        values.append(.init(arguments: arguments, environment: environment)); return result
    }
    func calls() -> [Call] { values }
}
actor GHAPICloneRecorder {
    private var values: [BackendGHCloneRequest] = []
    func record(_ value: BackendGHCloneRequest) { values.append(value) }
    func requests() -> [BackendGHCloneRequest] { values }
}
actor GHAPILogGate {
    private var begun = false, stopped = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func started() { begun = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
    func waitForStart() async { if !begun { await withCheckedContinuation { waiters.append($0) } } }
    func cancelled() { stopped = true }
    func didCancel() -> Bool { stopped }
}
