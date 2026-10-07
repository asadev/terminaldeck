import Foundation
import TerminalDeckNativeCore

extension BackendRemoteProtocol {
    static func parseStreamsAndCopilot(_ r: BackendRemoteReader) throws -> NativeRPCValue? {
        var message = r.base
        switch r.type {
        case "ports", "copilot.attach", "copilot.detach", "copilot.state", "copilot.sessions", "copilot.pending", "copilot.start",
             "copilot.cancel", "copilot.stop", "copilot.bye", "copilot.hello", "copilot.files": return message
        case "tunnel.open":
            return message.setting("id", .string(try r.id("id", reason: "tunnel.open without an id")))
                .setting("port", .number(try r.whole("port", 1, 65535, reason: "tunnel.open without a port")))
        case "tunnel.close", "upload.cancel", "credential.ack":
            return message.setting("id", .string(try r.id("id", reason: "\(r.type) without an id")))
        case "web.open": return message.setting("url", .string(try r.text("url", reason: "web.open without a usable url", units: 2048)))
        case "net.open":
            return message.setting("ch", .string(try r.id("ch", reason: "net.open without a channel id")))
                .setting("tunnel", .string(try r.id("tunnel", reason: "net.open without a tunnel id")))
        case "net.data", "upload.data":
            let field = r.type == "net.data" ? "ch" : "id"
            let id = try r.id(field, reason: r.type == "net.data" ? "net.data without a channel id" : "upload.data without an id")
            let data = try r.text("data", reason: "\(r.type) without data", allowEmpty: true, units: 32768, oversize: "\(r.type) over the chunk limit")
            guard data.range(of: #"^[A-Za-z0-9+/]*={0,2}$"#, options: .regularExpression) != nil, data.utf16.count % 4 == 0 else { throw r.bad("\(r.type) is not base64") }
            return message.setting(field, .string(id)).setting("data", .string(data))
        case "net.ack":
            return message.setting("ch", .string(try r.id("ch", reason: "net.ack without a channel id")))
                .setting("bytes", .number(try r.whole("bytes", 1, 262144, reason: "net.ack out of range")))
        case "net.close": return message.setting("ch", .string(try r.id("ch", reason: "net.close without a channel id")))
        case "upload.begin":
            message = message.setting("id", .string(try r.id("id", reason: "upload.begin without an id")))
                .setting("name", .string(try r.text("name", reason: "upload.begin without a name", bytes: 255, controls: true, oversize: "upload.begin with a name over the limit", controlReason: "upload.begin with an unusable name")))
                .setting("size", .number(try r.whole("size", 1, 536870912, reason: "upload.begin with an unusable size")))
            if r["dir"] != .missing && r["dir"] != .string("") {
                message = message.setting("dir", .string(try r.text("dir", reason: "upload.begin with an unusable folder", bytes: 4096, controls: true, oversize: "upload.begin with a folder over the limit")))
            }
            return message
        case "upload.end":
            let id = try r.id("id", reason: "upload.end without an id")
            let digest = try r.text("sha256", reason: "upload.end without a digest")
            guard digest.utf16.count == 64, digest.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil else { throw r.bad("upload.end without a digest") }
            return message.setting("id", .string(id)).setting("sha256", .string(digest.lowercased()))
        case "credential.answer":
            message = message.setting("id", .string(try r.id("id", reason: "credential.answer without an id")))
                .setting("username", .string(try r.text("username", reason: "credential.answer without a usable username", units: 128, controls: true)))
                .setting("password", .string(try r.text("password", reason: "credential.answer without a usable secret", units: 4096, controls: true)))
            if r["remember"].bool == true { message = message.setting("remember", .bool(true)) }
            return message
        case "credential.deny":
            message = message.setting("id", .string(try r.id("id", reason: "credential.deny without an id")))
            if let reason = r["reason"].string, ["denied", "no-account"].contains(reason) { message = message.setting("reason", .string(reason)) }
            return message
        case "copilot.answer":
            return message.setting("id", .string(try r.id("id", reason: "copilot.answer without a question id")))
                .setting("approved", .bool(try r.boolean("approved", reason: "copilot.answer without a decision")))
        case "copilot.say":
            return message.setting("text", .string(try r.text("text", reason: "copilot.say without text", bytes: 16384, controls: true, oversize: "copilot.say larger than the message limit", controlReason: "copilot.say with an unusable message")))
        case "copilot.log":
            try r.optional("limit", into: &message) { .number(try r.whole("limit", 1, 200, reason: "copilot.log with a limit out of range")) }
            try r.optional("before", into: &message) { .string(try r.id("before", reason: "copilot.log with an unusable cursor")) }
            return message
        case "copilot.interactive": return message.setting("on", .bool(try r.boolean("on", reason: "copilot.interactive without a state")))
        case "copilot.file.read", "copilot.file.write", "copilot.file.reset":
            let id = try r.text("id", reason: "\(r.type) with an unknown file")
            guard copilotFileTarget(id) != nil else { throw r.bad("\(r.type) with an unknown file") }
            message = message.setting("id", .string(id))
            if r.type == "copilot.file.write" { message = message.setting("text", .string(try r.text("text", reason: "copilot.file.write without text", allowEmpty: true, bytes: 32768, oversize: "copilot.file.write larger than the file limit"))) }
            return message
        case "copilot.memory.delete":
            let name = try r.text("name", reason: "copilot.memory.delete without a memory file")
            guard isCopilotMemoryName(name) else { throw r.bad("copilot.memory.delete without a memory file") }
            return message.setting("name", .string(name))
        default: return nil
        }
    }

    public enum CopilotFileTarget: Equatable, Sendable { case layer(String), memory(String) }
    public static func copilotFileTarget(_ value: String) -> CopilotFileTarget? {
        if ["yours", "contract", "composed", "folder"].contains(value) { return .layer(value) }
        guard value.hasPrefix("memory:") else { return nil }
        let name = String(value.dropFirst(7))
        return isCopilotMemoryName(name) ? .memory(name) : nil
    }
    public static func isCopilotMemoryName(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= 255 && !value.contains("..") && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
        && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*\.md$"#, options: .regularExpression) != nil
    }
}
