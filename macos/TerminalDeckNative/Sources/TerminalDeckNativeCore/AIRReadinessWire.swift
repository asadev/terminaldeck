import Foundation

/// The AIR bridge's values stay in Core so UI and MCP share one wire shape.
public enum AIRReadinessWire {
    public static func wire(_ plan: AIRReadinessActionPlan) -> NativeRPCValue {
        object([("checkID", .string(plan.checkID)), ("title", .string(plan.title)),
                ("agent", optional(plan.agent)), ("missingAndWhy", .string(plan.missingAndWhy)),
                ("steps", strings(plan.steps)), ("fix", plan.fix.map(wire) ?? .null),
                ("automaticFixAvailable", .bool(plan.automaticFixAvailable)),
                ("manualReason", optional(plan.manualReason)), ("aiPrompt", .string(plan.aiPrompt))])
    }
    public static func wire(_ change: AIRReadinessFileChange) -> NativeRPCValue {
        object([("path", .string(change.path)), ("before", optional(change.before)),
                ("after", optional(change.after)), ("action", optional(change.action))])
    }
    public static func wire(_ preview: AIRReadinessFixPreview) -> NativeRPCValue {
        object([("id", .string(preview.id)), ("projectPath", .string(preview.projectPath)),
                ("checkID", .string(preview.checkID)), ("agent", optional(preview.agent)),
                ("fixID", .string(preview.fixID)), ("title", .string(preview.title)),
                ("summary", .string(preview.summary)), ("changes", .array(preview.changes.map(wire))),
                ("checkFingerprint", .string(preview.checkFingerprint)),
                ("createdAt", .string(preview.createdAt)), ("expiresAt", .string(preview.expiresAt))])
    }
    public static func wire(_ outcome: AIRReadinessFixOutcome) -> NativeRPCValue {
        object([("result", wire(outcome.result)), ("report", wire(outcome.report))])
    }
    public static func wire(_ progress: AIRReadinessProgress) -> NativeRPCValue {
        object([("passing", .number(Double(progress.passing))), ("applicable", .number(Double(progress.applicable))),
                ("remaining", .number(Double(progress.remaining))), ("skipped", .number(Double(progress.skipped))),
                ("unverified", .number(Double(progress.unverified))), ("score", .number(Double(progress.score))),
                ("ready", .bool(progress.ready)), ("label", .string(progress.label))])
    }
    public static func wire(_ check: ReadinessCheck) -> NativeRPCValue {
        object([("id", .string(check.id)), ("title", .string(check.title)), ("status", .string(check.status.rawValue)),
                ("weight", .number(check.weight)), ("detail", .string(check.detail)), ("fix", check.fix.map(wire) ?? .null),
                ("gate", .bool(check.gate)), ("opens", optional(check.opens))])
    }
    public static func wire(_ fix: ReadinessFix) -> NativeRPCValue {
        object([("id", .string(fix.id)), ("label", .string(fix.label)), ("description", .string(fix.description)),
                ("touches", strings(fix.touches)), ("destructive", .bool(fix.destructive))])
    }
    public static func wire(_ report: ReadinessReport) -> NativeRPCValue {
        let agents = report.agents.map { row in
            object([("agent", .string(row.agent)), ("label", .string(row.label)), ("file", .string(row.file)),
                    ("check", wire(row.check)), ("score", .number(Double(row.score))),
                    ("band", .string(row.band.rawValue)), ("cappedBy", optional(row.cappedBy))])
        }
        return object([("projectPath", .string(report.projectPath)), ("score", .number(Double(report.score))),
                       ("band", .string(report.band.rawValue)), ("checks", .array(report.checks.map(wire))),
                       ("cappedBy", optional(report.cappedBy)), ("agents", .array(agents)),
                       ("scannedAt", .string(report.scannedAt))])
    }
    public static func wire(_ result: ReadinessFixResult) -> NativeRPCValue {
        object([("ok", .bool(result.ok)), ("message", .string(result.message)), ("changed", strings(result.changed))])
    }
    private static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue {
        .object(pairs.map { .init($0.0, $0.1) })
    }
    private static func optional(_ string: String?) -> NativeRPCValue { string.map(NativeRPCValue.string) ?? .null }
    private static func strings(_ values: [String]) -> NativeRPCValue { .array(values.map(NativeRPCValue.string)) }
}
