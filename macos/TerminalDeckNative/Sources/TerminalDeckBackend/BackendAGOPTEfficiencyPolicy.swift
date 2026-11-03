import Foundation
import TerminalDeckNativeCore

/// Helpers for the original AGS value; no separate settings store or profile.
public enum BackendAGOPTEfficiencyPolicy {
    public static func merge(_ base: AGOPTEfficiencySettings?, _ next: AGOPTEfficiencySettings?) -> AGOPTEfficiencySettings? {
        guard base != nil || next != nil else { return nil }
        var result = base ?? AGOPTEfficiencySettings()
        if let value = next?.reuseContext { result.reuseContext = value }
        if let value = next?.completion { result.completion = value }
        if let value = next?.addonsOff { result.addonsOff = value }
        if let value = next?.agentTokenBudget { result.agentTokenBudget = value }
        if let value = next?.taskTokenBudget { result.taskTokenBudget = value }
        if let value = next?.warningPercent { result.warningPercent = value }
        if let value = next?.serializeHeavyJobs { result.serializeHeavyJobs = value }
        if let value = next?.monthlyBudgetUSD { result.monthlyBudgetUSD = value }
        if let value = next?.onExhaustion { result.onExhaustion = value }
        return result
    }
    public static func check(_ settings: AGOPTEfficiencySettings?) throws {
        guard let settings else { return }
        if let value = settings.completion, !["stop", "park"].contains(value) { throw NativeRPCError.invalidArguments("When work finishes, choose Stop or Park.") }
        if let amount = settings.monthlyBudgetUSD, !amount.isFinite || amount < 0 || amount > 1_000_000_000 {
            throw NativeRPCError.invalidArguments("The monthly money budget must be from 0 to 1,000,000,000 USD.")
        }
        if let action = settings.onExhaustion, !["pause", "warn"].contains(action) { throw NativeRPCError.invalidArguments("When the budget runs out, choose Pause or Only warn.") }
        for budget in [settings.agentTokenBudget, settings.taskTokenBudget].compactMap({ $0 }) {
            guard (0...1_000_000_000).contains(budget) else { throw NativeRPCError.invalidArguments("Token budgets are from 0 to 1,000,000,000. Zero means no limit.") }
        }
        if let percent = settings.warningPercent, !(1...100).contains(percent) { throw NativeRPCError.invalidArguments("Warn at a percentage from 1 to 100.") }
    }
    public static func requireNarrowing(_ child: AGOPTEfficiencySettings?, owner: AGOPTEfficiencySettings?) throws {
        try check(child); try check(owner)
        func budget(_ child: Int?, _ owner: Int?) -> Bool {
            let a = child ?? 0, b = owner ?? 0
            return b == 0 || a > 0 && a <= b
        }
        let money = child?.monthlyBudgetUSD ?? 0, ownerMoney = owner?.monthlyBudgetUSD ?? 0
        guard (ownerMoney == 0 || money > 0 && money <= ownerMoney),
              owner?.onExhaustion != "pause" || child?.onExhaustion == "pause" else {
            throw NativeRPCError(code: "not-permitted", message: "A key may only narrow its owner's money budget and pause policy.")
        }
        guard budget(child?.agentTokenBudget, owner?.agentTokenBudget), budget(child?.taskTokenBudget, owner?.taskTokenBudget),
              (child?.warningPercent ?? 80) <= (owner?.warningPercent ?? 80),
              owner?.addonsOff != true || child?.addonsOff == true,
              owner?.completion != "stop" || child?.completion == "stop",
              owner?.reuseContext != false || child?.reuseContext == false,
              owner?.serializeHeavyJobs == false || child?.serializeHeavyJobs != false else {
            throw NativeRPCError(code: "not-permitted", message: "A key may only narrow its owner's efficiency controls.")
        }
    }
    /// Called only with a canonical, already authorized task record.
    public static func taskChoices(_ settings: AGSAgentSettings, task: NativeRPCValue) throws -> AGSAgentSettings {
        var result = settings
        if let model = task["model"].string { result.model = model }
        if let effort = task["effort"].string { result.effort = effort == "auto" ? nil : effort }
        if let budget = task["tokenBudget"].number {
            guard budget.isFinite, budget.rounded() == budget, (0...1_000_000_000).contains(budget) else { throw NativeRPCError.invalidArguments("The task token budget is invalid.") }
            var controls = result.efficiency ?? .init()
            // A task can shorten its profile budget but cannot remove or increase it.
            let profileBudget = controls.taskTokenBudget ?? 0
            guard profileBudget == 0 || budget > 0 && budget <= Double(profileBudget) else { throw NativeRPCError(code: "not-permitted", message: "The task budget cannot exceed the profile budget.") }
            controls.taskTokenBudget = Int(budget); result.efficiency = controls
        }
        try BackendAGSValidation.check(result); return result
    }
}
