import AppKit
import Observation
@preconcurrency import SwiftTerm
import SwiftUI
import TerminalDeckNativeCore

/// The Servers seat: every stored server, and — once a row is opened, which is
/// the press that connects to it — the coding logins on it and the panel that
/// sets an agent up, signs it in and signs it out. Two of those flows finish in
/// a terminal (a one-time code, a full-screen sign-in), so the panel opens a
/// real terminal on the server for them, as the web panel does.
///
/// Nothing is dialled until a row is opened; leaving the seat hangs up on every
/// server it opened.
@MainActor
@Observable
final class NativeCodingAIServersModel {
    enum Want: String { case install, signIn, signOut }

    struct Setup {
        var rows: [CodingAISetupRow] = []
        var states: [String: CodingAISetupState] = [:]
        var asking: (agentId: String, want: Want)?
        var running: (agentId: String, want: Want)?
        var refusal = ""
        var shell: NativeCodingAIServerShell?
    }

    private(set) var servers: [CodingAIServer] = []
    private(set) var reading = true
    private(set) var problem: String?
    private(set) var looks: [String: CodingAIServerLook] = [:]
    private(set) var setups: [String: Setup] = [:]
    var expanded: Set<String> = []
    @ObservationIgnored private var opened: Set<String> = []
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    func start() {
        guard subscriptions.isEmpty else { return }
        subscriptions = [
            // The push, not a timer: every push names its server and its row.
            EngineBridge.shared.on("servers:setup:changed") { [weak self] args in
                guard let self, let state = CodingAISetupState.parse(CodingAIJSON(args.first)),
                      self.setups[state.serverId] != nil else { return }
                self.setups[state.serverId]?.states[state.agentId] = state
                if state.step == .done || state.step == .idle { self.lookAtSetup(state.serverId) }
            },
        ]
        load()
    }

    func stop() {
        guard !subscriptions.isEmpty || !opened.isEmpty || !setups.isEmpty else { return }
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
        for (id, setup) in setups {
            setup.shell?.close()
            if setup.running != nil { Task { _ = try? await call("servers:setup:cancel", [id]) } }
        }
        setups = [:]
        // Only the ones this seat opened.
        for id in opened { Task { _ = try? await call("servers:close", [id]) } }
        opened = []
        looks = [:]
        expanded = []
    }

    private func load() {
        reading = true
        Task {
            let work = Task { try await call("servers:list") }
            let timer = Task {
                try? await Task.sleep(for: .seconds(CodingAIDeadline.readServers))
                work.cancel()
            }
            do {
                let raw = try await work.value
                timer.cancel()
                servers = CodingAIServer.parseList(raw)
                problem = nil
            } catch {
                timer.cancel()
                problem = work.isCancelled
                    ? CodingAIDeadline.overdue("reading your servers", seconds: CodingAIDeadline.readServers)
                    : CodingAIErrorText.from(error, fallback: "Could not read your servers.")
            }
            reading = false
        }
    }

    /// Opening a row is the press that buys the round trip. Opening it again does not redial.
    func open(_ server: CodingAIServer) {
        guard !opened.contains(server.id) else { return }
        opened.insert(server.id)
        looks[server.id] = .looking
        Task {
            do {
                let raw = try await call("servers:look", [server.id])
                let look = CodingAIServerLook.parse(raw, serverName: server.name)
                looks[server.id] = look
                if case .failed = look {
                    opened.remove(server.id)
                } else {
                    setups[server.id] = setups[server.id] ?? Setup()
                    lookAtSetup(server.id)
                }
            } catch {
                opened.remove(server.id)
                looks[server.id] = .failed(CodingAIErrorText.from(error, fallback: "\(server.name) did not answer."))
            }
        }
    }

