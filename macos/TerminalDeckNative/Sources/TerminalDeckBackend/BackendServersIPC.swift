import Foundation
import TerminalDeckNativeCore

public struct BackendServersIPCHooks: Sendable {
    public let resolve: @Sendable (NativeRPCContext) async throws -> BackendServersCaller
    public let pickKey: (@Sendable (NativeRPCContext) async throws -> String?)?
    public let uploadFile: @Sendable (BackendServersCaller, String, URL) async throws -> Void
    public let uploadDirectory: @Sendable (BackendServersCaller, String) async throws -> String
    public let appVersion: @Sendable () -> String
    public let linkStanding: @Sendable (String) async -> (name: String, online: Bool)?
    public let redial: @Sendable (String) async -> Void
    public let revokeWindows: @Sendable (String) async -> Void
    public let forgetReach: @Sendable (String) async -> Void
    public init(resolve: @escaping @Sendable (NativeRPCContext) async throws -> BackendServersCaller,
                pickKey: (@Sendable (NativeRPCContext) async throws -> String?)?,
                uploadFile: @escaping @Sendable (BackendServersCaller, String, URL) async throws -> Void,
                uploadDirectory: @escaping @Sendable (BackendServersCaller, String) async throws -> String,
                appVersion: @escaping @Sendable () -> String,
                linkStanding: @escaping @Sendable (String) async -> (name: String, online: Bool)?,
                redial: @escaping @Sendable (String) async -> Void, revokeWindows: @escaping @Sendable (String) async -> Void,
                forgetReach: @escaping @Sendable (String) async -> Void) {
        self.resolve = resolve; self.pickKey = pickKey; self.uploadFile = uploadFile; self.uploadDirectory = uploadDirectory; self.appVersion = appVersion
        self.linkStanding = linkStanding; self.redial = redial; self.revokeWindows = revokeWindows; self.forgetReach = forgetReach
    }
}
/// Complete source channel facade. Returns original discriminated results;
/// transport/identity sentences do not become Electron invocation exceptions.
public actor BackendServersIPC {
    public static let channels: Set<String> = {
        var channels: Set<String> = [
        "servers:list", "servers:look", "servers:preview", "servers:act", "servers:logs", "servers:close", "servers:add", "servers:rename", "servers:forget",
        "servers:keys", "servers:key-pick", "servers:key-read", "servers:grant", "servers:revoke", "servers:grant-state",
        "servers:shell:open", "servers:drive-windows", "servers:upload", "servers:shell:write", "servers:shell:resize", "servers:folder", "servers:start-in", "servers:start-in:set",
        "servers:controls:read", "servers:controls:apply", "servers:shell:account", "servers:shell:close",
        "servers:setup:state", "servers:setup:look", "servers:setup:install", "servers:setup:signin", "servers:setup:signout", "servers:setup:cancel", "servers:setup:remove",
        "servers:host:look", "servers:host:state", "servers:host:install", "servers:host:pair", "servers:host:link", "servers:host:remove", "servers:host:cancel"
        ]
        if BackendDockerMCPServerKeyScope.enabled { channels.formUnion(["servers:ai-access:read", "servers:ai-access:set"]) }
        channels.formUnion(["servers:ssh-aliases", "servers:access:read", "servers:access:set", "servers:shown-apps:read", "servers:shown-apps:set"])
        return channels
    }()
    public let room: BackendServersCoordinator
    public let shells: BackendServersShells
    private let store: BackendServersStore, credentials: BackendServersCredentials, keys: BackendServersKeyFileOffers
    private let setups: BackendServersSetups, hosts: BackendServersHosts, hooks: BackendServersIPCHooks
    private let activeChannels: Set<String>
    private let sshHome: URL?, sshConfig: BackendDockerMCPServerSSHConfig
    private var stopped = false
    /// SRVFILES #120: AI apps, keys and devices list folders only inside the server's allowed folders.
    private var folderGuard: (@Sendable (String, String) async throws -> String)?
    public func setFolderGuard(_ guardPath: @escaping @Sendable (String, String) async throws -> String) { folderGuard = guardPath }
    public init(room: BackendServersCoordinator, shells: BackendServersShells, store: BackendServersStore,
                credentials: BackendServersCredentials, keys: BackendServersKeyFileOffers,
                setups: BackendServersSetups, hosts: BackendServersHosts, hooks: BackendServersIPCHooks,
                serverAccessEnabled: Bool = BackendDockerMCPServerKeyScope.enabled,
                sshHome: URL? = nil, sshConfig: BackendDockerMCPServerSSHConfig = .init()) {
        self.sshHome = sshHome; self.sshConfig = sshConfig
        self.room = room; self.shells = shells; self.store = store; self.credentials = credentials; self.keys = keys
        self.setups = setups; self.hosts = hosts; self.hooks = hooks
        let aiAccess: Set<String> = ["servers:ai-access:read", "servers:ai-access:set"]
        activeChannels = serverAccessEnabled ? Self.channels.union(aiAccess) : Self.channels.subtracting(aiAccess)
    }
    public func register(on registry: NativeChannelRegistry, ownerID: String) async throws -> [NativeRPCSubscription] {
        var installed: [String] = [], subscriptions: [NativeRPCSubscription] = []
        do {
            for channel in activeChannels.sorted() {
                try await registry.register(channel, ownerID: ownerID) { [self] context, args in try await invoke(channel, arguments: args, context: context) }
                installed.append(channel)
            }
            // Native SwiftTerm uses send for input; older source callers use invoke.
            subscriptions.append(try await registry.onSend("servers:shell:write", ownerID: ownerID) { [self] context, args in
                _ = try await invoke("servers:shell:write", arguments: args, context: context)
            })
            return subscriptions
        } catch {
            for channel in installed { await registry.removeHandler(channel, ownerID: ownerID) }
            for token in subscriptions { await token.cancelAndWait() }; throw error
        }
    }
    public func invoke(_ channel: String, arguments: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard activeChannels.contains(channel), !stopped else { throw NativeRPCError(code: "missing-handler", message: "No active native handler for \(channel).") }
        let caller = try await hooks.resolve(context)
        guard caller.context.ownerID == context.ownerID else { throw NativeRPCError(code: "not-permitted", message: "The server caller identity does not match its authenticated surface.") }
        func arg(_ i: Int) -> NativeRPCValue { context.argument(i, in: arguments) }
        func text(_ i: Int, _ name: String) throws -> String { try arg(i).requireString(name, nonempty: true) }
        do {
            switch channel {
            case "servers:list": return try await room.list(caller, projectId: arg(0)["projectId"].string)
            case "servers:look":
                guard let id = arg(0).string else { return BackendServersWire.failure("No server was named.") }
                return BackendServersWire.ok([.init("view", try await room.look(id, caller: caller).wireValue())])
            case "servers:preview", "servers:act":
                guard let id = arg(0).string, let card = arg(1).string, let raw = arg(2).string, let action = BackendServersActionID(rawValue: raw) else { return BackendServersWire.failure("That isn’t something this app can do.") }
                if channel == "servers:preview" { return BackendServersWire.ok([.init("preview", try await room.preview(id, cardId: card, action: action, caller: caller))]) }
                return BackendServersWire.ok([.init("outcome", try await room.act(id, cardId: card, action: action, caller: caller).wireValue)])
            case "servers:logs":
                guard let id = arg(0).string, let card = arg(1).string else { return BackendServersWire.failure("No server was named.") }
                let result = try await room.logs(id, cardId: card, lines: arg(2).number ?? 200, caller: caller)
                return result.setting("ok", .bool(true))
            case "servers:close":
                guard let id = arg(0).string else { return flag("closed", false) }
                return try await room.closePage(id, caller: caller)
            case "servers:add":
                if arg(0)["method"].string == "ssh-config" { return try await addFromSSHSettings(arg(0), caller: caller) }
                return try await add(arg(0), caller: caller)
            case "servers:ssh-aliases":
                try await room.check(caller, .init(operation: channel, tier: .read))
                guard let home = sshHome else { return .object([.init("ok", .bool(true)), .init("aliases", .array([]))]) }
                let rows = await BackendServersSSHAliases(home: home, resolver: sshConfig).list()
                var added: [String: String] = [:]
                for row in try store.list() { if let alias = row.sshAlias { added[alias] = row.id } }
                return BackendServersSSHAliases.wire(rows, added: added)
            case "servers:access:read", "servers:access:set":
                let id = try text(0, "server")
                let changing = channel.hasSuffix(":set")
                guard let savedServer = try store.get(id) else { throw NativeRPCError.invalidArguments("That server is not saved in this app.") }
                if changing {
                    guard let lookOnly = arg(1)["lookOnly"].bool else { throw NativeRPCError.invalidArguments("Choose lookOnly true or false.") }
                    try await room.check(caller, .init(operation: channel, serverId: id, tier: .alter, arguments: .object([.init("lookOnly", .bool(lookOnly)), .init("projectId", .string(savedServer.resolvedProjectId))])))
                    guard caller.actsAsOwner else { throw NativeRPCError(code: "access-denied", message: "Only the person at this Mac, or an AI app they approve, can change what may be done on a server.") }
                    _ = try store.setLookOnly(id, lookOnly)
                    if lookOnly { await hooks.revokeWindows(id) }
                    await room.invalidate(id)
                } else {
                    try await room.check(caller, .init(operation: channel, serverId: id, tier: .read))
                }
                guard let row = try store.get(id) else { throw NativeRPCError.invalidArguments("That server is not saved in this app.") }
                var value = NativeRPCValue.object([.init("serverId", .string(id)), .init("lookOnly", .bool(row.isLookOnly)),
                    .init("sshAlias", row.sshAlias.map(NativeRPCValue.string) ?? .null)])
                if caller.kind == .nativeUI { value = value.setting("keyIDs", .array((row.aiKeyIDs ?? []).map(NativeRPCValue.string))) }
                return value
            case "servers:shown-apps:read", "servers:shown-apps:set":
                // The owner's own picker. The answer names hidden apps, so no AI app, key or paired
                // device may read it, and none may widen what it is shown.
                guard caller.kind == .nativeUI, context.caller == .nativeApp else {
                    throw NativeRPCError(code: "access-denied", message: "Only the person at this Mac can choose which apps a server shows.")
                }
                let id = try text(0, "server")
                guard try store.get(id) != nil else { throw NativeRPCError.invalidArguments("That server is not saved in this app.") }
                if channel.hasSuffix(":set") {
                    let names: [String]? = arg(1)["names"] == .null || arg(1)["names"] == .missing ? nil
                        : (arg(1)["names"].elements ?? []).compactMap(\.string)
                    _ = try store.setShownApps(id, names: names)
                    await room.invalidate(id)
                }
                let saved = try store.get(id)?.shownApps
                let seen = BackendServersShownApps.clean(BackendServersShownApps.shared.seenNames(id) + (saved ?? []))
                return .object([.init("serverId", .string(id)),
                    .init("shown", saved.map { .array($0.map(NativeRPCValue.string)) } ?? .null),
                    .init("seen", .array(seen.map(NativeRPCValue.string)))])
            case "servers:ai-access:read", "servers:ai-access:set":
                guard caller.kind == .nativeUI, context.caller == .nativeApp else {
                    throw NativeRPCError(code: "access-denied", message: "Only the owner can choose AI apps that can use this server.")
                }
                let id = try text(0, "server")
                try await room.check(caller, .init(operation: channel, serverId: id, tier: channel.hasSuffix(":set") ? .alter : .read))
                guard let savedServer = try store.get(id) else { throw NativeRPCError.invalidArguments("That server is not saved in this app.") }
                if channel.hasSuffix(":set") {
                    guard let values = arg(1).elements else { throw NativeRPCError.invalidArguments("Choose the AI app keys for this server.") }
                    let ids = try values.map { try $0.requireString("key ID", nonempty: true) }
                    _ = try store.setAIKeyAccess(id, keyIDs: ids)
                }
                return .object([.init("serverId", .string(id)), .init("keyIDs", .array((try store.get(id)?.aiKeyIDs ?? []).map(NativeRPCValue.string)))])
            case "servers:rename":
                guard let id = arg(0).string, let name = arg(1).string else { return flag("renamed", false) }
                try await room.check(caller, .init(operation: channel, serverId: id, tier: .alter))
                await room.invalidate(id); return flag("renamed", try store.rename(id, name: name))
            case "servers:forget":
                guard let id = arg(0).string else { return flag("forgotten", false) }
                try await room.check(caller, .init(operation: channel, serverId: id, tier: .alter))
                await room.beginForgetting(id)
                await setups.cancel(id); await hosts.cancel(id); await shells.forgetServer(id); await hooks.revokeWindows(id)
                await hooks.forgetReach(id)
                if let journal = room.journal as? BackendServersFileJournal { try? await journal.forgetServer(id) }
                await room.forgetServer(id)
                _ = try credentials.forget(id); return flag("forgotten", try store.forget(id))
            case "servers:keys":
                try await room.check(caller, .init(operation: channel, tier: .read))
                return .array(keys.list().map(\.wireValue))
            case "servers:key-pick":
                try await room.check(caller, .init(operation: channel, tier: .alter))
                guard caller.kind == .nativeUI, let pick = hooks.pickKey else { throw NativeRPCError(code: "unavailable", message: "This copy of the app cannot open the native key chooser.") }
                guard let path = try await pick(context) else { return .null }; return keys.chose(path)?.wireValue ?? .null
            case "servers:key-read":
                try await room.check(caller, .init(operation: channel, tier: .alter, arguments: .array(arguments)))
                guard caller.canConsumeCredentialInput else { throw NativeRPCError(code: "not-permitted", message: "Only the native sign-in form or its authorized server-manage adapter can read a selected key file.") }
                return keys.read(try text(0, "key file"))
            case "servers:grant":
                let id = try text(0, "server")
                try await room.check(caller, .init(operation: channel, serverId: id, tier: .alter))
                return BackendServersWire.ok([.init("grant", try BackendServersWire.value(room.grants.grant(id, asker: caller.kind == .nativeUI ? "local" : caller.kind.rawValue, forMilliseconds: arg(1).number ?? BackendServersGrants.defaultGrantMilliseconds)))])
            case "servers:revoke":
                guard let id = arg(0).string else { return flag("revoked", false) }
                try await room.check(caller, .init(operation: channel, serverId: id, tier: .alter)); room.grants.revoke(id); return flag("revoked", true)
            case "servers:grant-state":
                guard let id = arg(0).string else { return .null }
                try await room.check(caller, .init(operation: channel, serverId: id, tier: .read))
                return try room.grants.state(id).map(BackendServersWire.value) ?? .null
            case "servers:shell:open":
                guard let id = arg(0).string else { return BackendServersWire.failure("No server was named.") }
                return try await shells.open(id, cols: arg(1), rows: arg(2), startIn: arg(3), caller: caller)
            case "servers:shell:write":
                guard let id = arg(0).string, let value = arg(1).string else { return flag("written", false) }
                return try await shells.write(id, data: value, caller: caller)
            case "servers:shell:resize":
                guard let id = arg(0).string else { return flag("resized", false) }; return try await shells.resize(id, cols: arg(1), rows: arg(2), caller: caller)
            case "servers:shell:close":
                guard let id = arg(0).string else { return flag("closed", false) }; return try await shells.close(id, caller: caller)
            case "servers:drive-windows":
                guard let id = arg(0).string, let allowed = arg(1).bool else { return flag("drivesWindows", false) }
                try await room.check(caller, .init(operation: channel, serverId: id, tier: .alter))
                let result = try store.setDrivesWindows(id, allowed: allowed); if !result { await hooks.revokeWindows(id) }; return flag("drivesWindows", result)
            case "servers:upload": return try await upload(arg(0), path: arg(1), caller: caller)
            case "servers:folder":
                guard let id = arg(0).string else { return BackendServersWire.failure("No server was named.") }
                try await room.check(caller, .init(operation: channel, serverId: id, tier: .read, arguments: .array(arguments)))
                var folder = arg(1).string ?? ""
                if caller.kind != .nativeUI, let folderGuard { folder = try await folderGuard(id, folder) }
                return try await BackendServersWire.value(room.connections.listDirectory(id, path: folder)).setting("ok", .bool(true))
            case "servers:start-in":
                guard let id = arg(0).string else { return .object([.init("path", .null)]) }
                try await room.check(caller, .init(operation: channel, serverId: id, tier: .read))
                return .object([.init("path", try store.get(id)?.startIn.map(NativeRPCValue.string) ?? .null)])
            case "servers:start-in:set":
                guard let id = arg(0).string else { return flag("saved", false) }
                try await room.check(caller, .init(operation: channel, serverId: id, tier: .alter))
                return flag("saved", try store.setStartIn(id, path: arg(1).string.flatMap { $0.isEmpty ? nil : $0 }))
            case "servers:controls:read":
                guard let id = arg(0).string else { return .null }
                return try await shells.readControls(id, caller: caller)
            case "servers:controls:apply":
                guard let id = arg(0).string else { return .object([.init("ok", .bool(false)), .init("message", .string("No terminal was named.")), .init("reading", .object([.init("value", .null), .init("label", .null), .init("source", .null)]))]) }
                return try await shells.applyControls(id, control: arg(1).string ?? "", value: arg(2).string ?? "", caller: caller)
            case "servers:shell:account":
                guard let id = arg(0).string else { return .object([.init("known", .string("cannot")), .init("why", .string("No terminal was named."))]) }
                return try await account(id, caller: caller)
            case "servers:setup:state":
                guard let id = arg(0).string, let raw = arg(1).string, let agent = BackendServersAgentID(rawValue: raw) else { return .null }
                try await room.check(caller, .init(operation: channel, serverId: id, tier: .read)); return await setups.stateOf(id, agentId: agent).wireValue
            case "servers:setup:look": return try await setupOffer(text(0, "server"), caller: caller)
            case "servers:setup:install", "servers:setup:signin", "servers:setup:signout": return try await setup(channel, args: arguments, caller: caller)
            case "servers:setup:cancel":
                guard let id = arg(0).string else { return flag("cancelled", false) }
                try await room.check(caller, .init(operation: channel, serverId: id, tier: .alter)); await setups.cancel(id); await room.invalidate(id); return flag("cancelled", true)
            case "servers:setup:remove": return try await removeAgent(args: arguments, caller: caller)
            case "servers:host:look": return try await hostOffer(text(0, "server"), caller: caller)
            case "servers:host:state":
                guard let id = arg(0).string else { return .null }; try await room.check(caller, .init(operation: channel, serverId: id, tier: .read)); return await hosts.stateOf(id).wireValue
            case "servers:host:install", "servers:host:pair", "servers:host:link": return try await hostAction(channel, args: arguments, caller: caller)
            case "servers:host:remove":
                let id = try text(0, "server"); try await room.check(caller, .init(operation: channel, serverId: id, tier: .alter))
                let look = try await hosts.look(id), state = await hosts.uninstall(id, look: look.host, alsoData: arg(1).bool == true)
                await room.invalidate(id); return BackendServersWire.ok([.init("state", state.wireValue)])
            case "servers:host:cancel":
                guard let id = arg(0).string else { return flag("cancelled", false) }
                try await room.check(caller, .init(operation: channel, serverId: id, tier: .alter)); await hosts.cancel(id); return flag("cancelled", true)
            default: throw NativeRPCError(code: "unavailable", message: "This native server operation is unavailable.")
            }
        } catch is CancellationError { throw CancellationError() }
        catch { return BackendServersWire.failed(error) }
    }
    private func flag(_ key: String, _ value: Bool) -> NativeRPCValue { .object([.init(key, .bool(value))]) }
    private func add(_ draft: NativeRPCValue, caller: BackendServersCaller) async throws -> NativeRPCValue {
        try await room.check(caller, .init(operation: "servers:add", tier: .alter))
        guard caller.canConsumeCredentialInput, draft.fields != nil else { return .object([.init("ok", .bool(false)), .init("kind", .string("unknown")), .init("sentence", .string("That isn’t a server we can add."))]) }
        let input = try await credentials.credentialFromDraft(draft)
        switch input {
        case .refused(let problem, let sentence): return .object([.init("ok", .bool(false)), .init("kind", .string(problem == "nothing-typed" ? "unknown" : problem)), .init("sentence", .string(sentence))])
        case .accepted(let value):
            let canSave = (try? credentials.available()) == true
            let port = draft["port"].number.flatMap { value -> Int? in value.rounded(.towardZero) == value && (1...65535).contains(value) ? Int(value) : nil }
            let row: BackendServersStoredServer
            do { row = try store.add(.init(name: draft["name"].string ?? draft["address"].string ?? "", address: draft["address"].string ?? "", port: port, username: draft["username"].string ?? "", projectId: draft["projectId"].string), creatorKeyID: caller.kind == .key ? caller.keyID : nil) }
            catch { return addFailure(error) }
            var saved = false, note = ""
            if !canSave { note = BackendServersCredentials.noSecureStore; credentials.holdForSession(row.id, credential: value) }
            else if draft["remember"].bool == false { note = "This sign-in is kept only until you close the app."; credentials.holdForSession(row.id, credential: value) }
            else {
                do { let result = try credentials.save(row.id, credential: value); saved = result.ok; note = result.message; if !saved { credentials.holdForSession(row.id, credential: value) } }
                catch { _ = try? store.forget(row.id); _ = try? credentials.forget(row.id); return addFailure(error) }
            }
            do { let lease = try await room.connections.acquireLease(row.id); await room.connections.release(lease) }
            catch {
                _ = try? store.forget(row.id); _ = try? credentials.forget(row.id)
                return addFailure(error)
            }
            _ = try store.setCredentialKind(row.id, credential: value.kind)
            return BackendServersWire.ok([.init("id", .string(row.id)), .init("savedSignIn", .bool(saved)), .init("note", .string(note))])
        }
    }
    /// Adds a server named in the person's own SSH settings. No key is read,
    /// copied or saved: ssh reads their config and key files at each connect.
    private func addFromSSHSettings(_ draft: NativeRPCValue, caller: BackendServersCaller) async throws -> NativeRPCValue {
        func refused(_ sentence: String) -> NativeRPCValue { .object([.init("ok", .bool(false)), .init("kind", .string("unknown")), .init("sentence", .string(sentence))]) }
        guard let alias = draft["sshAlias"].string, BackendDockerMCPServerSSHConfig.validAlias(alias) else { return refused("Choose one name from your SSH settings.") }
        let lookOnly = draft["lookOnly"].bool != false
        try await room.check(caller, .init(operation: "servers:add", tier: .alter,
            arguments: .object([.init("sshAlias", .string(alias)), .init("lookOnly", .bool(lookOnly)), .init("projectId", .string(PROJProjects.resolve(projectID: draft["projectId"].string, folder: nil)))])))
        guard caller.actsAsOwner else { return refused("Only the person at this Mac, or an AI app they approve, can add a server.") }
        guard let home = sshHome else { return refused("This copy of the app cannot use SSH settings.") }
        let resolved: BackendDockerMCPServerSSHConfig.Resolution
        do { resolved = try await sshConfig.resolve(alias: alias, home: home) }
        catch is CancellationError { throw CancellationError() }
        catch { return refused("Terminal Deck could not read the SSH settings for \(alias).") }
        let name = BackendServersStore.clean(draft["name"].string, limit: 64)
        let row: BackendServersStoredServer
        do {
            row = try store.add(.init(name: name.isEmpty ? alias : name, address: resolved.hostname, port: resolved.port, username: resolved.user, projectId: draft["projectId"].string),
                                creatorKeyID: caller.kind == .key ? caller.keyID : nil, sshAlias: alias, lookOnly: lookOnly)
        } catch { return addFailure(error) }
        do { let lease = try await room.connections.acquireLease(row.id); await room.connections.release(lease) }
        catch {
            _ = try? store.forget(row.id)
            return addFailure(error)
        }
        _ = try store.setCredentialKind(row.id, credential: .sshConfig)
        return BackendServersWire.ok([.init("id", .string(row.id)), .init("projectId", .string(row.resolvedProjectId)), .init("savedSignIn", .bool(false)), .init("lookOnly", .bool(lookOnly)),
            .init("note", .string("Signs in with your SSH settings. Your keys stay where they are."))])
    }
    private func addFailure(_ error: Error) -> NativeRPCValue {
        let failure = BackendServersWire.failed(error)
        let known: Set<String> = ["sign-in-refused", "no-such-address", "no-answer", "not-a-server", "said-nothing", "nothing-in-common", "key-unreadable", "identity-changed", "identity-unconfirmed"]
        let kind = failure["kind"].string.flatMap { known.contains($0) ? $0 : nil } ?? "unknown"
        return .object([.init("ok", .bool(false)), .init("kind", .string(kind)), .init("sentence", failure["sentence"])])
    }
    private func upload(_ id: NativeRPCValue, path: NativeRPCValue, caller: BackendServersCaller) async throws -> NativeRPCValue {
      do {
        guard let id = id.string, let path = path.string, !path.isEmpty else { return .object([.init("ok", .bool(false)), .init("message", .string("That is not a server and a file."))]) }
        let file = URL(fileURLWithPath: path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let size = attributes[.size] as? NSNumber else { return .object([.init("ok", .bool(false)), .init("message", .string("That file is not there any more."))]) }
        guard size.int64Value <= 512 * 1024 * 1024 else { return .object([.init("ok", .bool(false)), .init("message", .string("That file is larger than 512 MB."))]) }
        try await room.check(caller, .init(operation: "servers:upload", serverId: id, tier: .alter, arguments: .object([.init("path", .string(path))])))
        try await hooks.uploadFile(caller, id, file)
        do {
            let folder = try await hooks.uploadDirectory(caller, id)
            let destination = try await room.connections.putFile(id, localPath: path, name: file.lastPathComponent, folder: folder)
            return BackendServersWire.ok([.init("path", .string(destination))])
        }
        catch { return .object([.init("ok", .bool(false)), .init("message", .string(error.localizedDescription))]) }
      } catch is CancellationError { throw CancellationError() }
      catch { return .object([.init("ok", .bool(false)), .init("message", .string(error.localizedDescription))]) }
    }
    private func account(_ id: String, caller: BackendServersCaller) async throws -> NativeRPCValue {
        guard let server = await shells.historicalServerOfShell(id) else { return .object([.init("known", .string("cannot")), .init("why", .string("That terminal is not open any more."))]) }
        try await room.check(caller, .init(operation: "servers:shell:account", serverId: server, shellId: id, tier: .read))
        let facts: BackendServersFacts
        do { facts = try await room.measured(server) } catch { return .object([.init("known", .string("cannot")), .init("why", .string("This server did not answer."))]) }
        if let why = facts.agents.why { return .object([.init("known", .string("cannot")), .init("why", .string(why))]) }
        let agents = facts.agents.value ?? []
        return .object([.init("known", .string("yes")), .init("agents", .number(Double(agents.count))), .init("logins", .array(agents.filter { $0.signedIn == .yes }.map { .object([.init("agentId", .string($0.id.rawValue)), .init("account", $0.account.map(NativeRPCValue.string) ?? .null)]) }))])
    }
    private func setupOffer(_ id: String, caller: BackendServersCaller) async throws -> NativeRPCValue {
        try await room.check(caller, .init(operation: "servers:setup:look", serverId: id, tier: .read))
        let facts = try await room.measured(id), name = try store.get(id)?.name ?? "this server"
        var rows: [NativeRPCValue] = []
        for agent in BackendServersSetupRules.setupAgents {
            let installed = BackendServersSetupRules.agentOn(facts, id: agent), state = await setups.stateOf(id, agentId: agent)
            let why = facts.agentInstall.value.flatMap { BackendServersSetupRules.whyNotInstall(agent, room: $0) }
            rows.append(.object([.init("agentId", .string(agent.rawValue)), .init("label", .string(BackendServersSetupRules.label(agent))),
                .init("installed", try installed.map(BackendServersWire.value) ?? .null), .init("canInstall", .bool(facts.agentInstall.value != nil && why == nil)),
                .init("why", why.map(NativeRPCValue.string) ?? .null), .init("consequence", .string(BackendServersSetupRules.installConsequence(agent, serverName: name))),
                .init("signOutConsequence", .string(BackendServersSetupRules.signOutConsequence(agent, serverName: name))),
                .init("whyNoSignOut", BackendServersSetupRules.whyNoSignOut(agent).map(NativeRPCValue.string) ?? .null), .init("state", state.wireValue)]))
        }
        return BackendServersWire.ok([.init("rows", .array(rows))])
    }
    private func setup(_ operation: String, args: [NativeRPCValue], caller: BackendServersCaller) async throws -> NativeRPCValue {
        guard args.count >= 3, let server = args[0].string, let raw = args[1].string, let agent = BackendServersAgentID(rawValue: raw), let shellId = args[2].string else { return BackendServersWire.failure("No server was named.") }
        try await room.check(caller, .init(operation: operation, serverId: server, shellId: shellId, tier: .alter))
        let shell = try await shells.shell(shellId, server: server, caller: caller), facts = try await room.measured(server)
        let state: BackendServersSetupState
        if operation == "servers:setup:install" {
            guard let install = facts.agentInstall.value else { return BackendServersWire.failure(facts.agentInstall.why ?? "This server did not answer.") }
            state = await setups.install(server, agentId: agent, shell: shell, room: install, serverName: try store.get(server)?.name ?? "this server")
        } else {
            guard let found = BackendServersSetupRules.agentOn(facts, id: agent), !found.version.isEmpty else { return BackendServersWire.failure("\(BackendServersSetupRules.label(agent)) is not ready on this server yet.") }
            state = operation == "servers:setup:signin" ? await setups.signIn(server, agentId: agent, shell: shell, binary: found.path) : await setups.signOut(server, agentId: agent, shell: shell, binary: found.path)
        }
        if ["done", "idle"].contains(state.wireValue["step"].string ?? "") { await room.invalidate(server) }
        return BackendServersWire.ok([.init("state", state.wireValue)])
    }
    private func removeAgent(args: [NativeRPCValue], caller: BackendServersCaller) async throws -> NativeRPCValue {
        guard args.count >= 2, let server = args[0].string, let raw = args[1].string, let agent = BackendServersAgentID(rawValue: raw) else { return BackendServersWire.failure("No server was named.") }
        try await room.check(caller, .init(operation: "servers:setup:remove", serverId: server, tier: .alter))
        let facts = try await room.measured(server)
        guard let installed = BackendServersSetupRules.agentOn(facts, id: agent) else { return BackendServersWire.failure("There is nothing here for this app to remove.") }
        let state = await setups.remove(server, agentId: agent, binary: installed.path); await room.invalidate(server)
        return BackendServersWire.ok([.init("state", state.wireValue)])
    }
    private func hostOffer(_ id: String, caller: BackendServersCaller) async throws -> NativeRPCValue {
        try await room.check(caller, .init(operation: "servers:host:look", serverId: id, tier: .read))
        let look = try await hosts.look(id), name = try store.get(id)?.name ?? "this server", carried = await hosts.carriedPackage()
        let why = carried == nil ? BackendServersHostPackages.noPackage : BackendServersHostRules.whyNotHost(look.room)
        let hostID = BackendServersHostRules.hostIdOf(look.host.status)
        let standing = hostID.isEmpty ? nil : await hooks.linkStanding(hostID)
        let notConnected = standing.map { !$0.online || BackendServersHostRules.channelsOf(look.host.status) == 0 } ?? false
        if notConnected { Task { await hooks.redial(hostID) } }
        let state = await hosts.stateOf(id)
        let offer = NativeRPCValue.object([.init("host", look.host.wireValue), .init("room", look.room.wireValue), .init("canInstall", .bool(why == nil)), .init("why", why.map(NativeRPCValue.string) ?? .null),
            .init("line", .string(BackendServersHostRules.hostLine(look.host))), .init("reach", BackendServersHostRules.reachLine(look.host).map(NativeRPCValue.string) ?? .null),
            .init("consequence", .string(BackendServersHostRules.hostConsequence(name, room: look.room))), .init("removes", .object([.init("keepData", .string(BackendServersHostRules.removeConsequence(look.host, alsoData: false))), .init("withData", .string(BackendServersHostRules.removeConsequence(look.host, alsoData: true)))])),
            .init("canLink", .bool(await hosts.canLink)), .init("linkedAs", standing.map { .string($0.name) } ?? .null), .init("linkedButNotConnected", .bool(notConnected)), .init("mine", .string(hooks.appVersion())), .init("state", state.wireValue)])
        return BackendServersWire.ok([.init("offer", offer)])
    }
    private func hostAction(_ operation: String, args: [NativeRPCValue], caller: BackendServersCaller) async throws -> NativeRPCValue {
        guard args.count >= 2, let server = args[0].string, let shellId = args[1].string else { return BackendServersWire.failure("No server was named.") }
        try await room.check(caller, .init(operation: operation, serverId: server, shellId: shellId, tier: .alter))
        let shell = try await shells.shell(shellId, server: server, caller: caller), look = try await hosts.look(server)
        let state: BackendServersHostState
        if operation == "servers:host:install" { state = await hosts.install(server, shell: shell, look: look, serverName: try store.get(server)?.name ?? "this server") }
        else {
            guard !look.host.command.isEmpty else { return BackendServersWire.failure(operation == "servers:host:pair" ? "There is no host on this server to pair with." : "There is no host on this server to link to.") }
            state = operation == "servers:host:pair" ? await hosts.pairDevice(server, shell: shell, command: look.host.command) : await hosts.link(server, shell: shell, command: look.host.command)
        }
        return BackendServersWire.ok([.init("state", state.wireValue)])
    }
    public func beginStopping() { stopped = true }
    public func stopFlows() async { stopped = true; await setups.cancelAll(); await hosts.cancelAll() }
    public func stop() async {
        await stopFlows(); await shells.stop(); await room.stop()
    }
}
