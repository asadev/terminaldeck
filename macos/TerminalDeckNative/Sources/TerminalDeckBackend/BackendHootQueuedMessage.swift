import Foundation
import TerminalDeckNativeCore

/// The host keeps accepted messages, so closing a phone or Mac window cannot lose the queue.
struct BackendHootQueuedMessage: Sendable {
    let id: String
    let text: String
    let attachments: [NativeRPCValue]
    let context: NativeRPCValue
    let caller: BackendDeckCoreSecurityCaller
    var held = false
    var deliveryPending = false

    var wire: NativeRPCValue {
        .object([.init("id", .string(id)), .init("text", .string(text)), .init("attachments", .array(attachments)),
            .init("context", context), .init("caller", caller.wireValue), .init("held", .bool(held)),
            .init("deliveryPending", .bool(deliveryPending))])
    }
    var summary: NativeRPCValue {
        .object([.init("id", .string(id)), .init("text", .string(text)), .init("held", .bool(held)),
            .init("deliveryPending", .bool(deliveryPending))])
    }
    init(id: String, text: String, attachments: [NativeRPCValue], context: NativeRPCValue, caller: BackendDeckCoreSecurityCaller) {
        self.id = id; self.text = text; self.attachments = attachments; self.context = context; self.caller = caller
    }
    init(wire: NativeRPCValue) throws {
        id = try wire["id"].requireString("queued message id", nonempty: true)
        text = try wire["text"].requireString("queued message")
        attachments = try wire["attachments"].requireArray("queued attachments")
        context = wire["context"]
        guard let kind = BackendDeckCoreSecurityCaller.Kind(rawValue: wire["caller"]["kind"].string ?? "") else {
            throw NativeRPCError.malformed("The queued message has no sender.")
        }
        caller = .init(kind: kind, tiers: [], deviceID: wire["caller"]["deviceId"].string,
            keyID: wire["caller"]["keyId"].string, keyName: wire["caller"]["keyName"].string)
        deliveryPending = wire["deliveryPending"].bool == true
        // A write interrupted by a host crash is uncertain. Never send that message twice.
        held = wire["held"].bool == true || deliveryPending
    }
}
