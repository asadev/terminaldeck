import Foundation
import TerminalDeckNativeCore

/// The sole accepted lifecycle-to-UI fanout. A single consumer preserves the
/// coordinator's order; it does not parse PTYs or invent status from prose.
public final class BackendCompositionEvents: @unchecked Sendable {
    private let registry: NativeChannelRegistry
    private let continuation: AsyncStream<BackendSessionLifecycleEvent>.Continuation
    private let lock = NSLock()
    private var consumer: Task<Void, Never>?
    private var core: BackendDeckCoreRuntime?
    private var usage: BackendCompositionUsage?
    private var targetAccounts: [String: String] = [:]
    public init(registry: NativeChannelRegistry) {
        self.registry = registry
        let pair = AsyncStream<BackendSessionLifecycleEvent>.makeStream(); continuation = pair.continuation
        consumer = Task { [weak self] in
            for await event in pair.stream { guard let self else { return }; await self.receive(event) }
        }
    }
    public func submit(_ event: BackendSessionLifecycleEvent) { continuation.yield(event) }
    public func bind(core: BackendDeckCoreRuntime) { lock.withLock { self.core = core } }
    public func bind(usage: BackendCompositionUsage) { lock.withLock { self.usage = usage } }
    private func receive(_ event: BackendSessionLifecycleEvent) async {
        let owners = lock.withLock { (core, usage) }
        await owners.1?.noteLifecycleEvent(event)
        do {
            switch event {
            case .created(let meta):
                try await registry.publish("session:created", arguments: [BackendCompositionSuppliers.sessionWire(meta)])
            case .replaced(let oldID, let meta, let note):
                targetAccounts[oldID] = nil
                try await registry.publish("session:switched", arguments: [.string(oldID), BackendCompositionSuppliers.sessionWire(meta), .string(note)])
            case .held(let rows):
                try await registry.publish("sessions:held", arguments: [.array(rows.map(\.wireValue))])
            case .status(let id, let status, _):
                try await registry.publish("session:status", arguments: [.string(id), .string(status.rawValue)])
                await owners.0?.noteStatus(sessionID: id, status: status.rawValue)
            case .switchPending(let id, let targetID, _): targetAccounts[id] = targetID
            case .switchFailed(let id, let message):
                try await registry.publish("session:switch-failed", arguments: [.string(id), targetAccounts[id].map(NativeRPCValue.string) ?? .null, .string(message)])
                targetAccounts[id] = nil
            case .process(let process):
                switch process {
                case .data(let id, let bytes):
                    // Raw terminal bytes go only to the person's app stream.
                    try await registry.publish("session:data", arguments: [.string(id), .string(bytes)], ownerID: BackendCompositionRoot.appOwnerID)
                case .exit(let id, let code):
                    try await registry.publish("session:exit", arguments: [.string(id), .number(Double(code))])
                    await owners.0?.noteExit(sessionID: id, exitCode: code)
                case .removed(let id, _):
                    targetAccounts[id] = nil
                    try await registry.publish("session:removed", arguments: [.string(id)])
                case .status: break // Accepted lifecycle status above is authoritative.
                }
            case .accountChanged, .restored: break // Their real consumers/read receipts own these updates.
            }
        } catch { NSLog("[native lifecycle] %@", error.localizedDescription) }
    }
    public func renamed(_ id: String, title: String) async {
        do { try await registry.publish("session:renamed", arguments: [.string(id), .string(title)]) }
        catch { NSLog("[native lifecycle] %@", error.localizedDescription) }
    }
    public func stop() async {
        continuation.finish(); await consumer?.value; consumer = nil
        lock.withLock { core = nil; usage = nil }
    }
}
