import Foundation
import TerminalDeckNativeCore

enum NativeChatPolicy {
    static func effective(_ events: [HootChatEvent], current: NativeRPCValue) -> (NativeRPCValue, String?) {
        guard current.fields != nil, current["authority"].string == "provider-response" else { return (.object([]), nil) }
        let source = events.last(where: { $0.record.kind == .session && $0.record.value["effectivePolicy"] == current })?.id
        return (current, source)
    }
    private static func clean(_ value: NativeRPCValue, keys: [String]) -> NativeRPCValue {
        if let text = value.string { return .string(String(text.prefix(4096))) }
        if let flag = value.bool { return .bool(flag) }
        guard value.fields != nil else { return .null }
        var fields: [NativeRPCValue.Field] = []
        for key in keys {
            let item = value[key]
            if let text = item.string { fields.append(.init(key, .string(String(text.prefix(4096))))) }
            else if let flag = item.bool { fields.append(.init(key, .bool(flag))) }
            else if let rows = item.elements { fields.append(.init(key, .array(rows.prefix(100).compactMap { $0.string.map { .string(String($0.prefix(4096))) } }))) }
        }
        return fields.isEmpty ? .null : .object(fields)
    }
    static func state(_ policy: NativeRPCValue, source: String?, choice: HootPermissionMode) -> NativeRPCValue {
        let sandbox = clean(policy["sandbox"], keys: ["type", "writableRoots", "readOnlyRoots", "networkAccess"])
        let approval = clean(policy["approval"], keys: ["type"])
        let trust = clean(policy["workspaceTrust"], keys: ["status", "trustedRoots"])
        let network = clean(policy["network"], keys: ["enabled", "allowedDomains", "blockedDomains"])
        func describe(_ value: NativeRPCValue) -> String {
            if value.isNullish { return "Not reported by the provider" }
            if let text = value.string { return text }
            if let flag = value.bool { return flag ? "Reported enabled" : "Reported disabled" }
            return (value.fields ?? []).map { field in
                let content = field.value.elements?.compactMap(\.string).joined(separator: ", ") ?? field.value.string ?? field.value.bool.map { $0 ? "Yes" : "No" } ?? "Unknown"
                return "\(field.key): \(content)"
            }.joined(separator: "\n")
        }
        let fields: [(String, String, NativeRPCValue)] = [("sandbox", "Effective sandbox", sandbox), ("approval", "Effective approval policy", approval), ("workspaceTrust", "Effective workspace trust", trust), ("network", "Effective network policy", network)]
        return NativeChatPanel.state("Effective provider boundaries", "Only the helper’s current provider receipt counts as current policy. Historical records alone cannot establish a restarted process’s boundary. Missing values stay unknown. The app's permission choice is shown separately and does not establish sandbox, workspace trust or network access. Lists are bounded to 100 entries and values to 4096 characters.", fields.map { NativeChatPanel.row($0.0, $0.1, describe($0.2)) } + [NativeChatPanel.row("choice", "App permission choice", choice.fullName)], [NativeChatPanel.action("Open Chat permission choice", "permissions"), NativeChatPanel.action("Open provider settings", "manage")]).setting("effective", .object(fields.map { .init($0.0, $0.2) })).setting("sourceEvent", source.map(NativeRPCValue.string) ?? .null).setting("appPermissionChoice", .string(choice.rawValue))
    }
}
extension NativeHootChatModel {
    func policyTool(_ action: String) throws -> NativeRPCValue {
        featurePanel("policy", action)
        if action == "permissions" { _ = try controlsTool("open", request: "permissions") }
        if action == "manage", !fixtureMode { NativeChatAccount.openSettings(provider: reportedChatProvider) }
        let (policy, source) = NativeChatPolicy.effective(transcriptExportEvents, current: chatCurrentEffectiveProviderPolicy)
        return NativeChatPolicy.state(policy, source: source, choice: composerDraft.permissionMode)
    }
}
