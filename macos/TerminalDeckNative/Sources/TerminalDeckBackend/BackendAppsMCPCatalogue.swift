import Foundation
import TerminalDeckNativeCore

/// Contract-backed Apps tools. The payload is the one object required by
/// macos/docker/CONTRACT-apps.md, with no approval token added by an agent.
public enum BackendAppsMCPCatalogue {
    public struct Definition: Sendable {
        public let id: String
        public let channel: String
        public let tier: BackendMCPTier
        public let description: String
        public let properties: NativeRPCValue
        public let required: [String]
        public let destructive: Bool

        public var wireName: String { id.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_") }
        public var inputSchema: NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", properties),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        public func specification() throws -> BackendMCPTool {
            try BackendMCPTool(id: id, wireName: wireName, description: description, inputSchema: inputSchema, tier: tier)
        }
    }

    public static func definitions() -> [Definition] {
        let string = NativeRPCValue.object([.init("type", .string("string")), .init("minLength", .number(1))])
        let plainString = NativeRPCValue.object([.init("type", .string("string"))])
        let boolean = NativeRPCValue.object([.init("type", .string("boolean"))])
        func choice(_ values: [String]) -> NativeRPCValue { string.setting("enum", .array(values.map(NativeRPCValue.string))) }
        func integer(_ minimum: Int, _ maximum: Int) -> NativeRPCValue {
            .object([.init("type", .string("integer")), .init("minimum", .number(Double(minimum))), .init("maximum", .number(Double(maximum)))])
        }
        func object(_ fields: [(String, NativeRPCValue)], required: [String]) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(fields.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let env = NativeRPCValue.object([.init("type", .string("object")), .init("additionalProperties", plainString)])
        let source = object([("kind", choice(["github"])), ("repository", string), ("branch", string),
                             ("build", choice(["auto", "dockerfile", "compose"])), ("port", integer(1, 65_535)),
                             ("dockerfile", string), ("composeFile", string), ("service", string)], required: ["kind", "repository", "build"])
        let strings = NativeRPCValue.object([.init("type", .string("array")), .init("items", string)])
        let server = [("serverId", string)]
        let app = server + [("appId", string)]
        func definition(_ suffix: String, _ description: String, fields: [(String, NativeRPCValue)], required: [String],
                        write: Bool = false, destructive: Bool = false) -> Definition {
            Definition(id: "apps." + suffix, channel: "apps:" + suffix.replacingOccurrences(of: ".", with: ":"),
                       tier: write ? .alter : .read, description: description,
                       properties: .object(fields.map { .init($0.0, $0.1) }), required: required, destructive: destructive)
        }
        return [
            definition("capabilities", "Read which app features are available on a connected server, with a reason for unavailable features.", fields: server, required: ["serverId"]),
            definition("list", "List a connected server's apps, status, addresses and setting names. Secret values are masked.", fields: server, required: ["serverId"]),
            definition("read", "Read one app's status, address and deployment details. Secret values are masked.", fields: app, required: ["serverId", "appId"]),
            definition("create", "Create an app from a GitHub repository with optional settings. Requires the person's approval.", fields: app + [("name", string), ("source", source), ("env", env)], required: ["serverId", "appId", "name", "source"], write: true),
            definition("deploy", "Deploy an app using its saved source and settings. Requires the person's approval.", fields: app, required: ["serverId", "appId"], write: true),
            definition("deployments", "Read an app's deployment history and available rollback targets.", fields: app, required: ["serverId", "appId"]),
            definition("rollback", "Roll an app back to a retained deployment without rolling back database data. Requires approval.", fields: app + [("deploymentId", string)], required: ["serverId", "appId", "deploymentId"], write: true),
            definition("restart", "Restart an app. Requires the person's approval.", fields: app, required: ["serverId", "appId"], write: true),
            definition("remove", "Remove an app only after approval and an exact app-name confirmation. Read the app name first.", fields: app + [("confirmation", string)], required: ["serverId", "appId", "confirmation"], write: true, destructive: true),
            definition("env.read", "Read an app's setting names. All setting values stay masked.", fields: app, required: ["serverId", "appId"]),
            definition("env.apply", "Replace an app's complete setting map. Values are hidden from approval metadata and replies. Requires approval.", fields: app + [("env", env)], required: ["serverId", "appId", "env"], write: true),
            definition("env.patch", "Change or remove selected settings, preserving untouched secret values. Requires the person's approval.", fields: app + [("set", env), ("remove", strings)], required: ["serverId", "appId", "set", "remove"], write: true),
            definition("domains.check", "Check whether an address points to the connected server and read the DNS instructions.", fields: app + [("domain", string)], required: ["serverId", "appId", "domain"]),
            definition("domains.apply", "Set an app's addresses after DNS checks. Requires the person's approval.", fields: app + [("domains", strings.setting("minItems", .number(1)).setting("maxItems", .number(20)))], required: ["serverId", "appId", "domains"], write: true),
            definition("caddy.plan", "Read the commands needed to install automatic HTTPS and the private administration address.", fields: server, required: ["serverId"]),
            definition("caddy.install", "Install and verify automatic HTTPS on the connected server. Requires the person's approval.", fields: server, required: ["serverId"], write: true),
            definition("databases.create", "Create a PostgreSQL, MySQL, Redis or MongoDB app. Passwords remain protected. Requires approval.", fields: app + [("name", string), ("kind", choice(["postgres", "mysql", "redis", "mongodb"])), ("version", string)], required: ["serverId", "appId", "name", "kind"], write: true),
            definition("backups.list", "Read an app's available backups.", fields: app, required: ["serverId", "appId"]),
            definition("backups.create", "Create and verify a backup. Requires the person's approval.", fields: app, required: ["serverId", "appId"], write: true),
            definition("backups.policy.read", "Read the app's scheduled-backup policy and whether it is enabled. Upload credentials are omitted.", fields: app, required: ["serverId", "appId"]),
            definition("backups.policy", "Enable or disable scheduled server backups. Keep a count of verified backups (1–365). Omitted upload keeps its saved settings, null removes it, and replacement credentials stay protected. Requires approval.", fields: app + [("enabled", boolean), ("schedule", string), ("retention", integer(1, 365)), ("upload", BackendAppsDataTools.backupUploadSchema)], required: ["serverId", "appId", "enabled"], write: true),
            definition("backups.restore", "Restore a backup over current data only after approval and an exact app-name confirmation.", fields: app + [("backupId", string), ("confirmation", string)], required: ["serverId", "appId", "backupId", "confirmation"], write: true, destructive: true),
            definition("templates.list", "Read the licensed one-click app templates; optionally check them for a connected server.", fields: server, required: []),
            definition("templates.deploy", "Create an app from a licensed template with optional protected settings. Requires approval.", fields: app + [("name", string), ("templateId", string), ("env", env)], required: ["serverId", "appId", "name", "templateId"], write: true),
            definition("auto-deploy.apply", "Change automatic deployment on push. Requires approval and trusted signed webhook ingress, or returns unavailable.", fields: app + [("enabled", boolean)], required: ["serverId", "appId", "enabled"], write: true),
            definition("logs.read", "Read a bounded recent app log with secret values masked.", fields: app + [("tail", integer(1, 1_000))], required: ["serverId", "appId"]),
            definition("logs.watch", "Read a short masked batch of live app logs, then close the stream before returning. Stops at owned EOF, reports stream errors and is limited to five seconds, 40 events and 64 KB.", fields: app + [("streamId", string)], required: ["serverId", "appId", "streamId"]),
            definition("logs.unwatch", "Stop this caller's app-log stream. AI live-log reads close their own streams within one call; returns unavailable when no owned stream remains.", fields: server + [("streamId", string)], required: ["serverId", "streamId"]),
        ] + BackendAppsDataTools.definitions()
    }
}
