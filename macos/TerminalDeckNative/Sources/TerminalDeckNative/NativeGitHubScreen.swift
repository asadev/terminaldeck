import AppKit
import Combine
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// GitHub sign-in and the native repository workspace share one page.
/// Account refreshes read authentication only; the workspace loads its own lists.
struct NativeGitHubScreen: View {
    @State private var model = GitHubScreenModel()
    var projectPath: String? = nil
    var embedded = false
    var section: String? = nil
    var lifecycleEnabled = true
    var workspaceModel: NativeGHWorkspaceModel? = nil
    init(model: GitHubScreenModel = GitHubScreenModel(), workspaceModel: NativeGHWorkspaceModel? = nil, projectPath: String? = nil, embedded: Bool = false, section: String? = nil, lifecycleEnabled: Bool = true) {
        _model = State(initialValue: model); self.workspaceModel = workspaceModel
        self.projectPath = projectPath; self.embedded = embedded; self.section = section; self.lifecycleEnabled = lifecycleEnabled
    }

    var body: some View {
        let project = projectPath ?? (lifecycleEnabled ? DeckProject.current : nil)
        Group {
            if lifecycleEnabled && projectPath == nil && AppModel.shared.sidebar == nil {
                LoadingView(message: "Loading Terminal Deck…")
            } else if let project {
                GitHubPage(model: model, cwd: project, embedded: embedded, section: section, workspaceModel: workspaceModel, lifecycleEnabled: lifecycleEnabled)
            } else {
                DeckNeedsProject(label: "GitHub", symbol: "chevron.left.forwardslash.chevron.right")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        .onChange(of: project, initial: true) { _, path in if lifecycleEnabled { model.show(path) } }
        // The page's `useWhenActive`: coming back to the app reads the sign-in again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if lifecycleEnabled { model.cameBack() } }
        .task {
            guard lifecycleEnabled else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                model.now = Date()
            }
        }

    }
}

// MARK: - Model

@MainActor
@Observable
final class GitHubScreenModel {
    private(set) var cwd: String?
    private(set) var copilot: (label: String, state: String, url: String?)?
    private(set) var auth: GitHubAuthState?
    private(set) var authLoading = true
    private(set) var authBusy = false
    /// Only a cancel already on its way greys Cancel out; the wait for GitHub (up to 15 minutes) never does.
    private(set) var cancelling = false
    var now = Date()
    var confirmingDisconnect = false
    private(set) var copied = false

    #if DEBUG
    static func renderFixture(cwd: String, auth: GitHubAuthState) -> GitHubScreenModel {
        let model = GitHubScreenModel(); model.cwd = cwd; model.auth = auth
        model.authLoading = false
        return model
    }
    #endif

    private var bridge: EngineBridge { EngineBridge.shared }

    func show(_ path: String?) {
        guard path != cwd else { return }
        cwd = path
        guard path != nil else { return }
        authLoading = true
        auth = nil
        confirmingDisconnect = false
        copied = false
        authBusy = false
        cancelling = false
        loadCopilot()
        Task { await loadAuth() }
    }

    func cameBack() {
        guard cwd != nil, !authBusy else { return }
        Task { await loadAuth() }
    }

    private func loadCopilot() {
        Task {
            guard let raw = try? await bridge.invoke("setup:status") else { return }
            copilot = GitHubRules.copilotTool(raw)
        }
    }

    @discardableResult
    func loadAuth() async -> GitHubAuthState? {
        guard let asked = cwd else { return nil }
        defer { if cwd == asked { authLoading = false } }
        guard let answer = try? await bridge.invoke("github:auth-status", [asked]) else {
            if cwd == asked { auth = .bridgeSilent }
            return nil
        }
        guard cwd == asked else { return nil }
        let next = GitHubAuthState(json: answer)
        auth = next
        return next
    }

