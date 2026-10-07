import Foundation
import TerminalDeckNativeCore

/// Reuses Machines' existing pairing, store and live link. No second relay,
/// key store, machine row or device identity is created for SSH Servers.
public struct BackendServersMachinePairReceipt: Sendable {
    public let machine: BackendMachineRecord
    public let guestFingerprint: String
    public init(machine: BackendMachineRecord, guestFingerprint: String) { self.machine = machine; self.guestFingerprint = guestFingerprint }
}
public struct BackendServersMachineLink: Sendable {
    public let machines: BackendMachineCoordinator
    public let registry: NativeChannelRegistry
    private let pairReceipt: @Sendable (String) async throws -> BackendServersMachinePairReceipt
    /// Machines must capture the public guest fingerprint during that exact
    /// pairing. Re-reading mutable secrets after pairing can race a re-pair.
    /// No default adapter guesses the guest from the host's row fingerprint.
    public init(machines: BackendMachineCoordinator, registry: NativeChannelRegistry,
                pairReceipt: @escaping @Sendable (String) async throws -> BackendServersMachinePairReceipt) {
        self.machines = machines; self.registry = registry; self.pairReceipt = pairReceipt
    }
    public func redeem(_ code: String) async -> BackendServersHostLinkOutcome {
        do {
            let receipt = try await pairReceipt(code), row = receipt.machine
            guard !receipt.guestFingerprint.isEmpty else { return .refused("The pairing returned no public fingerprint for this computer, so nothing can be approved.") }
            return .linked(machineId: row.id, machineName: row.name, deviceFingerprint: receipt.guestFingerprint)
        } catch { return .refused(error.localizedDescription) }
    }
    public func standing(_ hostID: String) async -> (name: String, online: Bool)? {
        guard let view = try? await machines.view(), let row = view["machines"].elements?.first(where: { $0["hostId"].string == hostID }), let id = row["id"].string else { return nil }
        return (row["name"].string ?? id, Self.isOnline(view, id: id))
    }
    public func redial(_ hostID: String) async {
        guard let row = try? await machines.store.list().first(where: { $0.hostID == hostID }) else { return }
        try? await machines.connect(row.id)
    }
    /// Called only AFTER host.ts's exact PTY fingerprint check and approval.
    /// A saved row does not count as reaching. There is no polling loop.
    public func whenReaching(_ id: String, ceilingMilliseconds: Int) async -> Bool {
        let signal = BackendServersMachineWait()
        let subscription: NativeRPCSubscription
        do {
            subscription = try await registry.subscribe("machines:state", ownerID: "servers-link-wait-" + UUID().uuidString) { event in
                if let view = event.arguments.first, Self.isOnline(view, id: id) { signal.resolve(true) }
            }
        } catch { return false }
        let timer = Task {
            do { try await Task.sleep(for: .milliseconds(max(0, ceilingMilliseconds))) } catch { return }
            signal.resolve(false)
        }
        let preparation = Task {
            do {
                try Task.checkCancellation(); try await machines.connect(id)
                try Task.checkCancellation()
                if let view = try? await machines.view(), Self.isOnline(view, id: id) { signal.resolve(true) }
            } catch { signal.resolve(false) }
        }
        let answer = await withTaskCancellationHandler { await signal.wait() } onCancel: { signal.resolve(false) }
        // An approved link belongs to Machines and may arrive after this wait
        // ends. A slow subscriber cannot extend the server host panel's wait.
        timer.cancel(); preparation.cancel(); await subscription.cancelAndWait(); return answer
    }
    static func isOnline(_ view: NativeRPCValue, id: String) -> Bool { view["links"].elements?.contains { $0["id"].string == id && $0["state"].string == "online" } == true }
}

private final class BackendServersMachineWait: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Bool?, continuation: CheckedContinuation<Bool, Never>?
    func resolve(_ value: Bool) {
        let waiting = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            guard answer == nil else { return nil }; answer = value
            let old = continuation; continuation = nil; return old
        }; waiting?.resume(returning: value)
    }
    func wait() async -> Bool {
        await withCheckedContinuation { waiting in
            let value = lock.withLock { () -> Bool? in
                if let answer { return answer }; continuation = waiting; return nil
            }; if let value { waiting.resume(returning: value) }
        }
    }
}
