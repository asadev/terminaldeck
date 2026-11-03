import Foundation
import TerminalDeckNativeCore

/// Phone agent chats (`chats`) and Hoot's Switch account (`hoot.account.*`): shapes only. Who may send them is the
/// access level's (`BackendINT2PhoneAccessLevel.permits`); which chat is visible is the host's session gate.
extension BackendRemoteProtocol {
    static func parseChats(_ r: BackendRemoteReader) throws -> NativeRPCValue? {
        var message = r.base
        switch r.type {
        case "chats.watch", "chats.unwatch", "chats.interrupt", "chats.options":
            return message.setting("id", .string(try r.id("id", reason: "\(r.type) without a chat id")))
        case "chats.older":
            return message.setting("id", .string(try r.id("id", reason: "chats.older without a chat id")))
                .setting("before", .number(try r.whole("before", 0, 1_000_000, reason: "chats.older without a place to read back from")))
        case "chats.set":
            message = message.setting("id", .string(try r.id("id", reason: "chats.set without a chat id")))
            try optionChoices(r, into: &message, type: r.type)
            guard message["permissionMode"] != .missing || message["model"] != .missing || message["effort"] != .missing else { throw r.bad("chats.set changing nothing") }
            return message
        case "chats.choices":
            message = message.setting("rid", .string(try r.id("rid", reason: "chats.choices without a request id")))
            try r.optional("cwd", into: &message) { .string(try r.folder("cwd", unusable: "chats.choices with an unusable folder", oversized: "chats.choices with a folder over the path limit")) }
            return message
        case "hoot.options.read":
            return message.setting("rid", .string(try r.id("rid", reason: "hoot.options.read without a request id")))
        case "hoot.options.set":
            message = message.setting("rid", .string(try r.id("rid", reason: "hoot.options.set without a request id")))
            try optionChoices(r, into: &message, type: r.type)
            guard message["permissionMode"] != .missing || message["model"] != .missing || message["effort"] != .missing else { throw r.bad("hoot.options.set changing nothing") }
            return message
        case "chats.say", "chats.steer":
            if r["clientMessageId"].string != nil { message = message.setting("clientMessageId", .string(try r.id("clientMessageId", reason: "Chat message without a message id"))) }
            for key in ["clientSequence", "sequence", "sentAt", "timestamp"] {
                if r[key].isNullish { continue }
                guard r[key].number != nil || (r[key].string?.utf8.count ?? 1025) <= 1024 else { throw r.bad("Invalid send timestamp or sequence") }
                message = message.setting(key, r[key])
            }
            try attachedFiles(r, into: &message)
            return message.setting("id", .string(try r.id("id", reason: r.type + " without a chat id")))
                .setting("text", .string(try messageText(r, allowEmpty: message["files"] != .missing)))
        case "chats.answer":
            return message.setting("id", .string(try r.id("id", reason: "chats.answer without a chat id")))
                .setting("request", .string(try r.id("request", reason: "chats.answer without a request id", watch: true)))
                .setting("approved", .bool(try r.boolean("approved", reason: "chats.answer without a decision")))
        case "chats.new":
            // An optional `rid` is kept so the host stamps it on any error answering this start (#58): the phone
            // then ends that start alone, not on some other request's error.
            if r["rid"] != .missing { message = message.setting("rid", .string(try r.id("rid", reason: "chats.new with an unusable request id"))) }
            message = message.setting("cwd", .string(try r.folder("cwd", unusable: "chats.new with an unusable folder", oversized: "chats.new with a folder over the path limit")))
            let provider = try r.named("provider", allowed: Array(BackendCreateSessionInput.chatProviders).sorted(), reason: "chats.new naming no chat agent")
            try startChoices(r, into: &message, type: r.type)
            return message.setting("provider", .string(provider))
        case "hoot.account.read":
            return message.setting("rid", .string(try r.id("rid", reason: "hoot.account.read without a request id")))
        case "hoot.account.switch":
            let account = try r.text("accountId", reason: "hoot.account.switch without an account", units: 200, oversize: "hoot.account.switch with an oversized account id")
            guard account.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil else { throw r.bad("hoot.account.switch with an unusable account id") }
            return message.setting("rid", .string(try r.id("rid", reason: "hoot.account.switch without a request id"))).setting("accountId", .string(account))
        default: return nil
        }
    }
    /// `files` on a chat or Hoot message (31 Oct, `chats.files`): up to four absolute paths, each one the phone's own
    /// upload answered with. Which of them the AI may have is the host's (`BackendUploadDestination.attachable`).
    static func attachedFiles(_ r: BackendRemoteReader, into message: inout NativeRPCValue) throws {
        guard r["files"] != .missing else { return }
        guard let rows = r["files"].elements, !rows.isEmpty, rows.count <= 4 else { throw r.bad("A message carries one to four files") }
        let paths = try rows.map { row -> NativeRPCValue in
            guard let path = row.string, path.hasPrefix("/"), path.utf8.count <= 4096, !BackendRemoteProtocol.containsControls(path) else {
                throw r.bad("A message file is not a usable path")
            }
            return .string(path)
        }
        message = message.setting("files", .array(paths))
    }

    /// The model, effort and permission words a chat's box (or Hoot's) may change: shapes only; the chat engine
    /// checks them against the chat's own AI.
    static func optionChoices(_ r: BackendRemoteReader, into message: inout NativeRPCValue, type: String) throws {
        if r["model"] != .missing {
            let model = try r.text("model", reason: "\(type) with an unusable model", units: 120, oversize: "\(type) with a model over the name limit")
            guard model.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,119}$"#, options: .regularExpression) != nil else { throw r.bad("\(type) with an unusable model") }
            message = message.setting("model", .string(model))
        }
        if r["effort"] != .missing {
            let effort = try r.text("effort", reason: "\(type) with an unusable effort", units: 16, oversize: "\(type) with an unusable effort")
            guard effort.range(of: #"^[a-z]{1,16}$"#, options: .regularExpression) != nil else { throw r.bad("\(type) with an unusable effort") }
            message = message.setting("effort", .string(effort))
        }
        if r["permissionMode"] != .missing {
            message = message.setting("permissionMode", .string(try r.named("permissionMode", allowed: BackendRemoteStartChoices.permissionModes,
                reason: "\(type) with an unknown permission mode")))
        }
    }

    /// A phone's New session choices (`create`, `chats.new`): the option words above, plus the agent it runs as
    /// and the account. Shapes only; the launch path checks each against this Mac.
    static func startChoices(_ r: BackendRemoteReader, into message: inout NativeRPCValue, type: String) throws {
        try optionChoices(r, into: &message, type: type)
        if r["agent"] != .missing { message = message.setting("agent", .string(try r.id("agent", reason: "\(type) with an unusable agent"))) }
        if r["account"] != .missing {
            let account = try r.text("account", reason: "\(type) with an unusable account", units: 200, oversize: "\(type) with an oversized account id")
            guard account.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil else { throw r.bad("\(type) with an unusable account") }
            message = message.setting("account", .string(account))
        }
    }
}
