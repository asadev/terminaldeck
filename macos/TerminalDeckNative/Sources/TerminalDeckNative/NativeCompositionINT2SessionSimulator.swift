import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The session dock shares the installed device engine and tool service. Its
/// attachment and viewer ownership never replaces the standalone viewer.
@MainActor
final class NativeCompositionINT2SessionSimulator {
    static let ownerID = "native.session-simulator"
    /// Record is on (PFRAME, 8 Oct): the phone panel's Record button uses the owned recorder.
    static let channels = BackendUIGSessionSimulatorChannels.channels.union(["session-simulator:send-hoot"])
    static let events = BackendUIGSessionSimulatorViewer.events.union([
        BackendUIGSessionSimulatorAttachments.changedEvent
    ])

    let attachments: BackendUIGSessionSimulatorAttachments
    let viewer: BackendUIGSessionSimulatorViewer
    var recording: BackendUIGSessionSimulatorRecording?
    private let registry: NativeChannelRegistry
    private let lifecycle: BackendSessionLifecycleCoordinator
    private let lifetime: Lifetime
    private let sink: AsyncStream<Push>.Continuation
    private let pump: Task<Void, Never>
    private var observer: UUID?
    private var stopped = false

    private struct Push: Sendable {
        let channel: String
        let arguments: [NativeRPCValue]
    }
    private final class Lifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false
        var isOpen: Bool { lock.withLock { !ended } }
        func stop() { lock.withLock { ended = true } }
    }

    private init(registry: NativeChannelRegistry, authority: BackendCompositionAuthority,
                 sessions: BackendCompositionSessions, devices: BackendCompositionDevices.Installed) {
        self.registry = registry
        lifecycle = sessions.lifecycle
        let lifetime = Lifetime()
        self.lifetime = lifetime
        let (stream, sink) = AsyncStream.makeStream(of: Push.self)
        self.sink = sink
        let publish: @Sendable (String, [NativeRPCValue]) -> Void = { channel, arguments in
            guard lifetime.isOpen else { return }
            sink.yield(Push(channel: channel, arguments: arguments))
        }
        let manager = authority.prepared.manager
        let attachments = BackendUIGSessionSimulatorAttachments(resolveLocalSession: { id in
            // Hoot's own phone panel (the same session panel, owned by Hoot): one fixed place.
            if id == "hoot" { return BackendUIGSessionSimulatorIdentity(sessionID: id, incarnation: "hoot") }
            guard let target = SessionTarget(tabId: id), case .local(let localID) = target, localID == id,
                  let meta = manager.list().first(where: { $0.id == id }), meta.exitCode == nil,
                  meta.createdAt.isFinite, NativeDevicePanelSurface.permitsOwner(chat: meta.chat == true, hasPTY: manager.pidOf(id) != nil, ended: meta.exitCode != nil) else {
                throw NativeRPCError(code: "not-permitted", message: "A running local session is required for its simulator panel.")
            }
            return BackendUIGSessionSimulatorIdentity(sessionID: meta.id, incarnation: String(meta.createdAt))
        }, attachmentChanged: { value in
            publish(BackendUIGSessionSimulatorAttachments.changedEvent, [value])
        })
        self.attachments = attachments
        viewer = BackendUIGSessionSimulatorViewer(manager: devices.manager, attachments: attachments,
            authorizeMutation: { try authority.authorizeMutation($0) },
            publish: { channel, arguments in publish(channel, arguments) })
        // Attachment changes and viewer frames use this same ordered publisher.
        // Only the actual current app owner receives these device pictures.
        pump = Task {
            for await push in stream {
                guard !Task.isCancelled, lifetime.isOpen,
                      (try? authority.localContext()) != nil else { continue }
                try? await registry.publish(push.channel, arguments: push.arguments,
                    ownerID: BackendCompositionRoot.appOwnerID)
            }
        }
    }

    static func install(root: BackendCompositionRoot, authority: BackendCompositionAuthority,
                        sessions: BackendCompositionSessions, devices: BackendCompositionDevices.Installed,
                        sendToHoot: @escaping @Sendable (String, [NativeRPCValue], NativeRPCValue, @escaping @Sendable () async throws -> Void) async throws -> NativeRPCValue) async throws -> NativeCompositionINT2SessionSimulator {
        try await root.requireAssemblyOpen()
        guard sessions.manager === authority.prepared.manager else {
            throw NativeRPCError(code: "composition-incomplete", message: "The simulator panel needs the one prepared local session manager.")
        }
        for channel in channels.sorted() where await root.registry.has(channel) {
            throw NativeRPCError(code: "duplicate-handler", message: "A different owner already handles '\(channel)'.")
        }
        let installed = NativeCompositionINT2SessionSimulator(registry: root.registry, authority: authority,
            sessions: sessions, devices: devices)
        let attachments = installed.attachments
        let manager = authority.prepared.manager
        // Recordings go where the screenshots go: ~/Pictures/Terminal Deck.
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Terminal Deck", isDirectory: true)
        let recording = BackendUIGSessionSimulatorRecording(attachments: attachments, service: devices.tools,
                                                            picturesDirectory: pictures)
        installed.recording = recording
        do {
            try await BackendUIGSessionSimulatorChannels.register(registry: root.registry, ownerID: ownerID,
                attachments: attachments, service: devices.tools, viewer: installed.viewer, recording: recording,
                requireLocalUI: { try authority.requireLocalUI($0) },
                authorizeMutation: { try authority.authorizeMutation($0) }, send: { ticket, payload in
                    _ = try payload.requireObject("session handoff")
                    guard payload["submit"].bool == true else {
                        throw NativeRPCError.invalidArguments("A simulator handoff must submit its message.")
                    }
                    let message = try payload["text"].requireString("handoff message", nonempty: true)
                    return try await BackendUIGSessionSimulatorHandoff.send(ticket: ticket, message: message,
                        attachments: attachments, manager: manager)
                })
            installed.observer = await sessions.lifecycle.observe { event in
                switch event {
                case .exit(let id, _), .removed(let id, _): await attachments.invalidate(sessionID: id)
                case .data, .status: break
                }
            }
            try await root.registry.register("session-simulator:send-hoot", ownerID: ownerID,
                policy: { try authority.requireLocalUI($0) }) { context, arguments in
                try authority.requireLocalUI(context)
                try authority.authorizeMutation(context)
                guard arguments.count == 4 else { throw NativeRPCError.invalidArguments("Expected the current phone ticket, message, pictures and source.") }
                let value = try arguments[0].requireObject("phone ticket")
                let sessionID = try value["sessionId"].requireString("sessionId", nonempty: true)
                let token = try value["attachmentToken"].requireString("attachmentToken", nonempty: true)
                guard let rawSlot = value["slot"].number, rawSlot.isFinite, rawSlot.rounded() == rawSlot,
                      rawSlot == 0 || rawSlot == 1 else { throw NativeRPCError.invalidArguments("Name the phone's slot.") }
                let ticket = try await attachments.ticket(sessionID: sessionID, token: token,
                    deviceID: value["deviceId"].string, slot: Int(rawSlot))
                let message = try arguments[1].requireString("message")
                let blocks = try arguments[2].requireArray("pictures")
                let source = try arguments[3].requireObject("source")
                let context = try BackendHOOTSIMChatContext(wire: .object([.init("source", source)]))
                return try await sendToHoot(message, blocks, context.value, {
                    try await attachments.validate(ticket)
                })
            }
            try await root.retain(.init(name: "session-simulator", domains: ["session-simulator"], ownerID: ownerID,
                invokes: channels, events: events, stop: { await installed.stop() }))
            return installed
        } catch {
            await installed.stop()
            throw error
        }
    }

    /// Root forwards these authoritative events from its existing session emit
    /// callback. The process observer above already owns exit/remove invalidation.
    func noteLifecycle(_ event: BackendSessionLifecycleEvent) async {
        guard !stopped else { return }
        switch event {
        case .accountChanged(let session, _): await attachments.invalidate(sessionID: session.id)
        case .replaced(let oldID, _, _): await attachments.invalidate(sessionID: oldID)
        default: break
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        lifetime.stop()
        if let observer { await lifecycle.removeObserver(observer); self.observer = nil }
        await recording?.stopAll()
        await viewer.stop()
        await attachments.reset()
        sink.finish(); pump.cancel()
        await pump.value
        await registry.removeOwner(Self.ownerID)
    }
}
