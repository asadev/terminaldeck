import AppKit
import Foundation
import Security
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func installBrowser() async throws {
        let access = NativeCompositionBrowserAuthority(authority: authority, joins: joins)
        let local = try authority.localContext()
        var dependencies = NativeCompositionBrowserDependencies(uiContext: local,
            requireWriter: { [root] in guard root.state.ownership == .exclusive else { throw NativeRPCError(code: "read-only", message: "Safari's Node writer has not transferred.") } },
            resolve: { try await access.principal($0) },
            resolveSession: { [sessions] id in
                guard sessions!.manager.list().contains(where: { $0.id == id }) else { throw BackendSessionFailure.missingSession }
                return .init(sessionId: id, machineId: "")
            }, authorizeBrowser: { try await access.browser($0) },
            // The window owns profile/data settings; the browser-reader store (store.*) is also
            // reached by agents' browser.store/extract through their checked core-call ticket
            // (TS store-tools: list is a read, install/remove are changes the core already consented).
            authorizeProfiles: { [authority] context, operation in
                if context.caller == .nativeApp { try authority!.requireLocalUI(context); return }
                guard operation.domain == "store", context.caller == .page else { try authority!.requireLocalUI(context); return }
                if operation.tier == .read { try authority!.authorizeMetadata(context) } else { try authority!.authorizeMutation(context) }
            },
            authorizeScraping: { try await access.scraping($0, operation: $1, profile: $2, file: $3, arguments: $4) },
            authorizeDownloads: { try await access.downloads($0, $1) },
            isCurrentUI: { [authority] context in (try? authority!.requireLocalUI(context)) != nil },
            report: { [report] in report($0.message) }, parentWindow: window)
        let cipher = BackendAccountKeychainCipher(appName: configuration.appName)
        dependencies.cipher = .keychain(cipher, available: { cipher.available() })
        dependencies.mcpContext = { try await access.rpc($0) }
        // TS readCliVersion for browser sign-in's agent list: `<cli> --version` on the login PATH.
        dependencies.readVersionOutput = BackendCompositionBrowserVersion.reader(providers: root.providers, executor: BackendDevProcessExecutor(),
            environment: configuration.inheritedEnvironment, home: configuration.homeDirectory.path)
        dependencies.authorizeProfileTool = { try await access.profile($0, $1) }
        dependencies.resolveToolWindow = { [access] native, tab, _ in
            let rpc = try await access.rpc(native)
            let principal = try await access.principal(rpc)
            let browser = try await NativeCompositionRoot.shared.browserForComposition()
            let state = try await browser.service.nativePage(rpc, id: tab, operation: "state", arguments: .object([]))
            _ = principal
            return try state["profileId"].requireString("profile id", nonempty: true)
        }
        dependencies.authorizeScrapingTool = { try await access.scrapingTool($0, tool: $1, tier: $2, arguments: $3) }
        dependencies.resolveDownloadTool = { [access, authority] native in
            let caller = try await authority!.resolve(native)
            return .init(context: try await access.rpc(native), attended: caller.attended, isSession: caller.caller.kind == .session)
        }
        dependencies.transferredSessionAuthority = true
        try await NativeCompositionRoot.shared.installBrowser(in: root, dependencies: dependencies,
            screenshotDirectory: root.dataRoot.appendingPathComponent("browser-screenshots"),
            downloadsDirectory: root.dataRoot.appendingPathComponent("browser-downloads"),
            excludedMCPToolIDs: try BackendCompositionCoreContributions.deckToolsSourceIDs())
        let browser = try NativeCompositionRoot.shared.browserForComposition()
        access.bind(browser)
        browserAccess = access
        let previous = browser.bindings.changed
        browser.bindings.changed = { [joins, weak browser] in
            previous?()
            guard let browser else { return }
            var rows: [String: [NativeRPCValue]] = [:]
            for window in browser.bindings.windows() {
                if let owner = browser.bindings.owner(of: window.tabID) { rows[owner.sessionId, default: []].append(window.value) }
            }
            joins.updateBrowserWindows(rows)
        }
        joins.bindBrowser(release: { [weak browser] id in
            await MainActor.run { browser?.bindings.release(id) }
        })
        installBrowserSessionContext(browser) // lane BR: agents told of their attached windows (NativeCompositionBRBrowserContext.swift)
    }
}

