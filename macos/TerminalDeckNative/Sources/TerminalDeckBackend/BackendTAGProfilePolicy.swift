import Foundation
import TerminalDeckNativeCore

/// MCP callers can restrict a task agent. The native profile page owns relaxations.
public enum BackendTAGProfilePolicy {
    public static func inheritedMode(arguments: [String]) -> String {
        if arguments.contains("--dangerously-skip-permissions") { return "bypassPermissions" }
        if let position = arguments.lastIndex(of: "--permission-mode"), position + 1 < arguments.count { return arguments[position + 1] }
        if let raw = arguments.last(where: { $0.hasPrefix("--permission-mode=") }) { return String(raw.dropFirst("--permission-mode=".count)) }
        return "default"
    }
    public static func validate(input: NativeRPCValue, existing: NativeRPCValue?, inheritedPermissionMode: String = "default") throws -> NativeRPCValue {
        let old = existing ?? .object([])
        let merged = old.merging(input)
        let oldBlocks = Set((old["blockedTools"].elements ?? []).compactMap(\.string))
        let newBlocks = Set((merged["blockedTools"].elements ?? []).compactMap(\.string))
        if let removed = oldBlocks.subtracting(newBlocks).sorted().first {
            throw refusal("Removing the \(removed) block")
        }
        if old["skillsOff"].bool == true && merged["skillsOff"].bool != true {
            throw refusal("Turning skills back on")
        }
        if let before = old["allowedTools"].elements {
            guard let after = merged["allowedTools"].elements else { throw refusal("Removing the tool allow-list") }
            let rules = before.compactMap(\.string)
            let additions = Set(after.compactMap(\.string).filter { tool in !rules.contains { BackendTAGToolPolicy.covers($0, tool: tool) } })
            if let added = additions.sorted().first { throw refusal("Adding \(added) to the tool allow-list") }
        }
        let order = ["plan": 0, "default": 1, "acceptEdits": 2, "bypassPermissions": 3]
        let beforeMode = old["permissionMode"].string ?? inheritedPermissionMode
        let afterMode = merged["permissionMode"].string ?? inheritedPermissionMode
        if beforeMode != afterMode && (order[beforeMode] == nil || order[afterMode] == nil) {
            throw refusal("Changing permission mode from \(beforeMode) to \(afterMode)")
        }
        if let before = order[beforeMode], let after = order[afterMode], after > before {
            throw refusal("Changing permission mode from \(beforeMode) to \(afterMode)")
        }
        let beforeClose = old["keepAliveUntilClose"].bool == true
        let afterClose = merged["keepAliveUntilClose"].bool == true
        if !beforeClose && afterClose { throw refusal("Keeping the agent open until you close it") }
        let beforeMinutes = old["keepAliveMinutes"].number ?? 30
        let afterMinutes = merged["keepAliveMinutes"].number ?? 30
        guard afterMinutes.isFinite, afterMinutes.rounded() == afterMinutes, (0...1_440).contains(afterMinutes) else {
            throw NativeRPCError.invalidArguments("Keep open has to be a whole number of minutes from 0 to 1440.")
        }
        if !beforeClose && !afterClose && afterMinutes > beforeMinutes {
            throw refusal("Extending keep-open from \(Int(beforeMinutes)) to \(Int(afterMinutes)) minutes")
        }
        // Imported provenance is supplied by the source importer.
        for field in ["sourceFile", "sourceDirectory", "syncStatus", "syncedAt", "syncError"] where input.has(field) && input[field] != old[field] && !(input[field].isNullish && old[field].isNullish) {
            throw refusal("Changing the imported agent source")
        }
        return merged
    }

    private static func refusal(_ action: String) -> NativeRPCError {
        NativeRPCError(code: "owner-required", message: action + " needs the owner (Settings → Task agents).")
    }
}
