import SwiftUI
import TerminalDeckNativeCore

@MainActor @Observable final class NativeChatAccountFocus {
    static let shared = NativeChatAccountFocus()
    var provider: String?
}
enum NativeChatAccount {
    static func focusedProvider(_ value: String?) -> String? { value.flatMap { ["claude", "codex", "gemini"].contains($0) ? $0 : nil } }
    static func summary(_ raw: NativeRPCValue, hoot: Bool, fallback: String?) -> NativeRPCValue {
        let selected = (raw["accounts"].elements ?? []).first { $0["id"].string == raw["profileId"].string }
        return .object([.init("provider", raw["provider"].string.map(NativeRPCValue.string) ?? fallback.map(NativeRPCValue.string) ?? .null),
            .init("account", raw["profileName"].string.map(NativeRPCValue.string) ?? selected?["name"] ?? .null),
            .init("profileId", raw["profileId"]), .init("signedIn", hoot ? selected?["signedIn"] ?? .null : .null),
            .init("ready", hoot ? raw["ready"] : .null), .init("pending", raw["pending"]), .init("reason", raw["reason"]),
            .init("basis", .string(hoot ? "Hoot's selected account and readiness reading" : "Reported session account attribution; sign-in health is not inferred"))])
    }
    @MainActor static func openSettings(provider: String?) {
        NativeChatAccountFocus.shared.provider = focusedProvider(provider)
        NativeCodingAIStore.shared.scope = .thisMachine
        AppModel.shared.openSettings(section: "agents")
    }
}
extension NativeHootChatModel {
    var reportedChatProvider: String? { transcriptExportEvents.last?.provider.rawValue ?? composerDraft.modelID.split(separator: ":").first.map(String.init).flatMap(NativeChatAccount.focusedProvider) }
    func accountTool(_ action: String, request: String?) async throws -> NativeRPCValue {
        let raw: NativeRPCValue
        if let id = source.sessionID { raw = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("session:account", [id])) }
        else { raw = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("hoot:ready:read", [false])) }
        let state = NativeChatAccount.summary(raw, hoot: source.isHoot, fallback: reportedChatProvider)
        if action == "open" {
            if request == "settings" { NativeChatAccount.openSettings(provider: state["provider"].string) }
            else if request == nil { chatAccountVisible = true }
            else { throw NativeRPCError.invalidArguments("Use request settings, or omit it to open account status.") }
        }
        if action == "close" { chatAccountVisible = false }
        return state
    }
    func routeAccountCommand(_ command: HootSlashCommand) {
        guard !fixtureMode else { return }
        if ["login", "logout"].contains(command.name) {
            Task { do { _ = try await accountTool("open", request: "settings") } catch { chatAccountProblem = error.localizedDescription; chatAccountVisible = true } }
        } else if ["feedback", "bug", "doctor"].contains(command.name) { chatDiagnosticsVisible = true }
        else if command.name == "status" { chatAccountVisible = true }
        else { AppModel.shared.requestSettings() }
    }
}
/// Account, plan limits (Hoot's; ordinary chats show theirs in the session header) and the chat's usage report
/// are one job: one "Usage & account" entry, one tab each.
struct NativeChatAccountPopover: View {
    @Bindable var model: NativeHootChatModel
    @State private var state: NativeRPCValue?
    @State private var loading = false
    var body: some View {
        Color.clear
            .popover(isPresented: Binding(get: { model.chatAccountVisible || model.chatLimitsVisible }, set: { if !$0 { model.chatAccountVisible = false; model.chatLimitsVisible = false } })) {
                let tabs = [("account", "Account")] + (model.source.isHoot ? [("limits", "Limits")] : []) + (model.chatReportedUsage.fields != nil ? [("usage", "Chat usage")] : [])
                NativeChatTabbedPanel(tabs, first: model.chatLimitsVisible && !model.chatAccountVisible ? "limits" : "account") { tab in
                    switch tab {
                    case "limits": NativeChatLimitsView(model: model)
                    case "usage": NativeChatReportedUsagePanel(reading: model.chatReportedUsage)
                    default: account
                    }
                }
            }
    }
    private var account: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coding AI account").font(.headline)
            if loading { ProgressView("Reading account status…") }
            if let state {
                Text(state["provider"].string.map(CodingAICatalog.label) ?? "Provider not reported").font(.callout.weight(.semibold))
                Text(state["account"].string ?? "Account not reported").textSelection(.enabled)
                Text(state["basis"].string ?? "").font(.caption).foregroundStyle(.secondary)
                if let signedIn = state["signedIn"].bool { Text(signedIn ? "Signed in" : "Not signed in").font(.callout) }
                if state["pending"].bool == true { Text("Account switch is awaiting provider confirmation.").font(.caption).foregroundStyle(.secondary) }
                if let reason = state["reason"].string { Text(reason).font(.caption).foregroundStyle(.secondary) }
            }
            if let problem = model.chatAccountProblem { Text(problem).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Coding AI account settings") { NativeChatAccount.openSettings(provider: state?["provider"].string ?? model.reportedChatProvider) }
                Button("Read status") { load() }.disabled(loading)
            }
        }.padding(16).frame(width: 450).task { load() }
    }
    private func load() { loading = true; Task { defer { loading = false }; do { state = try await model.accountTool("read", request: nil); model.chatAccountProblem = nil } catch { model.chatAccountProblem = error.localizedDescription } } }
}
