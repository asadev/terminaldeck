import Foundation
import TerminalDeckNativeCore

public enum BackendChatPlans {
    public static func isReview(_ request: NativeRPCValue) -> Bool {
        request["name"].string == "ExitPlanMode" || request["subtype"].string == "plan-review"
    }
    public static func decision(_ answers: NativeRPCValue, allowed: Bool) throws -> String {
        let decision = answers["decision"].string ?? (allowed ? "approve" : "continue")
        guard ["approve", "revise", "continue"].contains(decision), allowed == (decision == "approve") else {
            throw NativeRPCError.invalidArguments("Choose approve, revise or continue for this plan.")
        }
        if decision == "revise", (answers["feedback"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NativeRPCError.invalidArguments("Write what should change in the plan.")
        }
        return decision
    }
    public static func pending(events: [HootChatEvent], busy: Bool, provider: HootChatProvider) -> NativeRPCValue? {
        guard provider == .codex, !busy, let user = events.last(where: { $0.record.kind == .user }),
              let plan = events.last(where: { $0.turnID == user.turnID && $0.record.kind == .message && $0.record.value["planReview"].bool == true }),
              events.contains(where: { $0.turnID == user.turnID && $0.record.kind == .completed }),
              !events.contains(where: { $0.turnID == user.turnID && [.error, .interrupted].contains($0.record.kind) }) else { return nil }
        return .object([.init("requestId", .string("plan:" + user.turnID)), .init("subtype", .string("plan-review")),
            .init("name", .string("Plan review")), .init("input", .object([.init("plan", plan.record.value["text"])]))])
    }
}
