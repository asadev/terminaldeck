import Foundation
import TerminalDeckNativeCore

/// The existing handoff's paste/Return sequence, with a fresh ticket check at EACH write.
/// The host's write closure must compare the incarnation atomically with writing to its PTY.
public enum BackendUIGSessionSimulatorHandoff {
    public typealias Write = @Sendable (BackendUIGSessionSimulatorIdentity, String) throws -> Void
    /// Concrete local PTY sink, with the incarnation check inside the production manager lock.
    public static func send(ticket: BackendUIGSessionSimulatorTicket, message: String,
        attachments: BackendUIGSessionSimulatorAttachments, manager: BackendPTYManager) async throws -> NativeRPCValue {
        try await send(ticket: ticket, message: message, attachments: attachments) { identity, data in
            guard let createdAt = Double(identity.incarnation), createdAt.isFinite else {
                throw NativeRPCError(code: "stale-session", message: "The session handoff has no valid process incarnation.")
            }
            try manager.write(identity.sessionID, data: data, expectedCreatedAt: createdAt)
        }
    }
    public static func send(ticket: BackendUIGSessionSimulatorTicket, message: String,
        attachments: BackendUIGSessionSimulatorAttachments,
        gap: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(Handoff.submitGapMilliseconds)) },
        write: @escaping Write) async throws -> NativeRPCValue {
        guard ticket.deviceID != nil, !message.isEmpty else { throw NativeRPCError.invalidArguments("A device handoff needs an attached device and a message.") }
        for (index, data) in Handoff.terminalWrites(message).enumerated() {
            if index > 0 { try await gap() }
            if Task.isCancelled { throw CancellationError() }
            try await attachments.validate(ticket)
            try write(ticket.identity, data)
        }
        return ticket.value.setting("ok", .bool(true))
    }
}
