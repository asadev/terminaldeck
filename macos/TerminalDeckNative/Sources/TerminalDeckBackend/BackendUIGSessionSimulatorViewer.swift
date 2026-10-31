import Foundation
import TerminalDeckNativeCore

/// Routes the dock through the existing UI device facade, with an independent watch identity.
public actor BackendUIGSessionSimulatorViewer {
    public typealias Publish = @Sendable (String, [NativeRPCValue]) async throws -> Void
    private final class Lifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false
        var stopped: Bool { lock.withLock { ended } }
        func stop() { lock.withLock { ended = true } }
    }
    private struct View: Sendable { let ticket: BackendUIGSessionSimulatorTicket; let viewer: BackendAppDeviceViewer; let lifetime: Lifetime; let shutdown: @Sendable () -> Void }
    private let manager: BackendAppDeviceManager
    private let attachments: BackendUIGSessionSimulatorAttachments
    private let facade: BackendAppDeviceChannels
    private let publish: Publish
    private var views: [UUID: View] = [:]
    public static let events: Set<String> = ["session-simulator:frame", "session-simulator:closed"]
    public init(manager: BackendAppDeviceManager, attachments: BackendUIGSessionSimulatorAttachments,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void, publish: @escaping Publish) {
        self.manager = manager; self.attachments = attachments; self.publish = publish
        facade = BackendAppDeviceChannels(manager: manager, authorizeMutation: authorizeMutation)
    }
    private func view(_ ticket: BackendUIGSessionSimulatorTicket) async throws -> BackendAppDeviceViewer {
        views = views.filter { !$0.value.lifetime.stopped }
        if let view = views[ticket.revision] { return view.viewer }
        let id = "session-simulator:" + ticket.identity.sessionID + ":" + ticket.revision.uuidString
        let lifetime = Lifetime(), publish = self.publish
        // Keep the device engine's frame order using one ordered pump per viewer.
        let (stream, sink) = AsyncStream.makeStream(of: (String, [NativeRPCValue]).self)
        let pump = Task {
            for await (channel, args) in stream {
                guard !lifetime.stopped else { continue }
                let name = channel == "devices:frame" ? "session-simulator:frame" : "session-simulator:closed"
                try? await publish(name, [ticket.value] + args)
            }
        }
        let viewer = BackendAppDeviceViewer(id: id, send: { channel, args in
            guard !lifetime.stopped, args.first?.string == ticket.deviceID else { return }
            sink.yield((channel, args))
        }, isDestroyed: { lifetime.stopped })
        do {
            try await attachments.onInvalidated(ticket) { [manager] in
                lifetime.stop(); sink.finish(); pump.cancel()
                Task { await manager.forgetViewer(id) }
            }
        } catch { lifetime.stop(); sink.finish(); pump.cancel(); throw error }
        views[ticket.revision] = View(ticket: ticket, viewer: viewer, lifetime: lifetime, shutdown: { lifetime.stop(); sink.finish(); pump.cancel() })
        return viewer
    }
    /// [ticket, original devices:* channel, original arguments array]. Inventory belongs to the
    /// local UI picker; every selected-device operation is pinned to a validated ticket.
    public func invoke(ticket: BackendUIGSessionSimulatorTicket, channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard BackendAppDeviceChannels.channels.contains(channel), channel != "annotate:sent" else {
            throw BackendUIGSessionSimulatorAttachments.refused("That device operation is unavailable in a session panel.")
        }
        try await attachments.validate(ticket)
        if channel != "devices:list", ticket.deviceID == nil { throw BackendUIGSessionSimulatorAttachments.refused("Attach a device before using it in this session.") }
        if channel == "annotate:save" {
            guard args.indices.contains(1), args[1]["where"]["deviceId"].string == ticket.deviceID,
                  args[1]["where"]["kind"].string == "device" else { throw BackendUIGSessionSimulatorAttachments.stale() }
        } else if channel != "devices:list" {
            guard args.first?.string == ticket.deviceID else { throw BackendUIGSessionSimulatorAttachments.stale() }
        }
        let value = try await facade.invoke(channel, args: args, context: context, viewer: try await view(ticket))
        try await attachments.validate(ticket)
        if channel == "devices:boot", value["ok"].bool == true, let next = value["id"].string, next != ticket.deviceID {
            _ = try await attachments.booted(ticket, as: next)
        }
        return value
    }
    /// On panel hide/popout move, release ONLY this panel's interest. The standalone page remains.
    public func close(_ ticket: BackendUIGSessionSimulatorTicket) async {
        if let view = views.removeValue(forKey: ticket.revision) {
            view.shutdown(); await manager.forgetViewer(view.viewer.id)
        }
    }
    public func validateRound(roundID: String, ticket: BackendUIGSessionSimulatorTicket) async throws {
        try await attachments.validate(ticket)
        let rows = await manager.annotationRounds()
        guard rows.contains(where: { $0["id"].string == roundID && $0["where"]["kind"].string == "device" && $0["where"]["deviceId"].string == ticket.deviceID }) else {
            throw BackendUIGSessionSimulatorAttachments.refused("That annotation round was not captured on this session's device.")
        }
        try await attachments.validate(ticket)
    }
    public func markSent(roundID: String, ticket: BackendUIGSessionSimulatorTicket) async throws {
        try await validateRound(roundID: roundID, ticket: ticket)
        await manager.markSent(roundID, sessionID: ticket.identity.sessionID, label: ticket.identity.sessionID)
        try await attachments.noteSent(roundID: roundID, ticket: ticket)
    }
    public func stop() async { for view in views.values { view.shutdown(); await manager.forgetViewer(view.viewer.id) }; views.removeAll() }
}
