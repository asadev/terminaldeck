import Foundation
import TerminalDeckNativeCore

public enum BackendUIGSessionSimulatorChannels {
    public static let channels: Set<String> = ["session-simulator:get", "session-simulator:attach", "session-simulator:detach", "session-simulator:validate", "session-simulator:send", "session-simulator:device", "session-simulator:release", "session-simulator:recording", "session-simulator:record"]
    /// Reuse the existing ONE message/files handoff. The sink must compare ticket.identity with the
    /// live manager identity synchronously at its final enqueue/write, then address that session id.
    public typealias Send = @Sendable (BackendUIGSessionSimulatorTicket, NativeRPCValue) async throws -> NativeRPCValue
    public static func register(registry: NativeChannelRegistry, ownerID: String,
        attachments: BackendUIGSessionSimulatorAttachments, service: any BackendDeckToolsMachinesDeviceService,
        viewer: BackendUIGSessionSimulatorViewer, recording: BackendUIGSessionSimulatorRecording? = nil,
        requireLocalUI: @escaping @Sendable (NativeRPCContext) throws -> Void,
        authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void,
        send: @escaping Send) async throws {
        // The shared page has no Record action. Its dock registers only those same actions.
        let registeredChannels = recording == nil ? channels.subtracting(["session-simulator:recording", "session-simulator:record"]) : channels
        for channel in registeredChannels.sorted() {
            try await registry.register(channel, ownerID: ownerID, policy: requireLocalUI) { context, arguments in
                try requireLocalUI(context)
                let args = context.argument(0, in: arguments)
                let sessionID = try args["sessionId"].requireString("sessionId", nonempty: true)
                try await attachments.refresh(service: service)
                // The session's first or second device; any other number is refused, never converted.
                guard let slot = args["slot"].isNullish ? 0 : NativeNumber.integer(args["slot"].number, in: BackendUIGSessionSimulatorAttachments.slots) else {
                    throw BackendUIGSessionSimulatorAttachments.refused("A session can show at most two devices.")
                }
                if channel == "session-simulator:get" { return try await attachments.snapshot(sessionID: sessionID, slot: slot).value }
                if channel == "session-simulator:attach" {
                    try authorizeMutation(context)
                    let deviceID = try BackendDeckToolsMachinesDeviceRules.id(args)
                    return try await attachments.attach(sessionID: sessionID, deviceID: deviceID, slot: slot, service: service).value
                }
                let token = try args["attachmentToken"].requireString("attachmentToken", nonempty: true)
                let deviceID = args["deviceId"].string
                let ticket = try await attachments.ticket(sessionID: sessionID, token: token, deviceID: deviceID, slot: slot)
                if channel == "session-simulator:validate" { return ticket.value }
                if channel == "session-simulator:release" { await viewer.close(ticket); return ticket.value }
                if channel == "session-simulator:device" {
                    let original = try context.argument(1, in: arguments).requireString("device channel", nonempty: true)
                    guard let values = context.argument(2, in: arguments).elements else { throw NativeRPCError.invalidArguments("Device arguments must be an array.") }
                    return try await viewer.invoke(ticket: ticket, channel: original, args: values, context: context)
                }
                if channel == "session-simulator:recording", let recording { return try await recording.status(ticket) }
                try authorizeMutation(context)
                if channel == "session-simulator:record", let recording {
                    let action = try context.argument(1, in: arguments).requireString("recording action")
                    if action == "start" { return try await recording.start(ticket) }
                    if action == "stop" { return try await recording.stop(ticket) }
                    throw NativeRPCError.invalidArguments("Recording action must be start or stop.")
                }
                if channel == "session-simulator:detach" { return try await attachments.detach(sessionID: sessionID, slot: slot, expected: ticket).value }
                guard ticket.deviceID != nil else { throw BackendUIGSessionSimulatorAttachments.refused("Attach a device before sending its screenshot or markers.") }
                try await attachments.validate(ticket)
                if let roundID = args["roundId"].string, !roundID.isEmpty { try await viewer.validateRound(roundID: roundID, ticket: ticket) }
                try requireLocalUI(context); try authorizeMutation(context)
                let reply = try await send(ticket, context.argument(1, in: arguments))
                if let roundID = args["roundId"].string, !roundID.isEmpty { try await viewer.markSent(roundID: roundID, ticket: ticket) }
                return reply
            }
        }
    }
}
