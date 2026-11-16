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
    /// Why the last Connect, Disconnect, Forget, windows tick, port scan or "Open there" did not happen.
    private(set) var actionError: String?

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

    /// Connect, disconnect, forget, the windows tick: the answer is the new view. A refusal or a
    /// timeout is said under the list (#56), so the button never looks dead.
    private func settle(_ channel: String, _ args: [Any?], failure: String) {
        actionError = nil
        Task {
            do { view = MachinesView(json: try await RemoteCall.invoke(channel, args)) }
            catch { actionError = RemoteCall.text(error, failure) }
        }
    }

    func connect(_ machine: PairedMachine) { settle("machines:connect", [machine.id], failure: "Could not connect to \(machine.name).") }
    func disconnect(_ machine: PairedMachine) { settle("machines:disconnect", [machine.id], failure: "Could not disconnect from \(machine.name).") }
    func forget(_ machine: PairedMachine) { settle("machines:forget", [machine.id], failure: "Could not forget \(machine.name).") }
    func setDrivesWindows(_ machine: PairedMachine, _ allowed: Bool) {
        settle("machines:drive-windows", [machine.id, allowed], failure: "Could not change whether \(machine.name) may act on browser windows.")
    }

    func refreshPorts(_ machine: PairedMachine) {
        actionError = nil
        Task {
            do { _ = try await RemoteCall.invoke("machines:ports", [machine.id]) }
            catch { actionError = RemoteCall.text(error, "Could not read the ports open on \(machine.name).") }
        }
    }

    func openPort(_ machine: PairedMachine, _ port: Int) {
        actionError = nil
        Task {
            do { _ = try await RemoteCall.invoke("machines:open", [machine.id, "http://localhost:\(port)/"]) }
            catch { actionError = RemoteCall.text(error, "Could not open port \(port) of \(machine.name).") }
        }
    }

    /// A session row's press: its tab, as the page's `selectTab(machineTabId(…))`.
    func open(_ machineId: String, _ sessionId: String) {
        AppModel.shared.runButton(.selectTab(MachinesRules.tabId(machineId: machineId, sessionId: sessionId)))
    }
}