    func connect() {
        guard let asked = cwd, !authBusy else { return }
        authBusy = true
        copied = false
        confirmingDisconnect = false
        Task {
            defer { if cwd == asked { authBusy = false } }
            guard let started = try? await bridge.invoke("github:auth-connect") else {
                if cwd == asked { auth = .bridgeSilent }
                return
            }
            guard cwd == asked else { return }
            if let failure = GitHubFailure(json: started) {
                var state = auth ?? .bridgeSilent
                state.pending = nil
                state.failure = failure
                auth = state
                return
            }
            let prompt = GitHubAuthState(json: ["pending": started]).pending
            if let prompt { Self.openExternally(prompt.verificationUri) }
            var state = auth ?? .bridgeSilent
            state.pending = prompt
            state.failure = nil
            auth = state
            guard let settled = try? await bridge.invoke("github:auth-await", [asked]) else {
                if cwd == asked { auth = .bridgeSilent }
                return
            }
            guard cwd == asked else { return }
            let next = GitHubAuthState(json: settled)
            auth = next

        }
    }

    func cancelConnect() {
        guard let asked = cwd, !cancelling else { return }
        cancelling = true
        Task {
            defer { if cwd == asked { cancelling = false } }
            let answer = try? await bridge.invoke("github:auth-cancel", [asked])
            if cwd == asked { auth = answer.map { GitHubAuthState(json: $0) } ?? .bridgeSilent }
        }
    }

    func disconnect() {
        guard let asked = cwd else { return }
        authBusy = true
        Task {
            defer { if cwd == asked { authBusy = false } }
            guard let answer = try? await bridge.invoke("github:auth-disconnect", [asked]) else {
                if cwd == asked { auth = .bridgeSilent }
                return
            }
            guard cwd == asked else { return }
            auth = GitHubAuthState(json: answer)
            confirmingDisconnect = false
        }
    }

    func copyCode(_ code: String) {
        DeckProject.copy(code)
        copied = true
    }

    /// A link as the page's links open: in a browser tab of this app.
    static func open(_ url: String) {
        guard let link = URL(string: url), ["http", "https"].contains(link.scheme?.lowercased() ?? "") else { return }
        NativeBrowserTabs.shared.create(url: link)
    }

    /// The system browser, as the page's `openLinkExternally` (sign-in and install pages).
    static func openExternally(_ url: String) {
        guard let link = URL(string: url) else { return }
        NSWorkspace.shared.open(link)
    }
}

// MARK: - The page

private struct GitHubPage: View {
    @Bindable var model: GitHubScreenModel
    let cwd: String
    var embedded = false
    var section: String? = nil
    var workspaceModel: NativeGHWorkspaceModel? = nil
    var lifecycleEnabled = true

    var body: some View {
        if model.authLoading {
            NativePageNote("Checking your GitHub sign-in…", busy: true)
        } else {
            let state = model.auth ?? .bridgeSilent
            if let pending = state.pending {
                ScrollView {
                    DeviceCodeCard(model: model, prompt: pending)
                        .padding(44)
                        .frame(maxWidth: .infinity)
                }
            } else if !state.connected {
                ScrollView { ConnectPage(model: model, state: state).frame(maxWidth: .infinity) }
            } else {
                ConnectedPage(model: model, state: state, cwd: cwd, embedded: embedded, section: section, workspaceModel: workspaceModel, lifecycleEnabled: lifecycleEnabled)
            }
        }
    }
}

/// A row-like button that opens a GitHub link, with the page's link menu.
private struct LinkButton<Label: View>: View {
    let url: String
    let help: String
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button { GitHubScreenModel.open(url) } label: { label().contentShape(.rect) }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
            .contextMenu {
                Button("Open in System Browser") { GitHubScreenModel.openExternally(url) }
                Button("Copy Link") { DeckProject.copy(url) }
            }
    }
}

// MARK: Not signed in

private struct ConnectPage: View {
    let model: GitHubScreenModel
    let state: GitHubAuthState

