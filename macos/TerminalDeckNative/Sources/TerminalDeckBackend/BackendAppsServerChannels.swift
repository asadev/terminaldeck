import Foundation
import TerminalDeckNativeCore

/// One channel surface for the native Apps screens and the AI tools. The
/// existing approval gate (BackendAppsChannels.Authorize) runs before ANY
/// server I/O; reads run freely after the caller's grants, writes ask first.
public actor BackendAppsServerChannels {
    public typealias Authorize = BackendAppsChannels.Authorize
    public static let readChannels: Set<String> = [
        "apps:server:status", "apps:server:setup:plan", "apps:server:alerts:read", "apps:server:alerts:history",
        "apps:server:cleanup:read", "apps:server:cleanup:preview", "apps:server:jobs:list", "apps:server:jobs:log",
        "apps:server:autodeploy:read", "apps:server:deploy:log"
    ]
    public static let writeChannels: Set<String> = [
        "apps:server:setup:install", "apps:server:setup:remove", "apps:server:alerts:save", "apps:server:alerts:test",
        "apps:server:cleanup:save", "apps:server:cleanup:run", "apps:server:jobs:save", "apps:server:jobs:remove",
        "apps:server:jobs:run", "apps:server:autodeploy:apply", "apps:server:autodeploy:link", "apps:server:deploy:run"
    ]
    /// Results contain a secret meant for the person to paste into GitHub/CI.
    /// Only the native window may call these; no AI tool exists for them.
    public static let nativeOnlyChannels: Set<String> = ["apps:server:autodeploy:reveal", "apps:server:autodeploy:link"]
    public static let invokeChannels = readChannels.union(writeChannels).union(nativeOnlyChannels)

    /// Readies an app for server-started deploys (SRV2 writes its recipe, the only deploy path there).
    public typealias PrepareDeploys = @Sendable (_ serverID: String, _ appID: String) async throws -> Void

    private let service: BackendAppsServerService
    private let authorize: Authorize
    private let prepareDeploys: PrepareDeploys?

    public init(service: BackendAppsServerService, authorize: @escaping Authorize = { action, _ in
        if !BackendAppsServerChannels.readChannels.contains(action.channel) {
            throw NativeRPCError(code: "approval-required", message: "This server action needs approval through Terminal Deck.")
        }
    }, prepareDeploys: PrepareDeploys? = nil) {
        self.service = service; self.authorize = authorize; self.prepareDeploys = prepareDeploys
    }

    public static func register(registry: NativeChannelRegistry, service: BackendAppsServerChannels, ownerID: String = "native-apps-server",
                                finished: (@Sendable (NativeRPCContext) async -> Void)? = nil) async throws {
        var installed: [String] = []
        do {
            for channel in invokeChannels.sorted() {
                try await registry.register(channel, ownerID: ownerID) { context, args in
                    guard args.count == 1, args[0].fields != nil else { throw NativeRPCError.invalidArguments("Server actions expect one request object.") }
                    do { let value = try await service.invoke(channel, request: args[0], context: context); await finished?(context); return value }
                    catch { await finished?(context); throw error }
                }
                installed.append(channel)
            }
        } catch {
            for channel in installed { await registry.removeHandler(channel, ownerID: ownerID) }
            throw error
        }
    }

    public func invoke(_ channel: String, request: NativeRPCValue, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.invokeChannels.contains(channel), let fields = request.fields else { throw NativeRPCError.invalidArguments("That server action is not supported.") }
        guard Set(fields.map(\.key)).count == fields.count, fields.allSatisfy({ Self.payloadKeys(channel).contains($0.key) }) else {
            throw NativeRPCError.invalidArguments("That server request has unsupported or repeated fields.")
        }
        if Self.nativeOnlyChannels.contains(channel), context.caller != .nativeApp {
            throw NativeRPCError(code: "access-denied", message: "This shows a secret, so only the Terminal Deck window can open it.")
        }
        let changing = !Self.readChannels.contains(channel) && channel != "apps:server:autodeploy:reveal"
        try context.require(changing ? "apps.write" : "apps.read")
        let server = try Self.text(request, "serverId")
        let app = request.has("appId") ? try BackendAppsValidation.id(Self.text(request, "appId")) : nil
        if Self.needsApp(channel), app == nil { throw NativeRPCError.invalidArguments("Choose the app.") }
        let destructive = channel == "apps:server:setup:remove"
        let confirmation = request["confirmation"].string
        if destructive, confirmation?.isEmpty != false {
            throw NativeRPCError(code: "confirmation-required", message: "Type the server's name to remove Terminal Deck from it.")
        }
        // Validate before asking, so an approval is never spent on a bad request.
        var preview = BackendAppsValidation.object([("channel", .string(channel)), ("serverId", .string(server)),
                                                    ("appId", app.map(NativeRPCValue.string) ?? .null), ("destructive", .bool(destructive))])
        switch channel {
        case "apps:server:alerts:save":
            let settings = try BackendAppsServerSettings.alerts(request)
            preview = preview.setting("channels", .array((settings["channels"].elements ?? []).map {
                BackendAppsValidation.object([("id", $0["id"]), ("kind", $0["kind"])])
            })).setting("thresholds", settings["thresholds"]).setting("watch", settings["watch"])
        case "apps:server:cleanup:save": preview = preview.setting("settings", try BackendAppsServerSettings.cleanup(request))
        case "apps:server:jobs:save":
            let job = try BackendAppsServerSettings.job(request)
            preview = preview.setting("job", job)
        case "apps:server:jobs:remove", "apps:server:jobs:run", "apps:server:jobs:log":
            preview = preview.setting("jobId", .string(try BackendAppsValidation.id(Self.text(request, "jobId"))))
        case "apps:server:autodeploy:apply":
            guard let enabled = request["enabled"].bool else { throw NativeRPCError.invalidArguments("Choose whether automatic deploys are on.") }
            preview = preview.setting("enabled", .bool(enabled)).setting("deployKey", .bool(request["deployKey"].bool ?? false))
        case "apps:server:cleanup:run": preview = preview.setting("dryRun", .bool(false))
        case "apps:server:setup:remove":
            preview = preview.setting("addressManager", .bool(request["addressManager"].bool ?? false))
            // The exact line (and folder) Terminal Deck added, as shown to the person; SRV2 re-checks its receipt.
            if let undo = try Self.importUndo(request) {
                preview = preview.setting("importUndo", BackendAppsValidation.object([("file", .string(undo.file)), ("line", .string(undo.line)), ("folder", .string(undo.folder))]))
            }
        default: break
        }
        try Task.checkCancellation()
        try await authorize(.init(channel: channel, serverID: server, appID: app, destructive: destructive, confirmation: confirmation, preview: preview), context)
        try Task.checkCancellation()
        switch channel {
        case "apps:server:status": return try await service.status(serverID: server)
        case "apps:server:setup:plan": return try await service.plan(serverID: server)
        case "apps:server:setup:install": return try await service.install(serverID: server)
        case "apps:server:setup:remove":
            let facts = try await service.probe(server)
            guard confirmation == server || (!facts.hostname.isEmpty && confirmation == facts.hostname) else {
                throw NativeRPCError(code: "confirmation-required", message: "The name typed does not match this server. Nothing was removed.")
            }
            return try await service.remove(serverID: server, addressManager: request["addressManager"].bool ?? false, importUndo: try Self.importUndo(request))
        case "apps:server:alerts:read": return try await service.alertsRead(serverID: server)
        case "apps:server:alerts:save": return try await service.alertsSave(serverID: server, request: request.removing("serverId"))
        case "apps:server:alerts:test": return try await service.alertsTest(serverID: server)
        case "apps:server:alerts:history":
            return try await service.alertsHistory(serverID: server, limit: NativeNumber.clamped(request["limit"].number, to: 1...200, fallback: 50))
        case "apps:server:cleanup:read": return try await service.cleanupRead(serverID: server)
        case "apps:server:cleanup:save": return try await service.cleanupSave(serverID: server, request: request.removing("serverId"))
        case "apps:server:cleanup:preview": return try await service.cleanupRun(serverID: server, dryRun: true)
        case "apps:server:cleanup:run": return try await service.cleanupRun(serverID: server, dryRun: false)
        case "apps:server:jobs:list": return try await service.jobsList(serverID: server, appID: app!)
        case "apps:server:jobs:save": return try await service.jobSave(serverID: server, appID: app!, request: request)
        case "apps:server:jobs:remove": return try await service.jobRemove(serverID: server, appID: app!, jobID: Self.text(request, "jobId"))
        case "apps:server:jobs:run": return try await service.jobRun(serverID: server, appID: app!, jobID: Self.text(request, "jobId"))
        case "apps:server:jobs:log": return try await service.jobLog(serverID: server, appID: app!, jobID: Self.text(request, "jobId"))
        case "apps:server:autodeploy:read": return try await service.autoDeployRead(serverID: server, appID: app!)
        case "apps:server:autodeploy:apply":
            let enabled = request["enabled"].bool!
            if enabled { try await prepareDeploys?(server, app!) }
            return try await service.autoDeployApply(serverID: server, appID: app!, enabled: enabled, deployKey: request["deployKey"].bool ?? false)
        case "apps:server:autodeploy:reveal": return try await service.autoDeployReveal(serverID: server, appID: app!)
        case "apps:server:autodeploy:link": return try await service.deployLinkRotate(serverID: server, appID: app!)
        case "apps:server:deploy:run":
            try await prepareDeploys?(server, app!)
            return try await service.deployRun(serverID: server, appID: app!)
        case "apps:server:deploy:log": return try await service.deployLog(serverID: server, appID: app!)
        default: throw BackendAppsRuntime.unavailable("That server action is unavailable.")
        }
    }

    static func needsApp(_ channel: String) -> Bool { channel.hasPrefix("apps:server:jobs:") || channel.hasPrefix("apps:server:autodeploy:") || channel.hasPrefix("apps:server:deploy:") }

    /// Optional `importUndo {file, line, folder}` on setup:remove: the Caddy import line
    /// Terminal Deck added (from apps:router:persist:plan `owned`), echoed exactly.
    static func importUndo(_ request: NativeRPCValue) throws -> NativeAppsRouterPersistence.OwnedImport? {
        guard request.has("importUndo") else { return nil }
        let value = request["importUndo"]
        guard let fields = value.fields, Set(fields.map(\.key)) == ["file", "line", "folder"],
              let file = value["file"].string, let line = value["line"].string, let folder = value["folder"].string,
              [file, line, folder].allSatisfy({ $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) }) else {
            throw NativeRPCError.invalidArguments("importUndo must be the file, line and folder shown for removal.")
        }
        return .init(file: file, line: line, folder: folder)
    }

    static func payloadKeys(_ channel: String) -> Set<String> {
        var keys: Set<String> = ["serverId"]
        if needsApp(channel) { keys.insert("appId") }
        switch channel {
        case "apps:server:setup:remove": keys.formUnion(["confirmation", "addressManager", "importUndo"])
        case "apps:server:alerts:save": keys.formUnion(["enabled", "channels", "thresholds", "remindMinutes", "watch"])
        case "apps:server:alerts:history": keys.insert("limit")
        case "apps:server:cleanup:save": keys.formUnion(["enabled", "schedule", "removeOldVersions", "keepVersions", "buildCache", "unnamedStorage"])
        case "apps:server:jobs:save": keys.formUnion(["jobId", "name", "schedule", "command", "timeoutSeconds", "enabled"])
        case "apps:server:jobs:remove", "apps:server:jobs:run", "apps:server:jobs:log": keys.insert("jobId")
        case "apps:server:autodeploy:apply": keys.formUnion(["enabled", "deployKey"])
        default: break
        }
        return keys
    }

    private static func text(_ request: NativeRPCValue, _ key: String) throws -> String {
        let value = try request[key].requireString(key, nonempty: true)
        guard value.utf8.count <= 256, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw NativeRPCError.invalidArguments("Use a short \(key) without control characters.")
        }
        return value
    }
}

