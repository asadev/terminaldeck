import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Retained demand-driven owners. Call completion, disconnect and app shutdown
/// use the same services' owner cleanup; an expired ticket cannot orphan a stream.
actor NativeServerControlRuntime {
    let docker: BackendDockerService
    let apps: BackendAppsChannels
    let data: BackendAppsDataChannels
    let connections: BackendDockerMCPConnections
    let recovery: BackendAppsMCPRecoveryAuthority
    private let stopRequests: @Sendable () async -> Void
    init(docker: BackendDockerService, apps: BackendAppsChannels, data: BackendAppsDataChannels, connections: BackendDockerMCPConnections,
         recovery: BackendAppsMCPRecoveryAuthority, stopRequests: @escaping @Sendable () async -> Void) {
        self.docker = docker; self.apps = apps; self.data = data; self.connections = connections
        self.recovery = recovery
        self.stopRequests = stopRequests
    }
    func disconnect(ownerID: String) async {
        await docker.disconnect(ownerID: ownerID); await apps.disconnect(ownerID: ownerID)
    }
    func shutdown() async {
        await recovery.stopAccepting()
        await stopRequests()
        await apps.shutdown(); await docker.shutdown(); await recovery.shutdown(); await connections.clear()
    }
}

extension NativeCompositionProduction {
    /// The server's own address. A server saved by its number address is that address, so no
    /// command runs; otherwise the authenticated SSH connection reports it (`observe`), because
    /// DNS answers for a saved host are not proof that every address belongs to this server.
    nonisolated static func connectedAddresses(saved address: String, observe: () async throws -> BackendServersRunResult) async throws -> [String] {
        if let numeric = BackendAppsMCPDNS.numericAddress(address) { return [numeric] }
        let observed = try await observe()
        guard observed.code == 0, !observed.truncated else {
            throw NativeRPCError(code: "unavailable", message: "The connected server address could not be verified.")
        }
        let fields = observed.stdout.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 4, let numeric = BackendAppsMCPDNS.numericAddress(String(fields[2])) else {
            throw NativeRPCError(code: "unavailable", message: "The connected server did not report a usable address.")
        }
        return [numeric]
    }