    private func lookAtSetup(_ serverId: String) {
        Task {
            guard let raw = try? await call("servers:setup:look", [serverId]),
                  let rows = CodingAISetupRow.parseOffer(raw) else { return }
            var setup = setups[serverId] ?? Setup()
            setup.rows = rows
            // Seeded from the same answer, so a setup already in flight shows its line at once.
            setup.states = Dictionary(rows.map { ($0.agentId, $0.state) }, uniquingKeysWith: { $1 })
            setups[serverId] = setup
        }
    }

    // MARK: Actions on one row

    func ask(_ serverId: String, _ agentId: String, _ want: Want) {
        setups[serverId]?.asking = (agentId, want)
    }

    func cancelAsk(_ serverId: String) {
        setups[serverId]?.asking = nil
    }

    /// Start a flow: open the terminal it runs in, then ask the server to begin there.
    func run(_ server: CodingAIServer, _ agentId: String, _ want: Want) {
        guard var setup = setups[server.id], setup.running == nil else { return }
        setup.asking = nil
        setup.refusal = ""
        setup.running = (agentId, want)
        let shell = NativeCodingAIServerShell(serverId: server.id)
        shell.onOpened = { [weak self] shellId in self?.begin(server.id, shellId: shellId) }
        shell.onEnded = { [weak self] in self?.stopFlow(server.id) }
        setup.shell = shell
        setups[server.id] = setup
        shell.open()
    }

    private func begin(_ serverId: String, shellId: String) {
        guard let running = setups[serverId]?.running else { return }
        let channel: String
        switch running.want {
        case .install: channel = "servers:setup:install"
        case .signIn: channel = "servers:setup:signin"
        case .signOut: channel = "servers:setup:signout"
        }
        Task {
            do {
                let raw = try await call(channel, [serverId, running.agentId, shellId])
                if !CodingAISetupReply.ok(raw) { setups[serverId]?.refusal = CodingAISetupReply.sentence(raw) }
            } catch {
                setups[serverId]?.refusal = CodingAIErrorText.from(error, fallback: "This build of the app cannot ask a server to do that.")
            }
        }
    }

    /// Stop (or, on a route this app cannot watch, "I’m done"): close the terminal and cancel.
    func stopFlow(_ serverId: String) {
        guard setups[serverId] != nil else { return }
        setups[serverId]?.shell?.close()
        setups[serverId]?.shell = nil
        setups[serverId]?.running = nil
        setups[serverId]?.refusal = ""
        Task { _ = try? await call("servers:setup:cancel", [serverId]) }
    }

    func removeInstalled(_ serverId: String, _ agentId: String) {
        Task {
            _ = try? await call("servers:setup:remove", [serverId, agentId])
            lookAtSetup(serverId)
        }
    }
}

// MARK: - The section

struct NativeCodingAIServersSection: View {
    @Bindable var model: NativeCodingAIServersModel

