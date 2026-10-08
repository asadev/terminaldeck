import Foundation
import TerminalDeckNativeCore

extension BackendRemoteProtocol {
    static func parseFilesAndPanels(_ r: BackendRemoteReader) throws -> NativeRPCValue? {
        let type = r.type
        var message = r.base
        switch type {
        case "folders.browse":
            try r.optional("path", into: &message) { .string(try r.folder("path", unusable: "folders.browse with an unusable folder", oversized: "folders.browse with a folder over the path limit")) }
            return message
        case "panel.act", "panel.read":
            message = message.setting("panel", .string(try r.named("panel", allowed: BackendRemoteProtocol.panels, reason: "\(type) for a panel this build does not serve")))
            if type == "panel.act" {
                message = message.setting("action", .string(try r.text("action", reason: "panel.act with an unusable action", bytes: 128, controls: true)))
            }
            try r.optional("path", into: &message) { .string(try r.folder("path", unusable: "\(type) with an unusable folder", oversized: "\(type) with a folder over the path limit")) }
            if type == "panel.act" {
                try r.optional("id", into: &message) { .string(try r.text("id", reason: "panel.act naming a row this build cannot address", bytes: 128, controls: true)) }
            }
            for key in ["scope", "query"] {
                try r.optional(key, into: &message) { .string(try r.text(key, reason: "\(type) with an unusable \(key)", allowEmpty: true, bytes: 128)) }
            }
            if type == "panel.act", r["fields"] != .missing {
                guard let fields = r["fields"].fields else { throw r.bad("panel.act with an unusable form") }
                guard fields.count <= 24 else { throw r.large("panel.act with too many fields") }
                var cleaned: [NativeRPCValue.Field] = []
                for field in fields {
                    guard field.key.utf8.count <= 128, !containsControls(field.key) else { throw r.bad("panel.act with an unusable field name") }
                    guard let value = field.value.string else { throw r.bad("panel.act with an unusable field") }
                    guard value.utf8.count <= 2048 else { throw r.large("panel.act with a field over the limit") }
                    guard !containsControls(value) else { throw r.bad("panel.act with an unusable field") }
                    if field.key != "__proto__" { cleaned.append(.init(field.key, .string(value))) }
                }
                message = message.setting("fields", .object(cleaned))
            }
            return message
        case "files.list", "git.status", "files.read", "git.diff":
            let name = type == "files.read" ? "file" : "folder"
            let oversized = type == "files.read" ? "files.read with a path over the limit" : type == "git.diff" ? "git.diff with a path over the limit" : "\(type) with a folder over the path limit"
            message = message.setting("path", .string(try r.folder("path", unusable: "\(type) with an unusable \(name)", oversized: oversized)))
            if type == "files.read" {
                try r.optional("at", into: &message) { .number(try r.whole("at", 0, 1073741824, reason: "files.read from an unusable offset")) }
                try r.optional("max", into: &message) { .number(try r.whole("max", 1, 262144, reason: "files.read with an unusable size")) }
            }
            if type == "git.diff" {
                message = message.setting("file", .string(try r.folder("file", unusable: "git.diff with an unusable file", oversized: "git.diff with a path over the limit")))
                try r.optional("staged", into: &message) { .bool(try r.boolean("staged", reason: "git.diff with an unusable staged flag")) }
            }
            return message
        case "routines": return message
        case "routine.text", "routine.run", "routine.resume", "routine.delete", "routine.pause":
            let id = try r.text("id", reason: "\(type) naming a routine this build cannot address")
            guard id.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil else { throw r.bad("\(type) naming a routine this build cannot address") }
            message = message.setting("id", .string(id))
            if type == "routine.pause", r["reason"] != .missing {
                let reason = displayLabel(try r.text("reason", reason: "routine.pause with an unusable reason", allowEmpty: true), maximumUnits: 300)
                if !reason.isEmpty { message = message.setting("reason", .string(reason)) }
            }
            return message
        default: return nil
        }
    }

    static func parseBrowser(_ r: BackendRemoteReader) throws -> NativeRPCValue? {
        let type = r.type
        var message = r.base
        switch type {
        case "browser.windows", "browser.profiles": return message
        case "browser.profile.use", "browser.profile.clear":
            let id = try r.text("id", reason: "\(type) with an unusable profile", units: 64)
            guard id.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { throw r.bad("\(type) with an unusable profile") }
            return message.setting("id", .string(id))
        case "browser.window.open":
            try r.optional("url", into: &message) { .string(try r.text("url", reason: "browser.window.open with an unusable address", bytes: 2048, controls: true, oversize: "browser.window.open over the address limit")) }
            try r.optional("profile", into: &message) { .string(try r.text("profile", reason: "browser.window.open naming a profile this build cannot address", allowEmpty: true, bytes: 128)) }
            try r.optional("isolated", into: &message) { .bool(try r.boolean("isolated", reason: "browser.window.open with an unusable isolation")) }
            try r.optional("session", into: &message) { .string(try r.text("session", reason: "browser.window.open naming a session this build cannot address", bytes: 128, controls: true)) }
            return message
        case "browser.window.go", "browser.window.act", "browser.window.size", "browser.window.bind", "browser.window.shot", "browser.window.steps", "browser.window.pick":
            let id = try r.text("id", reason: "\(type) naming a window this build cannot address", bytes: 128, controls: true)
            message = message.setting("id", .string(id))
            switch type {
            case "browser.window.go":
                message = message.setting("url", .string(try r.text("url", reason: "browser.window.go with an unusable address", bytes: 2048, controls: true, oversize: "browser.window.go over the address limit")))
            case "browser.window.act":
                message = message.setting("action", .string(try r.named("action", allowed: ["back", "forward", "reload", "close", "record.on", "record.off", "share", "isolate"], reason: "browser.window.act for something this build does not do")))
            case "browser.window.size":
                let width = try r.finite("width", reason: "browser.window.size without a width to lay the page out in")
                let height = try r.finite("height", reason: "browser.window.size without a height to lay the page out in")
                message = message.setting("width", .number(min(4096, max(240, floor(width + 0.5)))))
                    .setting("height", .number(min(4096, max(160, floor(height + 0.5)))))
            case "browser.window.bind", "browser.window.shot":
                try r.optional("session", into: &message) { .string(try r.text("session", reason: "\(type) naming a session this build cannot address", bytes: 128, controls: true)) }
                if type == "browser.window.shot" { try r.optional("note", into: &message) { .string(try r.text("note", reason: "browser.window.shot with an unusable note", allowEmpty: true, bytes: 2048)) } }
            case "browser.window.pick":
                message = message.setting("x", .number(try r.finite("x", reason: "browser.window.pick without a point on the page")))
                    .setting("y", .number(try r.finite("y", reason: "browser.window.pick without a point on the page")))
                try r.optional("up", into: &message) { .number(try r.whole("up", 0, 64, reason: "browser.window.pick asking for more of the page than this build walks")) }
            default: break
            }
            return message
        default: return nil
        }
    }
}
