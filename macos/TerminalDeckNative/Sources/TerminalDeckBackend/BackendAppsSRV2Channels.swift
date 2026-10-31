import Foundation
import TerminalDeckNativeCore

/// SRV2 channels: the app definition's options, variables with build/run
/// flags, the address-manager check, and the deploy / rollback / addresses
/// actions that must honour those options. One surface for the app page and
/// the AI tools; every write passes the injected approval BEFORE server I/O.
public actor BackendAppsSRV2Channels {
    public struct Action: Sendable {
        public let channel: String
        public let serverID: String
        public let appID: String?
        public let destructive: Bool
        /// Never contains variable values, passwords or file text.
        public let preview: NativeRPCValue
    }
    public typealias Authorize = @Sendable (Action, NativeRPCContext) async throws -> Void
    public typealias Publish = @Sendable (String, NativeRPCValue, String) async throws -> Void
    /// The existing Apps channels (APE) for apps this engine doesn't deploy (templates, compose).
    public typealias Fallback = @Sendable (String, NativeRPCValue, NativeRPCContext) async throws -> NativeRPCValue

    public static let readChannels: Set<String> = ["apps:options:read", "apps:variables:read", "apps:router:read", "apps:router:persist:plan"]
    public static let writeChannels: Set<String> = ["apps:options:apply", "apps:variables:patch", "apps:router:persist:apply"]
    /// Server-level channels: no appId.
    public static let serverChannels: Set<String> = ["apps:router:read", "apps:router:persist:plan", "apps:router:persist:apply"]
    /// Registered from here instead of the existing engine once INT2 wires SRV2.
    public static let replacedChannels: Set<String> = ["apps:deploy", "apps:rollback", "apps:domains:apply"]
    public static let allWriteChannels = writeChannels.union(replacedChannels)

    let runtime: BackendAppsRuntime
    let store: BackendAppsStore
    let definition: BackendAppsSRV2Definition
    let variables: BackendAppsSRV2Variables
    let deployer: BackendAppsSRV2Deployer
    let authorize: Authorize
    let publish: Publish?
    let fallback: Fallback?
    let routerProbe: BackendAppsSRV2Deployer.RouterProbe?

    public init(runtime: BackendAppsRuntime, store: BackendAppsStore? = nil,
                authorize: @escaping Authorize = { action, context in
                    try context.require(BackendAppsSRV2Channels.allWriteChannels.contains(action.channel) ? "apps.write" : "apps.read")
                    if BackendAppsSRV2Channels.allWriteChannels.contains(action.channel) { throw NativeRPCError(code: "approval-required", message: "This server action needs approval through Terminal Deck.") }
                }, publish: Publish? = nil, fallback: Fallback? = nil, routerProbe: BackendAppsSRV2Deployer.RouterProbe? = nil) {
        let store = store ?? BackendAppsStore(runtime: runtime)
        self.runtime = runtime; self.store = store
        self.definition = BackendAppsSRV2Definition(store: store, runtime: runtime)
        self.variables = BackendAppsSRV2Variables(store: store)
        self.deployer = BackendAppsSRV2Deployer(runtime: runtime, store: store, routerProbe: routerProbe)
        self.routerProbe = routerProbe
        self.authorize = authorize; self.publish = publish; self.fallback = fallback
    }

    public static func register(registry: NativeChannelRegistry, service: BackendAppsSRV2Channels, ownerID: String = "native-apps-srv2", includeReplaced: Bool,
                                finished: (@Sendable (NativeRPCContext) async -> Void)? = nil) async throws {
        var registered: [String] = []
        let channels = readChannels.union(writeChannels).union(includeReplaced ? replacedChannels : [])
        do {
            for channel in channels.sorted() {
                try await registry.register(channel, ownerID: ownerID) { context, args in
                    guard args.count == 1, args[0].fields != nil else { throw NativeRPCError.invalidArguments("App actions expect one request object.") }
                    do {
                        let value = try await service.invoke(channel, request: args[0], context: context)
                        await finished?(context); return value
                    } catch { await finished?(context); throw error }
                }
                registered.append(channel)
            }
        } catch {
            for channel in registered { await registry.removeHandler(channel, ownerID: ownerID) }
            throw error
        }
    }

    public func invoke(_ channel: String, request: NativeRPCValue, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.readChannels.union(Self.allWriteChannels).contains(channel), request.fields != nil else { throw NativeRPCError.invalidArguments("That app action is not supported.") }
        guard let server = request["serverId"].string, !server.isEmpty else { throw NativeRPCError.invalidArguments("serverId is required.") }
        let appID = try request["appId"].string.map(BackendAppsValidation.id)
        if !Self.serverChannels.contains(channel), appID == nil { throw NativeRPCError.invalidArguments("appId is required.") }
        if channel == "apps:router:persist:apply" {
            guard request["file"].string?.isEmpty == false, request["line"].string?.hasPrefix("import ") == true else {
                throw NativeRPCError.invalidArguments("Send the file and the exact line that were shown for approval.")
            }
        }
        try await authorize(.init(channel: channel, serverID: server, appID: appID, destructive: false, preview: Self.preview(channel, request)), context)
        try Task.checkCancellation()
        let app = appID ?? ""
        let value: NativeRPCValue
        switch channel {
        case "apps:router:read":
            let facts = try await deployer.resolvedFacts(server, nil)
            return try facts.info.encoded()
        case "apps:router:persist:plan":
            return try Self.encode(try await BackendAppsSRV2CaddyKeep(runtime: runtime, store: store, routerProbe: routerProbe).plan(server))
        case "apps:router:persist:apply":
            return try await BackendAppsSRV2CaddyKeep(runtime: runtime, store: store, routerProbe: routerProbe).apply(server, file: request["file"].string ?? "", line: request["line"].string ?? "")
        case "apps:options:read":
            let options = try await definition.read(server, app)
            return Self.object([("options", try options.publicForm.value()), ("summary", .array(options.summaryLines.map(NativeRPCValue.string)))])
        case "apps:variables:read":
            _ = try await store.read(server, app)
            return try Self.encode(try await variables.read(server, app))
        case "apps:options:apply":
            let requested = try BackendAppsSRV2Definition.requested(request["options"])
            let definition = self.definition, deployer = self.deployer, store = self.store
            value = try await store.withLock(server, app) {
                let before = try BackendAppsSRV2Definition.options(try await store.read(server, app))
                let saved = try await definition.apply(server, app, requested)
                let written = try await deployer.writeRecipe(server, app, record: saved.record)
                var note = "Saved. The next deploy uses these settings."
                if before.web != saved.options.web {
                    // The running deploy routes with the settings it started with.
                    if !saved.record["pendingDeploymentId"].isNullish { note = "Saved. A deploy is running with the earlier settings; deploy again after it finishes to use these." }
                    else if written.facts.mode == .traefik { note = "Saved. Deploy the app to apply the new address settings." }
                    else if saved.record["activeDeploymentId"].string != nil, written.facts.caddyServerKey != nil {
                        _ = try await deployer.route(server, app, action: "apply-route")
                        note = "Saved. The address settings are already live; other changes apply on the next deploy."
                    }
                }
                return Self.object([("options", try saved.options.publicForm.value()), ("summary", .array(saved.options.summaryLines.map(NativeRPCValue.string))), ("note", .string(note))])
            }
        case "apps:variables:patch":
            let changes = try BackendAppsSRV2Variables.changes(request["set"])
            let remove = try (request["remove"].elements ?? []).map { try $0.requireString("Variable name", nonempty: true) }
            let variables = self.variables, deployer = self.deployer, store = self.store
            value = try await store.withLock(server, app) {
                let record = try await store.read(server, app)
                guard record["kind"].string == "app" else { throw NativeRPCError.invalidArguments("Database settings are changed in the database's own page.") }
                let rows = try await variables.patch(server, app, changes: changes, remove: remove)
                try await deployer.writeRecipe(server, app, record: record)
                return Self.object([("variables", try Self.encode(rows)), ("note", .string("Saved. The next deploy uses these values."))])
            }
        case "apps:deploy", "apps:rollback", "apps:domains:apply":
            let record = try await store.read(server, app)
            if record["source"]["kind"].string != "github" || record["source"]["build"].string == "compose" {
                guard let fallback else { throw BackendAppsRuntime.unavailable("This app type deploys through the earlier engine, which isn't connected here.") }
                return try await fallback(channel, request, context)
            }
            switch channel {
            case "apps:deploy":
                let revision = request["revision"].string
                value = try await deploymentEvent(server, app, context: context) { [deployer] in try await deployer.deploy(serverID: server, appID: app, source: .github(revision: revision)) }
            case "apps:rollback":
                let target = try request["deploymentId"].requireString("Deployment", nonempty: true)
                guard let row = BackendAppsDeployHistory.rows(record).first(where: { $0["id"].string == target }), let tag = row["imageTag"].string,
                      BackendAppsDeployHistory.canRollBack(row) else { throw NativeRPCError(code: "not-found", message: "That successful deploy is no longer available to roll back to.") }
                value = try await deploymentEvent(server, app, context: context) { [deployer] in
                    try await deployer.deploy(serverID: server, appID: app, source: .image(tag: tag)).setting("rollbackOf", .string(target))
                }
            default:
                value = try await domains(server, app, request)
            }
        default: throw BackendAppsRuntime.unavailable(NativeAppsUnavailableReason.operationNotImplemented)
        }
        if let record = try? await store.read(server, app) {
            try? await publish?("apps:changed", Self.object([("serverId", .string(server)), ("appId", .string(app)), ("record", BackendAppsStore.publicRecord(record))]), context.ownerID)
        }
        return value
    }

    /// Addresses honour the saved options: the route is re-applied with them.
    func domains(_ server: String, _ app: String, _ request: NativeRPCValue) async throws -> NativeRPCValue {
        let raw = try request["domains"].requireArray("Addresses")
        guard !raw.isEmpty, raw.count <= 20 else { throw NativeRPCError.invalidArguments("Choose between 1 and 20 addresses.") }
        let names = try raw.map { try BackendAppsCaddy.hostname($0.requireString("Address", nonempty: true)) }
        guard Set(names).count == names.count else { throw NativeRPCError.invalidArguments("Each address can appear once.") }
        let caddy = BackendAppsCaddy(runtime: runtime)
        for name in names {
            guard try await caddy.check(serverID: server, domain: name)["pointsHere"].bool == true else {
                throw NativeRPCError(code: "dns-mismatch", message: "\(name) does not point to this server yet. Follow its DNS instructions first.")
            }
        }
        let store = self.store, deployer = self.deployer, now = runtime.now()
        return try await store.withLock(server, app) {
            let old = try await store.read(server, app)
            guard old["kind"].string == "app" else { throw NativeRPCError.invalidArguments("Only web apps have public addresses.") }
            guard old["pendingDeploymentId"].isNullish else { throw NativeRPCError(code: "conflict", message: "A deploy is still finishing. Try again shortly.") }
            let next = old.setting("domains", .array(names.map(NativeRPCValue.string))).setting("address", .string("https://" + names[0])).setting("updatedAt", .number(now))
            let written = try await deployer.writeRecipe(server, app, record: next)
            if written.facts.mode == .caddy || written.facts.mode == .ownCaddy { try await deployer.checkConflicts(server, app, domains: written.domains, admin: written.facts.caddyAdmin) }
            try await store.write(server, app, next)
            if old["activeDeploymentId"].string != nil, written.facts.caddyServerKey != nil, written.facts.mode != .traefik {
                do { _ = try await deployer.route(server, app, action: "apply-route") }
                catch {
                    try await store.write(server, app, old)
                    _ = try? await deployer.writeRecipe(server, app, record: old)
                    throw error
                }
            }
            var result = BackendAppsStore.publicRecord(next)
            if written.facts.mode == .traefik { result = result.setting("note", .string("Saved. Deploy the app to use the new addresses.")) }
            return result
        }
    }

    func deploymentEvent(_ server: String, _ app: String, context: NativeRPCContext, action: @Sendable () async throws -> NativeRPCValue) async throws -> NativeRPCValue {
        let base = Self.object([("serverId", .string(server)), ("appId", .string(app))])
        try? await publish?("apps:deployment", base.setting("phase", .string("starting")).setting("message", .string("Deploy started.")), context.ownerID)
        do {
            let value = try await action()
            try? await publish?("apps:deployment", base.setting("deploymentId", value["id"]).setting("phase", .string("running")).setting("message", .string("Deploy finished.")), context.ownerID)
            return value
        } catch {
            let message = (error as? NativeRPCError)?.message ?? "Deploy did not finish. Check the app's saved deploys."
            try? await publish?("apps:deployment", base.setting("phase", .string("failed")).setting("message", .string(message)), context.ownerID)
            throw error
        }
    }

    /// Approval text: names and switches only, never values, passwords or file text.
    static func preview(_ channel: String, _ request: NativeRPCValue) -> NativeRPCValue {
        var fields: [(String, NativeRPCValue)] = [("channel", .string(channel)), ("serverId", request["serverId"]), ("appId", request["appId"])]
        switch channel {
        case "apps:options:apply":
            if let options = try? NativeAppsOptions.from(request["options"]) {
                var lines = options.summaryLines
                if options.web.password?.password != nil { lines.append("Sets a new password") }
                fields.append(("summary", .array(lines.map(NativeRPCValue.string))))
            }
        case "apps:variables:patch":
            let keys = (request["set"].elements ?? []).compactMap { $0["key"].string }
            fields.append(("changes", .array(keys.map(NativeRPCValue.string))))
            fields.append(("removes", .array((request["remove"].elements ?? []).compactMap(\.string).map(NativeRPCValue.string))))
        case "apps:domains:apply": fields.append(("domains", request["domains"]))
        case "apps:router:persist:apply":
            fields.append(("summary", .array([.string("Add this one line to " + (request["file"].string ?? "the Caddy settings file") + ":"), request["line"]])))
        case "apps:rollback": fields.append(("deploymentId", request["deploymentId"]))
        default: break
        }
        return object(fields.filter { $0.1 != .missing })
    }

    static func encode<T: Encodable>(_ value: T) throws -> NativeRPCValue {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try NativeRPCValue.parseJSON(encoder.encode(value))
    }
    static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
}

extension NativeAppsRouterInfo {
    func encoded() throws -> NativeRPCValue {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try NativeRPCValue.parseJSON(encoder.encode(self))
    }
}