    var body: some View {
        Group {
            if model.reading && model.servers.isEmpty {
                Section { Text("Reading your servers…").foregroundStyle(.secondary) }
            } else if let problem = model.problem {
                Section { NativeCodingAINotice(tone: .error, text: problem) }
            } else if model.servers.isEmpty {
                Section { Text("No servers yet.").foregroundStyle(.secondary) }
            } else {
                Section {
                    NativeCodingAINotice(tone: .info, text: CodingAIServerAgents.intro)
                }
                ForEach(model.servers) { server in
                    Section {
                        DisclosureGroup(isExpanded: Binding(
                            get: { model.expanded.contains(server.id) },
                            set: { open in
                                if open {
                                    model.expanded.insert(server.id)
                                    model.open(server)
                                } else {
                                    model.expanded.remove(server.id)
                                }
                            })
                        ) {
                            NativeCodingAIServerBody(model: model, server: server)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                Text(server.whereLine)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// One opened server: its logins in the runs, then the setup rows.
struct NativeCodingAIServerBody: View {
    @Bindable var model: NativeCodingAIServersModel
    let server: CodingAIServer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            logins
            if let setup = model.setups[server.id], !setup.rows.isEmpty {
                setupPanel(setup)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var logins: some View {
        switch model.looks[server.id] {
        case nil:
            EmptyView()
        case .looking?:
            Text("Asking \(server.name)…").foregroundStyle(.secondary)
        case .failed(let problem)?:
            NativeCodingAINotice(tone: .error, text: problem)
        case .notAsked?:
            Text(CodingAIServerAgents.notAsked(server.name)).foregroundStyle(.secondary)
        case .cannot(let why)?:
            Text(why).foregroundStyle(.secondary)
        case .agents(let found)?:
            ForEach(CodingAIServerAgents.runs(found)) { run in
                VStack(alignment: .leading, spacing: 4) {
                    if let title = run.title {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(run.agents) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                NativeCodingAIProviderMark(provider: row.id, size: 13)
                                Text(row.label)
                                if !row.version.isEmpty { NativeCodingAIBadge(text: row.version, quiet: true) }
                            }
                            HStack(spacing: 5) {
                                NativeCodingAIStateMark(state: row.state.rawValue)
                                Text(row.line).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    private func setupPanel(_ setup: NativeCodingAIServersModel.Setup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Coding agents")
                .font(.headline)
            ForEach(setup.rows) { row in
                setupRow(row, setup: setup)
            }
            if !setup.refusal.isEmpty {
                Text(setup.refusal)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let running = setup.running {
                let code = setup.states[running.agentId]?.code ?? ""
                if !code.isEmpty { NativeCodingAIOneTimeCode(code: code) }
                if let shell = setup.shell {
                    NativeCodingAIServerShellView(shell: shell)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    if let refused = shell.refused {
                        Text(refused).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func setupRow(_ row: CodingAISetupRow, setup: NativeCodingAIServersModel.Setup) -> some View {
        let state = setup.states[row.agentId] ?? row.state
        let idle = setup.running == nil
        let mine = setup.running?.agentId == row.agentId
        let offers = row.offers(state, idle: idle, canSignOut: true)
        let asking = setup.asking?.agentId == row.agentId ? setup.asking?.want : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.line(state))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if offers.setUp {
                    Button("Set it up") { model.ask(server.id, row.agentId, .install) }
                        .buttonStyle(.borderedProminent)
                }
                if offers.signIn {
                    Button("Sign in") { model.run(server, row.agentId, .signIn) }
                        .buttonStyle(.borderedProminent)
                }
                if offers.signOut {
                    Button("Sign out") { model.ask(server.id, row.agentId, .signOut) }
                }
                if offers.installAgain {
                    Button("Install it again") { model.ask(server.id, row.agentId, .install) }
                }
                if mine {
                    Button(state.byHand ? "I’m done" : "Stop") { model.stopFlow(server.id) }
                }
                if offers.remove {
                    Button("Remove what was installed", role: .destructive) { model.removeInstalled(server.id, row.agentId) }
                }
            }
            if let why = offers.why { why_(why) }
            if let whyNot = offers.whyNoSignOut { why_(whyNot) }
            if !state.detail.isEmpty { why_(state.detail) }
            if let asking {
                VStack(alignment: .leading, spacing: 6) {
                    Text(asking == .install ? row.consequence : row.signOutConsequence)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if asking == .install {
                            Button("Install") { model.run(server, row.agentId, .install) }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Sign out") { model.run(server, row.agentId, .signOut) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Cancel") { model.cancelAsk(server.id) }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
    }

    private func why_(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The code a device sign-in is waiting for, and Copy.
struct NativeCodingAIOneTimeCode: View {
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
final class NativeCodingAIServerShell {
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
    @ObservationIgnored private let proxy = NativeCodingAIShellDelegate()

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
private final class NativeCodingAIShellDelegate: TerminalViewDelegate {
    weak var owner: NativeCodingAIServerShell?

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

struct NativeCodingAIServerShellView: NSViewRepresentable {
    let shell: NativeCodingAIServerShell

    func makeNSView(context: Context) -> TerminalView { shell.view }
    func updateNSView(_ view: TerminalView, context: Context) {}
}
