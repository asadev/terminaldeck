import Foundation
import TerminalDeckNativeCore

/// History uses its own gate because Hoot is not a project session. Neither the phone's
/// capability claim nor a message ID grants access to a conversation.
public enum BackendPhoneChatHistory {
    public static let capability = "chats.history"
    public static let messages: Set<String> = ["chats.rewind", "chats.fork"]

    public static func feature(endpoint: BackendRemoteHost, trust: BackendRemoteTrustStore,
                               allHistorySupported: Bool = false,
                               action: @escaping @Sendable (String, String, String, BackendRemoteHostContext) async throws -> [BackendRemoteServerMessage]) -> BackendRemoteHostFeature {
        .init(capability: "chats", messageTypes: messages, policy: .grantedDevice,
              additionalAdvertisedCapabilities: allHistorySupported ? [capability] : []) { message, source in
            let context = try await endpoint.refreshedContext(source)
            try await trust.requirePhoneAccess(context.deviceID, message: message.type)
            guard context.phoneAccess == .full else {
                throw NativeRPCError(code: "access-denied", message: "Rewind and Fork need Full control on this phone.")
            }
            let id = try message["id"].requireString("chat", nonempty: true)
            if id == "hoot" {
                guard context.kind == .mine, await BackendCopilotRemoteAccess(trust: trust).linked(context.deviceID) else {
                    throw NativeRPCError(code: "access-denied", message: "Hoot is not shared with this device.")
                }
            } else {
                guard try await endpoint.panelSessionIDs(context).contains(id) else {
                    throw NativeRPCError(code: "unknown-session", message: "That chat is not shared with this phone.")
                }
            }
            return try await action(id, message.type, message["messageId"].requireString("message", nonempty: true), context)
        }
    }

    /// Phones use the stream message ID, not the Mac's combined row ID. Read all pages
    /// so choosing an older visible message never accidentally operates on a newer one.
    public static func sequence(messageID: String, read: @Sendable (Int?) async throws -> NativeRPCValue) async throws -> Int {
        var cursor: Int? = 0
        var found: Int?
        for _ in 0..<2000 {
            let page = try await read(cursor)
            for row in page["events"].elements ?? [] {
                let event = try HootChatEvent(wire: row)
                guard [.user, .message].contains(event.record.kind),
                      (event.record.messageID.isEmpty ? event.id : event.record.messageID) == messageID else { continue }
                if let found, found != event.sequence {
                    throw NativeRPCError(code: "unavailable", message: "That message does not have one clear history boundary. Nothing changed.")
                }
                found = event.sequence
            }
            if page["hasMore"].bool != true {
                guard let found else { throw NativeRPCError(code: "stale", message: "That message is no longer in this chat. Refresh it and try again.") }
                return found
            }
            guard let next = page["cursor"].number, next.isFinite, next > Double(cursor ?? 0), next < Double(Int.max / 2) else {
                throw NativeRPCError(code: "unavailable", message: "The chat history could not be read completely. Nothing changed.")
            }
            cursor = Int(next)
        }
        throw NativeRPCError(code: "unavailable", message: "This chat is too large to check safely. Nothing changed.")
    }
}
