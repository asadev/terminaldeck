import Foundation
import TerminalDeckNativeCore

/// MCP callers can restrict a task agent. The native profile page owns relaxations.
public enum BackendTAGProfilePolicy {
    /// Fields only the owner sets; an AI's change goes to the owner as a widening.
    public static let ownerFields: Set<String> = ["verifyCommand"]
    public static let initialFields = ["toolUseRestrictions", "blockedTools", "skillsOff", "allowedTools", "permissionMode", "keepAliveMinutes", "keepAliveUntilClose", "maxConcurrent", "maxRunMinutes"]
    public static func inheritedMode(arguments: [String]) -> String {
        if arguments.contains("--dangerously-skip-permissions") { return "bypassPermissions" }
        if let position = arguments.lastIndex(of: "--permission-mode"), position + 1 < arguments.count { return arguments[position + 1] }
        if let raw = arguments.last(where: { $0.hasPrefix("--permission-mode=") }) { return String(raw.dropFirst("--permission-mode=".count)) }
        return "default"
    }
    public static func validate(input: NativeRPCValue, existing: NativeRPCValue?, inheritedPermissionMode: String = "default", callerKeyID: String? = nil, trustedOwnership: Bool = false) throws -> NativeRPCValue {
        let old = existing ?? .object([])
        var merged = old.merging(input)
        if !trustedOwnership {
            for field in ["creatorKeyId", "keyInitializedFields"] where input.has(field) && input[field] != old[field] && !(input[field].isNullish && old[field].isNullish) { throw refusal("Changing profile creation ownership") }
        }
        let initialized = Set((old["keyInitializedFields"].elements ?? []).compactMap(\.string))
        let ownsFirst = callerKeyID != nil && (existing == nil || old["creatorKeyId"].string == callerKeyID)
        func first(_ field: String) -> Bool { ownsFirst && !initialized.contains(field) }
        if !ToolUseRestrictions.isNarrowing(merged["toolUseRestrictions"], previous: old["toolUseRestrictions"]) { throw refusal("Relaxing Deck tool argument rules") }
        let oldBlocks = Set((old["blockedTools"].elements ?? []).compactMap(\.string))
        let newBlocks = Set((merged["blockedTools"].elements ?? []).compactMap(\.string))
        if !first("blockedTools"), let removed = oldBlocks.subtracting(newBlocks).sorted().first {
            throw refusal("Removing the \(removed) block")
        }
        if !first("skillsOff"), old["skillsOff"].bool == true && merged["skillsOff"].bool != true {
            throw refusal("Turning skills back on")
        }
        if !first("allowedTools"), let before = old["allowedTools"].elements {
            guard let after = merged["allowedTools"].elements else { throw refusal("Removing the tool allow-list") }
            let rules = before.compactMap(\.string)
            let additions = Set(after.compactMap(\.string).filter { tool in !rules.contains { BackendTAGToolPolicy.covers($0, tool: tool) } })
            if let added = additions.sorted().first { throw refusal("Adding \(added) to the tool allow-list") }
        }
        let beforeMode = old["permissionMode"].string ?? inheritedPermissionMode
        let afterMode = merged["permissionMode"].string ?? inheritedPermissionMode
        if !first("permissionMode"), existing != nil, old["permissionMode"].string != merged["permissionMode"].string,
           merged["permissionMode"].string == nil || merged["permissionMode"].string == "default" {
            throw refusal("Changing permission mode from \(beforeMode) to \(afterMode)")
        }
        if !first("permissionMode"), beforeMode != afterMode && (BackendAGSPolicy.permissionRank(beforeMode) == nil || BackendAGSPolicy.permissionRank(afterMode) == nil) {
            throw refusal("Changing permission mode from \(beforeMode) to \(afterMode)")
        }
        if !first("permissionMode"), let before = BackendAGSPolicy.permissionRank(beforeMode), let after = BackendAGSPolicy.permissionRank(afterMode), after > before {
            throw refusal("Changing permission mode from \(beforeMode) to \(afterMode)")
        }
        let beforeClose = old["keepAliveUntilClose"].bool == true
        let afterClose = merged["keepAliveUntilClose"].bool == true
        if !beforeClose && afterClose { throw refusal("Keeping the agent open until you close it") }
        let beforeMinutes = old["keepAliveMinutes"].number ?? Double(TasksLimits.defaultKeepAliveMinutes)
        let afterMinutes = merged["keepAliveMinutes"].number ?? Double(TasksLimits.defaultKeepAliveMinutes)
        guard afterMinutes.isFinite, afterMinutes.rounded() == afterMinutes, (0...1_440).contains(afterMinutes) else {
            throw NativeRPCError.invalidArguments("Keep open has to be a whole number of minutes from 0 to 1440.")
        }
        if !first("keepAliveMinutes"), !beforeClose && !afterClose && afterMinutes > beforeMinutes {
            throw refusal("Extending keep-open from \(Int(beforeMinutes)) to \(Int(afterMinutes)) minutes")
        }
        if existing != nil || ownsFirst || old["creatorKeyId"].string != nil {
            for (field, fallback) in [("maxConcurrent", 0.0), ("maxRunMinutes", Double(TasksLimits.defaultRunMinutes))] where !first(field) && input.has(field) {
                let before = old[field].number ?? fallback, after = merged[field].number ?? fallback
                let wide = before > 0 && (after == 0 || after > before)   // both: 0 is no limit
                if wide { throw refusal("Increasing \(field)") }
            }
        }
        try requireOwnerForCheckCommand(merged, existing: old)
        // Imported provenance is supplied by the source importer.
        for field in ["sourceFile", "sourceDirectory", "syncStatus", "syncedAt", "syncError"] where input.has(field) && input[field] != old[field] && !(input[field].isNullish && old[field].isNullish) {
            throw refusal("Changing the imported agent source")
        }
        if let creator = old["creatorKeyId"].string ?? (ownsFirst ? callerKeyID : nil) {
            merged = merged.setting("creatorKeyId", .string(creator))
            let supplied = trustedOwnership ? (input["keyInitializedFields"].elements ?? []).compactMap(\.string) : Self.initialFields.filter { input.has($0) && !input[$0].isNullish }
            let chosen = initialized.union(supplied)
            merged = merged.setting("keyInitializedFields", .array(chosen.sorted().map(NativeRPCValue.string)))
        }
        return merged
    }

