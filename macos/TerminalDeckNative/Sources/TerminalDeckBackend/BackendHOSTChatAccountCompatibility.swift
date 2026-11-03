import Foundation
import TerminalDeckNativeCore

/// Negotiate before allocating a login or starting a child. Old hosts can bind
/// an authenticated app child, but only from an app-composed reservation.
enum BackendHOSTChatAccountCompatibility {
    typealias Resource = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue

    static func resolve(chat: Bool, arguments: NativeRPCValue, resource: Resource) async throws -> NativeRPCValue {
        guard chat else { return try await resource("account.resolve", arguments) }
        do { return try await resource("account.chat.resolve", arguments) }
        catch is CancellationError { throw CancellationError() }
        catch where refused(error) {
            try Task.checkCancellation()
            // This changes only the private host reservation's ownership flag.
            // The caller, login, fence, tools and remembered tab stay the same.
            let scope = arguments["scope"].setting("isAppComposed", .bool(true))
            return try await resource("account.resolve", arguments.setting("scope", scope))
        }
    }

    private static func refused(_ error: Error) -> Bool {
        guard case BackendHOSTFailure.remote(let detail) = error else { return false }
        let prefix = "The persistent host service could not complete account.chat.resolve: "
        guard detail.hasPrefix(prefix) else { return false }
        let reason = String(detail.dropFirst(prefix.count))
        return reason == "Unknown persistent account operation."
            || reason == "The private session host could not be authenticated."
    }
}
