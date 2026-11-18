import Foundation
import TerminalDeckNativeCore

extension BackendMachineChannels {
    /// The phone's options route answers by chat id (older Macs do not echo a rid on success).
    /// Only one read/change for a given chat may wait at once. Its rid also names any host refusal.
    static func chatOptions(_ guest: BackendRemoteGuest, chat: String, patch: NativeRPCValue?) async throws -> NativeRPCValue {
        let op = patch == nil ? "options" : "set"
        guard let (type, fields) = chatFrame(op, chat: chat, patch ?? .missing, .missing) else {
            throw NativeRPCError.invalidArguments("Choose a model, effort or permission mode for this chat.")
        }
        let answer = try await guest.chatOptionsRequest(type: type,
            fields: fields.filter { $0.key != "id" } + [.init("rid", .string(chat))], chat: chat)
        return answer["options"]
    }

    /// The existing machines tools keep their control verbs for chats. Values come from the host's chat options,
    /// never from its terminal screen or the receiving Mac's account defaults.
    static func chatControls(_ options: NativeRPCValue) -> NativeRPCValue {
        func reading(_ key: String) -> NativeRPCValue {
            let value = options[key]
            let label = key == "model" ? options["models"].elements?.first { $0["id"] == value }?["name"] ?? value : value
            return .object([.init("value", value.isNullish ? .null : value), .init("label", label.isNullish ? .null : label), .init("source", .string("settings"))])
        }
        return .object([.init("model", reading("model")), .init("effort", reading("effort")), .init("permission", reading("permissionMode")),
            .init("fast", .object([.init("value", .null), .init("label", .null), .init("unavailableReason", .string("This chat does not offer fast mode."))])),
            .init("live", .bool(true)), .init("agent", .object([.init("running", .bool(true))])),
            .init("gate", .object([.init("canType", .bool(true)), .init("reason", .null)]))])
    }
}
