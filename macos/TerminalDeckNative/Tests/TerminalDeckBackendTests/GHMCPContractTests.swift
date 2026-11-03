import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor GHMCPFakeService: BackendGHWorkspaceServing {
    private(set) var calls: [(String, NativeRPCValue)] = []
    private(set) var cancelled = false
    private(set) var rpcOwner: String?
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    let wait: Bool
    let failure: NativeRPCError?
    init(wait: Bool = false, failure: NativeRPCError? = nil) { self.wait = wait; self.failure = failure }
    func perform(operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        calls.append((operation, arguments))
        rpcOwner = NativeCompositionCallContext.rpc?.ownerID
        let waiters = startedWaiters; startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if wait {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch is CancellationError { cancelled = true; throw CancellationError() }
        }
        if let failure { throw failure }
        return .object([.init("items", .array([.object([.init("body", .string("private result body")), .init("author", .string("private author"))])])),
                        .init("page", .number(1)), .init("hasMore", .bool(false))])
    }
    func waitUntilStarted() async {
        if !calls.isEmpty { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func count() -> Int { calls.count }
    func lastArguments() -> NativeRPCValue? { calls.last?.1 }
    func operations() -> [String] { calls.map(\.0) }
}

private actor GHMCPAudit {
    struct Approval: Sendable { let id: String; let tier: BackendMCPTier; let owner: Bool; let arguments: NativeRPCValue }
    private(set) var approvals: [Approval] = []
    private(set) var records: [(NativeRPCValue, NativeRPCValue)] = []
    private(set) var folderChecks: [String] = []
    private var folderAllowed = true
    private var projectRepo = "sample/deck"
    let deny: Bool
    let revokeOnApproval: Bool
    let changeRepoOnApproval: Bool
    init(deny: Bool = false, revokeOnApproval: Bool = false, changeRepoOnApproval: Bool = false) {
        self.deny = deny; self.revokeOnApproval = revokeOnApproval; self.changeRepoOnApproval = changeRepoOnApproval
    }
    func folder(_ path: String) throws -> String {
        folderChecks.append(path)
        guard folderAllowed, path == "/work/deck" else {
            throw NativeRPCError(code: "not-granted", message: "This project folder has not been granted.")
        }
        return path
    }
    func repo(_ path: String) throws -> String { projectRepo }
    func approve(_ id: String, _ args: NativeRPCValue, _ tier: BackendMCPTier, _ owner: Bool) throws {
        approvals.append(.init(id: id, tier: tier, owner: owner, arguments: args))
        if deny, tier != .read { throw NativeRPCError(code: "approval-denied", message: "The person declined this GitHub change.") }
        if revokeOnApproval { folderAllowed = false }
        if changeRepoOnApproval { projectRepo = "sample/other" }
    }
    func record(_ args: NativeRPCValue, _ summary: NativeRPCValue) { records.append((args, summary)) }
    func approvalCount() -> Int { approvals.count }
    func recordCount() -> Int { records.count }
    func allApprovals() -> [Approval] { approvals }
    func allMetadata() -> String { approvals.map { $0.arguments.compact }.joined() + records.map { $0.0.compact + $0.1.compact }.joined() }
}

final class GHMCPContractTests: XCTestCase {
    private func context(tools: Set<String>? = nil, tiers: Set<BackendMCPTier> = [.read, .act, .alter],
                         cancellation: BackendMCPCancellation = .init()) -> BackendMCPCallContext {
        .init(sessionID: "gh-fixture", machineID: "", projectRoot: "/work/deck", attended: true,
              allowedTools: tools ?? Set(BackendGHMCPCatalogue.entries().map(\.id)), allowedTiers: tiers, cancellation: cancellation)
    }
    private func access(_ audit: GHMCPAudit, kind: BackendDeckToolsAppCaller.Kind = .local,
                        cancellation: BackendMCPCancellation? = nil) -> BackendDeckToolsAppAccess {
        .init(caller: { _ in .init(kind: kind, sessionID: kind == .session ? "gh-fixture" : nil) },
              knownFolder: { _, path in try await audit.folder(path) },
              session: { _, _ in throw NativeRPCError(code: "unavailable", message: "Unused fixture session.") },
              runnableProject: { _, path in try await audit.folder(path) },
              rpc: { _ in .init(caller: .internalEngine, ownerID: "gh-fixture") },
              authorize: { _, id, args, tier, _, owner in
                  try await audit.approve(id, args, tier, owner)
                  cancellation?.cancel()
              }, record: { _, _, args, summary in await audit.record(args, summary) })
    }
    private func tool(_ operation: BackendGHOperation, service: GHMCPFakeService, audit: GHMCPAudit,
                      kind: BackendDeckToolsAppCaller.Kind = .local, mapRepo: Bool = true,
                      cancellation: BackendMCPCancellation? = nil) throws -> BackendDeckToolsDefinition {
        var mapping: BackendGHMCPTools.RepoForFolder?
        if mapRepo { mapping = { path in try await audit.repo(path) } }
        return try XCTUnwrap(BackendGHMCPTools.definitions(service: service, access: access(audit, kind: kind, cancellation: cancellation), repoForFolder: mapping)
            .first { $0.spec.id == "github." + operation.rawValue })
    }
    private func arguments(_ operation: BackendGHOperation) -> NativeRPCValue {
        var args = NativeRPCValue.object([.init("repo", .string("sample/deck"))])
        switch operation {
        case .pullsList: return args.setting("scope", .string("repo"))
        case .reposList, .notificationsList: return .object([])
        case .notificationsRead: return .object([.init("threadId", .string("123"))])
        case .reposBranches, .reposCommits, .reposReleases, .actionsRuns, .issuesList: return args
        case .actionsJobs, .actionsRerun, .actionsCancel: return args.setting("runId", .number(101))
        case .actionsLogs: return args.setting("jobId", .number(202))
        case .reposDraftRelease: return args.setting("tagName", .string("v1.0"))
        case .reposClone: return args.setting("parentPath", .string("/work/deck")).setting("directoryName", .string("cloned"))
        case .pullsCreate: return args.setting("title", .string("Proposed change")).setting("head", .string("feature")).setting("base", .string("main"))
        case .issuesCreate: return args.setting("title", .string("Proposed issue"))
        default: args = args.setting("number", .number(7))
        }
        switch operation {
        case .pullsComment, .issuesComment: return args.setting("body", .string("private proposed comment"))
        case .pullsReview: return args.setting("event", .string("APPROVE"))
        case .pullsUpdate, .issuesUpdate: return args.setting("state", .string("closed"))
        case .issuesAssign: return args.setting("assignees", .array([.string("reviewer")]))
        case .issuesLabels: return args.setting("labels", .array([.string("bug")]))
        default: return args
        }
    }

    func testEveryNativeOperationHasOneToolWithItsExactTier() throws {
        let entries = BackendGHMCPCatalogue.entries()
        XCTAssertEqual(entries.count, 31)
        XCTAssertEqual(Set(entries.map(\.operation)), Set(BackendGHOperation.allCases))
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertFalse(entries.contains { ["github.look", "github.connect"].contains($0.id) })
        let source = try BackendDeckToolsAppMetadata.entries().map { $0.spec.id }
        XCTAssertTrue(Set(source).isDisjoint(with: Set(entries.map(\.id))))
        for entry in entries {
            let spec = try entry.specification()
            XCTAssertEqual(spec.tier, entry.operation.isWrite ? .alter : .read, entry.id)
            XCTAssertEqual(spec.inputSchema["additionalProperties"], .bool(false))
            XCTAssertEqual(spec.inputSchema["properties"]["projectPath"]["type"], .string("string"))
            XCTAssertFalse(spec.inputSchema.compact.lowercased().contains("token"))
        }
    }

    func testDeniedApprovalStopsEveryMutationBeforeService() async throws {
        for operation in BackendGHOperation.allCases where operation.isWrite {
            let service = GHMCPFakeService(), audit = GHMCPAudit(deny: true)
            let reply = try await tool(operation, service: service, audit: audit).handler(context(), arguments(operation))
            XCTAssertTrue(reply.isError, operation.rawValue)
            XCTAssertEqual(reply.structuredContent?["code"], .string("approval-denied"), operation.rawValue)
            let calls = await service.count(), count = await audit.approvalCount(), records = await audit.recordCount()
            XCTAssertEqual(calls, 0, operation.rawValue); XCTAssertEqual(count, 1); XCTAssertEqual(records, 0)
            let approval = await audit.allApprovals().first
            XCTAssertEqual(approval?.tier, .alter); XCTAssertEqual(approval?.owner, true)
        }
    }

    func testReadsStayFreeAndEachToolDispatchesItsExactOperation() async throws {
        let service = GHMCPFakeService(), audit = GHMCPAudit(deny: true)
        for operation in BackendGHOperation.allCases where !operation.isWrite {
            let reply = try await tool(operation, service: service, audit: audit).handler(context(tiers: [.read]), arguments(operation))
            XCTAssertFalse(reply.isError, operation.rawValue)
            XCTAssertEqual(reply.structuredContent?["page"], .number(1))
            XCTAssertEqual(reply.structuredContent?["hasMore"], .bool(false))
        }
        let operations = await service.operations(), approvals = await audit.allApprovals()
        XCTAssertEqual(Set(operations), Set(BackendGHOperation.allCases.filter { !$0.isWrite }.map(\.rawValue)))
        XCTAssertTrue(approvals.allSatisfy { $0.tier == .read && !$0.owner })
        let owner = await service.rpcOwner; XCTAssertEqual(owner, "gh-fixture")
    }

    func testToolAndTierGrantsFailBeforeApprovalOrAPI() async throws {
        let service = GHMCPFakeService(), audit = GHMCPAudit(), definition = try tool(.pullsComment, service: service, audit: audit)
        for caller in [context(tools: []), context(tiers: [.read])] {
            let reply = try await definition.handler(caller, arguments(.pullsComment))
            XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["code"], .string("not-granted"))
        }
        let calls = await service.count(), approvals = await audit.approvalCount()
        XCTAssertEqual(calls, 0); XCTAssertEqual(approvals, 0)
    }

    func testRemoteAndOtherCallersCannotBorrowLocalGitHubAccount() async throws {
        for kind in [BackendDeckToolsAppCaller.Kind.remote, .other] {
            let service = GHMCPFakeService(), audit = GHMCPAudit()
            let reply = try await tool(.issuesDetail, service: service, audit: audit, kind: kind).handler(context(), arguments(.issuesDetail))
            XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["code"], .string("not-granted"))
            let calls = await service.count(), approvals = await audit.approvalCount()
            XCTAssertEqual(calls, 0); XCTAssertEqual(approvals, 0)
        }
    }

    func testKeyCallerUsesExistingPersonApproval() async throws {
        let service = GHMCPFakeService(), audit = GHMCPAudit(deny: true)
        let reply = try await tool(.issuesComment, service: service, audit: audit, kind: .key).handler(context(), arguments(.issuesComment))
        XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["code"], .string("approval-denied"))
        let calls = await service.count(); XCTAssertEqual(calls, 0)
    }

    func testGrantedSessionCanReadOnlyItsExactProjectRepo() async throws {
        let service = GHMCPFakeService(), audit = GHMCPAudit()
        let definition = try tool(.pullsDetail, service: service, audit: audit, kind: .session)
        let args = arguments(.pullsDetail).setting("projectPath", .string("/work/deck"))
        let accepted = try await definition.handler(context(tiers: [.read]), args)
        XCTAssertFalse(accepted.isError)
        let refused = try await definition.handler(context(tiers: [.read]), args.setting("repo", .string("sample/other")))
        XCTAssertTrue(refused.isError); XCTAssertEqual(refused.structuredContent?["code"], .string("not-granted"))
        let calls = await service.count(); XCTAssertEqual(calls, 1)
    }

    func testSessionWriteStillRequiresPersonApproval() async throws {
        let service = GHMCPFakeService(), audit = GHMCPAudit(deny: true)
        let args = arguments(.pullsReview).setting("projectPath", .string("/work/deck"))
        let reply = try await tool(.pullsReview, service: service, audit: audit, kind: .session).handler(context(), args)
        XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["code"], .string("approval-denied"))
        let calls = await service.count(), approvals = await audit.allApprovals()
        XCTAssertEqual(calls, 0); XCTAssertEqual(approvals.first?.owner, true)
    }

    func testSessionWithoutMappingOrProjectCannotRun() async throws {
        let service = GHMCPFakeService(), audit = GHMCPAudit()
        for (hasMapping, hasProject) in [(false, true), (true, false)] {
            let definition = try tool(.issuesDetail, service: service, audit: audit, kind: .session, mapRepo: hasMapping)
            let args = hasProject ? arguments(.issuesDetail).setting("projectPath", .string("/work/deck")) : arguments(.issuesDetail)
            let reply = try await definition.handler(context(), args)
            XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["code"], .string("not-granted"))
        }
        let calls = await service.count(); XCTAssertEqual(calls, 0)
    }

    func testSessionsCannotReadGlobalInboxRepositoriesOrClone() async throws {
        for operation in [BackendGHOperation.reposList, .notificationsList, .notificationsRead, .reposClone] {
            let service = GHMCPFakeService(), audit = GHMCPAudit()
            let args = arguments(operation).setting("projectPath", .string("/work/deck"))
            let reply = try await tool(operation, service: service, audit: audit, kind: .session).handler(context(), args)
            XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["code"], .string("not-granted"))
            let calls = await service.count(), approvals = await audit.approvalCount()
            XCTAssertEqual(calls, 0); XCTAssertEqual(approvals, 0)
        }
    }

    func testSessionCannotRequestGlobalMineOrReviewRequestedPulls() async throws {
        let service = GHMCPFakeService(), audit = GHMCPAudit()
        let definition = try tool(.pullsList, service: service, audit: audit, kind: .session)
        for scope in ["mine", "review-requested"] {
            let args = NativeRPCValue.object([.init("scope", .string(scope)), .init("projectPath", .string("/work/deck"))])
            let reply = try await definition.handler(context(), args)
            XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["code"], .string("not-granted"))
        }
        let calls = await service.count(); XCTAssertEqual(calls, 0)
    }

    func testRevokedFolderAndChangedRepoAfterApprovalStopWrites() async throws {
        for audit in [GHMCPAudit(revokeOnApproval: true), GHMCPAudit(changeRepoOnApproval: true)] {
            let service = GHMCPFakeService()
            let args = arguments(.issuesComment).setting("projectPath", .string("/work/deck"))
            let reply = try await tool(.issuesComment, service: service, audit: audit, kind: .session).handler(context(), args)
            XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["code"], .string("not-granted"))
            let calls = await service.count(), approvals = await audit.approvalCount()
            XCTAssertEqual(calls, 0); XCTAssertEqual(approvals, 1)
        }
    }

    func testCloneRejectsForeignFolderBeforeApprovalAndRechecksAfter() async throws {
        for (audit, folder) in [(GHMCPAudit(), "/work/foreign"), (GHMCPAudit(revokeOnApproval: true), "/work/deck")] {
            let service = GHMCPFakeService()
            let reply = try await tool(.reposClone, service: service, audit: audit).handler(context(), arguments(.reposClone).setting("parentPath", .string(folder)))
            XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["code"], .string("not-granted"))
            let calls = await service.count(); XCTAssertEqual(calls, 0)
        }
    }

    func testCancellationBeforeCallOrDuringApprovalHasNoAPIEffect() async throws {
        for cancelDuringApproval in [false, true] {
            let service = GHMCPFakeService(), audit = GHMCPAudit(), cancellation = BackendMCPCancellation()
            if !cancelDuringApproval { cancellation.cancel() }
            let definition = try tool(.pullsMerge, service: service, audit: audit, cancellation: cancelDuringApproval ? cancellation : nil)
            do { _ = try await definition.handler(context(cancellation: cancellation), arguments(.pullsMerge)); XCTFail("Expected cancellation") }
            catch is CancellationError { }
            let calls = await service.count(); XCTAssertEqual(calls, 0)
        }
    }

    func testCallerCancellationCancelsInFlightServiceTask() async throws {
        let service = GHMCPFakeService(wait: true), audit = GHMCPAudit(), cancellation = BackendMCPCancellation()
        let definition = try tool(.actionsLogs, service: service, audit: audit), caller = context(cancellation: cancellation), args = arguments(.actionsLogs)
        let call = Task { try await definition.handler(caller, args) }
        await service.waitUntilStarted()
        cancellation.cancel()
        do { _ = try await call.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        let cancelled = await service.cancelled, records = await audit.recordCount()
        XCTAssertTrue(cancelled); XCTAssertEqual(records, 0)
    }

    func testMalformedArgumentsNeverReachApprovalOrService() async throws {
        let service = GHMCPFakeService(), audit = GHMCPAudit()
        let invalid: [(BackendGHOperation, NativeRPCValue)] = [
            (.pullsDetail, .array([])),
            (.pullsDetail, arguments(.pullsDetail).setting("repo", .string("owner/name/other"))),
            (.pullsDetail, arguments(.pullsDetail).setting("number", .number(0))),
            (.pullsDetail, arguments(.pullsDetail).setting("number", .number(1.5))),
            (.pullsDetail, .object([.init("repo", .string("sample/deck")), .init("repo", .string("sample/other")), .init("number", .number(7))])),
            (.pullsList, arguments(.pullsList).setting("perPage", .number(101))),
            (.pullsMerge, arguments(.pullsMerge).setting("mergeMethod", .string("delete"))),
            (.pullsReview, arguments(.pullsReview).setting("event", .string("REQUEST_CHANGES"))),
            (.pullsReview, arguments(.pullsReview).setting("event", .string("COMMENT"))),
            (.issuesUpdate, .object([.init("repo", .string("sample/deck")), .init("number", .number(7))])),
            (.issuesAssign, arguments(.issuesAssign).setting("assignees", .array([.string("reviewer"), .string("reviewer")]))),
            (.issuesList, arguments(.issuesList).setting("query", .string("bug OR repo:foreign/repo"))),
            (.reposClone, arguments(.reposClone).setting("directoryName", .string("../outside"))),
            (.notificationsRead, arguments(.notificationsRead).setting("threadId", .string("../other"))),
            (.pullsComment, arguments(.pullsComment).setting("token", .string("forbidden")))
        ]
        for (operation, args) in invalid {
            let reply = try await tool(operation, service: service, audit: audit).handler(context(), args)
            XCTAssertTrue(reply.isError, "\(operation.rawValue): \(args.compact)")
            XCTAssertEqual(reply.structuredContent?["code"], .string("invalid-arguments"))
        }
        let calls = await service.count(), approvals = await audit.approvalCount()
        XCTAssertEqual(calls, 0); XCTAssertEqual(approvals, 0)
    }

    func testReviewPreservesNativeLineCommentPayloadAfterApproval() async throws {
        let service = GHMCPFakeService(), audit = GHMCPAudit()
        let line = NativeRPCValue.object([.init("path", .string("Sources/View.swift")), .init("body", .string("private proposed line comment")),
            .init("line", .number(10)), .init("side", .string("RIGHT")), .init("startLine", .number(8)), .init("startSide", .string("RIGHT"))])
        let args = arguments(.pullsReview).setting("event", .string("COMMENT")).setting("comments", .array([line]))
        let reply = try await tool(.pullsReview, service: service, audit: audit).handler(context(), args)
        XCTAssertFalse(reply.isError)
        let delivered = await service.lastArguments(), metadata = await audit.allMetadata()
        XCTAssertEqual(delivered?["comments"], .array([line]))
        XCTAssertFalse(metadata.contains("private proposed line comment")); XCTAssertFalse(metadata.contains("private result body")); XCTAssertFalse(metadata.contains("private author"))
    }

    func testMalformedMultiLineCommentIsRejected() throws {
        let line = NativeRPCValue.object([.init("path", .string("Sources/View.swift")), .init("body", .string("Review")),
            .init("line", .number(10)), .init("side", .string("RIGHT")), .init("startLine", .number(12)), .init("startSide", .string("RIGHT"))])
        let args = arguments(.pullsReview).setting("comments", .array([line]))
        XCTAssertThrowsError(try BackendGHMCPTools.validate(operation: .pullsReview, arguments: args))
        XCTAssertThrowsError(try BackendGHMCPTools.validate(operation: .pullsReview, arguments: args.setting("comments", .array([line.setting("path", .string("../other"))]))))
    }

    func testAPIRateLimitAndPermissionErrorsAreNotEmptySuccesses() async throws {
        for error in [NativeRPCError(code: "github-rate-limit", message: "GitHub's request limit is reached. Try again after 10:30."),
                      NativeRPCError(code: "github-permission", message: "This GitHub account cannot read that repository.")] {
            let service = GHMCPFakeService(failure: error), audit = GHMCPAudit()
            let reply = try await tool(.reposBranches, service: service, audit: audit).handler(context(), arguments(.reposBranches))
            XCTAssertTrue(reply.isError); XCTAssertEqual(reply.structuredContent?["code"], .string(error.code))
            XCTAssertEqual(reply.structuredContent?["error"], .string(error.message))
            let records = await audit.recordCount(); XCTAssertEqual(records, 0)
        }
    }
}
