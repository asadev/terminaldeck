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
    func installServerControl() async throws {
        guard NativeServerControlRelease.enabled else { return }
        guard let servers = serversOwner, let authority, let core, let clients else {
            throw NativeRPCError(code: "unavailable", message: "Server control needs the existing server, caller and core owners.")
        }
        let registry = root.registry, joins = self.joins
        // Enabled only after the real-authority recovery and fake gate pass.
        let transactionRecoveryEnabled = false
        let advertisedFeatures: Set<String> = transactionRecoveryEnabled
            ? ["apps", "deploy", "rollback", "settings", "domains", "databases", "backups", "logs", BackendAppsDataChannels.recoveryFeature]
            : ["apps", "logs"]
        let caller = NativeCompositionServerCaller(authority: authority, joins: joins)
        let connection = BackendDockerMCPConnections(servers: servers, home: configuration.homeDirectory)
        let approval = BackendDockerMCPServerApproval(authority: authority, consent: core.consent,
            knownServer: { try await servers.room.knows($0) })
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
        let docker = BackendDockerService(dependencies: .init(resolve: { target, _ in
            try await connection.client(target)
        }, targets: { context in
            let records = try await servers.room.list(caller.resolve(context))
            var targets: [BackendDockerTarget] = []
            if let local = BackendDockerLocalDiscovery.discover(home: home) { targets.append(local) }
            for row in records.elements ?? [] {
                guard let id = row["id"].string, let name = row["name"].string else { continue }
                let cached = await servers.room.cached(id)
                let prepared = await connection.platform(id)
                let platform = prepared ?? (cached?.facts.kernel.value?.lowercased().hasPrefix("linux") == true ? "linux" : "unknown")
                targets.append(.init(id: id, name: name, kind: "server", platform: platform))
            }
            return targets
        }, authorize: { action, context in
            let named = action.confirmationName ?? action.resourceID ?? action.target
            let summary = action.channel == "docker:install"
                ? "Install Docker on server \"\(action.target)\" using Docker's official installer.\n" + BackendDockerInstall.command
                : action.channel.replacingOccurrences(of: ":", with: " ") + " \"" + named + "\" on \"" + action.target + "\"."
            let args = NativeRPCValue.object([.init("target", .string(action.target)),
                .init("name", .string(named)), .init("destructive", .bool(action.destructive))])
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
            // Observe the authenticated SSH connection. DNS answers for a
            // saved host are not proof that every address belongs to this server.
            let observed = try await servers.connections.run(server, argv: ["sh", "-c", "printf '%s' \"$SSH_CONNECTION\""])
            guard observed.code == 0, !observed.truncated else {
                throw NativeRPCError(code: "unavailable", message: "The connected server address could not be verified.")
            }
            if let numeric = BackendAppsMCPDNS.numericAddress(address) { return [numeric] }
            let fields = observed.stdout.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 4, let numeric = BackendAppsMCPDNS.numericAddress(String(fields[2])) else {
                throw NativeRPCError(code: "unavailable", message: "The connected server did not report a usable address.")
            }
            return [numeric]
        }, resolveDNS: BackendAppsMCPDNS.resolve, watchLogs: { server, container, receive in
            _ = try await checkIO(server)
            return try await connection.logs(server, container: container, receive: receive)
        }, features: advertisedFeatures, recovery: recoveryKernel)
        let appAuthorize: BackendAppsChannels.Authorize = { action, context in
            if BackendAppsChannels.writeChannels.union(BackendAppsDataChannels.writeChannels).contains(action.channel), !transactionRecoveryEnabled {
                throw NativeRPCError(code: "unavailable", message: "App changes are not available in this local build yet.")
            }
            try await recovery.authorizeAndRecord(action: action, context: context)
        }
        let appPublish: BackendAppsChannels.Publish = { channel, value, owner in
            try await registry.publish(channel, arguments: [value], ownerID: owner)
            BackendDockerMCPReceiver.apps(channel: channel, value: value)
        }
        let store = BackendAppsStore(runtime: runtime)
        let apps = BackendAppsChannels(runtime: runtime, store: store, authorize: appAuthorize, publish: appPublish)
        let data = BackendAppsDataChannels(runtime: runtime, store: store, authorize: appAuthorize, publish: appPublish)
        let owner = "native-composition:server-control"
        let graph = NativeServerControlRuntime(docker: docker, apps: apps, data: data, connections: connection, recovery: recovery,
            stopRequests: { await registry.stopOwnerAndWait(owner) })
        do {
            let dockerChannels = try await BackendDockerChannels.register(registry: registry, service: docker, ownerID: owner)
            let finished: @Sendable (NativeRPCContext) async -> Void = { context in
                await recovery.finish(requestID: context.requestID, ownerID: context.ownerID)
            }
            try await BackendAppsChannels.register(registry: registry, service: apps, ownerID: owner,
                excluding: BackendAppsDataChannels.inheritedChannels, finished: finished)
            try await BackendAppsDataChannels.register(registry: registry, service: data, ownerID: owner, finished: finished)
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
                    try await approval.checkScope(caller: context.caller, target: args["target"].string)
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
                    try await approval.checkScope(caller: context.caller, target: args["serverId"].string)
                    guard let row = BackendAppsMCP.definitions().first(where: { $0.id == tool }), await registry.has(row.channel) else {
                        throw NativeRPCError(code: "unavailable", message: "This app operation is unavailable.")
                    }
                    if row.tier != .read, !transactionRecoveryEnabled {
                        throw NativeRPCError(code: "unavailable", message: "App changes are not available in this local build yet.")
                    }
                    if BackendAppsMCP.isDestructive(tool: tool) {
                        _ = try await joins.contexts.invoke(handler: { native, _ in
                            let rpc = try await authority.rpc(native)
                            let identity = NativeRPCValue.object([.init("serverId", args["serverId"]), .init("appId", args["appId"])])
                            let record = try await registry.invoke("apps:read", context: rpc, arguments: [identity])
                            guard record["name"].string == args["confirmation"].string else {
                                throw NativeRPCError(code: "confirmation-required", message: "Type the app's exact name to confirm this action.")
                            }
                            return .value(.object([]))
                        }, arguments: args, context: context)
                    }
                })
            try joins.replaceContributions(owner: "server-control", [dockerBundle, appsBundle], policiesWrapped: true)
            try await root.retain(.init(name: "server-control", domains: ["docker", "apps"], ownerID: owner,
                invokes: Set(dockerChannels).union(BackendAppsChannels.invokeChannels).union(BackendAppsDataChannels.invokeChannels),
                events: BackendDockerChannels.eventChannels.union(BackendAppsChannels.eventChannels),
                stop: { await graph.shutdown(); try joins.replaceContributions(owner: "server-control", [], policiesWrapped: true) }))
            serverControl = graph
        } catch {
            await graph.shutdown(); await registry.removeOwner(owner)
            try? joins.replaceContributions(owner: "server-control", [], policiesWrapped: true)
            throw error
        }
    }

    func releaseServerControlOwner(_ ownerID: String) async { await serverControl?.disconnect(ownerID: ownerID) }
}
