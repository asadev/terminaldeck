import Foundation
import TerminalDeckNativeCore

/// SRV2 AI tools: same channels as the app page. Reads run freely; changes
/// go through the existing approval path (tier alter). INT2 appends
/// `BackendAppsSRV2MCP.definitions()` (BackendAppsSRV2Wiring) to
/// BackendAppsMCP.definitions() and routes validate/summary here first.
public enum BackendAppsSRV2MCP {
    /// One tool, described without the catalogue's type (so it compiles on its own).
    public struct Spec: Sendable {
        public let id: String
        public let channel: String
        public let write: Bool
        public let description: String
        public let properties: NativeRPCValue
        public let required: [String]
        public var wireName: String { id.replacingOccurrences(of: ".", with: "_") }
        public var inputSchema: NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", properties),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
    }
    public static func handles(_ tool: String) -> Bool { spec(tool) != nil }
    static func spec(_ tool: String) -> Spec? { specs().first { $0.id == tool || $0.wireName == tool } }

    public static func specs() -> [Spec] {
        let string = NativeRPCValue.object([.init("type", .string("string")), .init("minLength", .number(1))])
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        let boolean = NativeRPCValue.object([.init("type", .string("boolean"))])
        func integer(_ minimum: Int, _ maximum: Int) -> NativeRPCValue {
            .object([.init("type", .string("integer")), .init("minimum", .number(Double(minimum))), .init("maximum", .number(Double(maximum)))])
        }
        func choice(_ values: [String]) -> NativeRPCValue { string.setting("enum", .array(values.map(NativeRPCValue.string))) }
        func object(_ fields: [(String, NativeRPCValue)], required: [String] = []) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(fields.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        func array(_ items: NativeRPCValue, max: Int) -> NativeRPCValue {
            .object([.init("type", .string("array")), .init("items", items), .init("maxItems", .number(Double(max)))])
        }
        let options = object([
            ("version", integer(1, 1)),
            ("build", object([("baseDirectory", text), ("dockerfile", text), ("target", text), ("noCache", boolean)])),
            ("steps", object([("beforeDeploy", text), ("afterDeploy", text), ("timeoutSeconds", integer(10, 3600))])),
            ("health", object([("enabled", boolean), ("path", string), ("expectedStatus", integer(100, 599)), ("intervalSeconds", integer(1, 300)),
                               ("timeoutSeconds", integer(1, 120)), ("retries", integer(1, 20)), ("startPeriodSeconds", integer(0, 900))])),
            ("web", object([("redirect", choice(["none", "to-apex", "to-www"])), ("forceHTTPS", boolean), ("compression", boolean),
                            ("password", object([("username", string), ("password", string)], required: ["username"]))])),
            ("storage", array(object([("kind", choice(["volume", "file", "folder"])), ("path", string), ("source", text), ("readOnly", boolean), ("content", text)],
                                     required: ["kind", "path"]), max: 16))
        ])
        let change = object([("key", string), ("value", text), ("build", boolean), ("run", boolean), ("locked", boolean)], required: ["key"])
        let server = [("serverId", string)], app = server + [("appId", string)]
        func definition(_ suffix: String, _ description: String, fields: [(String, NativeRPCValue)], required: [String], write: Bool = false) -> Spec {
            Spec(id: "apps." + suffix, channel: "apps:" + suffix.replacingOccurrences(of: ".", with: ":"), write: write, description: description,
                 properties: .object(fields.map { .init($0.0, $0.1) }), required: required)
        }
        return [
            definition("options.read", "Read an app's build, deploy-step, health-check, address and storage options. Passwords are never returned.", fields: app, required: ["serverId", "appId"]),
            definition("options.apply", "Replace an app's options (send the complete options object read first). Build/steps/health/storage apply on the next deploy; address options apply at once where the server allows. To set password protection send web.password {username, password}; omit password to keep the saved one. Runs at once when the calling AI's permission mode allows it; the action is logged.",
                       fields: app + [("options", options)], required: ["serverId", "appId", "options"], write: true),
            definition("variables.read", "Read an app's variables with their flags (during build, while running, locked). Locked values are masked.", fields: app, required: ["serverId", "appId"]),
            definition("variables.patch", "Add, change or remove app variables. Omit value to change only flags and keep the saved value. Values may span several lines. Runs at once when the calling AI's permission mode allows it; the action is logged.",
                       fields: app + [("set", array(change, max: 256)), ("remove", array(string, max: 256))], required: ["serverId", "appId"], write: true),
            definition("router.persist.plan", "Tell whether this server's Caddy keeps Terminal Deck's app addresses after it restarts, and if not, the one import line (and file) that would keep them.", fields: server, required: ["serverId"]),
            definition("router.persist.apply", "Add the one import line from apps.router.persist.plan to the Caddy settings file (send that exact file and line). Nothing else in the file changes and Caddy is not restarted. Runs at once when the calling AI's permission mode allows it; the action is logged.",
                       fields: server + [("file", string), ("line", string)], required: ["serverId", "file", "line"], write: true),
            definition("router.read", "Tell what serves web addresses on a server (Terminal Deck's own, an existing Caddy, Coolify's or another Traefik, something else, or nothing) and what that means for apps.", fields: server, required: ["serverId"])
        ]
    }

    public static func validate(tool: String, arguments: NativeRPCValue) throws {
        guard let entry = spec(tool) else { throw NativeRPCError(code: "unavailable", message: "This app tool is unavailable.") }
        try BackendDockerMCPArguments.validate(arguments, schema: entry.inputSchema)
        if let appID = arguments["appId"].string { _ = try BackendAppsValidation.id(appID) }
        switch entry.id {
        case "apps.options.apply":
            let options = try BackendAppsSRV2Definition.requested(arguments["options"])
            var check = options
            if check.web.password?.password == nil, check.web.password != nil { check.web.password?.hash = nil }
            try check.validate()
        case "apps.variables.patch":
            let remove = (arguments["remove"].elements ?? []).compactMap(\.string)
            try BackendAppsSRV2Variables.validate(try BackendAppsSRV2Variables.changes(arguments["set"]), remove: remove)
            guard arguments.has("set") || arguments.has("remove") else { throw NativeRPCError.invalidArguments("Send set, remove, or both.") }
        case "apps.router.persist.apply":
            guard arguments["line"].string?.hasPrefix("import ") == true, arguments["line"].string?.contains("\n") == false else {
                throw NativeRPCError.invalidArguments("line must be the exact import line from apps.router.persist.plan.")
            }
        default: break
        }
    }

    /// Approval sentence: never a value, password or file text.
    public static func summary(tool: String, arguments: NativeRPCValue) -> String? {
        guard let entry = spec(tool) else { return nil }
        let app = arguments["appId"].string.map { "app \"\($0)\"" } ?? "the app"
        let server = arguments["serverId"].string ?? "connected server"
        switch entry.id {
        case "apps.options.apply":
            var lines = (try? NativeAppsOptions.from(arguments["options"]).summaryLines) ?? []
            if arguments["options"]["web"]["password"]["password"].string != nil { lines.append("Sets a new password") }
            return "Change the options of \(app) on server \"\(server)\": " + (lines.isEmpty ? "defaults" : lines.joined(separator: "; ")) + "."
        case "apps.variables.patch":
            let set = (arguments["set"].elements ?? []).compactMap { $0["key"].string }
            let remove = (arguments["remove"].elements ?? []).compactMap(\.string)
            var parts: [String] = []
            if !set.isEmpty { parts.append("change " + set.joined(separator: ", ")) }
            if !remove.isEmpty { parts.append("remove " + remove.joined(separator: ", ")) }
            return "For \(app) on server \"\(server)\": " + parts.joined(separator: " and ") + ". Untouched values stay as they are."
        case "apps.router.read": return "Check what serves web addresses on server \"\(server)\"."
        case "apps.router.persist.plan": return "Check whether server \"\(server)\" keeps app addresses after a Caddy restart."
        case "apps.router.persist.apply":
            return "On server \"\(server)\", add this one line to \(arguments["file"].string ?? "the Caddy settings file"): \(arguments["line"].string ?? ""). Nothing else in that file changes; Caddy is not restarted."
        default: return "Read \(app) on server \"\(server)\"."
        }
    }
}
