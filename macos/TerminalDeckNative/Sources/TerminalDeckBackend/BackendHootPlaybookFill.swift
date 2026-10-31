import Foundation
import TerminalDeckNativeCore

/// What a session is started with once the playbook has filled in what the caller left out.
public struct BackendPlaybookChoice: Sendable, Equatable {
    /// The playbook row that was used ("" = none matched).
    public var jobKind = ""
    public var provider: String?
    public var model: String?
    public var effort: String?
    /// The CLI's own word for the chosen AI ("acceptEdits", "workspace-write", …).
    public var permissionMode: String?
    public var instructions = ""
    /// Which of ai / model / effort / permission / instructions came from the playbook.
    public var fromPlaybook: [String] = []
    /// What the caller chose differently, and anything that could not be applied. Plain sentences.
    public var notes: [String] = []
    public var reason: String?

    /// Nothing was supplied or changed (no row, or a row with nothing in it).
    public var isEmpty: Bool { fromPlaybook.isEmpty && model == nil && effort == nil && permissionMode == nil && instructions.isEmpty && notes.isEmpty }
    public var wireValue: NativeRPCValue {
        func text(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
        return .object([.init("job", jobKind.isEmpty ? .null : .string(jobKind)), .init("ai", text(provider)), .init("model", text(model)),
                        .init("effort", text(effort)), .init("permission", text(permissionMode)),
                        .init("instructions", instructions.isEmpty ? .null : .string(instructions)),
                        .init("fromPlaybook", .array(fromPlaybook.map(NativeRPCValue.string))),
                        .init("notes", .array(notes.map(NativeRPCValue.string))), .init("reason", text(reason))])
    }
}

/// Deck Memory: the playbook in use. When Hoot (or a lead) starts a session and leaves out the
/// AI, model, effort, permission or standing instructions, the playbook row for that kind of job
/// supplies them. The caller can differ, with a reason; Bypass can only come from the playbook.
public enum BackendPlaybookFill {
    public struct Asked: Sendable, Equatable {
        public var provider: String?
        public var model: String?
        public var effort: String?
        public var permission: String?
        public var instructions: String?
        public var reason: String?
        public init(provider: String? = nil, model: String? = nil, effort: String? = nil, permission: String? = nil,
                    instructions: String? = nil, reason: String? = nil) {
            self.provider = provider; self.model = model; self.effort = effort; self.permission = permission
            self.instructions = instructions; self.reason = reason
        }
    }

    /// "Claude Code", "codex", "GPT", "gemini" → the app's id for that AI.
    public static func ai(_ text: String) -> String? {
        let low = text.lowercased()
        if low.contains("claude") || low.contains("anthropic") { return "claude" }
        if low.contains("codex") || low.contains("gpt") || low.contains("openai") { return "codex" }
        if low.contains("gemini") || low.contains("google") { return "gemini" }
        return nil
    }
    /// "ask first", "plan only", "auto", "bypass" (or a CLI's own word) → the app's four choices.
    public static func permission(_ text: String) -> BackendHOOTSIMPermissionMode? {
        let low = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        if ["bypass", "bypasspermissions", "bypass permissions", "danger full access", "yolo", "full access"].contains(low) { return .bypass }
        if ["plan", "plan only", "read only", "readonly"].contains(low) { return .plan }
        if ["auto", "changes", "edits", "accept edits", "acceptedits", "auto edit", "workspace write"].contains(low) { return .changes }
        if ["ask", "ask first", "default", "normal"].contains(low) { return .ask }
        return nil
    }
    /// "Extra high", "x-high", "Ultracode" → the CLI's own level name, when that AI has it.
    public static func effort(_ text: String, provider: String) -> String? {
        var low = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["extra", "extra high", "extra-high", "x-high", "x high"].contains(low) { low = "xhigh" }
        return AGSCapabilities.efforts(provider: provider).contains(low) ? low : nil
    }

