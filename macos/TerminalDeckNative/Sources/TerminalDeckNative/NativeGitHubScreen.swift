import AppKit
import Combine
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// GitHub, drawn in Swift — the web page (`components/GitHubPanel.tsx`) one-to-one:
/// checking the sign-in; the connect page (Connect / Try again / Check again, the
/// gh hint, what signing in asks for, the details, the notes); the device code
/// card (the code to copy, how long it works, Open GitHub again, Cancel); and once
/// connected, the account bar (Connected as, where the sign-in comes from, the
/// granted scopes, Disconnect with its confirm), the GitHub Copilot row, the
/// folder's repository and branch with Refresh, a failure for the page, and the
/// Pull requests / Issues / Repositories tabs with their counts and rows.
///
/// Rows open in a browser tab as the page's links do; a right click offers
/// "Open in System Browser" and "Copy Link". The page's channels:
/// `github:auth-status`, `github:overview`, `github:refresh`, `github:auth-connect`,
/// `github:auth-await`, `github:auth-cancel`, `github:auth-disconnect`, `setup:status`.
struct NativeGitHubScreen: View {
    @State private var model = GitHubScreenModel()

    var body: some View {
        let project = DeckProject.current
        Group {
            if AppModel.shared.sidebar == nil {
                LoadingView(message: "Loading Terminal Deck…")
            } else if let project {
                GitHubPage(model: model, cwd: project)
            } else {
                DeckNeedsProject(label: "GitHub", symbol: "chevron.left.forwardslash.chevron.right")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onChange(of: project, initial: true) { _, path in model.show(path) }
        // The page opened GitHub onto Issues or Pull requests while it is already showing.
        .onChange(of: PanelHandoff.pageFocus) { _, focus in model.focus(focus) }
        // The page's `useWhenActive`: coming back to the app reads the sign-in again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.cameBack() }
        .task {
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
    private(set) var result: GitHubResult?
    private(set) var loading = true
    private(set) var busy = false
    var tab = GitHubTab.pulls
    private(set) var copilot: (label: String, state: String, url: String?)?
    private(set) var auth: GitHubAuthState?
    private(set) var authLoading = true
    private(set) var authBusy = false
    var confirmingDisconnect = false
    private(set) var copied = false
    var repoQuery = ""
    var now = Date()

    private var bridge: EngineBridge { EngineBridge.shared }

    func show(_ path: String?) {
        guard path != cwd else { return }
        cwd = path
        guard let path else { return }
        loading = true
        authLoading = true
        result = nil
        auth = nil
        confirmingDisconnect = false
        copied = false
        repoQuery = ""
        tab = Self.initialTab()
        busy = false
        authBusy = false
        loadCopilot()
        Task {
            let state = await loadAuth()
            guard cwd == path else { return }
            if state?.connected == true { await load(refresh: false) } else { loading = false }
            if state?.connected == true, state?.repo?.failure != nil { tab = .repos }
        }
    }

    /// Issues when the page was opened onto them (the Overview tile, a command), else pull requests.
    private static func initialTab() -> GitHubTab {
        PanelHandoff.pageFocus == "issues" ? .issues : .pulls
    }

    func focus(_ value: String?) {
        if value == "issues" { tab = .issues } else if value == "pulls" { tab = .pulls }
    }

    func cameBack() {
        guard cwd != nil, !authBusy else { return }
        Task {
            let state = await loadAuth()
            if state?.connected == true { await load(refresh: false) }
        }
    }

    private func loadCopilot() {
        Task {
            guard let raw = try? await bridge.invoke("setup:status") else { return }
            copilot = GitHubRules.copilotTool(raw)
        }
    }

    func load(refresh: Bool) async {
        guard let asked = cwd else { return }
        if refresh { busy = true }
        let answer = try? await bridge.invoke(refresh ? "github:refresh" : "github:overview", [asked])
        guard cwd == asked else { return }
        result = answer.map { GitHubResult(json: $0) } ?? .failed(GitHubFailure(kind: "error", message: "The GitHub bridge did not answer."))
        loading = false
        busy = false
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
            if next.connected {
                loading = true
                await load(refresh: false)
            }
        }
    }

    func cancelConnect() {
        guard let asked = cwd else { return }
        Task {
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
            result = nil
            loading = false
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
                ConnectedPage(model: model, state: state, cwd: cwd)
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
            ? PageEmptyAction(label: "Try again", busy: model.authBusy) { Task { await model.loadAuth() } }
            : state.appConfigured
                ? PageEmptyAction(label: model.authBusy ? "Connecting…" : "Connect to GitHub", primary: true, busy: model.authBusy) { model.connect() }
                : PageEmptyAction(label: "Check again", busy: model.authBusy) { Task { await model.loadAuth() } }
        VStack(spacing: 0) {
            NativePageEmpty(symbol: "chevron.left.forwardslash.chevron.right", title: title, message: {
                if let failure, GitHubRules.showsAction(failure) {
                    Text(failure.message) + Text(" You can also run ") + Text(failure.action ?? "").font(.body.monospaced()) + Text(" in a terminal.")
                } else {
                    Text(failure?.message ?? "Connect an account to see this project’s pull requests and issues.")
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
                    .disabled(model.authBusy)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ConnectionBar(model: model, state: state)
            if let copilot = model.copilot { CopilotRow(tool: copilot) }
            NativeGHWorkspaceScreen(cwd: cwd)
        }
        .frame(maxWidth: 1312, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 44)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension ConnectedPage {
    static func overview(_ result: GitHubResult?) -> GitHubOverview? {
        if case .overview(let overview)? = result { return overview }
        return nil
    }

    static func rowCount<T>(_ section: GitHubSection<T>?) -> Int? {
        if case .rows(let rows)? = section { return rows.count }
        return nil
    }

    static func issuesOff(_ section: GitHubSection<GitHubIssue>?) -> Bool {
        if case .failed(let failure)? = section { return failure.kind == "issues-disabled" }
        return false
    }
}

private struct TabButton: View {
    let title: String
    let count: String?
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(on ? .semibold : .regular)).foregroundStyle(on ? .primary : .secondary)
                    if let count { Text(count).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Rectangle().fill(on ? Color.secondary : .clear).frame(height: 2)
            }
            .fixedSize()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
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
        WrapLayout(spacing: 6) {
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
private struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

private struct CopilotRow: View {
    let tool: (label: String, state: String, url: String?)

    var body: some View {
        HStack(spacing: 10) {
            Text(tool.state == "ready" ? "✓" : tool.state == "missing" ? "✕" : "!")
                .font(.caption.bold())
                .foregroundStyle(tool.state == "ready" ? Color.green : tool.state == "missing" ? Color.red : Color.orange)
                .accessibilityHidden(true)
            Text(tool.label).font(.callout)
            Spacer()
            Text(GitHubRules.toolStateLabel(tool.state)).font(.callout).foregroundStyle(.secondary)
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

/// A failure with its title, the "i" holding the sentence and command, Details, and Retry.
private struct FailureBlock: View {
    let failure: GitHubFailure
    let retry: () -> Void

    var body: some View {
        let title = GitHubRules.failureTitle(failure.kind)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                DeckInfoNote(label: title, text: GitHubRules.explanation(failure))
            }
            if !failure.detail.isEmpty { FailureDetails(detail: failure.detail) }
            if GitHubRules.offersRetry(failure) {
                Button("Retry", action: retry)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct ListBody: View {
    let model: GitHubScreenModel
    let kind: GitHubTab
    let overview: GitHubOverview?

    var body: some View {
        if kind == .pulls {
            switch overview?.pulls {
            case nil: NativePageNote("Reading GitHub…", busy: true).frame(minHeight: 120)
            case .failed(let failure)?: FailureBlock(failure: failure) { Task { await model.load(refresh: true) } }
            case .rows(let rows)?:
                if rows.isEmpty { note("No open pull requests.") } else {
                    VStack(spacing: 2) { ForEach(rows) { PullRow(pull: $0, now: model.now) } }
                }
            }
        } else {
            switch overview?.issues {
            case nil: NativePageNote("Reading GitHub…", busy: true).frame(minHeight: 120)
            case .failed(let failure)? where failure.kind == "issues-disabled": note(failure.message)
            case .failed(let failure)?: FailureBlock(failure: failure) { Task { await model.load(refresh: true) } }
            case .rows(let rows)?:
                if rows.isEmpty { note("No open issues.") } else {
                    VStack(spacing: 2) { ForEach(rows) { IssueRow(issue: $0, now: model.now) } }
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 12)
    }
}

enum GitHubColors {
    static func badge(_ badge: String) -> Color {
        switch badge {
        case "open": .green
        case "draft": .secondary
        case "merged": .purple
        case "closed": .red
        case "private": .secondary
        default: Color.secondary.opacity(0.8)
        }
    }

    static func review(_ review: String?) -> Color {
        switch review {
        case "approved": .green
        case "changes-requested": .red
        default: .orange
        }
    }
}

private struct RowFrame<Content: View>: View {
    let url: String
    let help: String
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        LinkButton(url: url, help: help) {
            HStack(alignment: .top, spacing: 12) { content() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Color.primary.opacity(0.05) : .clear, in: .rect(cornerRadius: 8))
        }
        .onHover { hovering = $0 }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .frame(width: 56, alignment: .leading)
            .padding(.top, 2)
    }
}

private struct Labels: View {
    let labels: [GitHubLabel]

    var body: some View {
        if !labels.isEmpty {
            HStack(spacing: 4) {
                ForEach(labels.prefix(3), id: \.name) { label in
                    HStack(spacing: 4) {
                        Circle().fill(color(label.color)).frame(width: 7, height: 7)
                        Text(label.name)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: .capsule)
                    .help(label.name)
                }
                if labels.count > 3 { Text("+\(labels.count - 3)").padding(.horizontal, 4) }
            }
        }
    }

    private func color(_ hex: String) -> Color {
        guard let rgb = GitHubRules.labelRGB(hex) else { return .secondary }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

private struct PullRow: View {
    let pull: GitHubPull
    let now: Date

    var body: some View {
        RowFrame(url: pull.url, help: "\(pull.title) — open on GitHub") {
            Badge(text: pull.badge, color: GitHubColors.badge(pull.badge))
            VStack(alignment: .leading, spacing: 3) {
                Text(pull.title).lineLimit(2)
                HStack(spacing: 8) {
                    Text("#\(pull.number)").monospacedDigit()
                    if let author = pull.author { Text(author).foregroundStyle(pull.authorIsBot ? .tertiary : .secondary) }
                    Text(GitHubRules.formatAge(pull.updatedAt, now: now)).help(pull.updatedAt)
                    if let review = GitHubRules.reviewLabel(pull.review) { Text(review).foregroundStyle(GitHubColors.review(pull.review)) }
                    if pull.fromFork { Text("fork") }
                    Labels(labels: pull.labels)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let added = pull.additions, let removed = pull.deletions {
                HStack(spacing: 4) {
                    Text("+\(added)").foregroundStyle(.green)
                    Text("−\(removed)").foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit())
            }
        }
    }
}

private struct IssueRow: View {
    let issue: GitHubIssue
    let now: Date

    var body: some View {
        RowFrame(url: issue.url, help: "\(issue.title) — open on GitHub") {
            Badge(text: issue.state, color: GitHubColors.badge(issue.state))
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).lineLimit(2)
                HStack(spacing: 8) {
                    Text("#\(issue.number)").monospacedDigit()
                    if let author = issue.author { Text(author).foregroundStyle(issue.authorIsBot ? .tertiary : .secondary) }
                    Text(GitHubRules.formatAge(issue.updatedAt, now: now)).help(issue.updatedAt)
                    if !issue.assignees.isEmpty { Text("→ \(issue.assignees.joined(separator: ", "))") }
                    Labels(labels: issue.labels)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct RepositoryList: View {
    @Bindable var model: GitHubScreenModel
    let access: GitHubRepoAccess?
    let current: String?
    let installUrl: String?

    var body: some View {
        switch access {
        case nil:
            NativePageNote("Reading your repositories…", busy: true).frame(minHeight: 120)
        case .failed(let failure)?:
            FailureBlock(failure: failure) { Task { await model.loadAuth() } }
        case .list(let list)?:
            let shown = GitHubRules.filterRepos(list.repos, query: model.repoQuery)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(GitHubRules.accessSummary(list)).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if list.repos.count > 5 {
                        TextField("Filter", text: $model.repoQuery)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .accessibilityLabel("Filter repositories")
                    }
                }
                if let selection = GitHubRules.selectionSentence(list) {
                    Text(selection).font(.callout).foregroundStyle(.secondary)
                }
                if list.repos.isEmpty {
                    Text("This sign-in cannot reach any repositories.\(installUrl != nil ? " Install the app on the repositories you want it to see." : "")")
                        .font(.callout).foregroundStyle(.secondary)
                } else if shown.isEmpty {
                    Text("Nothing matches “\(model.repoQuery)”\(list.truncated ? " in the page loaded here — the full list is on GitHub." : ".")")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 2) {
                        ForEach(shown) { repo in RepoRow(repo: repo, now: model.now, current: repo.nameWithOwner == current) }
                    }
                }
                if let installUrl {
                    Button("Change which repositories this app can see") { GitHubScreenModel.openExternally(installUrl) }
                        .buttonStyle(.link)
                }
            }
        }
    }
}

private struct RepoRow: View {
    let repo: GitHubRepoSummary
    let now: Date
    let current: Bool

    var body: some View {
        RowFrame(url: repo.url, help: "\(repo.nameWithOwner) — open on GitHub") {
            Badge(text: repo.isPrivate ? "private" : "public", color: GitHubColors.badge(repo.isPrivate ? "private" : "public"))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(repo.nameWithOwner)
                    if current {
                        Text("this folder").font(.caption).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6).background(Color.accentColor.opacity(0.12), in: .capsule)
                    }
                }
                HStack(spacing: 8) {
                    if let description = repo.description { Text(description).lineLimit(1) }
                    if let language = repo.language { Text(language) }
                    if repo.fork { Text("fork") }
                    if repo.archived { Text("archived") }
                    if let pushed = repo.pushedAt { Text(GitHubRules.formatAge(pushed, now: now)).help(pushed) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .background(current ? Color.accentColor.opacity(0.06) : .clear, in: .rect(cornerRadius: 8))
    }
}
