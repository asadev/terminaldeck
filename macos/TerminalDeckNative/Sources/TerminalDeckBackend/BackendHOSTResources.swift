import Foundation
import TerminalDeckNativeCore

/// One helper-owned account/hook/MCP graph. App clients may come and go;
/// only confirmed process drain authorizes final resource teardown.
public actor BackendHOSTResources {
    public nonisolated let chats: BackendHOSTChats
    public nonisolated let accounts: BackendHOSTAccountService
    public nonisolated let hooks: BackendHOSTHookService
    public nonisolated let mcp: BackendHOSTMCPPersistence
    public nonisolated let switches: BackendHOSTDeferredSwitch
    #if TD_HOST_ACCOUNT_BRIDGE
    public nonisolated let accountControl: BackendHOSTAccountControl
    #endif
    private let manager: BackendPTYManager
    private var observation: NativeRPCSubscription?
    private var stopped = false
    private var cleanupComplete = false
    private var cleanupTask: Task<Void, Error>?
    private var claimsAdopted = false
    private var claimAttachment: UUID?
    private var hookObservation: UUID?
    private var unconfirmedExits: Set<String> = []
    private var exitRetry: Task<Void, Never>?
    private let verifyClaims: @Sendable ([BackendSessionMeta]) async throws -> Bool
    private let confirmDescendants: @Sendable (String) async throws -> Bool
    private let openShim = BackendMacAppHandoffOpenShim(files: BackendMacAppHandoffShimDisk())

    private init(accounts: BackendHOSTAccountService, hooks: BackendHOSTHookService,
                 mcp: BackendHOSTMCPPersistence, hostInstance: UUID, manager: BackendPTYManager,
                 verifyClaims: @escaping @Sendable ([BackendSessionMeta]) async throws -> Bool,
                 confirmDescendants: @escaping @Sendable (String) async throws -> Bool,
                 metadataChanged: @escaping @Sendable (BackendSessionMeta) -> Void) {
        chats = BackendHOSTChats(manager: manager, directory: accounts.configuration.dataDirectory.appendingPathComponent("session-chats"))
        self.accounts = accounts; self.hooks = hooks; self.mcp = mcp; self.manager = manager
        self.verifyClaims = verifyClaims
        self.confirmDescendants = confirmDescendants
        #if TD_HOST_ACCOUNT_BRIDGE
        accountControl = BackendHOSTAccountControl(service: accounts, hostInstance: hostInstance,
            currentAttachment: { mcp.appAttachmentID() }, authorize: { request in
                let value = try NativeRPCValue.parseJSON(JSONEncoder().encode(request))
                let answer = try await mcp.invokeControl(operation: .accountAuthorize,
                    arguments: .object([.init("kind", .string("authorize")), .init("request", value)]))
                return try JSONDecoder().decode(BackendHOSTAccountControlApproval.self, from: answer.encodedJSON())
            }, providerResolver: { request in
                let value = try NativeRPCValue.parseJSON(JSONEncoder().encode(request))
                let answer = try await mcp.invokeControl(operation: .accountAuthorize,
                    arguments: .object([.init("kind", .string("provider")), .init("request", value)]))
                return try JSONDecoder().decode(BackendHOSTAccountControlProviderAnswer.self, from: answer.encodedJSON())
            }, sessionTitle: { id in manager.list().first { $0.id == id }?.title })
        #endif
        switches = BackendHOSTDeferredSwitch(accountService: accounts, manager: manager, changed: { event in
            if case .confirmed(let session) = event { metadataChanged(session) }
        })
    }
    public static func start(configuration: BackendAccountConfiguration, host: BackendHOSTProtocol.Hello,
                             manager: BackendPTYManager, realTools: [BackendMCPTool],
                             paths: BackendHOSTPaths? = nil,
                             nativeAccountOwnerDisabled: Bool,
                             makeHookCoordinator: @escaping BackendHOSTHookService.CoordinatorFactory,
                             peerBelongs: @escaping @Sendable (Int32, Int32) -> Bool,
                             additionalContext: @escaping @Sendable (BackendSessionHookEvent) async throws -> String?,
                             openLink: (@Sendable (URL, String?) async throws -> BackendSessionHookOpenAnswer)? = nil,
                             vaultCipher: (any BackendAccountVaultCipher)? = nil,
                             brokerFactory: (@Sendable (BackendAccountConfiguration, BackendAccountProfileStore, BackendAccountVault) async throws -> BackendAccountBroker)? = nil,
                             verifyClaims: @escaping @Sendable ([BackendSessionMeta]) async throws -> Bool,
                             confirmDescendants: @escaping @Sendable (String) async throws -> Bool,
                             metadataChanged: @escaping @Sendable (BackendSessionMeta) -> Void) async throws -> BackendHOSTResources {
        guard !manager.list().contains(where: { $0.exitCode == nil }), !realTools.isEmpty else {
            throw BackendHOSTFailure.invalid("Persistent services must be ready before the first hosted launch, with the real tool catalogue.")
        }
        let account = try await BackendHOSTAccountService.start(configuration: configuration,
            nativeAccountOwnerDisabled: nativeAccountOwnerDisabled, vaultCipher: vaultCipher, brokerFactory: brokerFactory)
        var relay: BackendHOSTAppRelayServer?
        var persistentMCP: BackendHOSTMCPPersistence?
        var hook: BackendHOSTHookService?
        do {
            let appRelay = try BackendHOSTAppRelayServer(paths: paths ?? BackendHOSTPaths(dataDirectory: configuration.dataDirectory), host: host)
            relay = appRelay
            let mcp = try BackendHOSTMCPPersistence(server: BackendNativeMCPServer(), relay: appRelay,
                userData: configuration.dataDirectory, sessionsDrained: {
                    guard !manager.list().contains(where: { $0.exitCode == nil }) else { return false }
                    return await manager.drain()
                })
            persistentMCP = mcp; try await mcp.installTools(realTools); _ = try await mcp.start()
            let hooks = try await BackendHOSTHookService.start(configuration: configuration, manager: manager, accounts: account,
                makeCoordinator: makeHookCoordinator, peerBelongs: peerBelongs, additionalContext: additionalContext, openLink: openLink)
            hook = hooks
            let owner = BackendHOSTResources(accounts: account, hooks: hooks, mcp: mcp, hostInstance: host.instance, manager: manager,
                verifyClaims: verifyClaims, confirmDescendants: confirmDescendants, metadataChanged: metadataChanged)
            try await owner.install()
            return owner
        } catch {
            try? await hook?.stop(afterProcessDrain: true); try? await persistentMCP?.stopAfterSessionsDrained()
            relay?.stop(); try? await account.stop(afterProcessDrain: true)
            throw error
        }
    }
    private func install() async throws {
        let endpoint = try await hooks.endpoint()
        let installed = try await openShim.write(dataRoot: accounts.configuration.dataDirectory.path, configPath: endpoint.configPath)
        manager.setOpenShim(directory: installed?.directory, browser: installed?.browser)
        observation = manager.remoteServeObserve { [weak self] value in
            Task { await self?.received(value.event) }
        }
        hookObservation = await hooks.observe { [weak self] value in
            Task { await self?.acceptedHook(value) }
        }
        #if TD_HOST_ACCOUNT_BRIDGE
        await hooks.observeAccepted { [weak self] event in
            Task { await self?.deliverAcceptedHook(event) }
        }
        #endif
    }
    #if TD_HOST_ACCOUNT_BRIDGE
    private func deliverAcceptedHook(_ event: BackendSessionHookEvent) async {
        _ = try? await mcp.invokeControl(operation: .hookContext, arguments: .object([.init("event", event.metadata)]))
    }
    #endif
    private func acceptedHook(_ value: BackendHOSTHookProjection) async {
        if let status = value.status { await switches.noteStatus(sessionID: value.sessionID, status: status) }
        await retryUnconfirmedExits()
    }
    private func received(_ event: BackendSessionEvent) async {
        if case .exit(let id, _) = event { await retryUnconfirmedExits(); await release(exited: id) }
    }
    /// 18 Oct (#80): an exit whose helper processes are not yet confirmed gone is kept, never dropped, and tried again
    /// on the next exit or hook and every few seconds, so its account seat, MCP files and hook state are released as
    /// soon as they are gone, not only when the whole host stops.
    private func release(exited id: String) async {
        // 18 Oct (#89): its agent has ended, so the account no longer counts as in use while its helpers finish.
        await accounts.accounts.agentEnded(sessionID: id)
        guard (try? await confirmDescendants(id)) == true else {
            if !stopped { unconfirmedExits.insert(id); scheduleExitRetry() }
            return
        }
        await switches.processExited(sessionID: id)
        await accounts.exited(sessionID: id); await mcp.releasePrepared(sessionID: id); await hooks.processExited(id)
    }
    private func retryUnconfirmedExits() async {
        for id in unconfirmedExits where !stopped { if unconfirmedExits.remove(id) != nil { await release(exited: id) } }
    }
    private func scheduleExitRetry() {
        guard exitRetry == nil else { return }
        exitRetry = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(BackendHOSTResources.exitRetrySeconds))
                guard !Task.isCancelled, let self, await self.retryExitsAgain() else { return }
            }
        }
    }
    private func retryExitsAgain() async -> Bool {
        await retryUnconfirmedExits()
        guard unconfirmedExits.isEmpty || stopped else { return true }
        exitRetry = nil; return false
    }
    static let exitRetrySeconds = 5
    public func detachApp() async { await accounts.detachApp(); await hooks.detachApp() }
    #if TD_HOST_ACCOUNT_BRIDGE
    public func keepWhileAppAttached() -> Bool { mcp.currentAppPID() != nil }
    public func finishStoppedSessions() async throws {
        guard !manager.list().contains(where: { $0.exitCode == nil }), await manager.drain(), try await accounts.externalSessionsDrained() else { throw BackendHOSTFailure.unavailable }
        for id in await accounts.liveSessionIDs() {
            guard try await confirmDescendants(id) else { throw BackendHOSTFailure.unavailable }
            unconfirmedExits.remove(id)
            await switches.processExited(sessionID: id)
            await accounts.exited(sessionID: id); await mcp.releasePrepared(sessionID: id); await hooks.processExited(id)
        }
    }
    #endif
    public func bindBeforeExec(_ launch: BackendHOSTProtocol.Launch, pid: Int32) async throws {
        claimsAdopted = false; claimAttachment = nil
        do {
            try Task.checkCancellation()
            if let handle = launch.accountHandle {
                try await accounts.bind(handle: handle, session: launch.metadata, pid: pid)
            } else if launch.metadata.profileId != nil {
                throw BackendHOSTFailure.invalid("This account launch has no host-owned reservation. The child was not executed.")
            }
            for lease in launch.mcpLeaseIDs ?? [] {
                try Task.checkCancellation()
                try await mcp.bindPrepared(lease, sessionID: launch.id, machineID: launch.machineID ?? "")
            }
            try Task.checkCancellation()
        } catch {
            await launchAbandoned(launch); throw error
        }
    }
    public func launchAbandoned(_ launch: BackendHOSTProtocol.Launch) async {
        if let handle = launch.accountHandle { await accounts.abandon(handle) }
        for lease in launch.mcpLeaseIDs ?? [] { await mcp.abandonPrepared(lease) }
    }
    public func readiness() -> BackendHOSTReadiness {
        var result = BackendHOSTReadiness()
        result.accountLeases = !stopped; result.hookEndpoint = !stopped; result.mcpGrantsAndFiles = !stopped
        result.pendingSwitches = !stopped
        result.taskAndReceiverClaims = claimsAdopted && claimAttachment != nil && claimAttachment == mcp.appAttachmentID()
        return result
    }
    public func invoke(_ method: String, payload: Data) async throws -> Data {
        #if TD_HOST_ACCOUNT_BRIDGE
        if method == "resources.shutdown" { try await stop(); return try NativeRPCValue.bool(true).encodedJSON() }
        #endif
        if method == "resources.closed" {
            guard cleanupComplete else { throw BackendHOSTFailure.invalid("Persistent resource cleanup is not complete.") }
            let releases = await accounts.shutdownReleases()
            let fields = releases.map { id, release -> NativeRPCValue.Field in
                let kind: String, detail: String?
                switch release {
                case .removed: kind = "removed"; detail = nil
                case .absent: kind = "absent"; detail = nil
                case .retainedForForeignProcess: kind = "foreign"; detail = nil
                case .retainedBecauseCaptureFailed(let message): kind = "capture-failed"; detail = message
                case .retainedNothingKept: kind = "nothing-kept"; detail = nil
                case .retainedRemovalFailed: kind = "remove-failed"; detail = nil
                }
                return .init(id, .object([.init("kind", .string(kind)), .init("detail", detail.map(NativeRPCValue.string) ?? .null)]))
            }
            return try NativeRPCValue.object([.init("closed", .bool(true)), .init("releases", .object(fields))]).encodedJSON()
        }
        guard !stopped else { throw BackendSessionFailure.closed }
        if method.hasPrefix("chats.") { return try await chats.invoke(method, payload: payload) }
        // 12 Oct: an account action (sign-in finishing, the store allowed, a login added) is when a broker that
        // started with the vault off comes up; quiet and throttled while the store still will not open.
        if method == "account.facade" || (method.hasPrefix("account.") && !method.hasPrefix("account.attribution")) { await accounts.accounts.reviveVault() }
        #if TD_HOST_ACCOUNT_BRIDGE
        if method == "account.facade" { return try await accountControl.invoke(payload: payload) }
        if method == "account.cancel" {
            let args = try NativeRPCValue.parseJSON(payload)
            guard let nonce = args["nonce"].string.flatMap(UUID.init(uuidString:)) else { throw BackendHOSTFailure.authentication }
            await accountControl.cancel(nonce: nonce); return try NativeRPCValue.null.encodedJSON()
        }
        #endif
        if method.hasPrefix("account."), !method.hasPrefix("account.attribution") { return try await accounts.invoke(method, payload: payload, manager: manager, appPID: mcp.currentAppPID()) }
        let args = try NativeRPCValue.parseJSON(payload, maximumBytes: BackendHOSTProtocol.maximumRequestBytes)
        let probe = BackendHOSTSessionProbe(manager: manager)
        let reply: NativeRPCValue
        switch method {
        case "account.attribution":
            let id = try args["id"].requireString("hosted session id")
            #if TD_HOST_ACCOUNT_BRIDGE
            let external = await accounts.externalMetadata(id), externalPID = try await accounts.externalPID(id)
            #else
            let external: BackendSessionMeta? = nil, externalPID: Int32? = nil
            #endif
            let found = await probe.session(id)
            guard let session = found.meta ?? external, args["expectedCreatedAt"].number == session.createdAt,
                  args["pid"].isNullish || args["pid"].number == (found.pid ?? externalPID).map(Double.init) else { throw BackendHOSTFailure.authentication }
            reply = await hooks.attribution.read(session, pid: found.pid ?? externalPID).wireValue
        case "account.attribution.drop":
            let id = try args["id"].requireString("hosted session id")
            #if TD_HOST_ACCOUNT_BRIDGE
            guard try await accounts.externalPID(id) == nil else { throw BackendHOSTFailure.invalid("An app-owned process still holds its account attribution.") }
            #endif
            guard await probe.session(id).pid == nil, try await confirmDescendants(id) else { throw BackendHOSTFailure.invalid("A running session still owns its account attribution.") }
            await hooks.attribution.drop(sessionID: id); reply = .null
        case "resources.adopted":
            let offered = Set((args["ids"].elements ?? []).compactMap(\.string))
            let rows = await probe.rows(), live = Set(rows.filter { $0.exitCode == nil }.map(\.id))
            guard offered == live else { throw BackendHOSTFailure.invalid("The app has not adopted every currently running host session.") }
            guard let attachment = mcp.appAttachmentID(), try await verifyClaims(rows), attachment == mcp.appAttachmentID() else {
                throw BackendHOSTFailure.remote("Actual task and Receiver claim adoption has not been confirmed by the current app.")
            }
            claimsAdopted = true; claimAttachment = attachment; reply = .bool(true)
        case "resources.readiness":
            let ready = readiness()
            #if TD_HOST_ACCOUNT_BRIDGE
            let externalDrained = try await accounts.externalSessionsDrained()
            #else
            let externalDrained = true
            #endif
            reply = .object([.init("safeToDetach", .bool(ready.safeToDetach && externalDrained)), .init("claimsAdopted", .bool(claimsAdopted))])
        case "switch.list": reply = try NativeRPCValue.parseJSON(JSONEncoder().encode(await switches.list()))
        case "switch.plan":
            // 12 Oct: in place where the session has a live seat; `reason: "no-seat"` for one started before switching
            // was ready (the app offers a restart that resumes the conversation); anything else a refusal in plain words.
            let id = try args["id"].requireString("session id"), targetID = try args["target"].requireString("account id"), found = await probe.session(id)
            reply = try await accounts.switchPlan(sessionID: id, targetID: targetID, live: found.meta,
                pid: found.pid, currentPID: { [manager] in manager.pidOf(id) })
        case "switch.stop": try await switches.stop(); reply = .null
        case "switch.recovery":
            // The host's Claude in-place path never destroys/replays input or
            // creates the replacement-session drafts used by the old path.
            _ = try args["id"].requireString("session id"); reply = .null
        case "switch.request":
            let id = try args["id"].requireString("session id"), target = try args["target"].requireString("account id"), found = await probe.session(id)
            let plan = try await accounts.switchPlan(sessionID: id, targetID: target, live: found.meta,
                pid: found.pid, currentPID: { [manager] in manager.pidOf(id) })
            if plan["reason"].string == "no-seat" { throw BackendSessionSwitchNoSeat(sessionID: id) }
            guard plan["verified"].bool == true else {
                throw BackendSessionFailure.unsupported(plan["refusal"].string ?? "The account could not be switched just now. Nothing was changed.")
            }
            let status = await hooks.snapshot().first(where: { $0.sessionID == id })?.status ?? manager.remoteServeSnapshot(id)?.status ?? .idle
            let row = try await switches.request(sessionID: id, targetID: target, status: status, deferUntilIdle: args["deferUntilIdle"].bool == true)
            reply = try NativeRPCValue.parseJSON(JSONEncoder().encode(row))
        case "switch.cancel": try await switches.cancel(sessionID: args["id"].requireString("session id")); reply = .null
        case "hooks.snapshot": reply = try NativeRPCValue.parseJSON(JSONEncoder().encode(await hooks.snapshot()))
        #if TD_HOST_ACCOUNT_BRIDGE
        case "hooks.configure":
            let fields = try args["settings"].requireObject("original hook settings files").fields ?? []
            var files: [String: URL] = [:]
            for field in fields {
                let path = try field.value.requireString("original hook settings path")
                guard files[field.key] == nil, path.hasPrefix("/"), !path.contains("\0") else { throw BackendHOSTFailure.invalid("Invalid original hook settings path.") }
                files[field.key] = URL(fileURLWithPath: path)
            }
            let offer = try args["offer"].requireString("original hook offer file")
            guard offer.hasPrefix("/"), !offer.contains("\0") else { throw BackendHOSTFailure.invalid("Invalid original hook offer file.") }
            let rpc = try await hooks.makeRPC(configuration: accounts.configuration, settings: files, offer: URL(fileURLWithPath: offer),
                authorizeMutation: BackendHOSTAccountControl.authorizeHookMutation)
            try await accountControl.installHookRPC(rpc); reply = .bool(true)
        case "hooks.accepted":
            let after = args["after"].number ?? 0
            guard after.isFinite, after >= 0, after <= Double(UInt64.max), after.rounded(.down) == after else { throw BackendHOSTFailure.invalid("Invalid accepted hook sequence.") }
            reply = .object([.init("events", try NativeRPCValue.parseJSON(JSONEncoder().encode(await hooks.accepted(after: UInt64(after)))))])
        #endif
        case "hooks.endpoint":
            let endpoint = try await hooks.endpoint()
            reply = endpoint.metadata.setting("sessionEnvironment", .string(endpoint.sessionEnvironment)).setting("appID", .string(endpoint.appID))
        case "mcp.projection": reply = try NativeRPCValue.parseJSON(JSONEncoder().encode(await mcp.projection()))
        case "mcp.caller.current":
            reply = try await mcp.sessionCallerResource(args)
        case "mcp.catalogue.replace":
            let descriptors = try JSONDecoder().decode([BackendHOSTConfiguration.Tool].self, from: args["tools"].encodedJSON())
            guard !descriptors.isEmpty, descriptors.count <= 4_096 else { throw BackendHOSTFailure.invalid("The actual tool catalogue is missing or too large.") }
            let tools = try descriptors.map { try $0.spec() }
            guard Set(tools.map(\.id)).count == tools.count, Set(tools.map(\.wireName)).count == tools.count else { throw BackendHOSTFailure.invalid("The actual tool catalogue has conflicting names.") }
            try await mcp.installTools(tools); reply = .bool(true)
        case "mcp.prepare":
            let prepared = try await mcp.prepareOrdinary(restricting: Self.optionalStrings(args["allowed"]),
                deniedTools: Self.optionalStrings(args["denied"]) ?? [], taskID: args["taskID"].string, taskProject: args["taskProject"].string)
            if let prepared {
                reply = .object([.init("id", .string(prepared.id.uuidString)), .init("arguments", .array(prepared.arguments.map(NativeRPCValue.string))),
                    .init("environment", .object(prepared.environment.map { .init($0.key, .string($0.value)) })),
                    .init("readableFiles", .array(prepared.readableFiles.map(NativeRPCValue.string))), .init("implementation", .string(prepared.implementation.rawValue))])
            } else { reply = .null }
        case "mcp.bind":
            guard let lease = args["lease"].string.flatMap(UUID.init(uuidString:)), let id = args["id"].string,
                  let session = await probe.session(id).meta else { throw BackendHOSTFailure.invalid("A real hosted session must claim its MCP lease.") }
            try await mcp.bindPrepared(lease, sessionID: id, machineID: args["machine"].string ?? "")
            if session.exitCode != nil, try await confirmDescendants(id) { await mcp.releasePrepared(sessionID: id) }; reply = .null
        case "mcp.abandon":
            guard let lease = args["lease"].string.flatMap(UUID.init(uuidString:)) else { throw BackendHOSTFailure.invalid("Invalid MCP lease.") }
            await mcp.abandonPrepared(lease); reply = .null
        case "mcp.release":
            let id = try args["id"].requireString("session id")
            guard await probe.session(id).pid == nil, try await confirmDescendants(id) else { throw BackendHOSTFailure.invalid("A running session or unconfirmed descendant still owns its MCP files.") }
            await mcp.releasePrepared(sessionID: id); reply = .null
        case "mcp.ags.reserve":
            let lease = try await mcp.reserveAgentSettingsFiles()
            reply = .object([.init("id", .string(lease.id.uuidString)), .init("directory", .string(lease.directory.path))])
        case "mcp.ags.write":
            let lease = try Self.leaseID(args), fields = try args["files"].requireObject("actual agent settings files").fields ?? []
            var files: [String: Data] = [:]
            for field in fields {
                guard files[field.key] == nil, let bytes = Data(base64Encoded: try field.value.requireString("agent settings file bytes")) else {
                    throw BackendHOSTFailure.invalid("Invalid actual agent settings file payload.")
                }
                files[field.key] = bytes
            }
            try await mcp.writeAgentSettingsFiles(lease, files: files); reply = .null
        case "mcp.ags.bind":
            let id = try args["id"].requireString("hosted session id")
            guard let session = await probe.session(id).meta else { throw BackendSessionFailure.missingSession }
            try await mcp.bindAgentSettingsFiles(Self.leaseID(args), sessionID: id)
            if session.exitCode != nil, try await confirmDescendants(id) { await mcp.releasePrepared(sessionID: id) }; reply = .null
        case "mcp.ags.configuration": reply = try await mcp.agentSettingsConfiguration(Self.leaseID(args))
        case "mcp.project.prepare":
            let definition = try Self.projectDefinition(args), machine = try args["machine"].requireString("original machine identity")
            let environment: [String: String]? = try args["environment"].isNullish ? nil : Self.environment(args["environment"])
            let prepared = try await mcp.prepareProject(definition: definition, provider: args["provider"].requireString("resolved provider"),
                cwd: args["cwd"].requireString("launch directory"), loginPath: args["path"].requireString("login PATH"),
                allowedTools: Self.optionalStrings(args["allowed"]), deniedTools: Self.optionalStrings(args["denied"]) ?? [],
                taskID: args["taskID"].string, taskProject: args["taskProject"].string, machineID: machine, inheritedEnvironment: environment)
            if let prepared {
                reply = .object([.init("id", .string(prepared.id.uuidString)), .init("arguments", .array(prepared.arguments.map(NativeRPCValue.string))),
                    .init("environment", .object(prepared.environment.map { .init($0.key, .string($0.value)) })),
                    .init("readableFiles", .array(prepared.readableFiles.map(NativeRPCValue.string))), .init("implementation", .string(prepared.implementation.rawValue))])
            } else { reply = .null }
        case "mcp.project.configuration": reply = try await mcp.projectAgentSettingsConfiguration(Self.leaseID(args))
        case "mcp.project.serverName":
            let name = try await mcp.projectAgentSettingsServerName(definition: Self.projectDefinition(args),
                provider: args["provider"].requireString("resolved provider"), cwd: args["cwd"].requireString("launch directory"), loginPath: args["path"].requireString("login PATH"))
            reply = name.map(NativeRPCValue.string) ?? .null
        default: throw BackendHOSTFailure.invalid("Unknown persistent session resource operation.")
        }
        return try reply.encodedJSON()
    }
    private static func leaseID(_ args: NativeRPCValue) throws -> UUID {
        guard let lease = args["lease"].string.flatMap(UUID.init(uuidString:)) else { throw BackendHOSTFailure.invalid("Invalid host tool lease identity.") }
        return lease
    }
    private static func optionalStrings(_ value: NativeRPCValue) throws -> [String]? {
        if value.isNullish { return nil }
        return try value.requireArray("original tool grant").map { try $0.requireString("original tool name") }
    }
    private static func environment(_ value: NativeRPCValue) throws -> [String: String] {
        var result: [String: String] = [:]
        for field in try value.requireObject("original project environment").fields ?? [] {
            let text = try field.value.requireString("original project environment value")
            guard result[field.key] == nil, !field.key.isEmpty, !field.key.contains("="), !field.key.contains("\0"), !text.contains("\0") else {
                throw BackendHOSTFailure.invalid("Invalid original project environment.")
            }
            result[field.key] = text
        }
        return result
    }
    private static func projectDefinition(_ args: NativeRPCValue) throws -> BackendHOSTProjectDefinition? {
        if args["definition"].isNullish { return nil }
        return try JSONDecoder().decode(BackendHOSTProjectDefinition.self, from: args["definition"].encodedJSON())
    }
    public func stop() async throws {
        if cleanupComplete { return }
        if let cleanupTask { return try await cleanupTask.value }
        let task = Task { try await self.performCleanup() }; cleanupTask = task
        do { try await task.value; cleanupTask = nil }
        catch { cleanupTask = nil; throw error }
    }
    private func performCleanup() async throws {
        #if TD_HOST_ACCOUNT_BRIDGE
        guard try await accounts.externalSessionsDrained() else { throw BackendHOSTFailure.remote("App-owned sessions still require their original account resources.") }
        #endif
        guard !manager.list().contains(where: { $0.exitCode == nil }), await manager.drain() else {
            throw BackendHOSTFailure.remote("Persistent session resources remain live until Stop Everything confirms process exits.")
        }
        stopped = true
        observation?.cancel(); observation = nil
        exitRetry?.cancel(); exitRetry = nil; unconfirmedExits.removeAll()
        if let hookObservation { await hooks.removeObserver(hookObservation); self.hookObservation = nil }
        #if TD_HOST_ACCOUNT_BRIDGE
        await accountControl.stop()
        #endif
        try await switches.stop(); try await hooks.stop(afterProcessDrain: true); try await mcp.stopAfterSessionsDrained(); try await accounts.stop(afterProcessDrain: true)
        manager.setOpenShim(directory: nil, browser: nil); try await openShim.remove(dataRoot: accounts.configuration.dataDirectory.path)
        cleanupComplete = true
    }
}
