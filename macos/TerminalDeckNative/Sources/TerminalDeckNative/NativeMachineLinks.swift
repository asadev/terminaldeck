import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// The machines this desktop dialled, drawn in Swift — the web's
/// `machines/MachineLinks.tsx` ("Machines you can reach": each machine's state,
/// version, reason, fingerprint, its sessions, its localhost ports, the browser
/// windows tick, Connect/Disconnect and Forget with its confirm) and
/// `machines/CodeEntry.tsx` (the six boxes and Pair). One model holds the half
/// both read (`MachinesHalfModel`); `NativeRemoteSection` holds it and places the
/// two views where the page places them.

@MainActor
@Observable
final class MachinesHalfModel {
    private(set) var view = MachinesView.empty
    /// The engine answers `machines:list`; false only when it never does.
    private(set) var wired = true
    private(set) var reading = true
    private(set) var error: String?
    /// The code being typed.
    private(set) var digits = ""
    private(set) var busy = false
    private(set) var pairError: String?

    @ObservationIgnored private var subscription: EngineSubscription?

    func start() async {
        if subscription == nil {
            subscription = EngineBridge.shared.on("machines:state") { [weak self] args in
                guard let self else { return }
                self.view = MachinesView(json: args.first)
                self.error = nil
            }
        }
        reading = true
        await reread()
        reading = false
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    func reread() async {
        do {
            view = MachinesView(json: try await EngineDeadline.invoke("machines:list", what: "The machines this desktop knows",
                                                                     seconds: RemoteRules.readDeadlineSeconds))
            error = nil
        } catch let failure as EngineWireError {
            if case .refused(let why) = failure, why.contains("No handler") { wired = false }
            error = RemoteCall.text(failure, "Could not read the machines this desktop knows.")
        } catch {
            self.error = RemoteCall.text(error, "Could not read the machines this desktop knows.")
        }
    }

    // MARK: Actions (`machineActions`)

    func type(_ next: String) {
        digits = next
        pairError = nil
    }

    func pair() {
        guard let code = CodeEntryRules.normalise(digits) else {
            pairError = "That is not a whole code yet."
            return
        }
        busy = true
        pairError = nil
        Task {
            do {
                if let failure = MachinesRules.pairFailure(try await RemoteCall.invoke("machines:pair", [code])) {
                    pairError = failure
                } else {
                    digits = ""
                    await reread()
                }
            } catch {
                pairError = RemoteCall.text(error, "That did not work, and this machine did not say why.")
            }
            busy = false
        }
    }

    /// Connect, disconnect, forget, the windows tick: the answer is the new view.
    private func settle(_ channel: String, _ args: [Any?]) {
        Task {
            if let next = try? await RemoteCall.invoke(channel, args) { view = MachinesView(json: next) }
        }
    }

    func connect(_ machine: PairedMachine) { settle("machines:connect", [machine.id]) }
    func disconnect(_ machine: PairedMachine) { settle("machines:disconnect", [machine.id]) }
    func forget(_ machine: PairedMachine) { settle("machines:forget", [machine.id]) }
    func setDrivesWindows(_ machine: PairedMachine, _ allowed: Bool) { settle("machines:drive-windows", [machine.id, allowed]) }

    func refreshPorts(_ machine: PairedMachine) {
        Task { _ = try? await RemoteCall.invoke("machines:ports", [machine.id]) }
    }

    func openPort(_ machine: PairedMachine, _ port: Int) {
        Task { _ = try? await RemoteCall.invoke("machines:open", [machine.id, "http://localhost:\(port)/"]) }
    }

    /// A session row's press: its tab, as the page's `selectTab(machineTabId(…))`.
    func open(_ machineId: String, _ sessionId: String) {
        AppModel.shared.web.run(.selectTab(MachinesRules.tabId(machineId: machineId, sessionId: sessionId)))
    }
}

// MARK: - Machines you can reach

struct NativeMachineLinksView: View {
    let half: MachinesHalfModel

