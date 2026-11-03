import Foundation
import TerminalDeckNativeCore

extension BackendRemoteProtocol {
    static func parseWatchAndWindows(_ r: BackendRemoteReader) throws -> NativeRPCValue? {
        var message = r.base
        switch r.type {
        case "window.holds":
            guard let raw = r["sessions"].elements else { throw r.bad("window.holds without a session list") }
            let sessions = raw.prefix(128).compactMap { value -> String? in
                guard let id = value.string, id.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$"#, options: .regularExpression) != nil else { return nil }
                return id
            }
            message = message.setting("sessions", .array(sessions.map(NativeRPCValue.string)))
            var wanted = Set(sessions), held: [NativeRPCValue] = []
            for entry in r["held"].elements ?? [] {
                guard let session = entry["session"].string, wanted.remove(session) != nil else { continue }
                held.append(.object([.init("session", .string(session)), .init("windows", .array(heldWindows(entry["windows"]))) ]))
            }
            if !held.isEmpty { message = message.setting("held", .array(held)) }
            return message
        case "window.call":
            return message.setting("id", .string(try r.id("id", reason: "window.call without an id")))
                .setting("session", .string(try r.id("session", reason: "window.call without a session")))
                .setting("tool", .string(try r.text("tool", reason: "window.call without a usable tool name", units: 64)))
                .setting("args", .string(try r.text("args", reason: "window.call without arguments", allowEmpty: true, bytes: 16384, oversize: "window.call larger than the argument cap")))
        case "window.result":
            return message.setting("id", .string(try r.id("id", reason: "window.result without an id")))
                .setting("ok", .bool(try r.boolean("ok", reason: "window.result without an outcome")))
                .setting("body", .string(try r.text("body", reason: "window.result without a body", allowEmpty: true, bytes: 49152, oversize: "window.result larger than the answer cap")))
        case "sessions.mine":
            guard let raw = r["sessions"].elements else { throw r.bad("sessions.mine without a session list") }
            let rows = raw.compactMap(remoteSession).prefix(128)
            return message.setting("sessions", .array(Array(rows)))
        case "browser.watch", "browser.unwatch", "browser.frame.ack", "browser.input", "browser.handover.take", "browser.handover.done":
            let window = try r.id("window", reason: "\(r.type) without a usable window", watch: true)
            switch r.type {
            case "browser.watch":
                let width = try r.finite("maxWidth", reason: "browser.watch without a width")
                let quality = try r.finite("quality", reason: "browser.watch without a quality")
                message = message.setting("window", .string(window)).setting("maxWidth", .number(min(1600, max(160, floor(width + 0.5)))))
                    .setting("quality", .number(min(80, max(1, floor(quality + 0.5)))))
                try r.optional("everyNth", into: &message) { .number(max(1, floor(try r.finite("everyNth", reason: "browser.watch with an unusable everyNth")))) }
            case "browser.unwatch": message = message.setting("window", .string(window))
            case "browser.frame.ack", "browser.input":
                message = message.setting("window", .string(window)).setting("seq", .number(try r.whole("seq", 0, Double.greatestFiniteMagnitude, reason: "\(r.type) without a sequence number")))
                if r.type == "browser.input" {
                    let present = ["mouse", "key", "touch", "paste"].filter { r[$0] != .missing }
                    guard present.count == 1, let kind = present.first else { throw r.bad("browser.input needs exactly one of mouse, key, touch or paste") }
                    if kind == "paste" {
                        let raw = try r.text("paste", reason: "browser.input with an unusable paste", allowEmpty: true)
                        let paste = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
                            let c = $0.value
                            return !((0...8).contains(c) || c == 11 || c == 12 || (14...31).contains(c) || (127...159).contains(c))
                        }))
                        guard paste.utf8.count <= 16384 else { throw r.large("browser.input paste larger than the paste limit") }
                        message = message.setting("paste", .string(paste))
                    } else {
                        message = message.setting(kind, try browserInput(kind: kind, value: r[kind], reader: r))
                    }
                }
            case "browser.handover.take", "browser.handover.done":
                message = message.setting("rid", .string(try r.id("rid", reason: "\(r.type) without a request id"))).setting("window", .string(window))
                if r.type == "browser.handover.done" { message = message.setting("carryOn", .bool(try r.boolean("carryOn", reason: "browser.handover.done without carryOn"))) }
            default: break
            }
            return message
        case "browser.surfaces": return message.setting("rid", .string(try r.id("rid", reason: "browser.surfaces without a request id")))
        default: return nil
        }
    }

    private static func browserInput(kind: String, value: NativeRPCValue, reader outer: BackendRemoteReader) throws -> NativeRPCValue {
        let reason = "browser.input with an unusable \(kind) event"
        guard value.fields != nil else { throw outer.bad(reason) }
        let r = BackendRemoteReader(value, type: kind)
        var result = NativeRPCValue.object([])
        switch kind {
        case "mouse":
            result = result.setting("type", .string(try r.named("type", allowed: ["down", "up", "move", "wheel"], reason: reason)))
                .setting("x", .number(try r.finite("x", reason: reason))).setting("y", .number(try r.finite("y", reason: reason)))
            try r.optional("button", into: &result) { .string(try r.named("button", allowed: ["left", "right", "middle", "none"], reason: reason)) }
            try r.optional("clicks", into: &result) { .number(try r.whole("clicks", 0, Double.greatestFiniteMagnitude, reason: reason)) }
            for key in ["dx", "dy"] { try r.optional(key, into: &result) { .number(try r.finite(key, reason: reason)) } }
        case "key":
            result = result.setting("type", .string(try r.named("type", allowed: ["down", "up", "char"], reason: reason)))
            for key in ["key", "code", "text"] {
                try r.optional(key, into: &result) { .string(try r.text(key, reason: reason, allowEmpty: true, units: 64, controls: key != "text")) }
            }
            try r.optional("mods", into: &result) { .number(try r.whole("mods", 0, Double.greatestFiniteMagnitude, reason: reason)) }
        case "touch":
            let type = try r.named("type", allowed: ["start", "move", "end", "cancel"], reason: reason)
            guard let raw = r["points"].elements, raw.count <= 10 else { throw r.bad(reason) }
            let points = try raw.map { point -> NativeRPCValue in
                guard point.fields != nil else { throw r.bad(reason) }
                let p = BackendRemoteReader(point, type: "point")
                return .object([.init("x", .number(try p.finite("x", reason: reason))), .init("y", .number(try p.finite("y", reason: reason)))])
            }
            result = result.setting("type", .string(type)).setting("points", .array(points))
        default: throw r.bad(reason)
        }
        return result
    }

    public static func remoteSession(_ raw: NativeRPCValue) -> NativeRPCValue? {
        guard raw.fields != nil, let id = raw["id"].string, !id.isEmpty, let title = raw["title"].string,
              let cwd = raw["cwd"].string, let provider = raw["provider"].string, let status = raw["status"].string else { return nil }
        let exitCode = raw["exitCode"].number.flatMap { $0.rounded() == $0 ? $0 : nil }
        return .object([.init("id", .string(id)), .init("title", .string(title)), .init("cwd", .string(cwd)),
            .init("provider", .string(provider)), .init("status", .string(status)), .init("exitCode", exitCode.map(NativeRPCValue.number) ?? .null)])
    }
    private static func heldWindows(_ raw: NativeRPCValue) -> [NativeRPCValue] {
        var result: [NativeRPCValue] = []
        for entry in raw.elements ?? [] {
            guard entry.fields != nil, let n = entry["n"].number, n.rounded() == n, n >= 1, n <= 9999 else { continue }
            let fields = ["title", "url", "host"].map { key -> NativeRPCValue.Field in
                let raw = entry[key].string ?? ""
                var flat = "", inControlRun = false
                for scalar in raw.unicodeScalars {
                    let c = scalar.value
                    if c < 32 || (127...159).contains(c) || c == 0x2028 || c == 0x2029 {
                        if !inControlRun { flat.append(" ") }
                        inControlRun = true
                    } else { flat.unicodeScalars.append(scalar); inControlRun = false }
                }
                return .init(key, .string(displayLabel(flat, maximumUnits: 512, wide: false)))
            }
            result.append(.object([.init("n", .number(n))] + fields))
            if result.count == 16 { break }
        }
        return result
    }
}