    var body: some View {
        let failure = state.failure
        let title = failure.map { GitHubRules.failureTitle($0.kind) } ?? "Not signed in to GitHub"
        let retryOnly = failure.map { GitHubRules.isRetryable($0.kind) } ?? false
        let action: PageEmptyAction = retryOnly
            ? PageEmptyAction(label: "Try again", busy: model.authBusy, autoRetry: true) { Task { await model.loadAuth() } }
            : state.appConfigured
                ? PageEmptyAction(label: model.authBusy ? "Connecting…" : "Connect to GitHub", primary: true, busy: model.authBusy) { model.connect() }
                : PageEmptyAction(label: "Check again", busy: model.authBusy) { Task { await model.loadAuth() } }
        VStack(spacing: 0) {
            NativePageEmpty(symbol: "chevron.left.forwardslash.chevron.right", title: title, message: {
                if let failure, GitHubRules.showsAction(failure) {
                    Text(failure.message) + Text(" You can also run ") + Text(failure.action ?? "").font(.body.monospaced()) + Text(" in a terminal.")
                } else {
                    Text(failure?.message ?? "Connect an account to see pull requests and issues.")
                }
            }, action: action, hint: {
                if state.ghInstalled && !retryOnly {
                    Text("An existing ") + Text("gh auth login").font(.callout.monospaced()) + Text(" is reused automatically, so nothing here signs you in twice.")
                }
            }, extra: {
                VStack(spacing: 12) {
                    if !retryOnly && state.appConfigured { AccessNotice(state: state) }
                    if let detail = failure?.detail, !detail.isEmpty { FailureDetails(detail: detail) }
                }
            })
            .frame(minHeight: 360)
            if state.expiredCredentialRemoved || state.repo != nil {
                VStack(spacing: 8) {
                    if state.expiredCredentialRemoved {
                        Text("The sign-in this app had stored was rejected by GitHub, so it was deleted. Nothing else was changed.")
                    }
                    if let repo = state.repo {
                        Text(repo.failure?.message
                             ?? "This folder is \(GitHubRules.folderLine(repo, branch: state.branch) ?? ""), and it will load as soon as you are signed in.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .padding(.bottom, 24)
            }
        }
    }
}

/// "What this asks for": what installing the GitHub App lets it see.
private struct AccessNotice: View {
    let state: GitHubAuthState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What this asks for").font(.callout.weight(.semibold))
            (Text("Signing in installs a GitHub App, so GitHub will ask you to choose ") + Text("all repositories").bold()
             + Text(" or ") + Text("only select repositories").bold()
             + Text(", and the app gets read-only access to what you pick — repository metadata, pull requests and issues."))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let url = state.installUrl {
                Button("Choose repositories on GitHub") { GitHubScreenModel.openExternally(url) }
                    .buttonStyle(.link)
            }
        }
        .padding(14)
        .frame(maxWidth: 440, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
    }
}

/// The page's `<details>`: "Details", opened to the raw output.
private struct FailureDetails: View {
    let detail: String
    @State private var open = false

    var body: some View {
        DisclosureGroup("Details", isExpanded: $open) {
            Text(detail)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .font(.callout)
        .frame(maxWidth: 440)
    }
}

private struct DeviceCodeCard: View {
    let model: GitHubScreenModel
    let prompt: GitHubDevicePrompt

    var body: some View {
        let minutes = GitHubRules.minutesLeft(expiresAt: prompt.expiresAt, now: model.now)
        VStack(alignment: .leading, spacing: 14) {
            Text("Type this code on GitHub").font(.title3.weight(.semibold))
            (Text("Your browser should already be open at ") + Text(prompt.verificationUri).font(.body.monospaced())
             + Text(". Enter the code below and approve the permissions; this window finishes on its own."))
                .foregroundStyle(.secondary)
            Button { model.copyCode(prompt.userCode) } label: {
                HStack(spacing: 12) {
                    Text(prompt.userCode).font(.system(size: 28, weight: .semibold, design: .monospaced))
                    Text(model.copied ? "Copied" : "Copy").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help("Copy this code")
            .accessibilityLabel("Sign-in code \(GitHubRules.spelled(prompt.userCode)). Click to copy.")
            Text(GitHubRules.expiryLine(minutes: minutes)).font(.callout).foregroundStyle(.secondary)
            Text("GitHub will ask which repositories this app may see — all of them, or only the ones you pick.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Open GitHub again") { GitHubScreenModel.openExternally(prompt.verificationUri) }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { model.cancelConnect() }
                    .disabled(model.cancelling)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: Connected

private struct ConnectedPage: View {
    @Bindable var model: GitHubScreenModel
    let state: GitHubAuthState
    let cwd: String
    var embedded = false
    var section: String? = nil
    var workspaceModel: NativeGHWorkspaceModel? = nil
    var lifecycleEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ConnectionBar(model: model, state: state)
            if let copilot = model.copilot { CopilotRow(tool: copilot) }
            if let workspaceModel {
                NativeGHWorkspaceScreen(model: workspaceModel, embedded: embedded, lifecycleEnabled: lifecycleEnabled)
            } else { NativeGHWorkspaceScreen(cwd: cwd, section: section, embedded: embedded) }
        }
        .frame(maxWidth: 1312, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, embedded ? 0 : 24)
        .padding(.vertical, embedded ? 0 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ConnectionBar: View {
    @Bindable var model: GitHubScreenModel
    let state: GitHubAuthState

    var body: some View {
        let login = state.login ?? "unknown account"
        HStack(alignment: .top, spacing: 14) {
            Text(String(login.prefix(1)).uppercased())
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.15), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Connected as").font(.body.weight(.semibold))
                    LinkButton(url: state.htmlUrl ?? "", help: "Open \(login) on \(state.host)") {
                        Text(login).font(.body.weight(.semibold))
                    }
                    if let name = state.name { Text(name).foregroundStyle(.secondary) }
                }
                HStack(spacing: 4) {
                    Text(GitHubRules.sourceWord(state.source)).foregroundStyle(.secondary)
                    DeckInfoNote(label: "Where this sign-in comes from", text: GitHubRules.sourceSentence(state.source, host: state.host))
                }
                .font(.callout)
                if state.scopesReported {
                    ScopeChips(scopes: state.scopes)
                }
            }
            Spacer(minLength: 12)
            if model.confirmingDisconnect {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(state.disconnect ?? "").font(.callout).foregroundStyle(.secondary).frame(maxWidth: 320, alignment: .trailing)
                    HStack(spacing: 8) {
                        Button("Disconnect", role: .destructive) { model.disconnect() }.disabled(model.authBusy)
                        Button("Keep it") { model.confirmingDisconnect = false }.disabled(model.authBusy)
                    }
                }
            } else if let disconnect = state.disconnect {
                Button("Disconnect") { model.confirmingDisconnect = true }
                    .buttonStyle(.borderless)
                    .disabled(model.authBusy)
                    .help(disconnect)
            } else {
                (Text("Nothing to disconnect — unset ") + Text("GH_TOKEN").font(.callout.monospaced()) + Text(" and restart."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 14))
    }
}

/// "Granted", then each scope as a chip — or "nothing".
private struct ScopeChips: View {
    let scopes: [String]

    var body: some View {
        TasksFlow(spacing: 6, lineSpacing: 6, fillsWidth: false) {
            Text("GRANTED").font(.caption).foregroundStyle(.secondary).padding(.vertical, 3)
            if scopes.isEmpty {
                chip("nothing").opacity(0.7)
            } else {
                ForEach(scopes, id: \.self) { chip($0) }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.08), in: .capsule)
    }
}

/// Children laid out in rows, wrapping at the width it is given.


private struct CopilotRow: View {
    let tool: (label: String, state: String, url: String?)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(tool.label).font(.callout)
            Spacer()
            HStack(spacing: 4) { Circle().fill(tool.state == "ready" ? Color.green : tool.state == "missing" ? Color.red : Color.orange).frame(width: 5, height: 5); Text(GitHubRules.toolStateLabel(tool.state)).font(.callout).foregroundStyle(.secondary) }
            if tool.state == "missing", let url = tool.url {
                Button("Install") { GitHubScreenModel.open(url) }
                    .buttonStyle(.link)
                    .contextMenu {
                        Button("Open in System Browser") { GitHubScreenModel.openExternally(url) }
                        Button("Copy Link") { DeckProject.copy(url) }
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}
