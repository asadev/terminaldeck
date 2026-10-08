import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Cross the real MCP-to-REST seam using the API lane's injected fake transport.
/// These checks catch ignored argument names that a fake service cannot see.
@MainActor
final class GHMCPAPIIntegrationTests: XCTestCase {
    private func service(_ http: GHAPIHTTP, tools: GHAPITools = GHAPITools()) throws -> BackendGHWorkspaceService {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gh-mcp-api-fixture-\(UUID())")
        let token = "fixture-token-only"
        let auth = try BackendGitHubAuthenticator(dataDirectory: folder, environment: ["GH_TOKEN": token], tools: tools, resolveRepo: { _ in .null })
        return BackendGHWorkspaceService(authenticator: auth, tools: tools, http: http, environment: [:])
    }
    private func access(deny: Bool = false) -> BackendDeckToolsAppAccess {
        .init(caller: { _ in .init(kind: .local) }, knownFolder: { _, path in path },
              session: { _, _ in .null }, runnableProject: { _, path in path },
              rpc: { _ in .init(caller: .internalEngine, ownerID: "gh-api-integration") },
              authorize: { _, _, _, tier, _, owner in
                  if tier != .read {
                      guard owner else { throw NativeRPCError(code: "approval-missing", message: "The real mutation must request a person's answer.") }
                      if deny { throw NativeRPCError(code: "approval-denied", message: "Declined.") }
                  }
              }, record: { _, _, _, _ in })
    }
    private func invoke(_ operation: BackendGHOperation, service: BackendGHWorkspaceService,
                        args: NativeRPCValue, deny: Bool = false) async throws -> BackendMCPToolReply {
        let id = "github." + operation.rawValue
        let definition = try XCTUnwrap(BackendGHMCPTools.definitions(service: service, access: access(deny: deny)).first { $0.spec.id == id })
        let caller = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: [id], allowedTiers: [.read, .alter], cancellation: .init())
        return try await definition.handler(caller, args)
    }
    private func args(_ fields: [(String, NativeRPCValue)] = []) -> NativeRPCValue {
        BackendGHAPIValidation.object([("repo", .string("sample/deck"))] + fields)
    }

    func testMCPDenialStopsTheRealRESTOwnerBeforeCredentialOrTransportUse() async throws {
        let http = GHAPIHTTP { _ in throw NativeRPCError(code: "unexpected", message: "A denied change must not reach HTTP.") }
        let tools = GHAPITools(), realService = try service(http, tools: tools)
        let reply = try await invoke(.pullsComment, service: realService,
            args: args([("number", .number(7)), ("body", .string("Declined comment"))]), deny: true)
        XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["code"], .string("approval-denied"))
        let requests = await http.calls(), processes = await tools.calls()
        XCTAssertTrue(requests.isEmpty); XCTAssertTrue(processes.isEmpty)
    }

    func testApprovedLineOnlyReviewCrossesTheRESTContractWithoutLosingItsBody() async throws {
        let http = GHAPIHTTP { _ in .init(status: 200, body: #"{"id":42,"state":"COMMENTED"}"#) }
        let line = BackendGHAPIValidation.object([("path", .string("Sources/View.swift")), ("body", .string("Please keep this guard")),
            ("line", .number(12)), ("side", .string("RIGHT")), ("startLine", .number(10)), ("startSide", .string("RIGHT"))])
        let reply = try await invoke(.pullsReview, service: service(http),
            args: args([("number", .number(7)), ("event", .string("COMMENT")), ("comments", .array([line]))]))
        XCTAssertFalse(reply.isError)
        let requests = await http.calls(), request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST"); XCTAssertTrue(request.url.contains("/repos/sample/deck/pulls/7/reviews"))
        let body = try NativeRPCValue.parseJSON(Data(try XCTUnwrap(request.body).utf8))
        XCTAssertEqual(body["event"], .string("COMMENT")); XCTAssertEqual(body["body"], .string("Review comments"))
        XCTAssertEqual(body["comments"].elements?.first?["body"], .string("Please keep this guard"))
        XCTAssertEqual(body["comments"].elements?.first?["start_line"], .number(10))
    }

    func testDraftPrereleaseAndNotificationStringIDReachTheirExactRESTFields() async throws {
        let http = GHAPIHTTP { request in
            .init(status: request.url.contains("/notifications/threads/") ? 204 : 201, body: request.url.contains("/notifications/threads/") ? "" : #"{"id":84,"draft":true,"prerelease":true}"#)
        }
        let realService = try service(http)
        let draft = try await invoke(.reposDraftRelease, service: realService,
            args: args([("tagName", .string("v1.2")), ("prerelease", .bool(true))]))
        XCTAssertFalse(draft.isError)
        let read = try await invoke(.notificationsRead, service: realService, args: .object([.init("threadId", .string("123456789"))]))
        XCTAssertFalse(read.isError)
        let requests = await http.calls(); XCTAssertEqual(requests.count, 2)
        let creation = try XCTUnwrap(requests.first { $0.url.contains("/releases") })
        let body = try NativeRPCValue.parseJSON(Data(try XCTUnwrap(creation.body).utf8))
        XCTAssertEqual(body["draft"], .bool(true)); XCTAssertEqual(body["prerelease"], .bool(true))
        let notification = try XCTUnwrap(requests.first { $0.url.contains("/notifications/threads/123456789") })
        XCTAssertEqual(notification.method, "PATCH")
    }

    func testMergeExpectedHeadAndInboxScopeAreNeverIgnored() async throws {
        let http = GHAPIHTTP { request in
            .init(status: 200, body: request.url.contains("/merge") ? #"{"merged":true}"# : "[]")
        }
        let realService = try service(http), head = String(repeating: "a", count: 40)
        let merge = try await invoke(.pullsMerge, service: realService,
            args: args([("number", .number(7)), ("expectedHeadSHA", .string(head)), ("mergeMethod", .string("squash"))]))
        XCTAssertFalse(merge.isError)
        let inbox = try await invoke(.notificationsList, service: realService,
            args: args([("since", .string("2026-10-01T00:00:00Z")), ("before", .string("2026-10-08T00:00:00Z"))]))
        XCTAssertFalse(inbox.isError)
        let requests = await http.calls(); XCTAssertEqual(requests.count, 2)
        let mergeRequest = try XCTUnwrap(requests.first { $0.url.contains("/merge") })
        let body = try NativeRPCValue.parseJSON(Data(try XCTUnwrap(mergeRequest.body).utf8))
        XCTAssertEqual(body["sha"], .string(head)); XCTAssertEqual(body["merge_method"], .string("squash"))
        let inboxRequest = try XCTUnwrap(requests.first { $0.url.contains("/repos/sample/deck/notifications") })
        let query = URLComponents(string: inboxRequest.url)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "since" }?.value, "2026-10-01T00:00:00Z")
        XCTAssertEqual(query.first { $0.name == "before" }?.value, "2026-10-08T00:00:00Z")
    }
}
