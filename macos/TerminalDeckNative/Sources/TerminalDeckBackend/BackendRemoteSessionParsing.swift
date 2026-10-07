import Foundation
import TerminalDeckNativeCore

extension BackendRemoteProtocol {
    static func parseSession(_ r: BackendRemoteReader) throws -> NativeRPCValue? {
        let type = r.type
        var message = r.base
        switch type {
        case "hello", "enroll":
            let protocolVersion = try r.whole("protocol", 0, 65535, reason: "\(type) without a protocol version")
            message = message.setting("protocol", .number(protocolVersion))
            if type == "hello" {
                message = message.setting("token", .string(try r.text("token", reason: "hello without a usable token", units: 200, controls: true)))
            }
            let device = r["device"]
            guard device.fields != nil, let name = device["name"].string, let platform = device["platform"].string else { throw r.bad("\(type) without a device descriptor") }
            let cleanedName = displayLabel(name, maximumUnits: 60), cleanedPlatform = displayLabel(platform, maximumUnits: 40)
            message = message.setting("device", .object([.init("name", .string(cleanedName.isEmpty ? "Unnamed device" : cleanedName)),
                .init("platform", .string(cleanedPlatform.isEmpty ? "unknown" : cleanedPlatform))]))
            if type == "enroll" {
                let username = try r.text("username", reason: "enroll without a usable username", allowEmpty: true).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !username.isEmpty, username.utf16.count <= 64, !containsControls(username) else { throw r.bad("enroll without a usable username") }
                message = message.setting("username", .string(username))
                    .setting("secret", .string(try r.text("secret", reason: "enroll without a usable secret", bytes: 16384)))
                    .setting("method", .string(try r.named("method", allowed: ["password", "key"], reason: "enroll without a known method")))
            }
            if r["capabilities"] != .missing {
                guard let entries = r["capabilities"].elements else { throw r.bad("\(type) with an unusable capability list") }
                var result: [String] = []
                for entry in entries {
                    guard let value = entry.string, !value.isEmpty, value.utf16.count <= 32, !containsControls(value), !result.contains(value) else { continue }
                    result.append(value)
                    if result.count == 24 { break }
                }
                message = message.setting("capabilities", .array(result.map(NativeRPCValue.string)))
            }
            return message
        case "list", "ping": return message
        case "attach", "create":
            if type == "attach" { message = message.setting("id", .string(try r.id("id", reason: "attach without a session id"))) }
            if type == "create" {
                try r.optional("cwd", into: &message) { .string(try r.folder("cwd", unusable: "create with an unusable folder", oversized: "create with a folder over the path limit")) }
                if r["provider"] != .missing {
                    let provider = try r.text("provider", reason: "create with an unusable provider", units: 32, oversize: "create with a provider over the name limit")
                    guard provider.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil else { throw r.bad("create with an unusable provider") }
                    message = message.setting("provider", .string(provider))
                }
            }
            if r["cols"] != .missing || r["rows"] != .missing {
                message = message.setting("cols", .number(try r.whole("cols", 20, 500, reason: "\(type) with a size out of range")))
                    .setting("rows", .number(try r.whole("rows", 5, 200, reason: "\(type) with a size out of range")))
            }
            return message
        case "detach", "close": return message.setting("id", .string(try r.id("id", reason: "\(type) without a session id")))
        case "input", "session.send":
            if type == "session.send" { message = message.setting("rid", .string(try r.id("rid", reason: "session.send without a request id"))) }
            message = message.setting("id", .string(try r.id("id", reason: "\(type) without a session id")))
            return message.setting("data", .string(try r.text("data", reason: "\(type) without data", allowEmpty: true, bytes: 16384,
                oversize: "\(type) larger than the paste limit")))
        case "resize":
            return message.setting("id", .string(try r.id("id", reason: "resize without a session id")))
                .setting("cols", .number(try r.whole("cols", 20, 500, reason: "resize out of range")))
                .setting("rows", .number(try r.whole("rows", 5, 200, reason: "resize out of range")))
        case "rename":
            let id = try r.id("id", reason: "rename without a session id")
            let title = try r.text("title", reason: "rename without a title", allowEmpty: true)
            return message.setting("id", .string(id)).setting("title", .string(displayLabel(title, maximumUnits: 80)))
        case "dev.status", "dev.start":
            return message.setting("folder", .string(try r.folder("folder", unusable: "\(type) with an unusable folder", oversized: "\(type) with a folder over the path limit")))
        case "controls.read", "controls.apply", "usage.read", "account.read", "account.switch":
            message = message.setting("rid", .string(try r.id("rid", reason: "\(type) without a request id")))
                .setting("id", .string(try r.id("id", reason: "\(type) without a session id")))
            if type == "controls.apply" {
                let control = try r.named("control", allowed: ["model", "effort", "fast", "permission"], reason: "controls.apply naming no known control")
                let value = try r.text("value", reason: "controls.apply without a value", units: 64, oversize: "controls.apply with a value over the length limit")
                guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9 ._()-]*$"#, options: .regularExpression) != nil else { throw r.bad("controls.apply with an unusable value") }
                message = message.setting("control", .string(control)).setting("value", .string(value))
            } else if type == "usage.read" {
                message = message.setting("want", .string(try r.named("want", allowed: ["plan", "refresh", "context"], reason: "usage.read naming no known reading")))
                    .setting("force", .bool(r["force"].bool == true))
            } else if type == "account.switch" { message = message.setting("accountId", .string(try accountID(r))) }
            return message
        case "logins.read", "logins.signin", "logins.signout", "settings.read", "settings.apply",
             "github.read", "github.connect", "github.cancel", "github.disconnect", "host.status", "host.restart", "host.stop", "devices.list", "devices.revoke":
            message = message.setting("rid", .string(try r.id("rid", reason: "\(type) without a request id")))
            if type == "logins.signin" || type == "logins.signout" { message = message.setting("accountId", .string(try accountID(r))) }
            if type == "devices.revoke" { message = message.setting("device", .string(try r.id("device", reason: "devices.revoke without a device id", device: true))) }
            if type == "settings.apply" {
                let key = try r.named("key", allowed: ["agents.defaultProvider", "general.restoreSessions"], reason: "settings.apply naming a key this machine does not own")
                let value = try r.text("value", reason: "settings.apply without a value", units: 64, oversize: "settings.apply with a value over the length limit")
                guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil else { throw r.bad("settings.apply with an unusable value") }
                message = message.setting("key", .string(key)).setting("value", .string(value))
            }
            return message
        default: return nil
        }
    }
    private static func accountID(_ r: BackendRemoteReader) throws -> String {
        let value = try r.text("accountId", reason: "\(r.type) without an account", units: 200, oversize: "\(r.type) with an oversized account id")
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil else { throw r.bad("\(r.type) with an unusable account id") }
        return value
    }
}
