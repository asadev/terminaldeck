import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class AGOPTProfileApprovalGateTests: XCTestCase, @unchecked Sendable {
    typealias Box<T> = HOOTFIXNoCardTests.Box<T>
    struct Rig {
        let control: BackendDeckCoreSecurityControl
        let runs: Box<Int>
    }
    static let args: NativeRPCValue = .object([.init("do", .string("save-many")), .init("ids", .array((1...24).map { .string("agent-\($0)") })), .init("agent", .object([.init("keepAliveUntilClose", .bool(true))]))])
    static let summary = "Commander asks to keep 24 agents open until you close them: " + (1...24).map { "Agent \($0)" }.joined(separator: ", ")
    func rig(changeLimit: Int = 30, toolID: String = "tasks.agents", approvalSummary: String? = nil, changedCount: Int = 24) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AGOPT-approval-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let clock = HOOTFIXNoCardTests.Clock(), runs = Box(0)
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in XCTFail("Widening runs as a standing approval: nothing is asked"); return false })
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: dir), consent: broker,
            budgets: .init(changes: .init(limit: changeLimit, windowMilliseconds: 300_000)), now: { clock.now() }, checkArguments: { _, _ in })
        let spec = try BackendMCPTool(id: toolID, wireName: toolID.replacingOccurrences(of: ".", with: "_"), description: "Profile changes", inputSchema: .object([.init("type", .string("object"))]), tier: .read)
        try await control.register([.init(tool: spec, summary: { _, _ in "Profile changes" }, run: { args, context in
            try await BackendAGOPTProfileApprovalScope.$narrowing.withValue(true) {
                _ = try await control.prepareEffect(context: context, tool: toolID, arguments: args, tier: .alter, sentence: "Apply validated narrowing", ownerMustAnswer: false)
            }
            try await control.approveProfileWidening(context: context, arguments: args, summary: approvalSummary ?? Self.summary)
            runs.edit { $0 += changedCount }
            return .init(value: .object([.init("changed", .number(Double(changedCount)))]))
        })])
        return .init(control: control, runs: runs)
    }
    func key(askFirst: Bool = true) -> BackendDeckCoreSecurityCallOptions {
        .init(caller: .init(kind: .key, tiers: [.read, .act, .alter], keyID: "exact-commander", keyName: "Commander", askFirst: askFirst, tasks: true))
    }
    /// Asad, 11 Oct: "app itself will not ask any permissions at all it all depends on ai model settings directly". A key's
    /// agent widening runs as a standing approval: no card, whatever its old ask-first switch says.
    /// (The rig's broker fails the test if anything is asked.)
    func testKeyWideningRunsWithNoCardWhateverItsAskSetting() async throws {
        for askFirst in [true, false] {
            let r = try await rig()
            let done = await r.control.call(name: "tasks_agents", arguments: Self.args, options: key(askFirst: askFirst))
            XCTAssertTrue(done.ok, done.error ?? ""); XCTAssertEqual(r.runs.get(), 24)
            XCTAssertEqual(done.row["confirmed"]["by"], .string("standing:key:exact-commander"))
        }
    }
    func testOriginalMutationRateLimitStillApplies() async throws {
        let r = try await rig(changeLimit: 1)
        let first = await r.control.call(name: "tasks_agents", arguments: Self.args, options: key())
        XCTAssertTrue(first.ok, first.error ?? ""); XCTAssertEqual(r.runs.get(), 24)
        let second = await r.control.call(name: "tasks_agents", arguments: Self.args, options: key())
        XCTAssertFalse(second.ok); XCTAssertEqual(second.refusal, .rateLimited); XCTAssertEqual(r.runs.get(), 24)
    }
    func testSettingsAndBudgetFieldWideningRunAtOnceAndKeepTheRateBudget() async throws {
        for tool in ["agents.settings_set", "agents.budget_set"] {
            let field = tool == "agents.settings_set" ? "keep_open_until_close" : "monthly_token_budget"
            let args = NativeRPCValue.object([.init("id", .string("agent-1")), .init("field", .string(field)), .init("value", tool == "agents.settings_set" ? .bool(true) : .number(0))])
            let r = try await rig(changeLimit: 1, toolID: tool, changedCount: 1)
            let done = await r.control.call(name: tool.replacingOccurrences(of: ".", with: "_"), arguments: args, options: key())
            XCTAssertTrue(done.ok, done.error ?? ""); XCTAssertEqual(r.runs.get(), 1)
            let fresh = await r.control.call(name: tool.replacingOccurrences(of: ".", with: "_"), arguments: args.setting("id", .string("agent-2")), options: key())
            XCTAssertEqual(fresh.refusal, .rateLimited); XCTAssertEqual(r.runs.get(), 1)
        }
    }
    func testPrivateFieldsCannotUseTheTrustedNarrowingException() async throws {
        let args = NativeRPCValue.object([.init("id", .string("agent-1")), .init("field", .string("hooks")), .init("value", .array([]))])
        let caller = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act, .alter], keyID: "exact-commander", askFirst: true, tasks: true)
        let permitted = BackendAGOPTProfileApprovalScope.$narrowing.withValue(true) {
            BackendAGOPTProfileApprovalScope.permitsNarrowing(tool: "agents.settings_set", arguments: args, caller: caller)
        }
        XCTAssertFalse(permitted)
    }
}
