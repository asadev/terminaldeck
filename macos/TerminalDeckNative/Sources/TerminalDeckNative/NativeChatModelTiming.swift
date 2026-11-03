import SwiftUI
import TerminalDeckNativeCore

enum NativeChatModelTiming {
    static func state(requested: String?, selected: String, applied: NativeRPCValue, queued: Bool, saving: Bool, busy: Bool) -> NativeRPCValue {
        let timing = queued ? (busy ? "Queued until the current turn ends" : "Queued for the next options save") : saving ? "Saving selection; not yet confirmed" : applied.string == requested && requested != nil ? "Provider-reported applied model matches request" : "Selection saved/read; provider applied-model receipt not confirmed"
        return NativeChatPanel.state("Model request and application", "A model selection acknowledgement is not proof that a running turn switched models. No live switch is inferred.", [
            NativeChatPanel.row("requested", "Requested model", requested ?? "No new request"), NativeChatPanel.row("selected", "Saved selection", selected.isEmpty ? "Not reported" : selected),
            NativeChatPanel.row("applied", "Provider-confirmed applied model", applied.string ?? "Not reported by this Chat service"), NativeChatPanel.row("timing", "When it changes", timing)
        ], [NativeChatPanel.action("Open Chat model control", "choose")]).setting("requested", requested.map(NativeRPCValue.string) ?? .null).setting("selected", .string(selected)).setting("applied", applied).setting("timing", .string(timing))
    }
}
extension NativeHootChatModel {
    func modelTimingTool(_ action: String) throws -> NativeRPCValue {
        featurePanel("model-timing", action)
        if action == "choose" { _ = try controlsTool("open", request: "model") }
        return chatModelTimingState
    }
}
