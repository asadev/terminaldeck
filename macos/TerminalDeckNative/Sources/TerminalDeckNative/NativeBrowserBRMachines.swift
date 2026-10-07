import AppKit
import SwiftUI
import TerminalDeckNativeCore

// Lane BR (browser parity): which computer a browser window's localhost addresses
// open on — MachinePicker.tsx beside the Session button, the "served by" word in
// the address field (served-mark.ts), the start page's ports for the chosen
// machine, and the tunnels behind them (reach-ledger.ts over `browser:reach:*`).
// Drawn only when another machine or server is paired, as the web browser does.

@MainActor @Observable
final class NativeBRMachines {
    static let shared = NativeBRMachines()
    fileprivate(set) var view = MachinesView.empty
    fileprivate(set) var servers: [(id: String, name: String)] = []
    fileprivate(set) var serverAnswers: [String: (ports: [MachinePort], refused: String?)] = [:]
    /// Every tunnel this desktop is serving (not just one window's).
    fileprivate(set) var holds: [BRReachedPort] = []
    /// The machine each browser tab's addresses open on ("" = this one).
    fileprivate(set) var picked: [String: String] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []

    var choices: [BRMachineChoice] {
        BRMachines.choices(view) + servers.map { BRServers.choice(id: $0.id, name: $0.name, answer: serverAnswers[$0.id]) }
    }
    /// `hereName`: what this computer calls itself, else "This Mac".
    var here: String {
        let named = view.here.trimmingCharacters(in: .whitespaces)
        return named.isEmpty ? "This Mac" : named
    }

    func picked(_ tabId: String) -> String { picked[tabId] ?? BRMachines.thisMachine }

    func start() {
        guard !started else { return }
        started = true
        subscriptions = [
            EngineBridge.shared.on("machines:state") { [weak self] args in self?.view = MachinesView(json: args.first) },
            EngineBridge.shared.on("browser:reach:state") { [weak self] args in self?.holds = BRMachines.readHolds(args.first) },
        ]
        refresh()
    }

    private func refresh() {
        Task {
            guard EngineBridge.shared.isReady else { return }
            if let raw = try? await EngineBridge.shared.invoke("machines:list") { view = MachinesView(json: raw) }
            if let raw = try? await EngineBridge.shared.invoke("browser:reach:list") { holds = BRMachines.readHolds(raw) }
            if let raw = try? await EngineBridge.shared.invoke("servers:list") { servers = BRServers.list(raw) }
        }
    }

    /// A machine's own list of what it serves, asked again (devices push it back; a server answers).
    func refreshPorts(_ machine: BRMachineChoice) {
        Task {
            if machine.kind == "server" {
                serverAnswers[machine.id] = BRServers.ports(try? await EngineBridge.shared.invoke("servers:ports", [machine.id]))
            } else {
                _ = try? await EngineBridge.shared.invoke("machines:ports", [machine.id])
            }
        }
    }

    /// `servedMark` for the address field.
    func served(_ tab: NativeBrowserTab) -> (mark: String, title: String) {
        let url = (tab.webView?.url ?? tab.url)?.absoluteString ?? ""
        return BRMachines.servedMark(page: BRMachines.servedBy(url, opened: holds), picked: picked(tab.id),
                                     blank: tab.url == nil || tab.showsStartView, here: here)
    }

    /// `moveToMachine`: choosing a machine in the picker moves the page's localhost there.
    func select(_ next: String, for tab: NativeBrowserTab) {
        let previous = picked(tab.id)
        guard next != previous else { return }
        let current = (tab.webView?.url ?? tab.url)?.absoluteString ?? ""
        picked[tab.id] = next
        // A server is asked what it serves only once somebody picks it (servers design §5.4); a device pushes its own.
        if let chosen = choices.first(where: { $0.id == next }),
           chosen.kind == "server" ? serverAnswers[chosen.id] == nil : chosen.ports.isEmpty { refreshPorts(chosen) }
        switch BRMachines.move(to: next, url: current, opened: holds) {
        case .already, .choose:
            return
        case .refused(let at):
            picked[tab.id] = at
            NativeBrowserTabs.shared.show("Not a machine’s page.")
        case .here(let url, let give):
            guard let held = give else { navigate(tab, url); return }
            Task {
                let raw = try? await EngineBridge.shared.invoke("browser:reach:release", [tab.id, held.machineId, held.port])
                if let stay = BRMachines.afterHandBack(raw, held: held) {
                    picked[tab.id] = stay.machineId
                    NativeBrowserTabs.shared.show(stay.notice)
                    return
                }
                navigate(tab, url)
            }
        case .there(let machineId, let port, let url):
            guard let target = choices.first(where: { $0.id == machineId }) else {
                picked[tab.id] = BRMachines.servedBy(current, opened: holds)?.machineId ?? BRMachines.thisMachine
                return
            }
            Task {
                let moved = await openThere(target, port: port, typed: url, in: tab)
                if !moved { picked[tab.id] = BRMachines.servedBy(current, opened: holds)?.machineId ?? BRMachines.thisMachine }
            }
        }
    }

