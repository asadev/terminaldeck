#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

public protocol BackendHOSTAppAccountFrontend: BackendHOSTAccountChannelInvoking, BackendHOSTProfileReading {}
extension BackendHOSTAccountControlFrontend: BackendHOSTAppAccountFrontend {}

actor BackendAppAccountSignInDrafts {
    private var profiles: [String: BackendAccountProfile] = [:]
    func put(_ profile: BackendAccountProfile) { profiles[profile.id] = profile }
    func find(_ id: String) -> BackendAccountProfile? { profiles[id] }
    func remove(_ id: String) { profiles[id] = nil }
}

/// Uses authenticated helper metadata, without opening a second profile writer
/// or the helper's vault. Only the app's own new account-logins/ folders may be
/// signed in here; arbitrary folders and the Mac's own install stay excluded.
struct BackendHOSTAppAccountSignInDependencies: BackendAppAccountSignInDependencies {
    let configuration: BackendAccountConfiguration
    let reader: any BackendHOSTAppAccountFrontend
    let providers: BackendNativeProviders
    let drafts: BackendAppAccountSignInDrafts
    func find(_ id: String) async throws -> BackendAccountProfile? {
        if let draft = await drafts.find(id) { return draft }
        return try await reader.find(id, context: BackendHOSTProfileScope.requireCurrent())
    }
    func managed(_ profile: BackendAccountProfile) async -> Bool { BackendAccountSignInStorage.ownsFolder(profile, configuration: configuration) && !profile.promised }
    func summaries() async throws -> [BackendAccountVaultSummary] { [] }
    func vaultUsable() async -> Bool { false }
    func loginPath() async throws -> String { try await providers.loginPath() }
    func binary(_ provider: String, path: String, refresh: Bool) async -> BackendNativeProviders.Binary { await providers.resolveBinary(provider, path: path, refresh: refresh) }
    func probeEnvironment(_ profile: BackendAccountProfile, provider: String, path: String) async throws -> [String: String] {
        BackendAccountSignInStorage.environment(profile, configuration: configuration, path: path)
    }
    func recheck(_ profile: BackendAccountProfile) async throws {}
    func readJSON(_ file: URL) -> NativeRPCValue {
        guard let data = try? BackendAccountFiles.boundedRead(file, maximum: 4 * 1024 * 1024), let value = try? NativeRPCValue.parseJSON(data) else { return .null }
        return value
    }
    func nonEmptyFile(_ file: URL) -> Bool { (((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0) > 0 }
}

/// The app starts the AI's sign-in before registering a new account with the
/// older helper. The helper already understands configDir and can launch the
/// resulting agent-kept login. A newer helper adopts it through its broker.
public actor BackendHOSTAppAccountSignIn {
    public nonisolated let apiAccounts: BackendAPIAccountService
    private let configuration: BackendAccountConfiguration
    private let frontend: any BackendHOSTAppAccountFrontend
    /// The titles of the open sessions running as an account.
    private let sessionsUsing: @Sendable (String) -> [String]
    private let drafts: BackendAppAccountSignInDrafts
    private let service: BackendAppAccountSignInService
    private var localFlows = Set<String>()
    private var shutdownFlows = Set<String>()
    private var created: [String: BackendAccountProfile] = [:]
    private var flowAccounts: [String: String] = [:]
    private var pendingDrafts: [String: BackendAccountProfile] = [:]
    private var settled = Set<String>()
    private var closing = false
    private var activeStarts = 0
    public init(configuration: BackendAccountConfiguration, frontend: any BackendHOSTAppAccountFrontend, providers: BackendNativeProviders,
                executor: any BackendAppSessionCommandExecuting = BackendAppSessionCommandExecutor(),
                sessionsUsing: @escaping @Sendable (String) -> [String] = { _ in [""] },
                authorizeMetadata: @escaping @Sendable (NativeRPCContext) throws -> Void,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void) {
        self.configuration = configuration; self.frontend = frontend
        self.sessionsUsing = sessionsUsing
        apiAccounts = BackendAPIAccountService(configuration: configuration, access: .init(
            find: { try await frontend.find($0, context: $1) },
            list: { try await frontend.list(provider: nil, context: $0) },
            create: { name, provider, directory, context in
                let value = try await frontend.invoke("profiles:create", args: [.string(name),
                    .object([.init("provider", .string(provider)), .init("configDir", .string(directory))])], context: context)
                return try JSONDecoder().decode(BackendAccountProfile.self, from: value.encodedJSON())
            }, rename: { id, name, context in
                let value = try await frontend.invoke("profiles:rename", args: [.string(id), .string(name)], context: context)
                return try JSONDecoder().decode(BackendAccountProfile.self, from: value.encodedJSON())
            }, remove: { id, context in
                try await BackendAPIAccountDeletion.$insideCleanup.withValue(true) {
                    try await frontend.invoke("profiles:delete", args: [.string(id), .object([.init("deleteFiles", .bool(false))])], context: context)
                }
            }),
            authorizeMutation: authorizeMutation, inUse: { BackendAccountUse(sessions: sessionsUsing($0)) })
        let drafts = BackendAppAccountSignInDrafts(); self.drafts = drafts
        service = BackendAppAccountSignInService(dependencies: BackendHOSTAppAccountSignInDependencies(configuration: configuration, reader: frontend, providers: providers, drafts: drafts),
            executor: executor, clock: BackendAppSessionSystemClock(), authorizeMetadata: authorizeMetadata, authorizeMutation: authorizeMutation)
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext, olderHost: Bool) async throws -> NativeRPCValue? {
        if BackendAPIAccountService.channels.contains(channel) { return try await apiAccounts.invoke(channel, args: args, context: context) }
        let starts = channel == "profiles:add-signin" || channel == "profiles:signin-start"
        if starts {
            guard !closing else { throw BackendAccountFailure("The sign-in is closing with the app. Quit and reopen Terminal Deck to start another sign-in.") }
            activeStarts += 1
        }
        defer { if starts { activeStarts -= 1 } }
        if starts { await forgetEnded() }
        switch channel {
        case "profiles:remove-copy":
            guard olderHost else { return nil }
            guard let id = args.first?.string, let profile = try await frontend.find(id, context: context), !profile.system else { throw BackendAccountFailure("Choose the saved second copy in Settings › Coding AIs.") }
            guard sessionsUsing(id).isEmpty else { throw BackendAccountFailure("This copy is in use. Choose the working account in its session’s Login menu, then click Remove copy again.") }
            let snapshot = try await frontend.invoke("profiles:list", args: [.string(profile.provider)], context: context)
            guard snapshot["vault"][id]["keptBy"].string != "unavailable" else { throw BackendAccountFailure(BackendAccountVaultRecovery.permissionStep) }
            let backup = try BackendAccountCopyBackup.archive(profile, configuration: configuration)
            do {
                let removed = try await frontend.invoke("profiles:delete", args: [.string(id), .object([.init("deleteFiles", .bool(false))])], context: context)
                guard removed["removed"].bool == true else { throw BackendAccountFailure("The second copy could not be removed. Click Remove copy to try again.") }
                guard removed["warning"].isNullish else { throw BackendAccountFailure("The account entry was removed and its history is backed up. Click Allow login store to finish removing its saved login.") }
                return .object([.init("removed", .bool(true)), .init("backupPath", backup.map { .string($0.path) } ?? .null)])
            } catch {
                if try await frontend.find(id, context: context) != nil { try BackendAccountCopyBackup.restore(backup, profile: profile) }
                throw error
            }
        case "profiles:signin-prepare": return try await service.invoke(channel, args: args, context: context)
        case "profiles:add-signin": return try await add(args, context: context)
        case "profiles:signin-discard":
            let id = args.first?.string ?? ""
            guard created[id] != nil else { throw BackendAccountFailure("Only an account made by this unfinished sign-in can be removed here.") }
            if let flow = flowAccounts.first(where: { $0.value == id })?.key { _ = try await service.invoke("profiles:signin-cancel", args: [.string(flow)], context: context) }
            try await discard(id, context: context)
            return .object([.init("removed", .bool(true))])
        case "profiles:signin-start":
            guard let id = args.first?.string, let profile = try await frontend.find(id, context: context) else { return nil }
            guard BackendAccountSignInStorage.ownsFolder(profile, configuration: configuration), !profile.promised else {
                if olderHost { throw BackendAccountFailure("Click Add account in Settings › Coding AIs to sign in to another login. This saved copy needs Allow login store on its account row before it can be used.") }
                return nil
            }
            let answer = try await service.invoke(channel, args: args, context: context)
            if closing, let flow = answer["flow"].string {
                _ = try await service.invoke("profiles:signin-cancel", args: [.string(flow)], context: context)
                throw BackendAccountFailure("The sign-in was cancelled because the app is closing.")
            }
            if let flow = answer["flow"].string { localFlows.insert(flow); shutdownFlows.insert(flow); flowAccounts[flow] = id }
            return answer.setting("loginStore", .string("agent"))
        case "profiles:signin-state", "profiles:signin-code", "profiles:signin-cancel":
            guard let flow = args.first?.string, localFlows.contains(flow) else { return nil }
            if !(await service.hasFlow(flow)) {
                // Only finished, drained receipts can have been pruned. There
                // is no command left to stop; remove only our unfinished Add.
                _ = try await service.invoke("profiles:signin-cancel", args: [.string(flow)], context: context)
                if let id = flowAccounts[flow], created[id] != nil { try await discard(id, context: context) }
                try await discardDraft(flow); shutdownFlows.remove(flow)
                return .object([.init("state", .string("cancelled")), .init("message", .string("That sign-in has ended. Click Add account to start again."))])
            }
            var answer = try await service.invoke(channel, args: args, context: context)
            if let id = flowAccounts[flow], ["failed", "cancelled"].contains(answer["state"].string ?? ""), created[id] != nil {
                // An expired command may still be responding to its stop signal.
                // Drain it before taking away the folder it was writing into.
                _ = try await service.invoke("profiles:signin-cancel", args: [.string(flow)], context: context)
                try await discard(id, context: context)
            } else if answer["state"].string == "done", !settled.contains(flow), let id = flowAccounts[flow] {
                settled.insert(flow)
                if let same = try await collision(id, context: context) {
                    if created[id] != nil { try await discard(id, context: context) }
                    let detail = "That is the same account as \(same.name)"
                    await service.rejectFlow(flow, detail: detail)
                    answer = answer.setting("state", .string("failed")).setting("message", .string(detail))
                } else { created[id] = nil }
            }
            if ["failed", "cancelled"].contains(answer["state"].string ?? ""), pendingDrafts[flow] != nil {
                _ = try await service.invoke("profiles:signin-cancel", args: [.string(flow)], context: context)
                try await discardDraft(flow)
            }
            if ["done", "failed", "cancelled"].contains(answer["state"].string ?? "") {
                _ = try await service.invoke("profiles:signin-cancel", args: [.string(flow)], context: context)
                shutdownFlows.remove(flow)
            }
            return answer.setting("loginStore", .string("agent"))
        default: return nil
        }
    }
    /// Called before the app revokes its UI authority or detaches its relay.
    /// Only this service's sign-in children are stopped. Saved account folders
    /// and all helper sessions are left with their existing owners.
    public func shutdown(context: NativeRPCContext) async throws {
        closing = true
        // A preflight or registration already underway must finish unwinding
        // before account cleanup and the helper detachment can run.
        for _ in 0..<500 where activeStarts > 0 { try await Task.sleep(for: .milliseconds(20)) }
        guard activeStarts == 0 else { throw BackendAccountFailure("The sign-in is still closing. Try Quit again in a moment.") }
        try await BackendHOSTProfileScope.withContext(context) {
            for flow in await self.pendingFlows() {
                // Confirm completed logins first, so a successful account is
                // kept. Cancel also drains failed/expired commands still exiting.
                _ = try await self.invoke("profiles:signin-state", args: [.string(flow)], context: context, olderHost: false)
                _ = try await self.invoke("profiles:signin-cancel", args: [.string(flow)], context: context, olderHost: false)
            }
        }
    }
    private func pendingFlows() -> [String] { Array(shutdownFlows).sorted() }
    func pendingShutdownCount() -> Int { shutdownFlows.count }
    private func add(_ args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        let options = args.first ?? .null, provider = options["provider"].string ?? "claude"
        _ = try await service.invoke("profiles:signin-prepare", args: [.string(provider)], context: context)
        guard !closing else { throw BackendAccountFailure("The account was not added because the app is closing.") }
        let wanted = (options["name"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try await frontend.list(provider: provider, context: context)
        guard !closing else { throw BackendAccountFailure("The account was not added because the app is closing.") }
        let label = BackendAccountProfile.providerLabel(provider) + " account"
        var name = wanted.isEmpty ? label : wanted
        if wanted.isEmpty {
            var suffix = 2
            while existing.contains(where: { $0.name.lowercased() == name.lowercased() }) { name = label + " \(suffix)"; suffix += 1 }
        }
        name = try BackendAccountProfileStore.normalizedName(name)
        let nonce = UUID().uuidString.lowercased(), directory = BackendAccountSignInStorage.root(configuration).appendingPathComponent(nonce)
        let draft = BackendAccountProfile(id: "pending-" + nonce, name: name, provider: provider, configDir: directory.path, system: false,
            color: BackendAccountProfile.colors[0], createdAt: Date().timeIntervalSince1970 * 1000)
        guard BackendAccountSignInStorage.ownsFolder(draft, configuration: configuration) else { throw BackendAccountFailure("The account login folder is a link. Move account-logins aside in Finder, then click Add account again.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        await drafts.put(draft)
        var flow: String?, registered: String?
        do {
            let started = try await service.invoke("profiles:signin-start", args: [.string(draft.id), options], context: context)
            guard let fid = started["flow"].string else { throw BackendAccountFailure("The AI's sign-in could not start. Click Add account to try again.") }
            flow = fid
            localFlows.insert(fid); shutdownFlows.insert(fid); flowAccounts[fid] = draft.id; pendingDrafts[fid] = draft
            guard !closing else { throw BackendAccountFailure("The sign-in was cancelled because the app is closing.") }
            guard ["waiting", "needs-code"].contains(started["state"].string ?? "") else { throw BackendAccountFailure("The AI's sign-in stopped before the account was added. Click Add account to try again.") }
            let value = try await frontend.invoke("profiles:create", args: [.string(name), .object([.init("provider", .string(provider)), .init("configDir", .string(directory.path))])], context: context)
            let profile = try JSONDecoder().decode(BackendAccountProfile.self, from: value.encodedJSON())
            registered = profile.id; created[profile.id] = profile
            flowAccounts[fid] = profile.id
            guard !closing else { throw BackendAccountFailure("The sign-in was cancelled because the app is closing.") }
            try await service.attachFlow(fid, profileID: profile.id)
            await drafts.remove(draft.id)
            pendingDrafts[fid] = nil
            localFlows.insert(fid); flowAccounts[fid] = profile.id
            return started.setting("profileId", .string(profile.id)).setting("accountName", .string(profile.name)).setting("loginStore", .string("agent"))
        } catch {
            if let flow {
                // A slow stop keeps this owned flow tracked for the next Cancel
                // or app close. Its folder is removed only after it has drained.
                _ = try await service.invoke("profiles:signin-cancel", args: [.string(flow)], context: context)
            }
            if let registered { try? await discard(registered, context: context) }
            else { try? FileManager.default.removeItem(at: directory) }
            await drafts.remove(draft.id)
            if let flow { pendingDrafts[flow] = nil }
            if let flow { shutdownFlows.remove(flow) }
            throw error
        }
    }
    private func discardDraft(_ flow: String) async throws {
        guard let draft = pendingDrafts[flow], BackendAccountSignInStorage.ownsFolder(draft, configuration: configuration) else { return }
        if FileManager.default.fileExists(atPath: draft.configDir) { try FileManager.default.removeItem(atPath: draft.configDir) }
        await drafts.remove(draft.id); pendingDrafts[flow] = nil
    }
    private func discard(_ id: String, context: NativeRPCContext) async throws {
        guard let profile = created[id], BackendAccountSignInStorage.ownsFolder(profile, configuration: configuration) else { return }
        let answer = try await frontend.invoke("profiles:delete", args: [.string(id), .object([.init("deleteFiles", .bool(false))])], context: context)
        guard answer["removed"].bool == true else { throw BackendAccountFailure("The unfinished account could not be removed. Press Cancel again.") }
        // The exact, new folder from this attempt only. Removing a projects
        // link never follows it to the person's conversation history.
        if FileManager.default.fileExists(atPath: profile.configDir) { try FileManager.default.removeItem(atPath: profile.configDir) }
        created[id] = nil
    }
    private func collision(_ id: String, context: NativeRPCContext) async throws -> BackendAccountProfile? {
        guard let profile = try await frontend.find(id, context: context) else { return nil }
        let own = try await service.invoke("profiles:signin", args: [.string(id), .object([.init("refresh", .bool(true))])], context: context)
        guard let email = CodingAILogins.normalizedEmail(own["account"].string) else { return nil }
        // 18 Oct (#414): only the new account is checked afresh. The others answer from their saved sign-in
        // reports (a check runs only where none is recent), all at once rather than one after another.
        let others = try await frontend.list(provider: profile.provider, context: context).filter { $0.id != id }
        let frontend = frontend
        let reports = await withTaskGroup(of: (Int, NativeRPCValue).self) { group in
            for (index, other) in others.enumerated() {
                group.addTask { (index, (try? await frontend.invoke("profiles:signin", args: [.string(other.id)], context: context)) ?? .null) }
            }
            var answers = [NativeRPCValue](repeating: .null, count: others.count)
            for await (index, report) in group { answers[index] = report }
            return answers
        }
        for (other, report) in zip(others, reports) {
            let otherEmail = report["state"].string == "signed-in" ? CodingAILogins.normalizedEmail(report["account"].string)
                : (!other.system && other.promised && report["state"].string != "signed-out" ? CodingAILogins.normalizedEmail(other.name) : nil)
            if otherEmail == email { return other }
        }
        return nil
    }
    /// 18 Oct (#414): a sign-in the service has already forgotten (it ended over ten minutes ago) is dropped
    /// here too, unless something of it is still to be cleaned up.
    private func forgetEnded() async {
        for flow in localFlows where !shutdownFlows.contains(flow) && pendingDrafts[flow] == nil {
            if let id = flowAccounts[flow], created[id] != nil { continue }
            guard !(await service.hasFlow(flow)) else { continue }
            localFlows.remove(flow); settled.remove(flow); flowAccounts[flow] = nil
        }
    }
}
#endif