    var body: some View {
        RemoteGroup("Machines you can reach") {
            if !half.wired {
                RemoteNotice(tone: .warn, text: "This window is running against an older preload, so it cannot reach the machines this desktop is paired with. Restarting the app usually fixes it.")
            } else if half.reading {
                RemoteSentence( "Reading the machines this desktop knows…")
            } else if let error = half.error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    RemoteNotice(tone: .warn, text: error)
                    Button("Try again") { Task { await half.reread() } }
                }
            } else if half.view.machines.isEmpty {
                RemoteSentence( "No other machine yet.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(half.view.machines) { machine in
                        MachineRowView(half: half, machine: machine, link: half.view.link(for: machine.id))
                        if machine.id != half.view.machines.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private struct MachineRowView: View {
    let half: MachinesHalfModel
    let machine: PairedMachine
    let link: MachineLink
    @State private var confirming = false

    var body: some View {
        let noun = MachinesRules.noun(machine, link)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(machine.name).font(.body.weight(.semibold))
                Text(noun).font(.callout).foregroundStyle(.secondary)
                Text(link.phase.label).font(.callout).foregroundStyle(link.phase == .error ? Color.red : .secondary)
            }
            if let version = MachinesRules.versionLine(link) {
                Text(version).font(.caption).foregroundStyle(.secondary)
            }
            if let reason = MachinesRules.reasonLine(machine, link) {
                Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(machine.fingerprint)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help("Compare this with the same six groups on that machine")
            if link.phase == .online && link.sessions.isEmpty {
                Text("Nothing is running on that \(noun) right now.").font(.callout).foregroundStyle(.secondary)
            }
            if !link.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(link.sessions) { session in
                        Button { half.open(machine.id, session.id) } label: {
                            HStack(spacing: 8) {
                                Text(session.title)
                                Text(MachinesRules.shortPath(session.cwd)).foregroundStyle(.secondary)
                                Text(session.status).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 16)
            }
            if link.phase == .online && link.capabilities.contains("localhost") {
                MachinePortsView(half: half, machine: machine, link: link, noun: noun)
            }
            Toggle("Let its sessions act on browser windows here", isOn: Binding(get: { machine.drivesWindows },
                                                                                 set: { half.setDrivesWindows(machine, $0) }))
                .toggleStyle(.checkbox)
            if MachinesRules.windowsMuted(machine, link) {
                Text("That \(noun) is running a build that cannot ask, so nothing will use this yet.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if link.phase == .online || link.phase == .connecting {
                    Button("Disconnect") { half.disconnect(machine) }
                } else {
                    Button("Connect") { half.connect(machine) }
                }
                if confirming {
                    Text("Forget this \(noun)? You would pair it again from scratch.").font(.callout).foregroundStyle(.secondary)
                    Button("Forget", role: .destructive) {
                        confirming = false
                        half.forget(machine)
                    }
                    Button("Keep") { confirming = false }
                } else {
                    Button("Forget") { confirming = true }
                }
            }
        }
        .padding(.vertical, 12)
    }

    private var dot: Color {
        switch link.phase {
        case .online: .green
        case .connecting, .awaitingApproval: .orange
        case .error: .red
        case .offline: .secondary
        }
    }
}

/// "Localhost on <machine>": the ports listening over there, Refresh, Open there.
private struct MachinePortsView: View {
    let half: MachinesHalfModel
    let machine: PairedMachine
    let link: MachineLink
    let noun: String

    var body: some View {
        let platform = link.hostPlatform.isEmpty ? machine.platform : link.hostPlatform
        let glyph = platform.hasPrefix("win") ? "pc" : platform.hasPrefix("darwin") ? "laptopcomputer" : "desktopcomputer"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: glyph).foregroundStyle(.secondary).accessibilityLabel("on \(machine.name)")
                Text("Localhost on \(machine.name)").font(.callout.weight(.medium))
                Spacer()
                Button("Refresh") { half.refreshPorts(machine) }.buttonStyle(.borderless)
            }
            if link.ports.isEmpty {
                Text("Nothing is listening on that \(noun) right now.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(link.ports) { port in
                    HStack(spacing: 6) {
                        Image(systemName: glyph).foregroundStyle(.secondary).accessibilityLabel("on \(machine.name)")
                        Text(MachinesRules.portLabel(port)).font(.callout.monospaced())
                        Spacer()
                        if link.capabilities.contains("web") {
                            Button("Open there") { half.openPort(machine, port.port) }
                                .buttonStyle(.borderless)
                                .help("Open localhost:\(port.port) in the browser on \(machine.name)")
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
    }
}

// MARK: - The six boxes and Pair

struct NativeCodeEntry: View {
    let half: MachinesHalfModel
    @FocusState private var focused: Int?

    var body: some View {
        let blocked = half.view.blocked
        let disabled = half.busy || blocked != nil || !half.wired
        let complete = CodeEntryRules.normalise(half.digits) != nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<CodeEntryRules.length, id: \.self) { index in
                    TextField("", text: Binding(get: { CodeEntryRules.digit(half.digits, at: index) },
                                                set: { change(index, $0) }))
                        .textFieldStyle(.roundedBorder)
                        .font(.title3.monospaced())
                        .multilineTextAlignment(.center)
                        .frame(width: 34)
                        .focused($focused, equals: index)
                        .disabled(disabled)
                        .help(blocked ?? "")
                        .onKeyPress(.delete) { backspace(index) }
                        .onKeyPress(.leftArrow) { move(index - 1) }
                        .onKeyPress(.rightArrow) { move(index + 1) }
                        .onSubmit { if complete { half.pair() } }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pairing code from the other machine, \(CodeEntryRules.length) digits")
            Button(half.busy ? "Pairing…" : "Pair") { half.pair() }
                .buttonStyle(.borderedProminent)
                .disabled(disabled || !complete)
            if !half.wired {
                RemoteNotice(tone: .warn, text: "This build cannot pair with another desktop. Restart the app.")
            }
            if let blocked { RemoteNotice(tone: .warn, text: blocked) }
            if let error = half.pairError { RemoteNotice(tone: .error, text: error) }
        }
    }

    private func change(_ index: Int, _ raw: String) {
        if let whole = CodeEntryRules.normalise(raw) {
            half.type(whole)
            focused = CodeEntryRules.length - 1
            return
        }
        let typed = CodeEntryRules.typed(into: half.digits, at: index,
                                         raw: CodeEntryRules.added(by: raw, previous: CodeEntryRules.digit(half.digits, at: index)))
        guard typed.digits != half.digits else { return }
        half.type(typed.digits)
        focused = typed.focus
    }

    private func backspace(_ index: Int) -> KeyPress.Result {
        guard CodeEntryRules.digit(half.digits, at: index).isEmpty, index > 0 else { return .ignored }
        half.type(String(half.digits.prefix(index - 1)))
        focused = index - 1
        return .handled
    }

    private func move(_ index: Int) -> KeyPress.Result {
        guard (0..<CodeEntryRules.length).contains(index) else { return .ignored }
        focused = index
        return .handled
    }
}
