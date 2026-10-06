import AppKit
import Observation
@preconcurrency import SwiftTerm
import SwiftUI
import TerminalDeckNativeCore

// Setting an agent up on a server (`ServerSetup.tsx`) and the terminal its
// flows run in (`ServerTerminal.tsx`), shared by Settings → Coding AI → Servers
// and Machines → a server's page — one panel, as on the web.

/// One server's "Coding agents" panel: its rows, the push that moves them, and
/// the one terminal an install, sign-in or sign-out runs in.
@MainActor
@Observable
final class NativeServerSetupModel {
    enum Want: String { case install, signIn, signOut }

    let serverId: String
    private(set) var rows: [CodingAISetupRow] = []
    private(set) var states: [String: CodingAISetupState] = [:]
    private(set) var asking: (agentId: String, want: Want)?
    private(set) var running: (agentId: String, want: Want)?
    private(set) var refusal = ""
    private(set) var shell: NativeServerShell?
    @ObservationIgnored private var subscription: EngineSubscription?

    init(serverId: String) { self.serverId = serverId }

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    /// Asked only once the server has been reached (`connected`).
    func start() {
        if subscription == nil {
            // The push, not a timer: every push names its server and its row.
            subscription = EngineBridge.shared.on("servers:setup:changed") { [weak self] args in
                guard let self, let state = CodingAISetupState.parse(CodingAIJSON(args.first)), state.serverId == self.serverId else { return }
                self.states[state.agentId] = state
                if state.step == .done || state.step == .idle { self.look() }
            }
        }
        look()
    }

    func stop() {
        shell?.close()
        shell = nil
        if running != nil { Task { _ = try? await call("servers:setup:cancel", [serverId]) } }
        running = nil
        subscription?.cancel()
        subscription = nil
    }

    func look() {
        Task {
            guard let raw = try? await call("servers:setup:look", [serverId]),
                  let rows = CodingAISetupRow.parseOffer(raw) else { return }
            self.rows = rows
            // Seeded from the same answer, so a setup already in flight shows its line at once.
            states = Dictionary(rows.map { ($0.agentId, $0.state) }, uniquingKeysWith: { $1 })
        }
    }

    func ask(_ agentId: String, _ want: Want) { asking = (agentId, want) }
    func cancelAsk() { asking = nil }

    /// Start a flow: open the terminal it runs in, then ask the server to begin there.
    func run(_ agentId: String, _ want: Want) {
        guard running == nil else { return }
        asking = nil
        refusal = ""
        running = (agentId, want)
        let shell = NativeServerShell(serverId: serverId)
        shell.onOpened = { [weak self] shellId in self?.begin(shellId) }
        shell.onEnded = { [weak self] in self?.stopFlow() }
        self.shell = shell
        shell.open()
    }

    private func begin(_ shellId: String) {
        guard let running else { return }
        let channel: String
        switch running.want {
        case .install: channel = "servers:setup:install"
        case .signIn: channel = "servers:setup:signin"
        case .signOut: channel = "servers:setup:signout"
        }
        Task {
            do {
                let raw = try await call(channel, [serverId, running.agentId, shellId])
                if !CodingAISetupReply.ok(raw) { refusal = CodingAISetupReply.sentence(raw) }
            } catch {
                refusal = CodingAIErrorText.from(error, fallback: "This build of the app cannot ask a server to do that.")
            }
        }
    }

    /// Stop (or, on a route this app cannot watch, "I’m done"): close the terminal and cancel.
    func stopFlow() {
        shell?.close()
        shell = nil
        running = nil
        refusal = ""
        Task { _ = try? await call("servers:setup:cancel", [serverId]) }
    }

    func removeInstalled(_ agentId: String) {
        Task {
            _ = try? await call("servers:setup:remove", [serverId, agentId])
            look()
        }
    }
}

/// The "Coding agents" section (`ServerSetup`): nothing until the server has answered.
struct NativeServerSetupPanel: View {
    @Bindable var model: NativeServerSetupModel

    var body: some View {
        if !model.rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Coding agents")
                    .font(.headline)
                ForEach(model.rows) { row in
                    setupRow(row)
                }
                if !model.refusal.isEmpty {
                    Text(model.refusal)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let running = model.running {
                    let code = model.states[running.agentId]?.code ?? ""
                    if !code.isEmpty { NativeServerOneTimeCode(code: code) }
                    if let shell = model.shell { NativeServerShellBox(shell: shell) }
                }
            }
        }
    }

    private func setupRow(_ row: CodingAISetupRow) -> some View {
        let state = model.states[row.agentId] ?? row.state
        let idle = model.running == nil
        let mine = model.running?.agentId == row.agentId
        let offers = row.offers(state, idle: idle, canSignOut: true)
        let asking = model.asking?.agentId == row.agentId ? model.asking?.want : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.line(state))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if offers.setUp {
                    Button("Set it up") { model.ask(row.agentId, .install) }
                        .buttonStyle(.borderedProminent)
                }
                if offers.signIn {
                    Button("Sign in") { model.run(row.agentId, .signIn) }
                        .buttonStyle(.borderedProminent)
                }
                if offers.signOut {
                    Button("Sign out") { model.ask(row.agentId, .signOut) }
                }
                if offers.installAgain {
                    Button("Install it again") { model.ask(row.agentId, .install) }
                }
                if mine {
                    Button(state.byHand ? "I’m done" : "Stop") { model.stopFlow() }
                }
                if offers.remove {
                    Button("Remove what was installed", role: .destructive) { model.removeInstalled(row.agentId) }
                }
            }
            if let why = offers.why { NativeServerWhy(text: why) }
            if let whyNot = offers.whyNoSignOut { NativeServerWhy(text: whyNot) }
            if !state.detail.isEmpty { NativeServerWhy(text: state.detail) }
            if let asking {
                VStack(alignment: .leading, spacing: 6) {
                    Text(asking == .install ? row.consequence : row.signOutConsequence)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if asking == .install {
                            Button("Install") { model.run(row.agentId, .install) }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Sign out") { model.run(row.agentId, .signOut) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Cancel") { model.cancelAsk() }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
    }
}

