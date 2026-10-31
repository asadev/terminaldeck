import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private actor AGOPTWorkApproval {
    var calls = 0
    var denied = false
    func ask(_ mustAnswer: Bool) throws {
        XCTAssertTrue(mustAnswer); calls += 1
        if denied { throw NativeRPCError(code: "approval-required", message: "Denied") }
    }
    func refuse() { denied = true }
}
final class AGOPTCoordinatorTests: XCTestCase, @unchecked Sendable {
    func testFIFOAndCompletionSignal() async throws {
        let lock = BackendAGOPTCoordinator()
        let one = try await lock.request(owner: "one"), two = try await lock.request(owner: "two"), three = try await lock.request(owner: "three")
        let before = await lock.status(owner: "two")
        XCTAssertEqual(before["position"].number, 1); XCTAssertFalse(before["granted"].bool!)
        let event = Task { await lock.wait(after: UInt64(before["revision"].number!), seconds: 1) }
        try await lock.release(one)
        let revision = await event.value, after = await lock.status(owner: "two")
        XCTAssertGreaterThan(revision, UInt64(before["revision"].number!)); XCTAssertTrue(after["granted"].bool!)
        let third = await lock.status(owner: "three"); XCTAssertEqual(third["position"].number, 1)
        try await lock.release(two); try await lock.waitUntilGranted(three); try await lock.release(three)
        let idle = await lock.status(owner: "one"); XCTAssertFalse(idle["busy"].bool!)
    }
    func testDifferentOwnerCannotReleaseTicketAndDuplicateRejected() async throws {
        let lock = BackendAGOPTCoordinator(), ticket = try await lock.request(owner: "one")
        do { try await lock.release(owner: "two", ticketID: ticket.id); XCTFail("Another owner released the lock") } catch {}
        do { _ = try await lock.request(owner: "one"); XCTFail("Duplicate request passed") } catch {}
        let state = await lock.status(owner: "two"); XCTAssertNil(state["ticket"].string)
        try await lock.release(ticket)
    }
    func testOperationFailureReleasesAndReadWaitCancellationDoesNot() async throws {
        let lock = BackendAGOPTCoordinator()
        do {
            let _: String = try await lock.withLease(owner: "failed") { throw NativeRPCError(code: "stub-error", message: "Expected") }
            XCTFail("Expected stub failure")
        } catch {}
        let idle = await lock.status(owner: "failed"); XCTAssertFalse(idle["busy"].bool!)
        let ticket = try await lock.request(owner: "owner"), state = await lock.status(owner: "owner")
        let cancellation = BackendMCPCancellation(); cancellation.cancel()
        _ = await lock.wait(after: UInt64(state["revision"].number!), seconds: 120, cancellation: cancellation)
        let retained = await lock.status(owner: "owner"); XCTAssertTrue(retained["granted"].bool!)
        try await lock.release(ticket)
    }
    func testCancelledQueuedOperationNeverRunsOrStrandsQueue() async throws {
        let lock = BackendAGOPTCoordinator(), holder = try await lock.request(owner: "holder")
        let queued = Task {
            try await lock.withLease(owner: "cancelled") { XCTFail("Cancelled queued operation ran"); return "bad" }
        }
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Cancelled operation passed") } catch {}
        let state = await lock.status(owner: "holder"); XCTAssertEqual(state["waiting"].number, 0)
        try await lock.release(holder)
    }
    func testSessionCleanupReleasesOnlyExactMappedSession() async throws {
        let lock = BackendAGOPTCoordinator()
        _ = try await lock.request(owner: "session:a", sessionID: "a")
        _ = try await lock.request(owner: "session:b", sessionID: "ba")
        await lock.releaseSession(sessionID: "a")
        let next = await lock.status(owner: "session:b"); XCTAssertTrue(next["granted"].bool!)
        await lock.releaseSession(sessionID: "a")
        let retained = await lock.status(owner: "session:b"); XCTAssertTrue(retained["granted"].bool!)
        await lock.releaseSession(sessionID: "ba")
        let idle = await lock.status(owner: "session:b"); XCTAssertFalse(idle["busy"].bool!)
    }
    func testSilentHolderLosesItsLeaseAndTheNextWaiterStarts() async throws {
        let lock = BackendAGOPTCoordinator(leaseSeconds: 0.2)
        _ = try await lock.request(owner: "key:gone"); let next = try await lock.request(owner: "session:next", sessionID: "next")
        let granted = expectation(description: "next waiter granted after the silent holder's lease")
        let waiter = Task { try await lock.waitUntilGranted(next); granted.fulfill() }
        await fulfillment(of: [granted], timeout: 5); try await waiter.value
        await lock.freeHolder()
        let idle = await lock.status(owner: "session:next"); XCTAssertFalse(idle["busy"].bool!)
    }
    func testHolderCallsRenewTheLeaseAndInProcessLeasesNeverExpire() async throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock(); private var value = Date(timeIntervalSince1970: 1_000_000)
            var now: Date { lock.withLock { value } }
            func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
        }
        let clock = Clock(), lock = BackendAGOPTCoordinator(leaseSeconds: 60, now: { clock.now })
        _ = try await lock.request(owner: "local:holder"); _ = try await lock.request(owner: "key:next")
        clock.advance(50); await lock.renew(owner: "local:holder"); await lock.renew(owner: "key:next")
        clock.advance(50)
        let kept = await lock.status(owner: "local:holder"); XCTAssertTrue(kept["granted"].bool!)
        clock.advance(11)
        let lost = await lock.status(owner: "local:holder"); XCTAssertFalse(lost["granted"].bool!)
        let promoted = await lock.status(owner: "key:next"); XCTAssertTrue(promoted["granted"].bool!)
        await lock.freeHolder()
        let result: String = try await lock.withLease(owner: "task:check") {
            clock.advance(3_600)
            let other = try await lock.request(owner: "key:other"), state = await lock.status(owner: "key:other")
            XCTAssertFalse(state["granted"].bool!); try await lock.release(other)
            return "finished"
        }
        XCTAssertEqual(result, "finished")
        let idle = await lock.status(owner: "key:other"); XCTAssertFalse(idle["busy"].bool!)
    }
    private func access(_ approval: AGOPTWorkApproval, kind: BackendDeckToolsAppCaller.Kind = .session, keyID: String? = nil) -> BackendDeckToolsAppAccess {
        .init(caller: { context in .init(kind: kind, sessionID: kind == .session ? context.sessionID : nil, machineID: context.machineID, keyID: keyID) }, knownFolder: { _, path in path }, session: { _, _ in .null }, runnableProject: { _, path in path }, rpc: { _ in .init(caller: .nativeApp, ownerID: "test") }, authorize: { _, _, _, _, _, must in try await approval.ask(must) }, record: { _, _, _, _ in })
    }
    private func context(_ id: String) -> BackendMCPCallContext {
        .init(sessionID: id, machineID: "stub", projectRoot: nil, attended: true, allowedTools: Set(BackendAGOPTWorkMCP.toolIDs), allowedTiers: [.read, .alter], cancellation: .init())
    }
    func testMCPReadAndWaitFreeChangesAskAndCannotImpersonate() async throws {
        let lock = BackendAGOPTCoordinator(), approval = AGOPTWorkApproval()
        let tools = try BackendAGOPTWorkMCP.definitions(access: access(approval), scope: .init(require: { _, _, mutation in XCTAssertFalse(mutation) }, baseProfile: { _ in .init() }), coordinator: lock)
        let read = try await tools[0].handler(context("one"), .object([.init("profile", .string("worker"))]))
        XCTAssertFalse(read.isError); let free = await approval.calls; XCTAssertEqual(free, 0)
        let acquired = try await tools[1].handler(context("one"), .object([.init("profile", .string("worker")), .init("action", .string("acquire"))]))
        XCTAssertFalse(acquired.isError)
        let value = try XCTUnwrap(acquired.structuredContent), ticket = try XCTUnwrap(value["ticket"].string)
        let wait = try await tools[2].handler(context("one"), .object([.init("profile", .string("worker")), .init("revision", value["revision"]), .init("timeoutSeconds", .number(0))]))
        XCTAssertFalse(wait.isError); let asked = await approval.calls; XCTAssertEqual(asked, 1)
        let impersonation = try await tools[1].handler(context("two"), .object([.init("profile", .string("worker")), .init("action", .string("release")), .init("ticket", .string(ticket))]))
        XCTAssertTrue(impersonation.isError)
        let released = try await tools[1].handler(context("one"), .object([.init("profile", .string("worker")), .init("action", .string("release")), .init("ticket", .string(ticket))]))
        XCTAssertFalse(released.isError)
        await approval.refuse()
        let denied = try await tools[1].handler(context("one"), .object([.init("action", .string("acquire"))]))
        XCTAssertTrue(denied.isError)
    }
    func testLocalAndKeyCallersWorkWithActualEmptyNativeSessionID() async throws {
        let lock = BackendAGOPTCoordinator(), approval = AGOPTWorkApproval()
        let scope = BackendAGSAccess(require: { _, _, _ in }, baseProfile: { _ in .init() })
        let localTools = try BackendAGOPTWorkMCP.definitions(access: access(approval, kind: .local), scope: scope, coordinator: lock)
        let local = try await localTools[1].handler(context(""), .object([.init("action", .string("acquire"))]))
        XCTAssertFalse(local.isError)
        let ticket = try XCTUnwrap(local.structuredContent?["ticket"].string)
        let released = try await localTools[1].handler(context(""), .object([.init("action", .string("release")), .init("ticket", .string(ticket))]))
        XCTAssertFalse(released.isError)
        let keyTools = try BackendAGOPTWorkMCP.definitions(access: access(approval, kind: .key, keyID: "actual-key"), scope: scope, coordinator: lock)
        let key = try await keyTools[1].handler(context(""), .object([.init("profile", .string("worker")), .init("action", .string("acquire"))]))
        XCTAssertFalse(key.isError)
        let keyTicket = try XCTUnwrap(key.structuredContent?["ticket"].string)
        let other = try BackendAGOPTWorkMCP.definitions(access: access(approval, kind: .key, keyID: "other-key"), scope: scope, coordinator: lock)
        let denied = try await other[1].handler(context(""), .object([.init("profile", .string("worker")), .init("action", .string("release")), .init("ticket", .string(keyTicket))]))
        XCTAssertTrue(denied.isError)
        let own = try await keyTools[1].handler(context(""), .object([.init("profile", .string("worker")), .init("action", .string("release")), .init("ticket", .string(keyTicket))]))
        XCTAssertFalse(own.isError)
    }
    func testKeyDisplayNameCannotStandInForKeyIdentity() async throws {
        let lock = BackendAGOPTCoordinator(), approval = AGOPTWorkApproval()
        let tools = try BackendAGOPTWorkMCP.definitions(access: access(approval, kind: .key), scope: .init(require: { _, _, _ in }, baseProfile: { _ in .init() }), coordinator: lock)
        let reply = try await tools[1].handler(context(""), .object([.init("action", .string("acquire"))]))
        XCTAssertTrue(reply.isError); let calls = await approval.calls; XCTAssertEqual(calls, 0)
    }
    func testWrongProfileAndMissingAlterGrantNeverAskOrAcquire() async throws {
        let lock = BackendAGOPTCoordinator(), approval = AGOPTWorkApproval()
        let tools = try BackendAGOPTWorkMCP.definitions(access: access(approval), scope: .init(require: { _, profile, _ in
            guard profile == "assigned" else { throw NativeRPCError(code: "not-granted", message: "Wrong task profile") }
        }, baseProfile: { _ in .init() }), coordinator: lock)
        let wrong = try await tools[1].handler(context("session"), .object([.init("profile", .string("other")), .init("action", .string("acquire"))]))
        XCTAssertTrue(wrong.isError)
        let readOnly = BackendMCPCallContext(sessionID: "session", machineID: "stub", projectRoot: nil, attended: true, allowedTools: Set(BackendAGOPTWorkMCP.toolIDs), allowedTiers: [.read], cancellation: .init())
        let grant = try await tools[1].handler(readOnly, .object([.init("profile", .string("assigned")), .init("action", .string("acquire"))]))
        XCTAssertTrue(grant.isError); let count = await approval.calls; XCTAssertEqual(count, 0)
        let status = await lock.status(owner: "session:stub:session"); XCTAssertFalse(status["busy"].bool!)
    }
    private func rows(_ strings: [String]) throws -> [NativeRPCValue] { try strings.map { try NativeRPCValue.parseJSON(Data($0.utf8)) } }
    func testUsageUsesCumulativeCodexNotContextOrLastRequest() throws {
        let values = try rows([#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":600},"last_token_usage":{"total_tokens":200},"model_context_window":100000}}}"#, #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":900}}}}"#])
        XCTAssertEqual(BackendAGOPTTokenUsage.total(provider: "codex", rows: values), 900)
        XCTAssertNil(BackendAGOPTTokenUsage.total(provider: "codex", rows: try rows([#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#])))
    }
    func testClaudeRepeatedUsageAndCacheAreCountedOnce() throws {
        let values = try rows([#"{"type":"assistant","requestId":"r","message":{"id":"a","usage":{"input_tokens":100,"output_tokens":5,"cache_read_input_tokens":20,"cache_creation_input_tokens":30}}}"#, #"{"type":"assistant","requestId":"r","message":{"id":"a","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30}}}"#])
        XCTAssertEqual(BackendAGOPTTokenUsage.total(provider: "claude", rows: values), 160)
    }
    func testGeminiUpdatesAndRewindAndUnknownRemainMissing() throws {
        let values = try rows([#"{"id":"a","type":"gemini","tokens":{"total":100}}"#, #"{"id":"a","type":"gemini","tokens":{"total":120}}"#, #"{"id":"b","type":"gemini","tokens":{"total":40}}"#, #"{"$rewindTo":"b"}"#])
        XCTAssertEqual(BackendAGOPTTokenUsage.total(provider: "gemini", rows: values), 160)
        XCTAssertNil(BackendAGOPTTokenUsage.total(provider: "gemini", rows: [])); XCTAssertNil(BackendAGOPTTokenUsage.total(provider: "unknown", rows: values))
    }
    func testClaudeScopeIsUsedAndUnscopedOrOtherProjectRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-claude-" + UUID().uuidString)
        let project = "/tmp/agopt-approved-project"
        let scope = NativeTranscriptScope(configDirectory: root.path, projectFolders: [project])
        let directory = try XCTUnwrap(NativeTranscriptPaths.projectDirectories(project, scope: scope).first)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = URL(fileURLWithPath: directory).appendingPathComponent("conversation.jsonl")
        try Data(#"{"type":"assistant","message":{"id":"a","usage":{"input_tokens":50,"output_tokens":20}}}"#.utf8).write(to: file)
        XCTAssertEqual(try BackendAGOPTTokenUsage.read(provider: "claude", target: .init(path: file.path, scope: scope)), 70)
        XCTAssertThrowsError(try BackendAGOPTTokenUsage.read(provider: "claude", target: .init(path: file.path, roots: [root.path])))
        let wrongScope = NativeTranscriptScope(configDirectory: root.path, projectFolders: ["/tmp/another-project"])
        XCTAssertThrowsError(try BackendAGOPTTokenUsage.read(provider: "claude", target: .init(path: file.path, scope: wrongScope)))
    }
    func testUsageReaderConfinesFileToExactAccountRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agopt-usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        try Data(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":300}}}}"#.utf8).write(to: file)
        XCTAssertEqual(try BackendAGOPTTokenUsage.read(provider: "codex", target: .init(path: file.path, roots: [root.path])), 300)
        XCTAssertThrowsError(try BackendAGOPTTokenUsage.read(provider: "codex", target: .init(path: file.path, roots: [root.appendingPathComponent("elsewhere").path])))
    }
}