/// AI tools for the same channels. Reads are free; changes go through the
/// person's approval. The two secret-revealing channels have no tool.
public enum BackendAppsServerTools {
    public static func definitions() -> [BackendAppsMCPCatalogue.Definition] {
        let string = NativeRPCValue.object([.init("type", .string("string")), .init("minLength", .number(1)), .init("maxLength", .number(256))])
        let boolean = NativeRPCValue.object([.init("type", .string("boolean"))])
        let anyObject = NativeRPCValue.object([.init("type", .string("object"))])
        let anyArray = NativeRPCValue.object([.init("type", .string("array"))])
        func integer(_ low: Int, _ high: Int) -> NativeRPCValue {
            .object([.init("type", .string("integer")), .init("minimum", .number(Double(low))), .init("maximum", .number(Double(high)))])
        }
        let thresholds = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([
            .init("diskPercent", integer(50, 99)), .init("memoryPressure", integer(1, 100)), .init("certDays", integer(1, 60))]))])
        let appID = string.setting("maxLength", .number(48)).setting("pattern", .string("^[a-z][a-z0-9-]{0,47}$"))
        let server: [(String, NativeRPCValue)] = [("serverId", string)]
        let app = server + [("appId", appID)]
        let job = app + [("jobId", appID)]
        func define(_ suffix: String, _ description: String, _ fields: [(String, NativeRPCValue)], _ required: [String], write: Bool = false, destructive: Bool = false) -> BackendAppsMCPCatalogue.Definition {
            .init(id: "apps.server." + suffix, channel: "apps:server:" + suffix.replacingOccurrences(of: ".", with: ":"), tier: write ? .alter : .read,
                  description: description, properties: .object(fields.map { .init($0.0, $0.1) }), required: required, destructive: destructive)
        }
        return [
            define("status", "Read whether a server is set up for Apps: Docker, which router owns ports 80/443 (none, Terminal Deck's Caddy, an existing Caddy, Coolify/Traefik, other), and whether alerts, checks, cleanup and the deploy endpoint are running.", server, ["serverId"]),
            define("setup.plan", "Read exactly what one-click server setup would install, in plain words. Changes nothing.", server, ["serverId"]),
            define("setup.install", "Set up the server for Apps: Docker if missing (official installer), an address manager only if ports 80/443 are free, and Terminal Deck's small helper set with systemd duties. Never replaces another tool's router. Runs at once when the calling AI's permission mode allows it; the action is logged.", server, ["serverId"], write: true),
            define("setup.remove", "Remove Terminal Deck's helpers, duties and settings from a server. Apps, data and backups stay. Requires the server's exact name; it runs when the calling AI's permission mode allows it. To also take out the Caddy import line Terminal Deck added, pass importUndo exactly as apps.router.persist.plan reports it in `owned`.",
                   server + [("confirmation", string), ("addressManager", boolean),
                             ("importUndo", .object([.init("type", .string("object")),
                                                     .init("properties", .object([.init("file", string.setting("maxLength", .number(512))), .init("line", string.setting("maxLength", .number(512))), .init("folder", string.setting("maxLength", .number(512)))])),
                                                     .init("required", .array([.string("file"), .string("line"), .string("folder")])), .init("additionalProperties", .bool(false))]))],
                   ["serverId", "confirmation"], write: true, destructive: true),
            define("alerts.read", "Read the server's alert settings (Telegram, email, webhook, Receiver). Passwords and tokens stay masked.", server, ["serverId"]),
            define("alerts.history", "Read the most recent alerts the server sent, newest first.", server + [("limit", integer(1, 200))], ["serverId"]),
            define("alerts.save", "Save the server's alert channels and limits (disk %, memory pressure, certificate days, reminder minutes, extra containers to watch). Omitted tokens keep their saved values. Runs at once when the calling AI's permission mode allows it; the action is logged.", server + [("enabled", boolean), ("channels", anyArray), ("thresholds", thresholds), ("remindMinutes", integer(10, 10_080)), ("watch", anyObject)], ["serverId"], write: true),
            define("alerts.test", "Send a test alert to every enabled channel and report which ones worked. Runs at once when the calling AI's permission mode allows it; the action is logged.", server, ["serverId"], write: true),
            define("cleanup.read", "Read the automatic cleanup settings, the next run and the last result. Cleanup only touches Terminal Deck's own labelled images, plus every tool's week-old build cache when that option is on (Docker keeps one build cache for the whole server).", server, ["serverId"]),
            define("cleanup.preview", "List what cleanup would remove right now, without removing anything.", server, ["serverId"]),
            define("cleanup.save", "Change the cleanup schedule and options (older app versions, unnamed storage, and every tool's week-old build cache on the whole server are opt-in). Runs at once when the calling AI's permission mode allows it; the action is logged.", server + [("enabled", boolean), ("schedule", string), ("removeOldVersions", boolean), ("keepVersions", integer(1, 50)), ("buildCache", boolean), ("unnamedStorage", boolean)], ["serverId"], write: true),
            define("cleanup.run", "Run cleanup now. Only Terminal Deck's own unused images are removed, plus every tool's week-old build cache on this server when that option is on. Runs at once when the calling AI's permission mode allows it; the action is logged.", server, ["serverId"], write: true),
            define("jobs.list", "List an app's scheduled jobs with their schedule, next run and last result.", app, ["serverId", "appId"]),
            define("jobs.log", "Read the last output of one scheduled job, with secret values masked.", job, ["serverId", "appId", "jobId"]),
            define("jobs.save", "Create or change a scheduled job that runs a command inside the app (systemd calendar schedule such as daily or \"*-*-* 02:30:00\"). Runs on the server with the Mac off. Runs at once when the calling AI's permission mode allows it; the action is logged.", job + [("name", string), ("schedule", string), ("command", string.setting("maxLength", .number(4096))), ("timeoutSeconds", integer(10, 86_400)), ("enabled", boolean)], ["serverId", "appId", "jobId", "schedule", "command"], write: true),
            define("jobs.remove", "Remove one scheduled job and its saved output. Runs at once when the calling AI's permission mode allows it; the action is logged.", job, ["serverId", "appId", "jobId"], write: true),
            define("jobs.run", "Run one scheduled job now. Runs at once when the calling AI's permission mode allows it; the action is logged.", job, ["serverId", "appId", "jobId"], write: true),
            define("autodeploy.read", "Read whether pushes deploy the app automatically on the server, its webhook address and deploy key. Secrets are never shown.", app, ["serverId", "appId"]),
            define("autodeploy.apply", "Turn automatic deploys on push on or off (optionally create a read-only deploy key). The person pastes the webhook secret from Terminal Deck. Runs at once when the calling AI's permission mode allows it; the action is logged.", app + [("enabled", boolean), ("deployKey", boolean)], ["serverId", "appId", "enabled"], write: true),
            define("deploy.run", "Deploy the app now using the server's own pipeline (works with the Mac off). Runs at once when the calling AI's permission mode allows it; the action is logged.", app, ["serverId", "appId"], write: true),
            define("deploy.log", "Read the last server-side deploy log, with secret values masked.", app, ["serverId", "appId"])
        ]
    }
}
