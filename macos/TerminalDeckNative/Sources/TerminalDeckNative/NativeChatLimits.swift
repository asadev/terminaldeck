import SwiftUI
import TerminalDeckNativeCore

enum NativeChatLimits {
    static func selectedReport(_ all: NativeRPCValue, provider: String?, profileID: String?, name: String?) -> NativeRPCValue {
        let selected = (all["readings"].elements ?? []).filter { row in
            provider != nil && profileID != nil && row["account"]["provider"].string == provider && row["account"]["id"].string == profileID
        }
        let account = NativeRPCValue.object([.init("provider", provider.map(NativeRPCValue.string) ?? .null), .init("id", profileID.map(NativeRPCValue.string) ?? .null), .init("name", name.map(NativeRPCValue.string) ?? .null)])
        return .object([.init("account", account), .init("readings", .array(selected.map { row in
                var output = row.setting("account", account)
                for key in ["used", "resets"] {
                    let value = row[key]
                    if value["state"].isNullish, let kind = value["kind"].string { output = output.setting(key, value.setting("state", .string(kind))) }
                }
                return output
            })), .init("assembledAt", all["assembledAt"]),
            .init("reason", selected.isEmpty ? .string("No plan limits have been reported for Hoot's selected account. Another account's limits are not substituted.") : .null)])
    }
}
extension NativeHootChatModel {
    func limitsTool(_ action: String) async throws -> NativeRPCValue {
        guard source.isHoot else { throw NativeRPCError.invalidArguments("Ordinary Chat uses its existing account-usage header. This panel is Hoot's.") }
        if action == "retry" {
            guard recoveryState["retry"]["needsAttachments"].bool != true else { throw NativeRPCError.invalidArguments("Restore the original files and resend through the composer before retrying this prompt.") }
            return try recover("retry").setting("retryRequested", .bool(true))
        }
        if action == "open" { chatLimitsVisible = true }
        if action == "close" { chatLimitsVisible = false }
        // #26 (post-24): "Read limits" starts Claude's own usage check for Hoot's account when the recorded figure is
        // at least an hour old (BackendUsageService.refreshAccount, shared with the phones' ring), then reads again.
        var checked: NativeRPCValue = .null
        if action == "refresh" {
            checked = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("hoot:usage:refresh", []))["detail"]
        }
        let account = try await accountTool("read", request: nil)
        // No session/screen lookup: the existing account metadata reader supplies the pool.
        let all = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("usage:read", []))
        let report = NativeChatLimits.selectedReport(all, provider: account["provider"].string, profileID: account["profileId"].string, name: account["account"].string)
        return .object([.init("report", report), .init("windows", SessionChatUsageSummary.wire(report)), .init("recovery", recoveryState),
            .init("checked", checked.string.map(NativeRPCValue.string) ?? .null),
            .init("scope", .string("Selected Hoot account; cached/reported plan windows. refresh asks Claude Code to check the limits when the newest figure is an hour old. Manual retry only; no spending/upgrade action."))])
    }
}
/// The Limits tab of Usage & account (Hoot's selected account).
struct NativeChatLimitsView: View {
    let model: NativeHootChatModel
    @State private var state: NativeRPCValue?
    @State private var loading = false
    @State private var outcome: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loading { ProgressView("Reading selected account limits…").padding(.horizontal, 16).padding(.top, 12) }
            SessionChatUsagePanel(report: state.map { UsageReport.decode($0["report"].foundation) } ?? nil, provider: state?["report"]["account"]["provider"].string ?? model.reportedChatProvider ?? "")
            VStack(alignment: .leading, spacing: 8) {
                Button("Read limits") { load(refresh: true) }.disabled(loading)
                if !model.recoveryState["retry"].isNullish {
                    Button("Retry last interrupted prompt") {
                        Task { do { _ = try await model.limitsTool("retry"); outcome = "Retry requested." } catch { outcome = error.localizedDescription } }
                    }.disabled(model.busy || model.sending || model.recoveryState["retry"]["needsAttachments"].bool == true)
                    if model.recoveryState["retry"]["needsAttachments"].bool == true { Text("Reattach the prompt's original files and resend through the composer.").font(.caption).foregroundStyle(.secondary) }
                }
                Text("Wait until the reported reset when needed, then retry manually. This panel never upgrades a plan or starts spending.").font(.caption).foregroundStyle(.secondary)
                if let outcome { Text(outcome).font(.caption).textSelection(.enabled) }
            }.padding(.horizontal, 16).padding(.bottom, 16)
        }.frame(width: 340).task { load() }
            .onChange(of: model.busy) { _, busy in if !busy { load() } }
    }
    /// Opening the tab and the end of a turn only read what is recorded; the button also asks for a fresh check.
    private func load(refresh: Bool = false) {
        guard !loading else { return }; loading = true
        Task {
            defer { loading = false }
            do { let next = try await model.limitsTool(refresh ? "refresh" : "read"); state = next; outcome = next["checked"].string }
            catch { outcome = error.localizedDescription }
        }
    }
}
