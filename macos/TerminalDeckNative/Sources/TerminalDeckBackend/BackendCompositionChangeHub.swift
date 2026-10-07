import Foundation
import TerminalDeckNativeCore

/// One owner's "this changed" hook fanned out to its retained observers
/// (TS: the `onChanged` callbacks github-auth.ts and friends expose). The
/// owner rings it; observers re-read the owner. No value is cached here.
public actor BackendCompositionChangeHub {
    private var observers: [UUID: @Sendable () async -> Void] = [:]
    public init() {}
    public func observe(_ callback: @escaping @Sendable () async -> Void) -> NativeRPCSubscription {
        let id = UUID(); observers[id] = callback
        return NativeRPCSubscription(id: id) { [weak self] in await self?.remove(id) }
    }
    public func fire() async { for observer in observers.values { await observer() } }
    private func remove(_ id: UUID) { observers[id] = nil }
}