/// `servers-card-why`: the small line saying why, or what happened.
struct NativeServerWhy: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// The terminal a flow runs in, framed.
struct NativeServerShellBox: View {
    let shell: NativeServerShell
    var body: some View {
        NativeServerShellView(shell: shell)
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        if let refused = shell.refused {
            Text(refused).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// The code a device sign-in is waiting for, and Copy.
struct NativeServerOneTimeCode: View {
    let code: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(code)
                .font(.title3.monospaced().weight(.semibold))
                .textSelection(.enabled)
                .accessibilityLabel(code.map(String.init).joined(separator: " "))
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(code, forType: .string)
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        }
    }
}

// MARK: - The terminal a setup runs in

/// A shell on one server (`servers:shell:*`), drawn by SwiftTerm.
@MainActor
@Observable
final class NativeServerShell {
    @ObservationIgnored let serverId: String
    @ObservationIgnored let view: TerminalView
    @ObservationIgnored private(set) var shellId: String?
    private(set) var refused: String?
    @ObservationIgnored var onOpened: ((String) -> Void)?
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored private var held: [(shellId: String, data: String)] = []
    @ObservationIgnored private var settled = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private let proxy = NativeServerShellDelegate()

    init(serverId: String) {
        self.serverId = serverId
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 720, height: 280))
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        proxy.owner = self
        view.terminalDelegate = proxy
        subscriptions = [
            EngineBridge.shared.on("servers:shell:output") { [weak self] args in
                guard let self, let chunk = CodingAISetupReply.shellOutput(CodingAIJSON(args.first)) else { return }
                if let id = self.shellId {
                    if chunk.shellId == id { self.view.feed(text: chunk.data) }
                } else if !self.settled {
                    // Output that lands before the open call answers is held, then replayed.
                    self.held.append(chunk)
                }
            },
            EngineBridge.shared.on("servers:shell:closed") { [weak self] args in
                guard let self, let chunk = CodingAISetupReply.shellOutput(CodingAIJSON(args.first)),
                      let id = self.shellId, chunk.shellId == id else { return }
                self.view.feed(text: "\r\n\r\n\u{1b}[2m[This terminal ended.]\u{1b}[0m\r\n")
                self.shellId = nil
                self.onEnded?()
            },
        ]
    }

    func open() {
        let terminal = view.getTerminal()
        let cols = max(terminal.cols, 40)
        let rows = max(terminal.rows, 10)
        Task {
            do {
                let raw = CodingAIJSON(try await EngineBridge.shared.invoke("servers:shell:open", [serverId, cols, rows]))
                settled = true
                guard let id = CodingAISetupReply.shellId(raw) else {
                    held = []
                    refused = "This copy of the app could not open a terminal on that server."
                    return
                }
                if closed {
                    _ = try? await EngineBridge.shared.invoke("servers:shell:close", [id])
                    return
                }
                shellId = id
                // The view has been laid out since the open was asked: give the far end its real size.
                let now = view.getTerminal()
                if now.cols != cols || now.rows != rows { resized(cols: now.cols, rows: now.rows) }
                onOpened?(id)
                let missed = held.filter { $0.shellId == id }.map(\.data).joined()
                held = []
                if !missed.isEmpty { view.feed(text: missed) }
                view.window?.makeFirstResponder(view)
            } catch {
                settled = true
                held = []
                refused = "That server would not open a terminal."
            }
        }
    }

    func close() {
        closed = true
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        if let id = shellId {
            shellId = nil
            Task { _ = try? await EngineBridge.shared.invoke("servers:shell:close", [id]) }
        }
    }

    fileprivate func send(_ data: ArraySlice<UInt8>) {
        guard let id = shellId else { return }
        EngineBridge.shared.send("servers:shell:write", [id, String(decoding: data, as: UTF8.self)])
    }

    fileprivate func resized(cols: Int, rows: Int) {
        guard let id = shellId, cols > 0, rows > 0 else { return }
        Task { _ = try? await EngineBridge.shared.invoke("servers:shell:resize", [id, cols, rows]) }
    }

    fileprivate func open(link: String) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
private final class NativeServerShellDelegate: TerminalViewDelegate {
    weak var owner: NativeServerShell?

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { owner?.resized(cols: newCols, rows: newRows) }
    }
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { owner?.send(data) }
    }
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        MainActor.assumeIsolated { owner?.open(link: link) }
    }
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        MainActor.assumeIsolated {
            guard let text = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

struct NativeServerShellView: NSViewRepresentable {
    let shell: NativeServerShell

    func makeNSView(context: Context) -> TerminalView { shell.view }
    func updateNSView(_ view: TerminalView, context: Context) {}
}