    /// `openThere` over `reachPort`: hold a tunnel to the machine's port, then open it here.
    @discardableResult
    func openThere(_ machine: BRMachineChoice, port: Int, typed: String, in tab: NativeBrowserTab) async -> Bool {
        let raw = try? await EngineBridge.shared.invoke("browser:reach:hold",
                                                        [tab.id, ["id": machine.id, "name": machine.name, "kind": machine.kind], port])
        let held = BRMachines.readHeld(raw)
        guard let opened = held.opened else {
            NativeBrowserTabs.shared.show(held.message)
            return false
        }
        let note = BRMachines.differentPortNote(port: opened.port, localPort: opened.localPort, sameNumber: opened.sameNumber,
                                                machineName: machine.name)
        if let stranded = held.stranded { NativeBrowserTabs.shared.show(BRMachines.strandedNote(stranded)) }
        else if !note.isEmpty { NativeBrowserTabs.shared.show(note) }
        navigate(tab, BRMachines.reachedAddress(typed: typed, opened: held.url))
        return true
    }

    private func navigate(_ tab: NativeBrowserTab, _ address: String) {
        if let url = URL(string: address) { tab.load(url) }
    }

    /// The tab is gone: its tunnels go with it (`browser:window-closed`, reach ledger dropHolder).
    static func windowClosed(_ tabId: String) {
        EngineBridge.shared.send("browser:window-closed", [tabId])
        shared.picked[tabId] = nil
    }
}

// MARK: - The picker (between the Session button and the address)

struct NativeBrowserMachinePicker: View {
    let tab: NativeBrowserTab
    @State private var store = NativeBRMachines.shared

    var body: some View {
        let machines = store.choices
        Group {
            if !machines.isEmpty {
                let selected = store.picked(tab.id)
                let label = BRMachines.label(machines, selected: selected, here: store.here)
                Menu {
                    Text("Open localhost on")
                    Button { store.select(BRMachines.thisMachine, for: tab) } label: {
                        if selected == BRMachines.thisMachine { Label(store.here, systemImage: "checkmark") } else { Text(store.here) }
                    }
                    ForEach(machines) { machine in
                        let trailing = machine.unreachable
                            ?? (machine.ports.isEmpty ? "" : "\(machine.ports.count) \(machine.ports.count == 1 ? "port" : "ports")")
                        let text = trailing.isEmpty ? machine.name : "\(machine.name)   \(trailing)"
                        Button { store.select(machine.id, for: tab) } label: {
                            if machine.id == selected { Label(text, systemImage: "checkmark") } else { Text(text) }
                        }
                        .disabled(machine.unreachable != nil)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "display").font(.system(size: 11))
                        Text(label).font(.caption).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(selected == BRMachines.thisMachine ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Open localhost on \(label)")
                .accessibilityLabel("Addresses open on \(label). Choose a machine.")
            }
        }
        .task { store.start() }
    }
}

/// The word in the address field saying which machine serves the page.
struct NativeBrowserServedMark: View {
    let tab: NativeBrowserTab
    @State private var store = NativeBRMachines.shared

    var body: some View {
        let served = store.served(tab)
        if !served.mark.isEmpty {
            Text(served.mark)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.8), in: .rect(cornerRadius: 4))
                .help(served.title)
                .accessibilityLabel(served.title)
        }
    }
}

/// The start page's list when another machine is picked (StartPage.tsx `source`).
struct NativeBrowserMachinePorts: View {
    let tab: NativeBrowserTab
    let machine: BRMachineChoice
    @State private var store = NativeBRMachines.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let refused = machine.kind == "server" ? store.serverAnswers[machine.id]?.refused : nil {
                Text(refused).foregroundStyle(.secondary)
            } else if machine.kind == "server" && store.serverAnswers[machine.id] == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking \(machine.name) what it is serving…").foregroundStyle(.secondary)
                }
            } else if machine.ports.isEmpty {
                Text("Nothing is listening on \(machine.name). Start a dev server, then scan again — or type an address above.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Listening on \(machine.name) right now:").foregroundStyle(.secondary)
                VStack(spacing: 4) {
                    ForEach(machine.ports) { port in
                        NativeBrowserPortRow(port: BrowserDevPort(port: port.port, process: port.process, guessed: port.guessed)) {
                            Task { await store.openThere(machine, port: port.port, typed: "http://localhost:\(port.port)/", in: tab) }
                        }
                    }
                }
            }
            Button("Scan Again") { store.refreshPorts(machine) }
                .padding(.top, 2)
        }
    }
}
