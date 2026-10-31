import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The core's tour channels and the tour tool share ONE stage, made before the
/// core starts; the window behind it is bound once the window authority exists.
/// Until then there is no approver window, which the stage reports as "no window".
final class NativeCompositionLateTourWindow: BackendDeckToolsTourWindow, @unchecked Sendable {
    private let lock = NSLock()
    private var inner: (any BackendDeckToolsTourWindow)?
    func bind(_ window: any BackendDeckToolsTourWindow) { lock.withLock { inner = window } }
    private var current: (any BackendDeckToolsTourWindow)? { lock.withLock { inner } }
    func send(_ tour: TourMessage) async -> Bool { await current?.send(tour) ?? false }
    func watch(_ gone: @escaping @Sendable () -> Void) async -> UUID {
        guard let current else { gone(); return UUID() }
        return await current.watch(gone)
    }
    func unwatch(_ id: UUID) async { await current?.unwatch(id) }
}
