import Foundation
import TerminalDeckNativeCore

enum NativeChatHooks {
    static func rows(_ events: [HootChatEvent]) -> [NativeRPCValue] {
        events.compactMap { event in
            let value = event.record.value
            let hook: NativeRPCValue
            if value["hook"].fields != nil { hook = value["hook"] }
            else if value["subtype"].string?.hasPrefix("hook_") == true { hook = value }
            else { return nil }
            let name = hook["name"].string ?? hook["hook_name"].string ?? hook["hookName"].string ?? "Reported hook"
            let status = hook["status"].string ?? value["subtype"].string ?? event.record.kind.rawValue
            let complete = ["success", "completed"].contains(status) && hook["warning"].string == nil
            let message = complete ? "Hook completed; successful stdout is kept out of this notice." : hook["warning"].string ?? hook["message"].string ?? hook["reason"].string ?? "No message reported"
            let stop = hook["stopReason"].string ?? hook["stop_reason"].string
            let trust = hook["trusted"].bool.map { $0 ? "Provider reports trusted" : "Provider reports untrusted" } ?? "Trust not reported"
            let detail = "\(status) · \(trust)\n\(message)" + (stop.map { "\nStop reason: " + $0 } ?? "")
            return NativeChatPanel.row(event.id, name, detail, [NativeChatPanel.action("Open emitted hook details", "details", event.id)])
        }
    }
}
extension NativeHootChatModel {
    func hooksTool(_ action: String, request: String?) throws -> NativeRPCValue {
        featurePanel("hooks", action)
        if action == "manage", !fixtureMode { NativeChatAccount.openSettings(provider: reportedChatProvider) }
        if action == "details" {
            guard NativeChatHooks.rows(transcriptExportEvents).contains(where: { $0["id"].string == request }) else { throw NativeRPCError.invalidArguments("Choose an emitted hook notice ID.") }
            _ = try detailTool("open", query: nil, recordID: request)
        }
        return NativeChatPanel.state("Emitted hook notices", "Only structured hook warnings, progress, responses and stop reasons recorded by this Chat are shown. No notices does not prove hooks are disabled, trusted or successful. Only scoped hook events actually received from the provider are available.", NativeChatHooks.rows(transcriptExportEvents), [NativeChatPanel.action("Open Coding AI hook setup", "manage")])
    }
}
