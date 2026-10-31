import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

private actor ApprovalAuthorizationFixture {
    var snapshots: [NativeRPCValue]
    var calls: [(BackendMCPTier, Bool)] = []
    init(_ snapshots: [NativeRPCValue]) { self.snapshots = snapshots }
    func read() -> NativeRPCValue { snapshots.count > 1 ? snapshots.removeFirst() : snapshots[0] }
    func authorize(_ tier: BackendMCPTier, _ owner: Bool) throws {
        guard calls.isEmpty else { throw NativeRPCError.invalidArguments("Effect gate entered twice.") }
        calls.append((tier, owner))
    }
    func recorded() -> [(BackendMCPTier, Bool)] { calls }
}

final class ChatApprovalAuthorityTests: XCTestCase, @unchecked Sendable {
    private func request(nonce: String?) throws -> NativeRPCValue {
        var value = try NativeRPCValue.parseJSON(Data(#"{"requestId":"same-id","subtype":"item/commandExecution/requestApproval","input":{"command":"cat fixture.txt","availableDecisions":["accept","acceptForSession","decline"]}}"#.utf8))
        if let nonce { value = value.setting("approvalNonce", .string(nonce)) }
        return value
    }
    private func snapshot(_ request: NativeRPCValue) -> NativeRPCValue { .object([.init("pending", .array([request]))]) }
    private var caller: BackendMCPCallContext { .init(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
        allowedTools: [], allowedTiers: [.act, .alter], cancellation: .init()) }
    private func run(_ fixture: ApprovalAuthorizationFixture, answers: NativeRPCValue) async throws -> NativeRPCValue {
        try await NativeChatApprovalAuthority.authorize(requestID: "same-id", allowed: true, answers: answers,
            ownerMustAnswer: false, caller: caller, read: { await fixture.read() },
            authorize: { _, tier, _, owner in try await fixture.authorize(tier, owner) })
    }
    func testSingleGateEntryPreservesOnceAndRequiresOwnerForRememberedPermission() async throws {
        for scope in ["once", "session"] {
            let original = try request(nonce: "lifetime-1")
            let fixture = ApprovalAuthorizationFixture([snapshot(original)])
            let bound = try await run(fixture, answers: .object([.init("scope", .string(scope))]))
            let calls = await fixture.recorded()
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls[0].0, scope == "session" ? .alter : .act)
            XCTAssertEqual(calls[0].1, scope == "session")
            XCTAssertEqual(bound["approvalNonce"].string, "lifetime-1")
            // The store checks this payload again atomically before writing to the CLI.
            XCTAssertThrowsError(try BackendChatApproval.validate(request(nonce: "replacement"), allowed: true, answers: bound))
        }
    }
    func testIdenticalOperationInNewRequestLifetimeCannotBorrowOwnerConfirmation() async throws {
        let fixture = ApprovalAuthorizationFixture([snapshot(try request(nonce: "lifetime-1")), snapshot(try request(nonce: "lifetime-2"))])
        do { _ = try await run(fixture, answers: .object([.init("scope", .string("session"))])); XCTFail("A replacement request borrowed approval.") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "stale-approval") }
        let calls = await fixture.recorded()
        XCTAssertEqual(calls.count, 1)
    }
    func testOldHelperAndStaleCallerCannotStartRememberedApproval() async throws {
        let cases: [(String?, NativeRPCValue)] = [(nil, .object([.init("scope", .string("session"))])),
            ("current", .object([.init("scope", .string("session")), .init("approvalNonce", .string("old"))]))]
        for (nonce, answers) in cases {
            let fixture = ApprovalAuthorizationFixture([snapshot(try request(nonce: nonce))])
            do { _ = try await run(fixture, answers: answers); XCTFail("An unbound remembered approval was accepted.") } catch { }
            let calls = await fixture.recorded()
            XCTAssertTrue(calls.isEmpty)
        }
    }
}
