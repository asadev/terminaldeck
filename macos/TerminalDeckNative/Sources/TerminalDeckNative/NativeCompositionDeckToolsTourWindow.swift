import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// tour-stage.ts `TourWindow` over the native drive host (deck-control/index.ts
/// L616-655). `send` routes the tour on `deck-control:tour` to the app's own
/// window, where `DriveHost` plays it and reports on `deck-control:tour-report`;
/// false when there is nobody to play it to. `watch` ends the tour when that
/// window goes away (closed, or the app quits); with no window it fires at once.
struct NativeCompositionDeckToolsTourWindow: BackendDeckToolsTourWindow {
    private let host: Host
    @MainActor init(registry: NativeChannelRegistry, authority: BackendCompositionAuthority,
                    window: @escaping @MainActor @Sendable () -> NSWindow?) {
        host = Host(registry: registry, authority: authority, window: window)
    }
    func send(_ tour: TourMessage) async -> Bool { await host.send(tour) }
    func watch(_ gone: @escaping @Sendable () -> Void) async -> UUID { await host.watch(gone) }
    func unwatch(_ id: UUID) async { await host.unwatch(id) }

    /// `{ record, stops }` as index.ts sends it: the record with every field it
    /// was written with, and the plan's stops in the shape `DriveTour.read` takes.
    static func envelope(_ message: TourMessage) throws -> NativeRPCValue {
        let record = try NativeRPCValue.fromFoundation(message.record.wire)
        let stops: [NativeRPCValue] = message.stops.map { stop in
            var fields: [NativeRPCValue.Field] = [.init("sessionId", .string(stop.sessionId)), .init("note", .string(stop.note)), .init("why", .string(stop.why))]
            switch stop.kind {
            case .message(let messageID, let quote):
                fields += [.init("kind", .string("message")), .init("messageId", .string(messageID)), .init("quote", .string(quote))]
            case .screen(let quote):
                fields += [.init("kind", .string("screen")), .init("quote", .string(quote))]
            case .anchor(let at, let path):
                fields += [.init("kind", .string("anchor")), .init("at", .string(at))]
                if let path { fields.append(.init("path", .string(path))) }
            }
            return .object(fields)
        }
        return .object([.init("record", record), .init("stops", .array(stops))])
    }

    @MainActor final class Host {
        private let registry: NativeChannelRegistry
        private let authority: BackendCompositionAuthority
        private let window: @MainActor @Sendable () -> NSWindow?
        private var watches: [UUID: [any NSObjectProtocol]] = [:]
        init(registry: NativeChannelRegistry, authority: BackendCompositionAuthority, window: @escaping @MainActor @Sendable () -> NSWindow?) {
            self.registry = registry; self.authority = authority; self.window = window
        }
        /// The approver: this app's own live window with the native drive host
        /// listening (index.ts: `approver === null || isDestroyed()` → none).
        private func approver() -> NSWindow? {
            guard NativeScreens.registered.contains(DriveHost.screenId), (try? authority.localContext()) != nil,
                  let window = window(), window.isVisible || window.isMiniaturized || NSApp.isHidden else { return nil }
            return window
        }
        func send(_ tour: TourMessage) async -> Bool {
            guard approver() != nil else { return false }
            do {
                let envelope = try NativeCompositionDeckToolsTourWindow.envelope(tour)
                try await registry.publish(DriveTour.channel, arguments: [envelope], ownerID: BackendCompositionRoot.appOwnerID)
                return true
            } catch {
                NSLog("[deck-control] could not hand the tour to the window: %@", error.localizedDescription)
                return false
            }
        }
        func watch(_ gone: @escaping @Sendable () -> Void) -> UUID {
            let id = UUID()
            guard let window = approver() else { gone(); return id }
            let ended: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.fire(id, gone)
                }
            }
            let center = NotificationCenter.default
            watches[id] = [center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: ended),
                           center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main, using: ended)]
            return id
        }
        /// Once per watch: a teardown that outlived its tour must not end the next one.
        private func fire(_ id: UUID, _ gone: @Sendable () -> Void) {
            guard watches[id] != nil else { return }
            unwatch(id)
            gone()
        }
        func unwatch(_ id: UUID) {
            for token in watches.removeValue(forKey: id) ?? [] { NotificationCenter.default.removeObserver(token) }
        }
    }
}
