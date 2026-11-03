import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class AGOPTEfficiencyPolicyTests: XCTestCase {
    func testDefaultsAndProfileInheritFieldByFieldAndZeroRemainsExplicit() throws {
        let defaults = AGSAgentSettings(efficiency: .init(reuseContext: true, agentTokenBudget: 1000, taskTokenBudget: 400, warningPercent: 75))
        let profile = AGSAgentSettings(efficiency: .init(reuseContext: false, agentTokenBudget: 0))
        let resolved = try BackendAGSPolicy.resolve(defaults: defaults, profile: profile)
        XCTAssertEqual(resolved.efficiency?.reuseContext, false)
        XCTAssertEqual(resolved.efficiency?.agentTokenBudget, 0)
        XCTAssertEqual(resolved.efficiency?.taskTokenBudget, 400)
        XCTAssertEqual(resolved.efficiency?.warningPercent, 75)
    }
    func testKeysCannotRaiseRemoveOrDelayOwnerBudget() throws {
        let owner = AGOPTEfficiencySettings(completion: "stop", addonsOff: true, agentTokenBudget: 1000, taskTokenBudget: 200, warningPercent: 70, serializeHeavyJobs: true)
        let narrowed = AGOPTEfficiencySettings(completion: "stop", addonsOff: true, agentTokenBudget: 500, taskTokenBudget: 100, warningPercent: 50, serializeHeavyJobs: true)
        XCTAssertNoThrow(try BackendAGOPTEfficiencyPolicy.requireNarrowing(narrowed, owner: owner))
        var widened = narrowed; widened.agentTokenBudget = 0
        XCTAssertThrowsError(try BackendAGOPTEfficiencyPolicy.requireNarrowing(widened, owner: owner))
        widened = narrowed; widened.warningPercent = 90
        XCTAssertThrowsError(try BackendAGOPTEfficiencyPolicy.requireNarrowing(widened, owner: owner))
        widened = narrowed; widened.completion = "park"
        XCTAssertThrowsError(try BackendAGOPTEfficiencyPolicy.requireNarrowing(widened, owner: owner))
        widened = narrowed; widened.serializeHeavyJobs = false
        XCTAssertThrowsError(try BackendAGOPTEfficiencyPolicy.requireNarrowing(widened, owner: owner))
    }
    func testTaskOverridesKeepPermissionsAndAreInFirstLaunchArguments() throws {
        let owner = AGSAgentSettings(model: "owner-model", effort: "low", permissionMode: "plan", allowedTools: ["Read"], efficiency: .init(taskTokenBudget: 100))
        let task: NativeRPCValue = .object([.init("model", .string("task-model")), .init("effort", .string("high")), .init("tokenBudget", .number(50))])
        let settings = try BackendAGOPTEfficiencyPolicy.taskChoices(owner, task: task)
        XCTAssertEqual(settings.permissionMode, "plan"); XCTAssertEqual(settings.allowedTools, ["Read"])
        let plan = try BackendAGSLaunch.plan(settings, privateDirectory: URL(fileURLWithPath: "/tmp/agopt-stub"), installedHelp: "--model --effort --permission-mode --tools --allowedTools --strict-mcp-config", knownServers: [])
        XCTAssertEqual(Array(plan.arguments.prefix(4)), ["--model", "task-model", "--effort", "high"])
        XCTAssertEqual(plan.arguments.filter { $0 == "--model" }.count, 1)
        XCTAssertThrowsError(try BackendAGOPTEfficiencyPolicy.taskChoices(owner, task: task.setting("tokenBudget", .number(0))))
        XCTAssertThrowsError(try BackendAGOPTEfficiencyPolicy.taskChoices(owner, task: task.setting("tokenBudget", .number(101))))
    }
    func testAddonsOffPreservesRealControlServerAndDropsExtraLeaseGrants() {
        let settings = AGSAgentSettings(efficiency: .init(addonsOff: true))
        let tools: Set<String> = ["tools_run", "notifications_wait"]
        XCTAssertEqual(BackendAGSLaunchBinding.grant(tools, server: "deck-control", settings: settings), tools)
        XCTAssertEqual(BackendAGSLaunchBinding.grant(tools, server: "extra-addon", settings: settings), [])
    }
    func testWorkToolsJoinOnlyRealTaskGrantsAndStillHonorProfileDenials() {
        let task = BackendTAGToolPolicy.sessionNames(taskID: "local:worker")
        for id in BackendAGOPTWorkMCP.toolIDs {
            XCTAssertTrue(task.contains(id)); XCTAssertTrue(task.contains(id.replacingOccurrences(of: ".", with: "_")))
            XCTAssertFalse(BackendTAGToolPolicy.sessionNames(taskID: nil).contains(id))
        }
        let filtered = BackendTAGToolPolicy.filter(task, server: "deck-control", allowed: nil, denied: ["mcp__deck-control__agents_work_change"])
        XCTAssertFalse(filtered.contains("agents.work_change")); XCTAssertFalse(filtered.contains("agents_work_change"))
    }
    func testInvalidPoliciesFailBeforeLaunch() {
        XCTAssertThrowsError(try BackendAGSValidation.check(AGSAgentSettings(efficiency: .init(completion: "wait forever"))))
        XCTAssertThrowsError(try BackendAGSValidation.check(AGSAgentSettings(efficiency: .init(agentTokenBudget: -1))))
        XCTAssertThrowsError(try BackendAGSValidation.check(AGSAgentSettings(efficiency: .init(warningPercent: 101))))
    }
    func testMonthlyMoneyAndPauseDefaultsSurviveAProfileTokenOverride() throws {
        let defaults = AGSAgentSettings(efficiency: .init(agentTokenBudget: 1000, monthlyBudgetUSD: 25, onExhaustion: "pause"))
        let profile = AGSAgentSettings(efficiency: .init(agentTokenBudget: 500))
        let resolved = try BackendAGSPolicy.resolve(defaults: defaults, profile: profile)
        XCTAssertEqual(resolved.efficiency?.agentTokenBudget, 500)
        XCTAssertEqual(resolved.efficiency?.monthlyBudgetUSD, 25)
        XCTAssertEqual(resolved.efficiency?.onExhaustion, "pause")
        let noMoneyBudget = AGSAgentSettings(efficiency: .init(monthlyBudgetUSD: 0))
        let removed = try BackendAGSPolicy.resolve(defaults: defaults, profile: noMoneyBudget)
        XCTAssertEqual(removed.efficiency?.monthlyBudgetUSD, 0)
        XCTAssertEqual(removed.efficiency?.onExhaustion, "pause")
    }
    func testAKeyCannotRemoveMoneyBudgetOrReplacePauseWithWarn() throws {
        let owner = AGOPTEfficiencySettings(monthlyBudgetUSD: 25, onExhaustion: "pause")
        let narrow = AGOPTEfficiencySettings(monthlyBudgetUSD: 10, onExhaustion: "pause")
        XCTAssertNoThrow(try BackendAGOPTEfficiencyPolicy.requireNarrowing(narrow, owner: owner))
        XCTAssertThrowsError(try BackendAGOPTEfficiencyPolicy.requireNarrowing(.init(monthlyBudgetUSD: 0, onExhaustion: "pause"), owner: owner))
        XCTAssertThrowsError(try BackendAGOPTEfficiencyPolicy.requireNarrowing(.init(monthlyBudgetUSD: 50, onExhaustion: "pause"), owner: owner))
        XCTAssertThrowsError(try BackendAGOPTEfficiencyPolicy.requireNarrowing(.init(monthlyBudgetUSD: 10, onExhaustion: "warn"), owner: owner))
        XCTAssertThrowsError(try BackendAGOPTEfficiencyPolicy.check(.init(monthlyBudgetUSD: .nan)))
        XCTAssertThrowsError(try BackendAGOPTEfficiencyPolicy.check(.init(onExhaustion: "keep spending")))
    }
}