    /// Owner edits close first-value freedom for settings the owner supplied.
    public static func ownershipForSave(_ input: NativeRPCValue, existing: NativeRPCValue?, keyMutation: Bool) -> NativeRPCValue {
        guard let creator = existing?["creatorKeyId"].string ?? (keyMutation ? input["creatorKeyId"].string : nil) else { return input.removing("creatorKeyId").removing("keyInitializedFields") }
        var chosen = Set((existing?["keyInitializedFields"].elements ?? []).compactMap(\.string))
        if keyMutation { chosen.formUnion((input["keyInitializedFields"].elements ?? []).compactMap(\.string)) }
        else { chosen.formUnion(Self.initialFields.filter { input.has($0) }) }
        return input.setting("creatorKeyId", .string(creator)).setting("keyInitializedFields", .array(chosen.sorted().map(NativeRPCValue.string)))
    }
    public static func hasInitialSelection(input: NativeRPCValue, existing: NativeRPCValue?, callerKeyID: String?) -> Bool {
        guard let callerKeyID else { return false }
        if existing == nil { return true }
        guard existing?["creatorKeyId"].string == callerKeyID else { return false }
        let old = Set((existing?["keyInitializedFields"].elements ?? []).compactMap(\.string))
        let selected = Set((input["keyInitializedFields"].elements ?? []).compactMap(\.string))
        return !selected.subtracting(old).isEmpty
    }

    /// #24: the check command is run on this Mac as a shell command after each task, outside the agent's own
    /// permission mode and tool blocks: setting or changing it is the owner's decision. Clearing it narrows.
    public static func requireOwnerForCheckCommand(_ merged: NativeRPCValue, existing: NativeRPCValue?) throws {
        func text(_ value: NativeRPCValue?) -> String { value?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        let command = text(merged["verifyCommand"])
        if !command.isEmpty, command != text(existing?["verifyCommand"]) { throw refusal("Setting the check command") }
    }

    private static func refusal(_ action: String) -> NativeRPCError {
        NativeRPCError(code: "owner-required", message: action + " needs the owner (Settings → Task agents).")
    }
}