    func installServerControl() async throws {
        guard NativeServerControlRelease.enabled else { return }
        guard let servers = serversOwner, let authority, let core, let clients else {
            throw NativeRPCError(code: "unavailable", message: "Server control needs the existing server, caller and core owners.")
        }
        let registry = root.registry, joins = self.joins
        // On (SRV2, 2026-10-09): the real-authority recovery kernel covers in-process failures, and
        // every locked change keeps a server-side journal that the server itself undoes (or, for a
        // deploy, resumes) when the change stops halfway — BackendAppsSRV2TxnRecovery, live-proven.
        let transactionRecoveryEnabled = true
        let advertisedFeatures: Set<String> = transactionRecoveryEnabled
            ? ["apps", "deploy", "rollback", "settings", "domains", "databases", "backups", "logs", BackendAppsDataChannels.recoveryFeature]
            : ["apps", "logs"]
        let caller = NativeCompositionServerCaller(authority: authority, joins: joins)
        let connection = BackendDockerMCPConnections(servers: servers, home: configuration.homeDirectory)
        let serverRows = await servers.room.store
        // Per-server AI app access and Look only both read the saved server row.
        let approval = BackendDockerMCPServerApproval(authority: authority, consent: core.consent,
            knownServer: { try await servers.room.knows($0) },
            keyAllowed: { key, target in target == "local" ? false : (try serverRows.get(target)?.aiKeyIDs?.contains(key) == true) },
            lookOnly: { try serverRows.get($0)?.isLookOnly == true })
        let recoveryNamespace = try BackendAppsMCPRecoveryNamespace(stateRoot: "/var/lib/terminaldeck/apps",
            resourcePrefix: "terminaldeck", privateNetwork: "terminaldeck-apps",
            caddyAutosavePath: "/var/lib/caddy/terminaldeck/config/caddy/autosave.json")
        let recovery = BackendAppsMCPRecoveryAuthority(authority: authority, approval: approval,
            namespace: recoveryNamespace, factory: { scope, context, register in
                try await register(context)
                let pin = try await BackendDockerMCPRecoveryLease.acquire(servers: servers, serverID: scope.serverID,
                    lifetimeSeconds: scope.lifetimeSeconds)
                do {
                    try await register(context); try await pin.requireCurrent()
                    let client = BackendDockerClient(transport: pin.dockerTransport())
                    let caddy = pin.caddyTransport()
                    let check: @Sendable (String) async throws -> Void = { server in
                        guard server == scope.serverID else { throw NativeRPCError(code: "access-denied", message: "Recovery cannot change its captured server.") }
                        try await pin.requireCurrent()
                    }
                    return BackendAppsRecoveryTransport(execute: { server, command, input, timeout, maximum in
                        try await check(server)
                        return try await pin.execute(command: command, stdin: input, timeoutMilliseconds: timeout,
                                                     maximumOutputBytes: maximum)
                    }, docker: { server, method, path, body in
                        try await check(server)
                        return try await BackendDockerMCPConnections.appsHTTP(client: client, method: method, path: path, body: body)
                    }, caddy: { server, method, path, body in
                        try await check(server)
                        let result = try await caddy.request(.init(method: method, path: path, body: body ?? Data()))
                        return .init(status: result.status, body: result.body)
                    }, authorizeRegistration: { supplied in
                        try await register(supplied); try await pin.requireCurrent()
                    }, validateBinding: { try await pin.requireCurrent() }, close: { await pin.close() })
                } catch { await pin.close(); throw error }
            }, audit: { event in
                let formatter = ISO8601DateFormatter()
                _ = await core.log.record(.object([.init("at", .string(formatter.string(from: Date()))),
                    .init("id", .string(UUID().uuidString)), .init("action", .string("apps.recovery")),
                    .init("detail", .string("App recovery " + event.event)), .init("result", event.value)]))
                guard !(await core.log.broken()) else {
                    throw NativeRPCError(code: "unavailable", message: "App recovery could not be recorded.")
                }
            }, originalAction: { context in
                let native = try await authority.nativeCaller(context)
                return try await joins.nativeTool(native)
            })
        let recoveryKernel = await recovery.kernel()
        let home = configuration.homeDirectory
        // Every Docker target this caller may reach, or only the one asked for.
        let dockerTargets: @Sendable (NativeRPCContext, String?) async throws -> [BackendDockerTarget] = { context, only in
            // The channel's own approval already checked this caller. List only
            // the servers it may reach; leave the rest out instead of refusing.
            let who = context.caller == .nativeApp ? nil : try await authority.rpcCaller(context)
            let rows = BackendDockerMCPServerKeyScope.visible(try serverRows.list(), caller: who).filter { only == nil || $0.id == only }
            var targets: [BackendDockerTarget] = []
            // This Mac's Docker has no per-key grant yet, so AI app keys do not see it.
            if who?.kind != .key, let local = BackendDockerLocalDiscovery.discover(home: home), only == nil || local.id == only { targets.append(local) }
            for row in rows {
                let id = row.id, name = row.name
                let cached = await servers.room.cached(id)
                let prepared = await connection.platform(id)
                let platform = prepared ?? (cached?.facts.kernel.value?.lowercased().hasPrefix("linux") == true ? "linux" : "unknown")
                targets.append(.init(id: id, name: name, kind: "server", platform: platform, lookOnly: row.isLookOnly))
            }
            return targets
        }
        let docker = BackendDockerService(dependencies: .init(resolve: { target, _ in
            try await connection.client(target)
        }, targets: { context in try await dockerTargets(context, nil) },
        target: { id, context in try await dockerTargets(context, id).first }, authorize: { action, context in
            let named = action.confirmationName ?? action.resourceID ?? action.target
            let copied = (action.parameters["files"].elements ?? []).compactMap { $0["name"].string }.joined(separator: ", ")
            let summary = action.channel == "docker:install"
                ? "Install Docker on server \"\(action.target)\" using Docker's official installer.\n" + BackendDockerInstall.command
                : action.channel == "docker:containers:upload"
                ? "Copy \(copied) into \(action.parameters["folder"].string ?? "the working folder") in container \"\(named)\" on \"\(action.target)\". Existing files are not overwritten."
                : action.channel.replacingOccurrences(of: ":", with: " ") + " \"" + named + "\" on \"" + action.target + "\"."
            let args = NativeRPCValue.object([.init("target", .string(action.target)),
                .init("name", .string(named)), .init("destructive", .bool(action.destructive))])
            // Look only is refused before any approval, installer preparation or I/O.
            try await approval.checkLookOnly(target: action.target.isEmpty ? nil : action.target,
                changing: action.writesServer || action.channel == "docker:install")
            if action.channel == "docker:install" || action.channel == "docker:install:preview" {
                try await approval.authorize(context: context, channel: action.channel, target: action.target,
                    changing: false, summary: summary, arguments: args)
                try await connection.prepareInstaller(action.target)
            }
            try await approval.authorize(context: context, channel: action.channel,
                target: action.target.isEmpty ? nil : action.target, changing: action.writesServer,
                summary: summary, arguments: args)
        }, install: { target, command, _ in
            guard command == BackendDockerInstall.command else { throw NativeRPCError(code: "access-denied", message: "Only Docker's official installer is supported.") }
            let facts = try await servers.room.measured(target)
            guard facts.kernel.value?.lowercased().hasPrefix("linux") == true,
                  facts.privilege.value == .yes || facts.privilege.value == .sudoNoPassword else {
                throw NativeRPCError(code: "unavailable", message: "Installing Docker needs a Linux administrator connection.")
            }
            let prefix = facts.privilege.value == .yes ? "sh -c " : "sudo -n sh -c "
            let result = try await servers.connections.withConnection(target) {
                try await $0.exec(command: prefix + BackendServersConnections.quote(command), stdin: nil,
                    timeoutMilliseconds: 300_000, maximumOutputBytes: 16_384)
            }
            guard result.code == 0, !result.truncated else { throw NativeRPCError(code: "unavailable", message: "Docker's installer did not finish successfully.") }
        }, secretValues: { _, _ in await clients.githubAuth?.secrets() ?? [] }))

        // This closure is called inside the real registry's scoped dispatch.
        // Recheck current caller/server provenance before every pipeline I/O.
        let checkIO: @Sendable (String) async throws -> NativeRPCContext = { server in
            guard !server.isEmpty, server != "local" else {
                throw NativeRPCError(code: "access-denied", message: "Apps require a saved server connection.")
            }
            guard let context = NativeCompositionCallContext.rpc else {
                throw NativeRPCError(code: "access-denied", message: "This server operation has no current caller.")
            }
            try await approval.authorize(context: context, channel: "apps:transport", target: server,
                changing: false, summary: "Read server connection", arguments: .object([]))
            return context
        }
        let runtime = BackendAppsRuntime(execute: { server, command, stdin, timeout, maximum in
            _ = try await checkIO(server)
            return try await servers.connections.withConnection(server) {
                try await $0.exec(command: command, stdin: stdin, timeoutMilliseconds: timeout, maximumOutputBytes: maximum)
            }
        }, docker: { server, method, path, body in
            _ = try await checkIO(server)
            return try await connection.appsHTTP(server, method: method, path: path, body: body)
        }, caddy: { server, method, path, body in
            _ = try await checkIO(server)
            let transport = BackendDockerHTTPTransport(opener: { try await servers.connections.caddyAdmin(server) }, host: "127.0.0.1:2019")
            let response = try await transport.request(.init(method: method, path: path, body: body ?? Data()))
            return .init(status: response.status, body: response.body)
        }, githubCredential: { server in
            _ = try await checkIO(server)
            guard let auth = clients.githubAuth else { throw NativeRPCError(code: "unavailable", message: "The existing GitHub sign-in owner is unavailable.") }
            return await auth.gitCredential()?.password
        }, serverAddresses: { server in
            let context = try await checkIO(server)
            let records = try await servers.room.list(caller.resolve(context))
            guard let address = records.elements?.first(where: { $0["id"].string == server })?["address"].string else {
                throw NativeRPCError(code: "unavailable", message: "The saved server address is unavailable.")
            }
            return try await NativeCompositionProduction.connectedAddresses(saved: address) {
                try await servers.connections.run(server, argv: ["sh", "-c", "printf '%s' \"$SSH_CONNECTION\""])
            }
        }, resolveDNS: BackendAppsMCPDNS.resolve, watchLogs: { server, container, receive in
            _ = try await checkIO(server)
            return try await connection.logs(server, container: container, receive: receive)
        }, features: advertisedFeatures, recovery: recoveryKernel)
        let store = BackendAppsStore(runtime: runtime)
        let appAuthorize: BackendAppsChannels.Authorize = { action, context in
            if BackendAppsServerChannels.nativeOnlyChannels.contains(action.channel) { try authority.requireLocalUI(context) }
            // SETTINGS-TRUTH row 98: "Show only these apps" — an app hidden on this server is refused on every Apps
            // channel (the screens and the apps.* AI tools), before any approval or change.
            try await BackendServersShownApps.shared.requireShown(serverID: action.serverID, appID: action.appID) {
                guard let app = action.appID else { return nil }
                return (try? await store.read(action.serverID, app))?["name"].string
            }
            if BackendAppsChannels.writeChannels.union(BackendAppsDataChannels.writeChannels).union(BackendAppsSRV2Channels.allWriteChannels).union(BackendAppsServerChannels.writeChannels).contains(action.channel), !transactionRecoveryEnabled {
                throw NativeRPCError(code: "unavailable", message: "App changes are not available in this local build yet.")
            }
            try await recovery.authorizeAndRecord(action: action, context: context)
        }
        let appPublish: BackendAppsChannels.Publish = { channel, value, owner in
            try await registry.publish(channel, arguments: [value], ownerID: owner)
            BackendDockerMCPReceiver.apps(channel: channel, value: value)
        }
        let apps = BackendAppsChannels(runtime: runtime, store: store, authorize: appAuthorize, publish: appPublish)
        let data = BackendAppsDataChannels(runtime: runtime, store: store, authorize: appAuthorize, publish: appPublish)
        let srv2 = BackendAppsSRV2Channels(runtime: runtime, store: store,
            authorize: BackendAppsSRV2Channels.authorize(using: appAuthorize), publish: appPublish,
            fallback: { channel, request, context in try await apps.invoke(channel, request: request, context: context) },
            routerProbe: BackendAppsSRV2Channels.srv1RouterProbe(runtime: runtime))
        let srv1 = try BackendAppsServerService(runtime: runtime)
        let srv1Channels = BackendAppsServerChannels(service: srv1, authorize: appAuthorize,
            prepareDeploys: { server, app in try await srv2.prepareServerDeploys(serverID: server, appID: app) })
        let srv1Owner = "native-apps-server"
        let owner = "native-composition:server-control"
        let graph = NativeServerControlRuntime(docker: docker, apps: apps, data: data, connections: connection, recovery: recovery,
            stopRequests: {
                await registry.stopOwnerAndWait(srv1Owner)
                await registry.stopOwnerAndWait(owner)
            })
        do {
            let dockerChannels = try await BackendDockerChannels.register(registry: registry, service: docker, ownerID: owner)
            let finished: @Sendable (NativeRPCContext) async -> Void = { context in
                await recovery.finish(requestID: context.requestID, ownerID: context.ownerID)
            }
            try await BackendAppsChannels.register(registry: registry, service: apps, ownerID: owner,
                excluding: BackendAppsDataChannels.inheritedChannels.union(BackendAppsSRV2Channels.replacedChannels).union(["apps:remove", "apps:auto-deploy:apply"]),
                finished: finished)
            // Keep APE's exact removal/approval/recovery, then remove only SRV2's extra route.
            try await registry.register("apps:remove", ownerID: owner) { context, args in
                guard args.count == 1, args[0].fields != nil else {
                    throw NativeRPCError.invalidArguments("App actions expect one request object.")
                }
                do {
                    let value = try await apps.invoke("apps:remove", request: args[0], context: context)
                    if value["removed"].bool == true {
                        let server = try args[0]["serverId"].requireString("serverId", nonempty: true)
                        let app = try args[0]["appId"].requireString("appId", nonempty: true)
                        _ = try? await srv1.forgetApp(serverID: server, appID: app)
                        await srv2.removeExtraRoutes(serverID: server, appID: app)
                    }
                    await finished(context)
                    return value
                } catch { await finished(context); throw error }
            }
            // The compatibility tool keeps its original caller; the server now owns signed push deploys.
            try await registry.register("apps:auto-deploy:apply", ownerID: owner) { context, args in
                guard args.count == 1, args[0].fields != nil else {
                    throw NativeRPCError.invalidArguments("App actions expect one request object.")
                }
                do {
                    let value = try await srv1Channels.invoke("apps:server:autodeploy:apply", request: args[0], context: context)
                    await finished(context); return value
                } catch { await finished(context); throw error }
            }
            try await BackendAppsDataChannels.register(registry: registry, service: data, ownerID: owner, finished: finished)
            try await BackendAppsServerChannels.register(registry: registry, service: srv1Channels,
                ownerID: srv1Owner, finished: finished)

            try await BackendAppsSRV2Channels.register(registry: registry, service: srv2, ownerID: owner,
                includeReplaced: true, finished: finished)
            let gate = try joins.deckToolsGate()
            let access = BackendDockerMCPAccess(rpcContext: { native in
                let rpc = try await authority.rpc(native)
                _ = native.cancellation.observe { Task { await graph.disconnect(ownerID: rpc.ownerID) } }
                return rpc
            }, authorize: { native, _, _, tier, sentence, _ in
                try await gate.authorize(native, tier, sentence, tier != .read)
            }, noteResult: gate.noteResult)
            func scoped(_ entries: [(BackendMCPTool, BackendNativeMCPServer.Handler)]) -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
                entries.map { tool, handler in
                    let guarded: BackendNativeMCPServer.Handler = { native, args in
                        let rpc = try await authority.rpc(native)
                        do {
                            let reply = try await handler(native, args)
                            await graph.disconnect(ownerID: rpc.ownerID)
                            await recovery.finish(requestID: rpc.requestID, ownerID: rpc.ownerID)
                            return reply
                        } catch {
                            await graph.disconnect(ownerID: rpc.ownerID)
                            await recovery.finish(requestID: rpc.requestID, ownerID: rpc.ownerID)
                            throw error
                        }
                    }
                    return (tool, guarded)
                }
            }
            let dockerBundle = try BackendDockerMCPComposition.bundle(
                registrations: scoped(BackendDockerMCP.contribution(registry: registry, access: access)), joins: joins,
                validate: { try BackendDockerMCP.validate(tool: $0, arguments: $1) },
                summary: { (try? BackendDockerMCP.summary(tool: $0, arguments: $1)) ?? "Use Docker" },
                preflight: { context, tool, args in
                    try await approval.checkScope(caller: context.caller, target: args["target"].string,
                        changing: BackendDockerMCP.changes(tool: tool))
                    try await BackendDockerMCP.preflight(tool: tool, arguments: args, registry: registry)
                    if tool == "docker.install" || tool == "docker.install.preview" {
                        try await connection.prepareInstaller(args["target"].requireString("target", nonempty: true))
                    }
                    if BackendDockerMCP.isDestructive(tool: tool) {
                        _ = try await joins.contexts.invoke(handler: { native, _ in
                            let rpc = try await authority.rpc(native)
                            try await BackendDockerMCP.validateConfirmation(tool: tool, arguments: args, registry: registry, context: rpc)
                            return .value(.object([]))
                        }, arguments: args, context: context)
                    }
                })
            let appsBundle = try BackendDockerMCPComposition.bundle(
                registrations: scoped(BackendAppsMCP.contribution(registry: registry, access: access)), joins: joins,
                validate: { try BackendAppsMCP.validate(tool: $0, arguments: $1) },
                summary: { BackendAppsMCP.summary(tool: $0, arguments: $1) },
                preflight: { context, tool, args in
                    guard args["serverId"].string != "local" else {
                        throw NativeRPCError(code: "access-denied", message: "Apps require a saved server connection.")
                    }
                    guard let row = BackendAppsMCP.definitions().first(where: { $0.id == tool }), await registry.has(row.channel) else {
                        throw NativeRPCError(code: "unavailable", message: "This app operation is unavailable.")
                    }
                    try await approval.checkScope(caller: context.caller, target: args["serverId"].string, changing: row.tier != .read)
                    if row.tier != .read, !transactionRecoveryEnabled {
                        throw NativeRPCError(code: "unavailable", message: "App changes are not available in this local build yet.")
                    }
                    if BackendAppsMCP.isDestructive(tool: tool) {
                        _ = try await joins.contexts.invoke(handler: { native, _ in
                            let rpc = try await authority.rpc(native)
                            try await BackendAppsMCP.validateConfirmation(tool: tool, arguments: args,
                                registry: registry, context: rpc)
                            return .value(.object([]))
                        }, arguments: args, context: context)
                    }
                })
            try joins.replaceContributions(owner: "server-control", [dockerBundle, appsBundle], policiesWrapped: true)
            try await root.retain(.init(name: "server-control", domains: ["docker", "apps"], ownerID: owner,
                invokes: Set(dockerChannels).union(BackendAppsChannels.invokeChannels).union(BackendAppsDataChannels.invokeChannels).union(BackendAppsSRV2Channels.invokeChannels),
                events: BackendDockerChannels.eventChannels.union(BackendAppsChannels.eventChannels),
                stop: { await graph.shutdown(); try joins.replaceContributions(owner: "server-control", [], policiesWrapped: true) }))
            try await root.retain(.init(name: "apps-server", domains: ["apps-server"], ownerID: srv1Owner,
                invokes: BackendAppsServerChannels.invokeChannels, events: [],
                stop: { await registry.stopOwnerAndWait(srv1Owner); await registry.removeOwner(srv1Owner) }))
            serverControl = graph
        } catch {
            await graph.shutdown(); await registry.removeOwner(owner); await registry.removeOwner(srv1Owner)
            try? joins.replaceContributions(owner: "server-control", [], policiesWrapped: true)
            throw error
        }
    }

    func releaseServerControlOwner(_ ownerID: String) async { await serverControl?.disconnect(ownerID: ownerID) }
}
