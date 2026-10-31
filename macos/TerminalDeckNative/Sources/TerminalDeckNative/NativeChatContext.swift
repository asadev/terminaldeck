import SwiftUI
import TerminalDeckNativeCore

extension NativeHootChatModel {
    var chatContextReading: ContextReading? { ContextReading.decode(chatContextReadingWire.foundation) }
    var chatContextState: NativeRPCValue {
        .object([.init("conversationId", .string(conversationID)), .init("provider", reportedChatProvider.map(NativeRPCValue.string) ?? .null),
            .init("reading", chatContextReadingWire), .init("state", .string(chatContextReading?.state.rawValue ?? "not-reported")),
            .init("scope", .string("This conversation's contextReading snapshot; account limits are separate"))])
    }
}
