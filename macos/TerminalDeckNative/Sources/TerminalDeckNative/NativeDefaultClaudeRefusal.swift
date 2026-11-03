import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The same Switch operation as the chip: it keeps the conversation and checks its plan first.
struct NativeDefaultClaudeRefusal: View {
    let sessionId: String
    let cwd: String?
    let title: String
    let profileId: String?
    @State private var signedOut = false
    @State private var target: CodingAIAccount?
    @State private var choices: [CodingAIAccount] = []
    @State private var choosing = false
    @State private var problem: String?

    var body: some View {
        Group {
            if signedOut {
                NativeClaudeSignedOutRow(target: target?.name, canChoose: !choices.isEmpty, problem: problem,
                    switchLogin: { if let target { switchTo(target) } else { choosing = true } })
                    .padding(.horizontal, 16).padding(.vertical, 4)
            }
        }
        .task(id: profileId) { await read() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await read() }
        }
        .onChange(of: NativeCodingAIStore.shared.signIn["system"]?.state) { _, state in
            if state == .signedIn || state == .signedOut { Task { await read() } }
        }
        .sheet(isPresented: $choosing) {
            NativeClaudeLoginChoice(accounts: choices) { account in choosing = false; switchTo(account) }
        }
    }

    private func read() async {
        choices = []; target = nil; problem = nil; signedOut = false
        do {
            let actual = SessionAccountView.decode(try await EngineBridge.shared.invoke("session:account", [sessionId]))
            guard case .known(let provider, _, let id, _, _) = actual, provider == "claude", id == "system" else { return }
            let status = try await EngineBridge.shared.invoke("profiles:signin", ["system", ["refresh": true]])
            signedOut = CodingAIAccountsParse.signIn(CodingAIJSON(status)).state == .signedOut
            guard signedOut else { return }
            let raw = try await EngineBridge.shared.invoke("profiles:list")
            let accounts = CodingAIAccountsParse.snapshot(CodingAIJSON(raw)).accounts
            var emails: [String: String] = [:]
            for account in accounts where !account.system && account.provider == "claude" && !account.isAPIKey {
                let raw = try await EngineBridge.shared.invoke("profiles:signin", [account.id, ["refresh": true]])
                let report = CodingAIAccountsParse.signIn(CodingAIJSON(raw))
                if report.state == .signedIn {
                    var shown = account
                    shown.name = report.account.map { $0 == account.name ? $0 : account.name + " — " + $0 } ?? account.name
                    emails[account.id] = report.account
                    choices.append(shown)
                }
            }
            do {
                let value = try await EngineBridge.shared.invoke("profiles:resolve", [["sessionProfileId": "system", "projectPath": cwd ?? "", "provider": "claude"]])
                let id = (value as? [String: Any])?["id"] as? String
                target = choices.first { $0.id == id }
                if let id, let email = emails[id] { target?.name = email }
            } catch {
                if !error.localizedDescription.contains(BackendDefaultClaudeLogin.chooseMarker) { throw error }
            }
        } catch { problem = "The saved logins could not be checked. Use the account menu to Switch, or Sign in." }
    }

    private func switchTo(_ account: CodingAIAccount) {
        NativeAccountLevelsModel.markChosen(sessionID: sessionId)
        NativeAccountSwitcher.shared.ask(sessionId: sessionId, accountId: account.id, title: title, from: "Not signed in", to: account.name)
    }
}

struct NativeClaudeLoginChoice: View {
    let accounts: [CodingAIAccount]
    let choose: (CodingAIAccount) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch").font(.headline)
            Text("Choose the Claude login this session should use.").foregroundStyle(.secondary)
            ForEach(accounts) { account in
                Button(account.name) { choose(account) }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(minWidth: 360)
    }
}

struct NativeClaudeSignedOutRow: View {
    let target: String?
    let canChoose: Bool
    let problem: String?
    let switchLogin: () -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { message; actions }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                message
                HStack(spacing: 6) { actions }
            }
        }
        .font(.callout)
    }
    private var message: some View {
        Text(problem ?? "This session’s Claude login is not signed in.").foregroundStyle(.secondary)
    }
    @ViewBuilder private var actions: some View {
        if let target { Button("Switch to \(target)", action: switchLogin) }
        else if canChoose { Button("Switch…", action: switchLogin) }
        Button("Sign in…") { NativeChatAccount.openSettings(provider: "claude") }
    }
}
