import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// "Sessions on this server" (`ServerHost.tsx`): putting this app's host on a
/// server, updating it, linking this computer to it, a pairing code for a phone,
/// its address for a phone, and removing it — then, once this computer is linked
/// to it, the host over the relay (`ServerHostRelayControl.tsx`) and the
/// machine's GitHub (`ServerConnectGitHub.tsx`).
struct NativeServerHost: View {
    let server: CodingAIServer
    let connected: Bool
    @State private var model: NativeServerHostModel

    init(server: CodingAIServer, connected: Bool) {
        self.server = server
        self.connected = connected
        _model = State(initialValue: NativeServerHostModel(serverId: server.id))
    }

    var body: some View {
        Group {
            if let offer = model.offer {
                hostPanel(offer)
                if let machine = model.linkedMachine(offer) {
                    if machine.capabilities.contains("host.control") {
                        NativeServerHostRelayControl(machineId: machine.id)
                    }
                    if machine.capabilities.contains("github") {
                        NativeServerConnectGitHub(machineId: machine.id)
                    }
                }
            }
        }
        .onAppear { model.start(connected: connected) }
        .onChange(of: connected) { _, now in if now { model.look() } }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private func hostPanel(_ offer: ServerHostOffer) -> some View {
        let controls = ServerHostRules.controls(offer, busy: model.running != nil)
        let state = model.state
        VStack(alignment: .leading, spacing: 10) {
            Text("Sessions on this server").font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(state.map { $0.working ? $0.line : offer.line } ?? offer.line)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if controls.install {
                    Button("Set it up") { model.asking = .install }.buttonStyle(.borderedProminent)
                }
                if let update = controls.update {
                    Button("Update it to \(update)") { model.asking = .install }.buttonStyle(.borderedProminent)
                }
                if controls.link {
                    Button("Link this computer") { model.run(.link) }.buttonStyle(.borderedProminent)
                }
                if controls.pair {
                    Button("Show a code for a phone") { model.run(.pair) }
                }
                if controls.remove {
                    Button("Remove Terminal Deck from this server", role: .destructive) { model.asking = .remove }
                }
                if controls.stop {
                    Button("Stop") { model.stopFlow() }
                }
            }
            if let why = controls.why { NativeServerWhy(text: why) }
            if let reach = controls.reach { NativeServerWhy(text: reach) }
            if let linkedAs = controls.linkedAs {
                NativeServerWhy(text: controls.away ? ServerHostRules.awayLine(linkedAs) : ServerHostRules.linkedLine(linkedAs))
            }
            if controls.here {
                NativeServerAddress(address: offer.address, running: offer.running)
                NativeServerWhy(text: ServerHostRules.serverCopilot)
            }
            if let state, !state.done.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(state.done.enumerated()), id: \.offset) { index, line in
                        Text("\(index + 1). \(line)").font(.callout)
                    }
                }
            }
            if let state, !state.detail.isEmpty { NativeServerWhy(text: state.detail) }
            if !model.refusal.isEmpty { NativeServerWhy(text: model.refusal) }
            if model.running == .pair, let code = state?.code {
                VStack(alignment: .leading, spacing: 6) {
                    Text(code).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                    NativeServerWhy(text: ServerHostRules.pairingHelp)
                }
            }
            if model.asking == .install {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(offer.consequence.components(separatedBy: "\n\n"), id: \.self) { para in
                        NativeSettingsProse(text: para)
                    }
                    HStack {
                        Button("Install") {
                            model.asking = nil
                            model.run(.install)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Cancel") { model.asking = nil }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
            if model.asking == .remove {
                VStack(alignment: .leading, spacing: 6) {
                    NativeSettingsProse(text: model.alsoData ? offer.removesWithData : offer.removesKeepData)
                    Toggle("Remove what it stored on this server as well", isOn: $model.alsoData)
                        .toggleStyle(.checkbox)
                    HStack {
                        Button("Remove it", role: .destructive) { model.remove() }
                        Button("Cancel") { model.asking = nil }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
            if let shell = model.shell { NativeServerShellBox(shell: shell) }
            if controls.here && !offer.status.isEmpty {
                DisclosureGroup("What it says about itself") {
                    Text(offer.status)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

@MainActor
@Observable
final class NativeServerHostModel {
    enum Flow { case install, link, pair }
    enum Ask { case install, remove }

    let serverId: String
    private(set) var offer: ServerHostOffer?
    private(set) var state: ServerHostState?
    private(set) var running: Flow?
    var asking: Ask?
    var alsoData = false
    private(set) var refusal = ""
    private(set) var shell: NativeServerShell?
    private(set) var machines: [CodingAIDevice] = []
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []

    init(serverId: String) { self.serverId = serverId }

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    func start(connected: Bool) {
        if subscriptions.isEmpty {
            subscriptions = [
                EngineBridge.shared.on("servers:host:changed") { [weak self] args in
                    guard let self, let read = ServerHostState.parse(CodingAIJSON(args.first)), read.serverId == self.serverId else { return }
                    self.state = read
                    if read.step == .done || read.step == .idle || read.step == .failed { self.look() }
                },
                EngineBridge.shared.on("machines:state") { [weak self] args in
                    self?.machines = CodingAIMachinesView.parse(CodingAIJSON(args.first)).devices
                },
            ]
            Task { machines = CodingAIMachinesView.parse((try? await call("machines:list")) ?? .null).devices }
        }
        if connected { look() }
    }

    func stop() {
        shell?.close()
        shell = nil
        if running != nil { Task { [serverId] in _ = try? await EngineBridge.shared.invoke("servers:host:cancel", [serverId]) } }
        running = nil
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
    }

    func look() {
        Task {
            guard let raw = try? await call("servers:host:look", [serverId]), raw["ok"].isTrue,
                  let read = ServerHostOffer.parse(raw["offer"]) else { return }
            offer = read
            state = read.state
        }
    }

    /// The machine this computer is linked to it as, when it is online here.
    func linkedMachine(_ offer: ServerHostOffer) -> CodingAIDevice? {
        guard let name = offer.linkedAs else { return nil }
        return machines.first { $0.name == name }
    }

    func run(_ flow: Flow) {
        guard running == nil else { return }
        refusal = ""
        running = flow
        let shell = NativeServerShell(serverId: serverId)
        shell.onOpened = { [weak self] shellId in self?.begin(shellId) }
        shell.onEnded = { [weak self] in self?.stopFlow() }
        self.shell = shell
        shell.open()
    }

    private func begin(_ shellId: String) {
        guard let running else { return }
        let channel: String
        switch running {
        case .install: channel = "servers:host:install"
        case .link: channel = "servers:host:link"
        case .pair: channel = "servers:host:pair"
        }
        Task {
            if let raw = try? await call(channel, [serverId, shellId]), !raw["ok"].isTrue {
                refusal = ServerHostRules.sentence(raw)
            }
        }
    }

    func stopFlow() {
        shell?.close()
        shell = nil
        running = nil
        Task { _ = try? await call("servers:host:cancel", [serverId]) }
    }

    func remove() {
        asking = nil
        refusal = ""
        Task {
            if let raw = try? await call("servers:host:remove", [serverId, alsoData]), !raw["ok"].isTrue {
                refusal = ServerHostRules.sentence(raw)
            }
            look()
        }
    }
}

/// The address a phone pastes (`ServerAddress`).
struct NativeServerAddress: View {
    let address: String
    let running: ServerHostOffer.Running
    @State private var said = ""

    var body: some View {
        if address.isEmpty {
            NativeServerWhy(text: ServerHostRules.noAddressLine(running))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Address for a phone").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(said == "copied" ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        said = NSPasteboard.general.setString(address, forType: .string) ? "copied" : "refused"
                        Task {
                            try? await Task.sleep(for: .seconds(4))
                            said = ""
                        }
                    }
                }
                Text(address).font(.callout.monospaced()).textSelection(.enabled)
                if said == "refused" {
                    NativeServerWhy(text: "This window could not reach the clipboard. Select the address above and copy it.")
                }
                NativeServerWhy(text: ServerHostRules.addressHow)
                NativeServerWhy(text: ServerHostRules.addressNotASecret)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
    }
}

// MARK: - The host over the relay

struct NativeServerHostRelayControl: View {
    let machineId: String
    @State private var control: ServerHostControl?
    @State private var working = false
    @State private var note: String?
    @State private var timedOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The host, over the relay").font(.headline)
            Text(control?.say ?? "Reaching the host over the relay…")
            if let control { NativeServerWhy(text: control.detail) }
            NativeServerWhy(text: "Reached over the relay, so these work even when this server’s address is offline.")
            HStack {
                Button(working ? "Working…" : "Restart it") { verb("machines:host:restart") }
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
                Button("Stop", role: .destructive) { verb("machines:host:stop") }
                    .disabled(working)
                Button("Check again") { read() }
                    .disabled(working)
            }
            if let note { NativeServerWhy(text: note) }
            if timedOut {
                NativeServerWhy(text: "No word came back before the connection dropped — the host may be on its way back up. Press Check again in a moment.")
            }
        }
        .onAppear(perform: read)
    }

    private func read() {
        Task {
            guard let raw = try? await EngineBridge.shared.invoke("machines:host:read", [machineId]),
                  let wire = ServerHostControl.parse(CodingAIJSON(raw)) else { return }
            control = wire
            if let said = wire.note { note = said }
        }
    }

    private func verb(_ channel: String) {
        guard !working else { return }
        working = true
        timedOut = false
        note = nil
        Task {
            let raw = try? await EngineBridge.shared.invoke(channel, [machineId])
            working = false
            guard let raw, let wire = ServerHostControl.parse(CodingAIJSON(raw)) else {
                timedOut = true
                return
            }
            control = wire
            note = wire.note
        }
    }
}

// MARK: - The machine's GitHub

struct NativeServerConnectGitHub: View {
    let machineId: String
    @State private var github: ServerGitHub?
    @State private var working = false
    @State private var timedOut = false
    @State private var copied = false
    @State private var subscription: EngineSubscription?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub").font(.headline)
            if let github {
                content(github)
            } else {
                Text("Reading the machine’s GitHub…")
            }
            if timedOut { NativeServerWhy(text: "This machine did not answer. Try again.") }
        }
        .onAppear {
            read()
            subscription = EngineBridge.shared.on("machines:github:changed") { args in
                guard args.first as? String == machineId, args.count > 1,
                      let wire = ServerGitHub.parse(CodingAIJSON(args[1])) else { return }
                github = wire
                working = false
                timedOut = false
            }
        }
        .onDisappear { subscription?.cancel() }
    }

    @ViewBuilder private func content(_ github: ServerGitHub) -> some View {
        switch github.phase {
        case .signingIn:
            NativeServerWhy(text: "On the machine, open GitHub and enter this code:")
            Text(github.userCode ?? "").font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
            HStack {
                Button(copied ? "Copied" : "Copy code") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(github.userCode ?? "", forType: .string)
                }
                Button("Open GitHub") {
                    if let url = URL(string: github.verificationUri ?? "") { NSWorkspace.shared.open(url) }
                }
            }
            NativeServerWhy(text: github.verificationUri ?? "")
            NativeServerWhy(text: "It finishes on its own once the code is entered — you do not have to stay here.")
            Button(working ? "Cancelling…" : "Cancel sign-in") { verb("machines:github:cancel") }
                .disabled(working)
        case .connected:
            Text("@\(github.login ?? "")")
            if let subtitle = github.subtitle, !subtitle.isEmpty { NativeServerWhy(text: subtitle) }
            if let install = github.installUrl, let url = URL(string: install) {
                Button("Choose repositories on GitHub") { NSWorkspace.shared.open(url) }
            }
            Button(working ? "Disconnecting…" : "Disconnect", role: .destructive) { verb("machines:github:disconnect") }
                .disabled(working)
        case .notConfigured:
            NativeServerWhy(text: github.failure ?? ServerGitHub.notConfigured)
        case .ready:
            NativeServerWhy(text: "Connect a GitHub account on this machine. It signs in over there and uses it for git in your sessions — this computer never holds the token.")
            Button(working ? "Starting…" : "Connect GitHub") { verb("machines:github:connect") }
                .buttonStyle(.borderedProminent)
                .disabled(working)
        }
        if github.phase != .notConfigured, let failure = github.failure { NativeServerWhy(text: failure) }
    }

    private func read() {
        Task {
            guard let raw = try? await EngineBridge.shared.invoke("machines:github:read", [machineId]),
                  let wire = ServerGitHub.parse(CodingAIJSON(raw)) else { return }
            github = wire
        }
    }

    private func verb(_ channel: String) {
        guard !working else { return }
        working = true
        timedOut = false
        Task {
            let raw = try? await EngineBridge.shared.invoke(channel, [machineId])
            working = false
            if let raw, let wire = ServerGitHub.parse(CodingAIJSON(raw)) { github = wire } else { timedOut = true }
        }
    }
}
