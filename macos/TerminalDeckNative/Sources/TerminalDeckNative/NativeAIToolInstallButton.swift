import AppKit
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// CONNECT-SKILLS (Asad "go", 11 Oct): wherever a missing Claude Code, Codex or Gemini CLI is reported (first run,
// Settings › Coding AI, an account row, Add account, the sign-in, New session, an agent's AI, the readiness AI
// picker) there is now one Install button instead of a terminal command. It installs with progress, checks the AI
// starts, and goes straight on to sign-in. One model for the whole app, so an install started on one screen (or by
// Hoot through ai_tools_install) shows its progress on every screen that offers the same AI.

extension Notification.Name {
    /// A coding AI was just installed (object: its id). Screens that list AIs read them again.
    static let nativeAIToolInstalled = Notification.Name("NativeAIToolInstalled")
}

@MainActor @Observable
final class NativeAIToolInstallModel {
    static let shared = NativeAIToolInstallModel()
    static let progressEvent = "ai-tools:install-progress"

    struct Progress: Equatable {
        /// idle | running | installed | failed | needs
        var state = "idle"
        var step = ""
        var line = ""
        var message = ""
        var version: String?
        var helpURL: String?
    }
    private(set) var progress: [String: Progress] = [:]
    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private var after: [String: [@MainActor () -> Void]] = [:]

    /// Which AI a sentence says is missing or broken (an error from a sign-in, a remedy line).
    static func missingTool(in text: String) -> String? { BackendAIToolInstallText.missingTool(in: text) }

    func listen() {
        guard subscription == nil, EngineBridge.shared.isReady else { return }
        subscription = EngineBridge.shared.on(Self.progressEvent) { [weak self] args in self?.apply(args.first) }
    }

    /// Picks up an install started elsewhere (another screen, Hoot).
    func refresh(_ tool: String) {
        listen()
        guard EngineBridge.shared.isReady else { return }
        Task { if let raw = try? await EngineBridge.shared.invoke("ai-tools:install-state", [tool]) { apply(raw) } }
    }

    /// `then`: what happens once it is installed; nil goes on to sign-in.
    func install(_ tool: String, upgrade: Bool = false, then: (@MainActor @Sendable () -> Void)? = nil) {
        listen()
        let next: @MainActor () -> Void
        if let then { next = then } else if upgrade { next = { NativeCodingAIStore.shared.refreshAll() } } else { next = { Self.continueToSignIn(tool) } }
        after[tool, default: []].append(next)
        guard progress[tool]?.state != "running" else { return }
        progress[tool] = Progress(state: "running", step: "Starting")
        Task {
            do { apply(try await EngineBridge.shared.invoke("ai-tools:install", [tool, ["upgrade": upgrade]])) }
            catch {
                progress[tool] = Progress(state: "failed", message: CodingAIErrorText.from(error, fallback: "The install could not start."),
                                          helpURL: CodingAICatalog.agent(tool)?.url)
                after[tool] = nil
            }
        }
    }

    private func apply(_ raw: Any?) {
        guard let row = raw as? [String: Any], let tool = row["tool"] as? String else { return }
        let state = row["state"] as? String ?? "idle"
        // A fresh "idle" never hides an install this screen just started.
        if state == "idle", progress[tool]?.state == "running" { return }
        let was = progress[tool]?.state
        progress[tool] = Progress(state: state, step: row["step"] as? String ?? "", line: row["line"] as? String ?? "",
                                  message: row["message"] as? String ?? "", version: row["version"] as? String, helpURL: row["helpURL"] as? String)
        guard was != state, ["installed", "failed", "needs"].contains(state) else { return }
        let next = after.removeValue(forKey: tool) ?? []
        guard state == "installed" else { return }
        NativeCodingAIStore.shared.refreshAll()
        NotificationCenter.default.post(name: .nativeAIToolInstalled, object: tool)
        for each in next { each() }
    }

    /// After an install: read the accounts again and open this Mac's own sign-in for that AI, unless it is
    /// already signed in (a reinstall keeps its login).
    /// The store says when the fresh accounts and that account's sign-in answer arrive, however long a slow
    /// read takes; nothing is polled. Two minutes is only the limit for an answer that never comes.
    static func continueToSignIn(_ tool: String) {
        let store = NativeCodingAIStore.shared
        store.refreshAll()
        Task { @MainActor in
            let wake = NativeWake(), deadline = ContinuousClock.now + .seconds(120)
            var found: CodingAIAccount?
            while ContinuousClock.now < deadline {
                if !store.accountsLoading {
                    found = store.snapshot.accounts.first(where: { ($0.provider ?? "claude") == tool && $0.system })
                    if let account = found, let answer = store.signIn[account.id], answer != .checking {
                        if answer.state != .signedIn { NativeAccountSignInModel.shared.open(account, store: store) }
                        return
                    }
                }
                await wake.waitForChange(of: { _ = store.accountsLoading; _ = store.snapshot; _ = store.signIn },
                                         upTo: deadline - ContinuousClock.now)
            }
            // No answer about its login yet: open the sign-in anyway (it says so itself if already signed in).
            if let found { NativeAccountSignInModel.shared.open(found, store: store) }
        }
    }
}

/// The Install button and, once pressed, where it stands. `then` replaces "go on to sign-in".
struct NativeAIToolInstallButton: View {
    let tool: String
    var then: (@MainActor () -> Void)? = nil
    private var model: NativeAIToolInstallModel { .shared }

    var body: some View {
        let progress = model.progress[tool] ?? .init()
        let label = CodingAICatalog.label(tool)
        VStack(alignment: .leading, spacing: 4) {
            switch progress.state {
            case "running":
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress.step.isEmpty ? "Installing \(label)…" : progress.step).font(.callout)
                }
                .accessibilityElement(children: .combine)
                if !progress.line.isEmpty {
                    Text(progress.line).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(progress.line)
                }
            case "installed":
                Label(progress.message.isEmpty ? "\(label) is installed." : progress.message, systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            case "failed", "needs":
                Text(progress.message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button(progress.state == "needs" ? "Check again" : "Try again") { model.install(tool, then: then) }
                    if let help = progress.helpURL, let url = URL(string: help) {
                        Button(help.contains("nodejs.org") ? "Get Node.js" : "Open \(label)’s page") { NSWorkspace.shared.open(url) }
                    }
                }
            default:
                Button { model.install(tool, then: then) } label: { Label("Install", systemImage: "arrow.down.circle") }
                    .accessibilityLabel("Install \(label)")
                    .help("Install \(label) on this Mac with its official installer. No terminal needed.")
            }
        }
        .onAppear { model.refresh(tool) }
    }
}