@MainActor
final class NativeCompositionBrowserAuthority {
    let authority: BackendCompositionAuthority
    let joins: BackendCompositionProductionBindings
    private weak var graph: NativeCompositionBrowser?
    private var contexts: [String: (rpc: NativeRPCContext, native: BackendMCPCallContext)] = [:]
    init(authority: BackendCompositionAuthority, joins: BackendCompositionProductionBindings) { self.authority = authority; self.joins = joins }
    func bind(_ graph: NativeCompositionBrowser) { self.graph = graph }
    func rpc(_ native: BackendMCPCallContext) async throws -> NativeRPCContext {
        let rpc = try await authority.rpc(native); contexts[rpc.ownerID] = (rpc, native); return rpc
    }
    func principal(_ rpc: NativeRPCContext) async throws -> BackendBrowserPrincipal {
        if rpc.caller == .nativeApp {
            try authority.requireLocalUI(rpc); return .init(ownerID: rpc.ownerID, managesWindows: true)
        }
        if rpc.caller == .pairedDevice { return try await joins.remoteBrowserPrincipal(rpc) }
        guard let saved = contexts[rpc.ownerID], saved.rpc.requestID == rpc.requestID else { throw denied() }
        let core = try await authority.resolve(saved.native)
        return .init(ownerID: rpc.ownerID, sessionID: core.caller.sessionID, machineID: core.caller.machineID ?? "",
            managesWindows: core.caller.actsAsOwner, routesToOriginatingDevice: core.caller.kind == .remote)
    }
    func browser(_ access: BackendBrowserAccess) async throws {
        if access.principal.ownerID == BackendCompositionRoot.appOwnerID {
            try authority.requireLocalUI(authority.localContext()); return
        }
        if let saved = contexts[access.principal.ownerID] {
            let caller = try await authority.resolve(saved.native)
            if let session = access.targetSession { _ = try await authority.requireSession(session.sessionId, native: saved.native) }
            guard caller.caller.kind != .remote else { throw denied() }
            try await joins.prepareNative(saved.native, tier: access.tier, sentence: "Use " + access.tool)
            return
        }
        _ = try await joins.remoteBrowserPrincipal(.init(caller: .pairedDevice, ownerID: access.principal.ownerID))
    }
    func profile(_ native: BackendMCPCallContext, _ operation: BackendBrowserProfilesOperation) async throws -> BackendBrowserProfilesToolGrant {
        let core = try await authority.resolve(native)
        guard core.caller.kind != .session, core.caller.kind != .remote else { throw denied() }
        if operation.action != "access" {
            try await joins.prepareNative(native, tier: operation.tier,
                sentence: "Use browser " + operation.domain + ": " + operation.action, ownerMustAnswer: operation.ownerMustAnswer)
        }
        guard let graph else { throw denied() }
        let profileIDs = Set(try await graph.profiles.state().profiles.map(\.id))
        let tabIDs = Set(graph.tabs.tabs.map(\.id))
        return .init(kind: .ownerApplication, attended: core.attended, tiers: core.caller.tiers,
            profileIDs: profileIDs, tabIDs: tabIDs, globalSettings: core.caller.actsAsOwner,
            ownerAnswered: operation.action != "access" && operation.ownerMustAnswer,
            stillPermitted: { [authority] in (try? await authority.resolve(native)) != nil })
    }
    /// The scraping caller for an already-gated core call (no second consent): who, attended, its ticket.
    func scrapingCaller(_ native: BackendMCPCallContext) async throws -> BackendBrowserScrapingCaller {
        let core = try await authority.resolve(native)
        guard core.caller.kind != .remote else { throw denied() }
        return .init(ownerID: core.caller.keyID ?? core.caller.sessionID ?? "core-local",
            sessionID: core.caller.sessionID, machineID: core.caller.machineID, attended: core.attended, remote: false,
            rpc: try await rpc(native))
    }
    /// TS lift-ask-tool → browser-lift-requests fileLiftRequest, into the ONE inbox the Scraping panel answers.
    func fileLift(_ ask: BackendCompositionDeckToolsLiftAsk, native: BackendMCPCallContext) async throws -> NativeRPCValue {
        guard let graph else { throw denied() }
        let caller = try await scrapingCaller(native)
        let workers = try await graph.workers.view(caller)
        var args: [NativeRPCValue.Field] = [.init("from", .string(ask.from)), .init("reason", ask.reason)]
        if !ask.into.isEmpty { args.append(.init("into", .array(ask.into.map(NativeRPCValue.string)))) }
        return try await graph.inbox.file(.object(args), caller: caller, workers: workers)
    }
    func scrapingTool(_ native: BackendMCPCallContext, tool: String, tier: BackendMCPTier, arguments: NativeRPCValue) async throws -> BackendBrowserScrapingCaller {
        let core = try await authority.resolve(native)
        guard core.caller.kind != .remote else { throw denied() }
        try await joins.prepareNative(native, tier: tier, sentence: "Use " + tool)
        return .init(ownerID: core.caller.keyID ?? core.caller.sessionID ?? "core-local",
            sessionID: core.caller.sessionID, machineID: core.caller.machineID, attended: core.attended, remote: false,
            rpc: try await rpc(native))
    }
    func scraping(_ caller: BackendBrowserScrapingCaller, operation: String, profile: String?, file: URL?, arguments: NativeRPCValue) async throws {
        guard let rpc = caller.rpc, !caller.remote else { throw denied() }
        if rpc.caller == .nativeApp { try authority.requireLocalUI(rpc) }
        else { guard let saved = contexts[rpc.ownerID] else { throw denied() }; _ = try await authority.resolve(saved.native) }
        // The URL slot carries the page or resource address for arming, capture and assets
        // (TS scraping authorize); only a real file on disk goes through the folder scope.
        if let file, file.isFileURL { _ = try await BackendFilesystemAuthority(scope: { [authority] in try await authority.filesystemScope($0) }).authorize(file.path, context: rpc, intent: .write) }
        if let profile, let id = caller.sessionID {
            let session = try joins.sessions().manager.list().first { $0.id == id }
            guard session?.profileId == profile else { throw denied() }
        }
    }
    func downloads(_ rpc: NativeRPCContext, _ access: BackendBrowserDownloadsAccess) async throws {
        if rpc.caller == .nativeApp { try authority.requireLocalUI(rpc); return }
        guard let saved = contexts[rpc.ownerID] else { throw denied() }
        let core = try await authority.resolve(saved.native)
        guard core.caller.kind != .session, core.caller.kind != .remote else { throw denied() }
        try await joins.prepareNative(saved.native, tier: access.tier, sentence: "Use browser downloads: " + access.operation.rawValue)
    }
    private func denied() -> NativeRPCError { .init(code: "access-denied", message: "The current browser caller has no matching native grant.") }
}