    /// `fallbackProvider`: the app's default AI, used only to check a level or a permission when no AI was named.
    public static func resolve(row: DeckMemoryPlaybookRow?, asked: Asked, fallbackProvider: String = "claude") throws -> BackendPlaybookChoice {
        var choice = BackendPlaybookChoice()
        let reason = asked.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        choice.reason = reason?.isEmpty == false ? reason : nil
        choice.jobKind = row?.jobKind ?? ""
        let rowAI = row.flatMap { ai($0.ai) }
        choice.provider = asked.provider ?? rowAI
        if asked.provider == nil, rowAI != nil { choice.fromPlaybook.append("ai") }
        let concrete = choice.provider ?? fallbackProvider
        // A model or level written for one AI is never handed to another.
        let otherAI = rowAI != nil && asked.provider != nil && asked.provider != rowAI
        if otherAI, let row, !(row.model.isEmpty && row.effort.isEmpty) {
            choice.notes.append("The playbook's model and effort for \"\(row.jobKind)\" are for \(row.ai); you chose \(asked.provider ?? ""), so they were not used.")
        }
        var differs: [String] = []
        func clean(_ value: String?) -> String? {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        }
        let rowModel = otherAI ? nil : clean(row?.model), rowEffortText = otherAI ? nil : clean(row?.effort)

        // Model
        if let model = clean(asked.model) {
            choice.model = model
            if let rowModel, rowModel != model { differs.append("model \(rowModel)") }
        } else if let rowModel { choice.model = rowModel; choice.fromPlaybook.append("model") }

        // Effort
        if let wanted = clean(asked.effort) {
            guard let level = effort(wanted, provider: concrete) else {
                throw NativeRPCError.invalidArguments("effort \"\(wanted)\" is not a level \(concrete) has. Use one of: \(AGSCapabilities.efforts(provider: concrete).joined(separator: ", ")).")
            }
            choice.effort = level
            if let rowEffortText, effort(rowEffortText, provider: concrete) != level { differs.append("effort \(rowEffortText)") }
        } else if let rowEffortText {
            if let level = effort(rowEffortText, provider: concrete) { choice.effort = level; choice.fromPlaybook.append("effort") }
            else { choice.notes.append("The playbook's effort \"\(rowEffortText)\" is not a level \(concrete) has, so its own default was used.") }
        }

        // Permission
        let rowPermission = clean(row?.permission), rowMode = rowPermission.flatMap(permission)
        var mode: BackendHOOTSIMPermissionMode?
        if let wanted = clean(asked.permission) {
            guard let chosen = permission(wanted) else {
                throw NativeRPCError.invalidArguments("permission \"\(wanted)\" is not known. Use ask, plan, auto or leave it out.")
            }
            if chosen == .bypass, rowMode != .bypass {
                throw NativeRPCError.invalidArguments("Only the person can choose Bypass. It has to be written in the playbook for this kind of job; leave permission out of `differ` or use ask, plan or auto.")
            }
            mode = chosen
            if let rowMode, rowMode != chosen { differs.append("permission \(rowPermission ?? "")") }
        } else if let rowPermission {
            if let rowMode { mode = rowMode; choice.fromPlaybook.append("permission") }
            else { choice.notes.append("The playbook's permission \"\(rowPermission)\" is not one this app knows (ask, plan, auto, bypass), so the AI's own setting was used.") }
        }
        if let mode, let cli = HootChatProvider(rawValue: concrete) { choice.permissionMode = mode.cliMode(provider: cli) }

        // Standing instructions
        let rowInstructions = clean(row?.instructions)
        if let own = clean(asked.instructions) {
            choice.instructions = own
            if let rowInstructions, rowInstructions != own { differs.append("standing instructions") }
        } else if let rowInstructions { choice.instructions = rowInstructions; choice.fromPlaybook.append("instructions") }

        if !differs.isEmpty {
            guard let reason = choice.reason else {
                throw NativeRPCError.invalidArguments("The playbook for \"\(choice.jobKind)\" jobs says \(differs.joined(separator: ", ")). To differ, add `reason` (one line on why) inside `differ`; or leave `differ` out and the playbook is used.")
            }
            choice.notes.append("Differs from the playbook (\(differs.joined(separator: ", "))) because: \(reason)")
        }
        return choice
    }

    /// The brief a worker reads first: what was asked, then the playbook's standing instructions, the
    /// report form, and who is asking (the assistant's words are never the person's own).
    public static func brief(_ brief: String, choice: BackendPlaybookChoice) -> String {
        var parts = [brief]
        if !choice.instructions.isEmpty { parts.append("## Standing instructions\n" + choice.instructions) }
        parts.append(BackendHootDesk.reportForm)
        parts.append("## Who is asking\n\(BackendSharedBrand.assistant), this app's assistant, wrote this brief for the person. It is not the person's own typing: where it quotes the person it says so, and everything else is \(BackendSharedBrand.assistant)'s.")
        return parts.joined(separator: "\n\n")
    }

    /// The playbook row for a job, for the app's own callers. Nil when memory is not ready or has no row.
    public static func row(owner: DeckMemoryOwner, job: String, memory: any DeckMemoryStoring = DeckMemory.store) async -> DeckMemoryPlaybookRow? {
        await BackendMCPCallBudget.within(3) { try? await memory.playbookRow(owner, job: job) } ?? nil
    }
}
