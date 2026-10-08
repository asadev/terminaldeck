import Foundation
import TerminalDeckNativeCore

public struct BackendAppsAction: Sendable {
    public let channel: String
    public let serverID: String
    public let appID: String?
    public let destructive: Bool
    public let confirmation: String?
    /// Approval previews must never contain environment values or credentials.
    public let preview: NativeRPCValue
}

/// One channel surface for native screens and DKA's MCP tools. The caller's
/// approval is checked before ANY server I/O for a write, including inspection.
public actor BackendAppsChannels {
    public typealias Authorize = @Sendable (BackendAppsAction, NativeRPCContext) async throws -> Void
    public typealias Publish = @Sendable (String, NativeRPCValue, String) async throws -> Void
    public static let readChannels: Set<String> = ["apps:capabilities", "apps:list", "apps:read", "apps:deployments", "apps:env:read", "apps:domains:check", "apps:caddy:plan", "apps:backups:list", "apps:backups:policy:read", "apps:templates:list", "apps:logs:read", "apps:logs:watch", "apps:logs:unwatch"]
    public static let writeChannels: Set<String> = ["apps:create", "apps:deploy", "apps:rollback", "apps:restart", "apps:remove", "apps:env:apply", "apps:env:patch", "apps:domains:apply", "apps:caddy:install", "apps:databases:create", "apps:backups:create", "apps:backups:policy", "apps:backups:restore", "apps:templates:deploy", "apps:auto-deploy:apply"]
    public static let invokeChannels = readChannels.union(writeChannels)
    public static let eventChannels: Set<String> = ["apps:changed", "apps:deployment", "apps:logs", "apps:logs:end"]
    private let runtime: BackendAppsRuntime, store: BackendAppsStore, caddy: BackendAppsCaddy
    private let deploy: BackendAppsDeploy, databases: BackendAppsDatabases, backups: BackendAppsBackups
    private let autoDeploy: BackendAppsAutoDeploy
    private let authorize: Authorize
    private let publish: Publish?
    private struct LogStream { let owner: String, server: String, app: String, secrets: [String]; var pending = ""; var subscription: NativeRPCSubscription? }
    private var streams: [String: LogStream] = [:]

    public init(runtime: BackendAppsRuntime, store: BackendAppsStore? = nil, autoDeployIngress: BackendAppsAutoDeployIngress? = nil,
                authorize: @escaping Authorize = { action, context in
                    try context.require(BackendAppsChannels.writeChannels.contains(action.channel) ? "apps.write" : "apps.read")
                    if BackendAppsChannels.writeChannels.contains(action.channel) { throw NativeRPCError(code: "approval-required", message: "This server action needs approval through Terminal Deck.") }
                }, publish: Publish? = nil) {
        let store = store ?? BackendAppsStore(runtime: runtime), caddy = BackendAppsCaddy(runtime: runtime)
        self.runtime = runtime; self.store = store; self.caddy = caddy
        self.deploy = BackendAppsDeploy(runtime: runtime, store: store, caddy: caddy)
        self.databases = BackendAppsDatabases(runtime: runtime, store: store)
        self.backups = BackendAppsBackups(runtime: runtime, store: store)
        self.autoDeploy = BackendAppsAutoDeploy(runtime: runtime, store: store, trustedIngress: autoDeployIngress)
        self.authorize = authorize; self.publish = publish
    }
    public static func register(registry: NativeChannelRegistry, service: BackendAppsChannels, ownerID: String = "native-apps", excluding: Set<String> = [],
                                finished: (@Sendable (NativeRPCContext) async -> Void)? = nil) async throws {
        var registered: [String] = []
        do {
            for channel in invokeChannels.subtracting(excluding).sorted() {
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
        guard Self.invokeChannels.contains(channel), request.fields != nil else { throw NativeRPCError.invalidArguments("That app action is not supported.") }
        let server = channel == "apps:templates:list" ? (request["serverId"].string ?? "") : try text(request, "serverId")
        let appOptional = request["appId"].string
        if let appOptional { _ = try BackendAppsValidation.id(appOptional) }
        let destructive = ["apps:remove", "apps:backups:restore"].contains(channel)
        let preview = BackendAppsValidation.object([("channel", .string(channel)), ("serverId", .string(server)), ("appId", appOptional.map(NativeRPCValue.string) ?? .null), ("destructive", .bool(destructive))])
        try await authorize(.init(channel: channel, serverID: server, appID: appOptional, destructive: destructive, confirmation: request["confirmation"].string, preview: channel == "apps:caddy:install" ? caddy.plan() : preview), context)
        try Task.checkCancellation()
        func app() throws -> String { try BackendAppsValidation.id(text(request, "appId")) }
        let value: NativeRPCValue
        switch channel {
        case "apps:templates:list": return BackendAppsTemplates.list()
        case "apps:capabilities": return BackendAppsValidation.object([("available", .bool(!runtime.features.isEmpty)), ("features", .array(runtime.features.sorted().map(NativeRPCValue.string))), ("unavailableReason", runtime.features.isEmpty ? .string("The app engine has not been connected in this build.") : .null)])
        case "apps:list": return try await listObserved(server)
        case "apps:read": return try await readObserved(server, app())
        case "apps:deployments": return try await deploy.history(serverID: server, appID: app())
        case "apps:env:read":
            let id = try app(); _ = try await store.read(server, id)
            return masked(try await store.environment(server, id))
        case "apps:backups:policy:read":
            let policy = BackendAppsStore.publicRecord(try await store.read(server, app()))["backupPolicy"]
            return policy.isNullish ? BackendAppsValidation.object([("enabled", .bool(false))]) : policy
        case "apps:domains:check": return try await caddy.check(serverID: server, domain: text(request, "domain"))
        case "apps:caddy:plan": return caddy.plan()
        case "apps:caddy:install": return try await caddy.install(serverID: server)
        case "apps:create": value = try await create(server, request, template: false)
        case "apps:templates:deploy":
            _ = try await create(server, request, template: true)
            value = try await deploy.deploy(serverID: server, appID: app())
        case "apps:deploy":
            let id = try app(), deploy = self.deploy
            value = try await deploymentEvent(server, id, context: context) { try await deploy.deploy(serverID: server, appID: id) }
        case "apps:rollback":
            let id = try app(), deploymentID = try text(request, "deploymentId"), deploy = self.deploy
            value = try await deploymentEvent(server, id, context: context) { try await deploy.rollback(serverID: server, appID: id, deploymentID: deploymentID) }
        case "apps:restart": value = try await restart(server, app())
        case "apps:remove": return try await remove(server, app(), confirmation: text(request, "confirmation"), context: context)
        case "apps:env:apply", "apps:env:patch": value = try await settings(server, app(), request, patch: channel == "apps:env:patch")
        case "apps:domains:apply": value = try await domains(server, app(), request)
        case "apps:databases:create": value = try await databases.create(serverID: server, appID: app(), name: text(request, "name"), kind: text(request, "kind"), version: request["version"].string)
        case "apps:backups:list": return try await backups.list(serverID: server, appID: app())
        case "apps:backups:create": value = try await backups.create(serverID: server, appID: app())
        case "apps:backups:policy": value = try await backups.policy(serverID: server, appID: app(), request: request)
        case "apps:backups:restore": value = try await backups.restore(serverID: server, appID: app(), backupID: text(request, "backupId"), confirmation: text(request, "confirmation"))
        case "apps:auto-deploy:apply":
            guard let enabled = request["enabled"].bool else { throw NativeRPCError.invalidArguments("Choose whether automatic deploys are enabled.") }
            value = try await autoDeploy.apply(serverID: server, appID: app(), enabled: enabled, context: context)
        case "apps:logs:read":
            let id = try app(), record = try await store.read(server, id)
            let count = request["tail"].number ?? 200
            guard count >= 1, count <= 1000, count.rounded() == count else { throw NativeRPCError.invalidArguments("Choose between 1 and 1000 log lines.") }
            let container = try containerID(record)
            let inspection = try await ownedService(server, app: id, container: container)
            let result = try await runtime.checked(server, "docker logs --tail \(Int(count)) -- \(BackendAppsRuntime.quote(container)) 2>&1", message: "App logs could not be read.")
            let secrets = Array(try await store.environment(server, id).values) + Self.inspectSecrets(inspection)
            return BackendAppsValidation.object([("text", .string(BackendAppsValidation.mask(result, secrets: secrets)))])
        case "apps:logs:watch": return try await watch(server, app(), streamID: text(request, "streamId"), context: context)
        case "apps:logs:unwatch":
            let id = try text(request, "streamId")
            guard let stream = streams[id], stream.owner == context.ownerID, stream.server == server else { throw NativeRPCError(code: "access-denied", message: "That log view belongs to another window or session.") }
            streams[id] = nil; await stream.subscription?.cancelAndWait(); await logEnd(id, stream: stream, reason: "closed")
            return BackendAppsValidation.object([("stopped", .bool(true))])
        default: throw BackendAppsRuntime.unavailable("This app operation has no implementation.")
        }
        if let id = appOptional, let record = try? await store.read(server, id) { try? await publish?("apps:changed", BackendAppsValidation.object([("serverId", .string(server)), ("appId", .string(id)), ("record", BackendAppsStore.publicRecord(record))]), context.ownerID) }
        return value
    }

    private func create(_ server: String, _ request: NativeRPCValue, template: Bool) async throws -> NativeRPCValue {
        let id = try BackendAppsValidation.id(text(request, "appId")), name = try text(request, "name")
        guard name.count <= 120, !name.unicodeScalars.contains(where: { $0.value < 32 }) else { throw NativeRPCError.invalidArguments("Choose a short app name without control characters.") }
        var source = template ? try BackendAppsTemplates.source(templateID: text(request, "templateId")) : request["source"]
        if !template { guard source["kind"].string == "github", source["repository"].string?.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("Choose a GitHub repository as owner/repository.") } }
        let sourceKeys: Set<String> = template ? ["kind", "templateId", "image", "port", "dataPath"] : ["kind", "repository", "branch", "build", "port", "dockerfile", "composeFile", "service"]
        guard (source.fields ?? []).allSatisfy({ sourceKeys.contains($0.key) }) else { throw NativeRPCError.invalidArguments("The app source contains unsupported settings. Put secrets in the settings editor.") }
        source = .object(source.fields ?? [])
        if !template { _ = try BackendAppsDeploySource(source) }
        let cleanSource = source
        let env = try BackendAppsValidation.environment(request["env"] == .missing ? .object([]) : request["env"])
        let store = self.store, caddy = self.caddy, now = runtime.now()
        return try await store.withLock(server, id) {
            if try await store.readFile(server, path: store.directory(id) + "/state.json") != nil { throw NativeRPCError(code: "conflict", message: "An app with that ID already exists on this server.") }
            let domain = try await caddy.defaultDomain(serverID: server, appID: id)
            let record = BackendAppsValidation.object([("id", .string(id)), ("name", .string(name)), ("kind", .string("app")), ("status", .string("stopped")), ("address", .string("https://" + domain)), ("domains", .array([.string(domain)])), ("source", cleanSource), ("createdAt", .number(now)), ("updatedAt", .number(now)), ("envKeys", .array(env.keys.sorted().map(NativeRPCValue.string))), ("activeDeploymentId", .null), ("autoDeploy", .bool(false)), ("backupPolicy", BackendAppsValidation.object([("enabled", .bool(false))]))])
            try await store.applyEnvironment(server, id, env); try await store.write(server, id, record)
            return BackendAppsStore.publicRecord(record)
        }
    }
    private func settings(_ server: String, _ app: String, _ request: NativeRPCValue, patch: Bool) async throws -> NativeRPCValue {
        let store = self.store, now = runtime.now()
        return try await store.withLock(server, app) {
            let record = try await store.read(server, app), previous = try await store.environment(server, app)
            guard record["kind"].string == "app" else { throw BackendAppsRuntime.unavailable("Database settings must be changed through their managed data controls.") }
            var env = patch ? previous : [:]
            let set = try BackendAppsValidation.environment(request[patch ? "set" : "env"] == .missing && patch ? .object([]) : request[patch ? "set" : "env"])
            for (key, value) in set { guard value != "••••••••", value != "••••••", value != "[redacted]" else { throw NativeRPCError.invalidArguments("Masked settings cannot be used as real values. Leave them unchanged.") }; env[key] = value }
            if patch {
                let removes = request["remove"] == .missing ? [] : try request["remove"].requireArray("Settings to remove")
                for key in removes { env.removeValue(forKey: try key.requireString("Setting name", nonempty: true)) }
            }
            try await store.applyEnvironment(server, app, env)
            do { try await store.write(server, app, record.setting("envKeys", .array(env.keys.sorted().map(NativeRPCValue.string))).setting("updatedAt", .number(now))) }
            catch {
                do { try await store.applyEnvironment(server, app, previous) }
                catch { throw NativeRPCError(code: "state-failed", message: "The settings and their saved summary need recovery. No deploy was started.") }
                throw error
            }
            return Self.masked(env)
        }
    }
    private func domains(_ server: String, _ app: String, _ request: NativeRPCValue) async throws -> NativeRPCValue {
        let raw = try request["domains"].requireArray("Addresses"), store = self.store, caddy = self.caddy
        guard !raw.isEmpty, raw.count <= 20 else { throw NativeRPCError.invalidArguments("Choose between 1 and 20 addresses.") }
        let names = try raw.map { try $0.requireString("Address", nonempty: true) }
        return try await store.withLock(server, app) {
            let old = try await store.read(server, app)
            guard old["kind"].string == "app" else { throw NativeRPCError.invalidArguments("Only web apps have public addresses.") }
            guard old["pendingDeploymentId"].isNullish else { throw NativeRPCError(code: "conflict", message: "An interrupted address or deploy change needs recovery first.") }
            for domain in names { guard try await caddy.check(serverID: server, domain: domain)["pointsHere"].bool == true else { throw NativeRPCError(code: "dns-mismatch", message: "An address does not point to this server yet. Follow its DNS instructions first.") } }
            let active = (old["deployments"].elements ?? []).first { $0["id"] == old["activeDeploymentId"] }
            let port = try active.map { try BackendAppsDeploy.port($0["port"]) }
            if let active, let upstream = active["upstream"].string, let port {
                let intent = old.setting("pendingDeploymentId", .string("domain-recovery-" + UUID().uuidString.lowercased())).setting("pendingDomains", .array(names.map(NativeRPCValue.string)))
                try await store.write(server, app, intent)
                do { try await caddy.swap(serverID: server, appID: app, domains: names, upstream: upstream, port: port) }
                catch {
                    if (error as? NativeRPCError)?.details["routeUncertain"].bool != true { try? await store.write(server, app, old) }
                    throw error
                }
            } else if old["activeDeploymentId"].string != nil { throw NativeRPCError(code: "state-failed", message: "The current app's address details need recovery.") }
            let updatedRows = (old["deployments"].elements ?? []).map { $0["id"] == old["activeDeploymentId"] ? $0.setting("domains", .array(names.map(NativeRPCValue.string))) : $0 }
            let next = old.setting("domains", .array(names.map(NativeRPCValue.string))).setting("address", .string("https://" + names[0])).setting("deployments", .array(updatedRows))
            do { try await store.write(server, app, next) }
            catch {
                if let active, let upstream = active["upstream"].string, let port {
                    do { try await caddy.swap(serverID: server, appID: app, domains: (old["domains"].elements ?? []).compactMap(\.string), upstream: upstream, port: port); try await store.write(server, app, old) }
                    catch { throw NativeRPCError(code: "route-failed", message: "The app's address and saved state need recovery before another change.") }
                }
                throw error
            }
            return BackendAppsStore.publicRecord(next)
        }
    }
    private func restart(_ server: String, _ app: String) async throws -> NativeRPCValue {
        let store = self.store, runtime = self.runtime
        return try await store.withLock(server, app) {
            let record = try await store.read(server, app), id = try Self.containerID(record)
            let inspected = try await runtime.docker(server, "GET", "/containers/\(id)/json", nil)
            guard inspected.ok, let detail = try? inspected.value(), detail["Config"]["Labels"]["io.terminaldeck.app"].string == app, detail["Config"]["Labels"]["io.terminaldeck.managed"].string == "true" else { throw NativeRPCError(code: "conflict", message: "This running service is not owned by the selected app.") }
            let response = try await runtime.docker(server, "POST", "/containers/\(id)/restart?t=10", nil)
            guard response.ok else { throw BackendAppsRuntime.unavailable("The app could not be restarted.") }
            let checked = try await runtime.docker(server, "GET", "/containers/\(id)/json", nil)
            guard checked.ok, let detail = try? checked.value(), let running = detail["State"]["Running"].bool else { throw BackendAppsRuntime.unavailable("Restart was requested, but the app's current state could not be checked.") }
            let failed = detail["State"]["Health"]["Status"].string == "unhealthy"
            let next = record.setting("status", .string(failed ? "failed" : (running ? "running" : "stopped"))).setting("updatedAt", .number(runtime.now()))
            try await store.write(server, app, next)
            return BackendAppsStore.publicRecord(next)
        }
    }
    private func remove(_ server: String, _ app: String, confirmation: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        let record = try await store.read(server, app)
        guard record["name"].string == confirmation else { throw NativeRPCError(code: "confirmation-required", message: "Type this app's exact name before removing it.") }
        if record["autoDeploy"].bool == true { _ = try await autoDeploy.apply(serverID: server, appID: app, enabled: false, context: context) }
        if record["backupPolicy"]["enabled"].bool == true { _ = try await backups.policy(serverID: server, appID: app, request: BackendAppsValidation.object([("enabled", .bool(false))])) }
        let store = self.store, caddy = self.caddy, runtime = self.runtime
        return try await store.withLock(server, app) {
            let latest = try await store.read(server, app)
            guard latest["name"].string == confirmation else { throw NativeRPCError(code: "confirmation-required", message: "The app name changed. Confirm its current name.") }
            guard latest["autoDeploy"].bool != true, latest["pendingAutoDeploy"].isNullish,
                  latest["backupPolicy"]["enabled"].bool != true else { throw NativeRPCError(code: "conflict", message: "A scheduled app action changed before removal. Disable it and try again.") }
            let filters = BackendAppsValidation.object([("label", .array([.string("io.terminaldeck.app=" + app), .string("io.terminaldeck.managed=true")]))]).compact.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
            let listed = try await runtime.docker(server, "GET", "/containers/json?all=true&filters=" + filters, nil)
            guard listed.ok, let rows = try listed.value().elements else { throw BackendAppsRuntime.unavailable("The app's running services could not be checked.") }
            for row in rows { guard row["Labels"]["io.terminaldeck.app"].string == app, row["Labels"]["io.terminaldeck.managed"].string == "true" else { throw NativeRPCError(code: "conflict", message: "A service is not owned by this app, so removal stopped.") } }
            if latest["kind"].string == "app" { try await caddy.remove(serverID: server, appID: app) }
            for row in rows {
                let id = try BackendAppsValidation.identifier(row["Id"].requireString("Service ID", nonempty: true))
                guard try await runtime.docker(server, "DELETE", "/containers/\(id)?force=true&v=false", nil).ok else { throw BackendAppsRuntime.unavailable("App removal stopped because one service could not be removed. Saved data is still present.") }
            }
            try await store.archiveLocked(server, app)
            return BackendAppsValidation.object([("removed", .bool(true)), ("dataPreserved", .bool(true)), ("message", .string("App removed. Its saved data and backups were kept for recovery."))])
        }
    }
    private func watch(_ server: String, _ app: String, streamID: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard publish != nil else { throw BackendAppsRuntime.unavailable("Live app logs need an event connection for this window.") }
        _ = try BackendAppsValidation.identifier(streamID)
        guard streams[streamID] == nil else { throw NativeRPCError(code: "conflict", message: "That log view is already open.") }
        let record = try await store.read(server, app), container = try Self.containerID(record)
        let inspection = try await ownedService(server, app: app, container: container)
        let secrets = Array(try await store.environment(server, app).values) + Self.inspectSecrets(inspection)
        streams[streamID] = .init(owner: context.ownerID, server: server, app: app, secrets: secrets)
        do {
            let subscription = try await runtime.watchLogs(server, container) { [weak self] event in await self?.logEvent(streamID, event) }
            guard streams[streamID] != nil else { await subscription.cancelAndWait(); throw NativeRPCError(code: "cancelled", message: "The log view was closed.") }
            streams[streamID]?.subscription = subscription
        } catch { streams[streamID] = nil; throw error }
        return BackendAppsValidation.object([("streamId", .string(streamID))])
    }
    private func logText(_ id: String, _ text: String) async {
        guard var stream = streams[id] else { return }
        stream.pending += text
        guard stream.pending.utf8.count <= 262_144 else { streams[id] = nil; stream.subscription?.cancel(); await logEnd(id, stream: stream, reason: "overflow"); return }
        // Hold incomplete lines so a credential split over transport chunks
        // is masked before it reaches a native window or an agent.
        guard let end = stream.pending.lastIndex(of: "\n") else { streams[id] = stream; return }
        let safe = BackendAppsValidation.mask(String(stream.pending[...end]), secrets: stream.secrets)
        stream.pending = String(stream.pending[stream.pending.index(after: end)...]); streams[id] = stream
        try? await publish?("apps:logs", BackendAppsValidation.object([("serverId", .string(stream.server)), ("appId", .string(stream.app)), ("streamId", .string(id)), ("text", .string(safe))]), stream.owner)
    }
    private func logEvent(_ id: String, _ event: BackendAppsLogEvent) async {
        switch event {
        case .text(let text): await logText(id, text)
        case .ended(let failed):
            guard let stream = streams.removeValue(forKey: id) else { return }
            if !stream.pending.isEmpty { try? await publish?("apps:logs", BackendAppsValidation.object([("serverId", .string(stream.server)), ("appId", .string(stream.app)), ("streamId", .string(id)), ("text", .string(BackendAppsValidation.mask(stream.pending, secrets: stream.secrets)))]), stream.owner) }
            stream.subscription?.cancel(); await logEnd(id, stream: stream, reason: failed ? "error" : "eof")
        }
    }
    private func logEnd(_ id: String, stream: LogStream, reason: String) async {
        try? await publish?("apps:logs:end", BackendAppsValidation.object([("serverId", .string(stream.server)), ("appId", .string(stream.app)), ("streamId", .string(id)), ("reason", .string(reason))]), stream.owner)
    }
    private func deploymentEvent(_ server: String, _ app: String, context: NativeRPCContext, action: @Sendable () async throws -> NativeRPCValue) async throws -> NativeRPCValue {
        let base = BackendAppsValidation.object([("serverId", .string(server)), ("appId", .string(app))])
        try? await publish?("apps:deployment", base.setting("phase", .string("starting")).setting("message", .string("Deploy started.")), context.ownerID)
        do {
            let value = try await action()
            try? await publish?("apps:deployment", base.setting("deploymentId", value["id"]).setting("phase", .string("running")).setting("message", .string("Deploy finished.")), context.ownerID)
            return value
        } catch {
            try? await publish?("apps:deployment", base.setting("phase", .string("failed")).setting("message", .string("Deploy did not finish. Check the app's saved deploys.")), context.ownerID)
            throw error
        }
    }
    public func disconnect(ownerID: String) async { let ids = streams.filter { $0.value.owner == ownerID }.map(\.key); for id in ids { let stream = streams.removeValue(forKey: id); await stream?.subscription?.cancelAndWait() } }
    /// Only a verified existing helper/ingress may call this. It performs HMAC
    /// verification and obtains a new approval for this exact push before I/O.
    public func receivePush(serverID: String, appID: String, headers: [BackendAppsPushHeader], body: Data, context: NativeRPCContext) async throws -> NativeRPCValue {
        try await autoDeploy.receive(serverID: serverID, appID: appID, headers: headers, body: body, context: context)
    }
    public func disconnect(serverID: String) async {
        let ids = streams.filter { $0.value.server == serverID }.map(\.key)
        for id in ids { if let stream = streams.removeValue(forKey: id) { await stream.subscription?.cancelAndWait(); await logEnd(id, stream: stream, reason: "closed") } }
    }
    public func shutdown() async { let old = streams; streams.removeAll(); for stream in old.values { await stream.subscription?.cancelAndWait() } }
    private static func text(_ value: NativeRPCValue, _ key: String) throws -> String { try value[key].requireString(key, nonempty: true) }
    private func text(_ value: NativeRPCValue, _ key: String) throws -> String { try Self.text(value, key) }
    private static func containerID(_ record: NativeRPCValue) throws -> String {
        let active = (record["deployments"].elements ?? []).first { $0["id"] == record["activeDeploymentId"] }
        guard let id = record["containerId"].string ?? active?["containerId"].string else { throw BackendAppsRuntime.unavailable("This app has no running service yet. Deploy it first.") }
        return try BackendAppsValidation.identifier(id)
    }
    private func ownedService(_ server: String, app: String, container: String) async throws -> NativeRPCValue {
        let response = try await runtime.docker(server, "GET", "/containers/\(container)/json", nil)
        guard response.ok, let value = try? response.value(), value["Config"]["Labels"]["io.terminaldeck.app"].string == app, value["Config"]["Labels"]["io.terminaldeck.managed"].string == "true" else { throw NativeRPCError(code: "conflict", message: "This running service is not owned by the selected app.") }
        return value
    }
    private func readObserved(_ server: String, _ app: String) async throws -> NativeRPCValue {
        var record = try await store.read(server, app)
        if record["containerId"].isNullish && record["activeDeploymentId"].isNullish { return BackendAppsStore.publicRecord(record) }
        let container = try Self.containerID(record)
        let response = try await runtime.docker(server, "GET", "/containers/\(container)/json", nil)
        if response.status == 404 { return BackendAppsStore.publicRecord(record.setting("status", .string("stopped"))).setting("observedAt", .number(runtime.now())) }
        guard response.ok, let value = try? response.value(), value["Config"]["Labels"]["io.terminaldeck.app"].string == app, value["Config"]["Labels"]["io.terminaldeck.managed"].string == "true", let running = value["State"]["Running"].bool else { throw BackendAppsRuntime.unavailable("The app's current running state could not be checked.") }
        record = record.setting("status", .string(value["State"]["Health"]["Status"].string == "unhealthy" ? "failed" : (running ? "running" : "stopped")))
        return BackendAppsStore.publicRecord(record).setting("observedAt", .number(runtime.now()))
    }
    private func listObserved(_ server: String) async throws -> NativeRPCValue {
        let records = try await store.list(server)
        guard !records.isEmpty else { return .array([]) }
        let filters = BackendAppsValidation.object([("label", .array([.string("io.terminaldeck.managed=true")]))]).compact.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let response = try await runtime.docker(server, "GET", "/containers/json?all=true&filters=" + filters, nil)
        guard response.ok, let value = try? response.value(), let services = value.elements else { throw BackendAppsRuntime.unavailable("The apps' current running state could not be checked.") }
        var result: [NativeRPCValue] = []
        for var record in records {
            if !record["containerId"].isNullish || !record["activeDeploymentId"].isNullish {
                let container = try Self.containerID(record)
                if let service = services.first(where: { $0["Id"].string == container && $0["Labels"]["io.terminaldeck.app"].string == record["id"].string && $0["Labels"]["io.terminaldeck.managed"].string == "true" }) {
                    guard let state = service["State"].string, ["running", "paused", "restarting", "created", "exited", "dead", "removing"].contains(state) else { throw BackendAppsRuntime.unavailable("An app's current running state could not be read safely.") }
                    let unhealthy = service["Status"].string?.contains("(unhealthy)") == true
                    record = record.setting("status", .string(unhealthy ? "failed" : (state == "running" ? "running" : (state == "restarting" ? "deploying" : "stopped"))))
                } else { record = record.setting("status", .string("stopped")) }
            }
            result.append(BackendAppsStore.publicRecord(record).setting("observedAt", .number(runtime.now())))
        }
        return .array(result)
    }
    private static func inspectSecrets(_ value: NativeRPCValue) -> [String] {
        (value["Config"]["Env"].elements ?? []).compactMap { entry in
            guard let text = entry.string, let equal = text.firstIndex(of: "=") else { return nil }
            return String(text[text.index(after: equal)...])
        }
    }
    private func containerID(_ record: NativeRPCValue) throws -> String { try Self.containerID(record) }
    private static func masked(_ env: [String: String]) -> NativeRPCValue { .array(env.keys.sorted().map { BackendAppsValidation.object([("key", .string($0)), ("value", .string("••••••••")), ("secret", .bool(true))]) }) }
    private func masked(_ env: [String: String]) -> NativeRPCValue { Self.masked(env) }
}
