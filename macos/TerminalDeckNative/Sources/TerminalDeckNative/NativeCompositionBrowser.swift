import AppKit
import Foundation
import WebKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The app-owned Safari graph. Construction is inert; start is called only
/// after the root has excluded Node's browser writers for this exact data root.
@MainActor
final class NativeCompositionBrowser: BackendRemoteServeBrowserDocumentPicking {
    static let ownerID = "native-composition-browser"
    let registry: NativeChannelRegistry
    let mcp: BackendNativeMCPServer
    let dataRoot: URL
    let screenshotDirectory: URL
    let downloadsDirectory: URL
    let tabs: NativeBrowserTabs
    let dependencies: NativeCompositionBrowserDependencies
    let excludedMCPToolIDs: Set<String>
    let profiles: BackendBrowserProfiles
    private(set) var passwords: BackendBrowserPasswords!
    private(set) var started = false
    private var stopping = false
    private var stopFinished = false
    private var stopFailure: NativeRPCError?
    private var ownsLegacyCutover = false
    private var subscriptions: [NativeRPCSubscription] = []
    private var eventTasks: [String: Task<Void, Error>] = [:]
    private var lifecycleTasks: [UUID: Task<Void, Never>] = [:]
    private var retiringProfiles: Set<String> = []
    private var assetOperations: [UUID: (profile: String, cancel: () -> Void, drain: () async -> Void)] = [:]
    private var captures: [String: NativeSafariCaptureBridge] = [:]
    private var rules: [String: NativeSafariProfileArmingRules] = [:]
    private var lifecycles: [String: NativeSafariProfileArming] = [:]
    private var liveViews: [String: WKWebView] = [:]
    private var requestedURLs: [String: URL] = [:]
    private var responseStatus: [String: Int] = [:]
    private var retirements: [String: Task<Void, Error>] = [:]
    private var captureHolders: [String: String] = [:]
    private(set) var registeredMCPToolIDs: [String] = []
    private var ruleStore: WKContentRuleListStore?
    private var installedProfiles: Set<String> = []

    func pickDocumentPoint(tabID: String, x: Double, y: Double, up: Int,
                           context: NativeRPCContext) async throws -> BackendRemoteServeBrowserPicked {
        guard started, !stopping else { throw NativeCompositionBrowserDependencies.unavailable("the active Safari page owner") }
        let picked = try await service.nativePage(context, id: tabID, operation: "pick", arguments:
            .object([.init("x", .number(x)), .init("y", .number(y)), .init("up", .number(Double(up)))]))
        // NativeSafariRuntime owns document coordinates, secret-label filtering
        // and the page-generation/handover checks surrounding the WebKit await.
        return .init(found: picked["found"].bool == true, moved: picked["moved"].bool == true,
            tag: picked["tag"].string ?? "", selector: picked["selector"].string ?? "",
            label: picked["label"].string ?? "", labelSource: picked["labelSource"].string ?? "none",
            x: picked["rect"]["x"].number ?? 0, y: picked["rect"]["y"].number ?? 0,
            width: picked["rect"]["w"].number ?? 0, height: picked["rect"]["h"].number ?? 0,
            depth: picked["depth"].number ?? 0, maxUp: picked["maxUp"].number ?? 0)
    }

    init(registry: NativeChannelRegistry, mcp: BackendNativeMCPServer, dataRoot: URL,
         screenshotDirectory: URL, downloadsDirectory: URL, tabs: NativeBrowserTabs = .shared,
         dependencies: NativeCompositionBrowserDependencies, excludedMCPToolIDs: Set<String> = []) throws {
        self.registry = registry; self.mcp = mcp; self.dataRoot = dataRoot.standardizedFileURL
        self.screenshotDirectory = screenshotDirectory.standardizedFileURL
        self.downloadsDirectory = downloadsDirectory.standardizedFileURL
        self.tabs = tabs; self.dependencies = dependencies
        self.excludedMCPToolIDs = excludedMCPToolIDs
        let link = NativeCompositionBrowserLink()
        profiles = try BackendBrowserProfiles(dataRoot: dataRoot, requireWriter: dependencies.requireWriter,
            deleteWebsiteData: { [link] id in
                guard let owner = await link.owner else { throw NativeCompositionBrowserDependencies.unavailable("the native profile owner") }
                try await owner.clearProfile(id)
            })
        link.owner = self
        passwords = try BackendBrowserPasswords(dataRoot: dataRoot,
            cipher: dependencies.cipher ?? .init(available: { false },
                decrypt: { _ in throw NativeCompositionBrowserDependencies.unavailable("the original safe-storage Keychain cipher") },
                encrypt: { _, _ in throw NativeCompositionBrowserDependencies.unavailable("the original safe-storage Keychain cipher") }),
            host: passwordAdapter.makeHost(), requireWriter: dependencies.requireWriter,
            requireProfile: { [profiles] id in try await profiles.requireProfile(id) })
    }

    private(set) lazy var bindings = BackendBrowserBindings()
    private(set) lazy var dataBridge = NativeBrowserDataBridge(tabs: tabs, authorizeFetch: { [weak self] partition, url, operation in
        guard let self else { throw NativeCompositionBrowserDependencies.unavailable("the app-owned data bridge") }
        try await self.authorizeDataFetch(partition: partition, url: url, operation: operation)
    })
    private(set) lazy var runtime = NativeSafariRuntime(tabs: tabs, bindings: bindings, dataRoot: dataRoot,
        screenshotDirectory: screenshotDirectory, browserData: { [weak self] operation, args in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("the app-owned data bridge") }
            return try await self.dataBridge.handle(operation, args)
        }, authorizePopup: { [weak self] opener, _, _ in
            guard let self, self.started, !self.stopping, self.tabs.tab(opener)?.webView != nil else {
                throw NativeRPCError(code: "browser-popup-owner", message: "The popup's native opener is no longer available.")
            }
        }, publish: { [weak self] channel, value in self?.publishUI(channel, value) })
    // Swift 6.4 checks a lazy initial value like a default argument and refuses its mixed isolation; same value, built on first use.
    private lazy var profileAdapter: NativeSafariProfiles = makeProfileAdapter()
    private func makeProfileAdapter() -> NativeSafariProfiles { NativeSafariProfiles(tabs: tabs, bindings: bindings,
        authorizeRetirement: { [weak self] id, tabIDs in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("profile retirement authority") }
            try await self.dependencies.authorizeProfiles(self.dependencies.uiContext,
                .init(domain: "profiles", action: "delete", tier: .alter, profileID: id,
                      details: .array(tabIDs.map(NativeRPCValue.string))))
        }, stopProfileWork: { [weak self] id in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("the profile retirement barrier") }
            try await self.stopProfileWork(id)
        },
        requireKnownProfile: { [weak self] id in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("the profile catalogue") }
            // delete already marked this profile retiring; requireProfile would
            // refuse the trusted clear itself. Check the current known row here.
            guard try await self.profiles.state().profiles.contains(where: { $0.id == id }) else {
                throw NativeRPCError(code: "profile-missing", message: "This profile is no longer known.")
            }
        }, authorizeRead: { [weak self] id in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("profile read authority") }
            try await self.profiles.requireProfile(id)
            try await self.dependencies.authorizeProfiles(self.dependencies.uiContext,
                .init(domain: "profiles", action: "list", tier: .read, profileID: id))
        }) }
    private lazy var passwordAdapter = NativeSafariPasswords(ownership: { [weak self] id in
        guard let self, let tab = self.tabs.tab(id), !self.runtime.isTransientPopup(id) else { return nil }
        return .init(profileID: tab.profile, isolated: tab.isolated,
            agentHolding: self.bindings.owner(of: id) != nil || self.service.agentHolds(id) || tab.handoverPrompt != nil)
    }, signInOffer: { [weak self] id, value in
        self?.tabs.tab(id)?.savedSignInOffer = value
        self?.publishUI("browser:signin-offer", (value ?? .object([])).setting("tabId", .string(id)))
    }, passwordOffer: { [weak self] id, summary in
        self?.passwordOffered(id, summary: summary)
    }, reportFailure: { [weak self] message in self?.report(.init(code: "browser-password", message: message)) })
    private lazy var signIn = NativeSafariPasswords.signInHost(readVersionOutput: { [dependencies] provider in
        guard let read = dependencies.readVersionOutput else { throw NativeCompositionBrowserDependencies.unavailable("the login-PATH version runner") }
        return try await read(provider)
    })
    private lazy var workerAdapter = NativeSafariWorkers(tabs: tabs, profiles: profiles,
        authorize: dependencies.authorizeScraping, profilesChanged: { [weak self] state in try await self?.profilesChanged(state) })
    private(set) lazy var workers = BackendBrowserWorkers(dataRoot: dataRoot, hooks: workerAdapter.hooks(), changed: { [weak self] in
        await self?.scheduleChanged()
    })
    private(set) lazy var service = BackendBrowserService(runtime: runtime, bindings: bindings,
        resolve: dependencies.resolve, resolveSession: dependencies.resolveSession,
        resolveProfile: { [weak self] context, named in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("profile authority") }
            let caller = BackendBrowserScrapingCaller.native(context)
            let id = try await self.resolveProfile(caller, named: named)
            let profile = try await self.profiles.state().resolve(id)
            return .init(id: profile.id, name: profile.name, partition: profile.partition)
        }, resolveCreationProfile: { [weak self] context, named in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("worker profile authority") }
            return try await self.workerAdapter.creationProfile(context, requestedID: named, workers: self.workers)
        }, authorize: { [weak self] access in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("browser authority") }
            try await self.dependencies.authorizeBrowser(access)
            if let id = access.tabID, access.principal.sessionID != nil || access.targetSession != nil {
                try await self.lifecycles[id]?.yieldToDrive()
            }
        }, publish: { [registry] context, channel, value in
            try await registry.publish(channel, arguments: [value], ownerID: context.ownerID)
        }, reportEventFailure: dependencies.report, forward: dependencies.forward)
    private lazy var websiteData = BackendBrowserWebsiteData(runtime: runtime,
        resolveProfile: { [weak self] context, named in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("profile authority") }
            let id = try await self.resolveProfile(.native(context), named: named)
            let profile = try await self.profiles.state().resolve(id)
            return .init(id: profile.id, name: profile.name, partition: profile.partition)
        }, authorize: { [dependencies] context, action, profile, site in
            try await dependencies.authorizeProfiles(context,
                .init(domain: "data", action: action, tier: action.hasPrefix("clear") ? .alter : .read,
                      profileID: profile, origin: site))
        })
    private(set) lazy var recipes = BackendBrowserRecipes(dataRoot: dataRoot, catalogue: BackendBrowserRecipeCatalogue.entries,
        authorize: { [dependencies] context, action, id in
            try await dependencies.authorizeProfiles(context,
                .init(domain: "store", action: action, tier: action == "list" ? .read : .alter, details: id.map(NativeRPCValue.string) ?? .missing))
        }, extract: { [service] context, args in try await service.page(context, operation: "extract", arguments: args, sessionReader: true) })
    private(set) lazy var scrapingStore = BackendBrowserScrapingStore(dataRoot: dataRoot, changed: { [weak self] profile in
        // Return from the store callback before reconcile: summaries themselves
        // publish here and awaiting reconcile inside that write would deadlock.
        await self?.scheduleChanged(profile: profile)
    })
    private lazy var assetFetch = NativeSafariCaptureAssetFetch(store: { [weak self] id in
        guard let self, self.started, !self.retiringProfiles.contains(id), self.installedProfiles.contains(id) else {
            throw NativeRPCError(code: "profile-retiring", message: "This browser profile is unavailable or being retired.")
        }
        return self.tabs.store(for: id)
    }, authorize: dependencies.authorizeScraping)
    private(set) lazy var assets = BackendBrowserScrapingAssets(store: scrapingStore, hooks: assetHooks)
    /// The one Safari asset transport (this app's own WebKit profile, per-redirect grants), shared
    /// by browser.scraping and the deck-tools assets.* domain (TS: one assetFetchFor/probeAsset).
    private(set) lazy var assetHooks = BackendBrowserAssetHooks(
        resolveProfile: { [weak self] caller, named in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("asset profile authority") }
            if named == nil || named == BackendBrowserAssetHooks.publicProfileID { return BackendBrowserAssetHooks.publicProfileID }
            return try await self.resolveProfile(caller, named: named)
        }, fetch: { [weak self] caller, profile, url, method, maximum in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("asset transport") }
            return try await self.fetchAsset(caller, profile: profile, url: url, method: method, maximum: maximum)
        }, probe: { [weak self] caller, profile, url, dimensions in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("asset probe") }
            return try await self.probeAsset(caller, profile: profile, url: url, dimensions: dimensions)
        }, directory: { [dependencies] caller, path in
            guard let directory = dependencies.assetDirectory else { throw NativeCompositionBrowserDependencies.unavailable("approved asset directories") }
            return try await directory(caller, path)
        }, file: { [dependencies] caller, path in
            guard let file = dependencies.assetFile else { throw NativeCompositionBrowserDependencies.unavailable("approved asset files") }
            return try await file(caller, path)
        }, authorize: dependencies.authorizeScraping)
    private(set) lazy var network = BackendBrowserNetworkCapture(store: scrapingStore, hooks: .init(
        target: { [weak self] caller, args in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("capture target authority") }
            return try await self.captureTarget(caller, args: args)
        }, observe: { [weak self] caller, target, sink in
            guard let self, let bridge = await self.captures[target.tabID] else { throw NativeCompositionBrowserDependencies.unavailable("the live capture observer") }
            let observation = try await bridge.start(caller: caller, target: target, sink: sink)
            await self.noteCaptureHolder(caller.holder, tabID: target.tabID)
            return observation
        }, authorize: dependencies.authorizeScraping))
    private lazy var liftAdapter = NativeSafariSessionLift(changed: { [weak self] in self?.scheduleChanged() },
        seedOutcome: { [weak self] report in self?.publishUI("browser-worker:seed-outcome", report.wireValue) })
    /// Signed-in hosts per profile, recorded as lifts land (deck-tools browser.workers metadata).
    let signIns = BackendCompositionDeckToolsWorkerSignIns()
    private lazy var sessionLift = BackendBrowserSessionLift(hooks: signIns.recording(liftAdapter.makeHooks(
        source: { [weak self] caller, tab, profile in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("session lift source authority") }
            return try await self.liftSource(caller, tab: tab, profile: profile)
        }, targets: { [weak self] caller, ids, origin in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("session lift target authority") }
            return try await self.liftTargets(caller, ids: ids, origin: origin)
        }, approve: { [dependencies] caller, source, targets in
            guard let approve = dependencies.approveLift else { throw NativeCompositionBrowserDependencies.unavailable("a fresh native session-transfer approval") }
            return try await approve(caller, source, targets)
        })), authorize: dependencies.authorizeScraping, changed: { [weak self] in await self?.scheduleChanged() })
    private(set) lazy var inbox: BackendBrowserWorkersLiftRequests = makeInbox()
    private func makeInbox() -> BackendBrowserWorkersLiftRequests { BackendBrowserWorkersLiftRequests(profiles: { [workerAdapter] caller in
        try await workerAdapter.hooks().profiles(caller)
    }, authorize: dependencies.authorizeScraping, changed: { [weak self] in await self?.scheduleChanged() },
        transfer: { [sessionLift] caller, ask in try await sessionLift.approveRequest(caller, request: ask) }) }
    private(set) lazy var scrapingRPC = BackendBrowserScrapingRPC(workers: workers, store: scrapingStore,
        assets: assets, network: network, inbox: inbox, resolveProfile: { [weak self] caller, named in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("scraping profile authority") }
            return try await self.resolveProfile(caller, named: named)
        }, profiles: { [workerAdapter] caller in try await workerAdapter.hooks().profiles(caller) },
        authorize: dependencies.authorizeScraping, reveal: { [dependencies] caller, url in
            try await dependencies.authorizeScraping(caller, "browser.scraping.reveal", nil, nil, .string(url.path))
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }, sessionLift: sessionLift)
    private lazy var arming = BackendWebKitProfileArming(store: scrapingStore, network: network, assets: assets, hooks: .init(
        authorize: dependencies.authorizeScraping, baton: { [weak self] target in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("the current browser baton") }
            return try await self.baton(target)
        }, networkArguments: { target in .object([.init("nativeTab", .string(target.tabID))]) },
        applyRules: { [weak self] caller, target, plan in
            guard let self, let rules = await self.rules[target.tabID] else { throw NativeCompositionBrowserDependencies.unavailable("this tab's content-rule owner") }
            try await rules.apply(caller: caller, target: target, plan: plan)
        }, removeRules: { [weak self] id in await self?.rules[id]?.remove() },
        recordBlock: { [weak self] caller, target, requested, status, failure in
            guard let self, let capture = await self.captures[target.tabID] else { throw NativeCompositionBrowserDependencies.unavailable("this tab's block capture") }
            return try await capture.recordBlock(caller: caller, store: self.scrapingStore, requestedURL: requested, httpStatus: status, failure: failure)
        }, safeText: { [weak self] caller, target, maximum in
            guard let self else { throw NativeCompositionBrowserDependencies.unavailable("privacy-safe page text") }
            return try await self.safeText(caller, target: target, maximum: maximum)
        }, changed: { [weak self] id, state in await self?.publishUI("browser-profile:arming", state.setting("tabId", .string(id))) }))
    private var downloadsService: BackendBrowserDownloads?
    private var nativeDownloads: NativeSafariDownloads?
    private var downloadsRPC: BackendBrowserDownloadsRPC?

    func start() async throws {
        guard !started, !stopping else { return }
        guard dependencies.transferredSessionAuthority, dependencies.mcpContext != nil else {
            throw NativeCompositionBrowserDependencies.unavailable("the completed session/MCP authority transfer; Node's browser driver remains authoritative")
        }
        try dependencies.requireWriter()
        guard await dependencies.isCurrentUI(dependencies.uiContext) else { throw NativeCompositionBrowserDependencies.unavailable("the current native UI owner") }
        ownsLegacyCutover = true
        await tabs.retireLegacyBrowserOwners()
        do {
            try Task.checkCancellation()
            guard !stopping else { throw NativeRPCError(code: "browser-shutdown", message: "The browser closed while its native graph was starting.") }
            try await profiles.open()
            try await profilesChanged(try await profiles.state())
            passwordAdapter.connect(passwords)
            try await passwords.open()
            let storeURL = dataRoot.appendingPathComponent("webkit-content-rules", isDirectory: true)
            try BackendBrowserScrapingPaths.rejectSymlinks(storeURL)
            try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
            ruleStore = WKContentRuleListStore(url: storeURL)
            guard ruleStore != nil else { throw NativeCompositionBrowserDependencies.unavailable("the app-owned WebKit content-rule store") }
            let downloads = try BackendBrowserDownloads(dataRoot: dataRoot, defaultFolder: downloadsDirectory,
                applicationName: "Terminal Deck", dependencies: NativeSafariDownloadsSystem.dependencies(
                    authorize: { [weak self] context, access in
                        guard let self else { throw NativeCompositionBrowserDependencies.unavailable("the native download authority") }
                        try await self.dependencies.authorizeDownloads(context, access)
                        if access.operation == .start, let binding = access.binding {
                            try await self.validateDownloadStart(binding)
                        }
                    }, parentWindow: dependencies.parentWindow, deliver: dependencies.deliverDownload))
            downloadsService = downloads
            let facade = NativeSafariDownloads(service: downloads, context: dependencies.uiContext, applicationName: "Terminal Deck",
                resolveBinding: { [weak self] view in
                    guard let self, let tab = self.tabs.tabs.first(where: { $0.webView === view }) else {
                        throw NativeRPCError(code: "download-owner", message: "This download has no live native tab owner.")
                    }
                    let owner = self.bindings.owner(of: tab.id)
                    return (self.dependencies.uiContext, .init(tabID: tab.id,
                        profileID: self.profileID(tab), sessionID: owner?.sessionId, machineID: owner?.machineId ?? "", origin: view.url))
                }, showDownloads: { [weak tabs] in tabs?.downloadsShown = true })
            try await facade.start(); nativeDownloads = facade
            let downloadsRPC = BackendBrowserDownloadsRPC(downloads: downloads, attended: dependencies.isCurrentUI)
            self.downloadsRPC = downloadsRPC
            subscriptions = try await BackendBrowserFactories.registerChannels(registry, service: service, ownerID: Self.ownerID)
            try await websiteData.registerChannels(registry, ownerID: Self.ownerID)
            try await recipes.registerChannels(registry, ownerID: Self.ownerID)
            try await BackendBrowserProfilesChannels.register(in: registry, ownerID: Self.ownerID, profiles: profiles,
                passwords: passwords, signIn: signIn, authorize: dependencies.authorizeProfiles,
                changed: { [weak self] state in try await self?.profilesChanged(state) })
            try await downloadsRPC.registerChannels(in: registry, ownerID: Self.ownerID)
            try await scrapingRPC.register(on: registry, ownerID: Self.ownerID)
            try await registerTools(downloadsRPC)
            eventTasks[dependencies.uiContext.ownerID] = try await downloadsRPC.forwardEvents(to: registry, context: dependencies.uiContext)
            started = true
            tabs.installNativeBrowser(self, downloads: facade)
            for tab in tabs.tabs { tab.reopenForNativeComposition() }
        } catch {
            dependencies.report(.wrapping(error))
            do { try await stop() } catch { dependencies.report(.wrapping(error)) }
            throw error
        }
    }

    private func registerTools(_ downloadsRPC: BackendBrowserDownloadsRPC) async throws {
        let staging = BackendNativeMCPServer()
        let context: BackendBrowserFactories.MCPContext = { [dependencies] caller in
            guard let resolve = dependencies.mcpContext else { throw NativeCompositionBrowserDependencies.unavailable("the authenticated MCP caller table") }
            return try await resolve(caller)
        }
        try await BackendBrowserFactories.registerTools(staging, service: service, context: context)
        try await websiteData.registerTools(staging, context: context)
        try await recipes.registerTools(staging, context: context)
        try await BackendBrowserProfilesToolFactories.register(in: staging, profiles: profiles, passwords: passwords,
            signIn: signIn, authorize: { [dependencies] caller, operation in
                guard let authorize = dependencies.authorizeProfileTool else { throw NativeCompositionBrowserDependencies.unavailable("MCP profile/action consent and current tiers") }
                return try await authorize(caller, operation)
            }, resolveWindow: { [dependencies] caller, window, session in
                guard let resolve = dependencies.resolveToolWindow else { throw NativeCompositionBrowserDependencies.unavailable("authorized MCP window and session resolution") }
                return try await resolve(caller, window, session)
            }, changed: { [weak self] state in try await self?.profilesChanged(state) })
        try await downloadsRPC.registerMCP(in: staging, resolveCaller: { [dependencies] caller in
            guard let resolve = dependencies.resolveDownloadTool else { throw NativeCompositionBrowserDependencies.unavailable("authenticated MCP download caller grants") }
            return try await resolve(caller)
        })
        try await BackendBrowserScrapingMCP.install(on: staging, rpc: scrapingRPC, authorizeCall: { [dependencies] caller, tool, tier, args in
            guard let authorize = dependencies.authorizeScrapingTool else { throw NativeCompositionBrowserDependencies.unavailable("MCP scraping action tiers, budgets and consent") }
            return try await authorize(caller, tool, tier, args)
        })
        let collected = await staging.registrations().filter { !excludedMCPToolIDs.contains($0.0.id) }
        let contribution: [(BackendMCPTool, BackendNativeMCPServer.Handler)] = collected.map { spec, handler in
            (spec, { [dependencies] caller, arguments in
                guard let resolve = dependencies.mcpContext else {
                    throw NativeCompositionBrowserDependencies.unavailable("the authenticated MCP caller table")
                }
                let context = try await resolve(caller)
                return try await NativeCompositionCallContext.$rpc.withValue(context) {
                    try await handler(caller, arguments)
                }
            })
        }
        try await mcp.replaceTools(ownerID: Self.ownerID, tools: contribution)
        registeredMCPToolIDs = contribution.map { $0.0.id }.sorted()
    }

    func stop() async throws {
        if stopping {
            if let stopFailure { throw stopFailure }
            guard stopFinished else { throw NativeRPCError(code: "browser-drain-in-progress", message: "The browser is still draining its existing operations.") }
            return
        }
        stopping = true
        guard started || ownsLegacyCutover else { stopFinished = true; return }
        service.shutdown()
        var failures: [String] = []
        for task in eventTasks.values { task.cancel() }
        for task in eventTasks.values { _ = try? await task.value }; eventTasks.removeAll()
        for operation in assetOperations.values { operation.cancel() }
        for operation in assetOperations.values { await operation.drain() }
        await dataBridge.shutdown()
        await nativeDownloads?.stop()
        do { try await liftAdapter.stop() } catch { failures.append(error.localizedDescription) }
        for id in Array(liveViews.keys) {
            do { try await retirePage(id, reason: .appShutdown) } catch { failures.append(error.localizedDescription) }
        }
        // Page close may have queued a retained retirement; await all of it.
        while !lifecycleTasks.isEmpty {
            for task in Array(lifecycleTasks.values) { await task.value }
        }
        for tab in tabs.tabs { tab.tearDown() }
        runtime.shutdown(); passwordAdapter.shutdown(); liftAdapter.shutdown()
        do { try await profiles.flushHistory(); try await profiles.close() } catch { failures.append(error.localizedDescription) }
        await passwords.close()
        for token in subscriptions { await token.cancelAndWait() }; subscriptions.removeAll()
        await registry.removeOwner(Self.ownerID)
        await mcp.removeTools(ownerID: Self.ownerID)
        registeredMCPToolIDs = []
        tabs.uninstallNativeBrowser(self)
        nativeDownloads = nil; downloadsRPC = nil; ruleStore = nil; started = false
        stopFinished = true
        if !failures.isEmpty {
            let failure = NativeRPCError(code: "browser-drain", message: failures.joined(separator: "\n"))
            stopFailure = failure
            throw failure
        }
    }

    func disconnect(_ context: NativeRPCContext) async {
        service.disconnect(context.ownerID)
        let caller = BackendBrowserScrapingCaller.native(context)
        await scrapingRPC.disconnect(caller); await sessionLift.disconnect(holder: caller.holder)
        if let task = eventTasks.removeValue(forKey: context.ownerID) { task.cancel(); _ = try? await task.value }
    }
    private func report(_ failure: NativeRPCError) { dependencies.report(failure); tabs.show(failure.message) }
    private func retainLifecycle(_ operation: @escaping @MainActor () async throws -> Void) {
        let id = UUID()
        lifecycleTasks[id] = Task { [weak self] in
            defer { self?.lifecycleTasks[id] = nil }
            do { try await operation() } catch { self?.report(.wrapping(error)) }
        }
    }
    private func publishUI(_ channel: String, _ value: NativeRPCValue) {
        guard !stopping else { return }
        retainLifecycle { [dependencies, registry] in
            guard await dependencies.isCurrentUI(dependencies.uiContext) else { return }
            try await registry.publish(channel, arguments: [value], ownerID: dependencies.uiContext.ownerID)
        }
    }
    private func scheduleChanged(profile: String? = nil) {
        guard !stopping else { return }
        retainLifecycle { [weak self] in
            guard let self else { return }
            await self.scrapingRPC.publishChanged(on: self.registry, profile: profile)
            if let profile { await self.arming.settingsChanged(profileID: profile) }
        }
    }
    private func profilesChanged(_ state: BackendBrowserProfileState) async throws {
        try await dependencies.authorizeProfiles(dependencies.uiContext, .init(domain: "profiles", action: "list", tier: .read))
        tabs.applyNativeProfiles(state.wireValue.foundation ?? NSNull())
        for profile in state.profiles where !state.retiringIDs.contains(profile.id) {
            if !installedProfiles.contains(profile.id) {
                try liftAdapter.bindProfile(profileID: profile.id, name: profile.name, store: tabs.store(for: profile.id))
                installedProfiles.insert(profile.id)
            }
        }
        for id in installedProfiles.subtracting(state.profiles.map(\.id)) { liftAdapter.unbindProfile(id); installedProfiles.remove(id) }
        try await registry.publish("browser-profile:state", arguments: [state.wireValue], ownerID: dependencies.uiContext.ownerID)
    }
    private func resolveProfile(_ caller: BackendBrowserScrapingCaller, named: String?) async throws -> String {
        let normalized = named == "" ? "default" : named
        let state = try await profiles.state()
        let profile: BackendBrowserProfile
        if let normalized {
            let matches = state.profiles.filter { $0.id == normalized || $0.name.lowercased() == normalized.lowercased() }
            guard matches.count == 1, let known = matches.first else { throw NativeRPCError.invalidArguments("Name one unambiguous browser profile.") }
            profile = known
        } else { profile = try state.resolve(nil) }
        try await profiles.requireProfile(profile.id)
        try await dependencies.authorizeScraping(caller, "browser.profile.resolve", profile.id, nil, .missing)
        return profile.id
    }
    private func profileID(_ tab: NativeBrowserTab) -> String {
        tab.isolated ? "isolated-" + tab.id : BackendBrowserProfiles.normalizedID(tab.profile)
    }
    private func authorizeDataFetch(partition: String, url: URL, operation: String) async throws {
        guard let context = NativeCompositionCallContext.rpc else {
            throw NativeCompositionBrowserDependencies.unavailable("the authenticated raw-data request context")
        }
        let prefix = "persist:terminaldeck-browser"
        let profile = partition == prefix ? "default" : partition.hasPrefix(prefix + "-") ? String(partition.dropFirst((prefix + "-").count)) : nil
        if let profile {
            try await profiles.requireProfile(profile)
            guard !retiringProfiles.contains(profile) else { throw NativeRPCError(code: "profile-retiring", message: "This profile is being retired.") }
        }
        let principal = try await dependencies.resolve(context)
        guard principal.managesWindows else { throw NativeRPCError(code: "access-denied", message: "Raw browser data requires the person's current profile grant.") }
        try await dependencies.authorizeBrowser(.init(tool: "browser-data:fetch", principal: principal,
            profileID: profile ?? partition, origin: BackendBrowserOrigin.exact(url.absoluteString), tier: .alter,
            arguments: .object([.init("phase", .string(operation)), .init("partition", .string(partition)), .init("url", .string(url.absoluteString))])))
    }
    private func fetchAsset(_ caller: BackendBrowserScrapingCaller, profile: String, url: URL, method: String, maximum: Int) async throws -> BackendBrowserAssetResponse {
        if profile != BackendBrowserAssetHooks.publicProfileID { try await profiles.requireProfile(profile) }
        guard !retiringProfiles.contains(profile), !stopping else { throw CancellationError() }
        let task = Task { [assetFetch] in try await assetFetch.fetch(caller: caller, profileID: profile, url: url, method: method, maximumBytes: maximum) }
        let id = UUID(); assetOperations[id] = (profile, { task.cancel() }, { _ = try? await task.value })
        defer { assetOperations[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func probeAsset(_ caller: BackendBrowserScrapingCaller, profile: String, url: URL, dimensions: Bool) async throws -> BackendBrowserRenditionProbe? {
        if profile != BackendBrowserAssetHooks.publicProfileID { try await profiles.requireProfile(profile) }
        guard !retiringProfiles.contains(profile), !stopping else { throw CancellationError() }
        let task = Task { [assetFetch] in try await assetFetch.probe(caller: caller, profileID: profile, url: url, dimensions: dimensions) }
        let id = UUID(); assetOperations[id] = (profile, { task.cancel() }, { _ = try? await task.value })
        defer { assetOperations[id] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func captureTarget(_ caller: BackendBrowserScrapingCaller, args: NativeRPCValue) async throws -> BackendBrowserCaptureTarget {
        let id: String
        if let internalID = args["nativeTab"].string {
            // This key is produced only by the profile lifecycle above. MCP's
            // closed schema has no such property, and the app owner is required.
            guard let context = caller.rpc, await dependencies.isCurrentUI(context), context.ownerID == dependencies.uiContext.ownerID else {
                throw NativeRPCError(code: "access-denied", message: "A passive profile target belongs to the native app owner.")
            }
            id = internalID
        } else {
            guard let window = args["window"].string else { throw NativeRPCError.invalidArguments("Capture needs an authorized window.") }
            let session: BrowserDriverSession?
            if let requested = args["sessionId"].string { session = try await dependencies.resolveSession(requested) }
            else if let own = caller.sessionID { session = try await dependencies.resolveSession(own) }
            else { session = nil }
            guard let context = caller.rpc else { throw NativeCompositionBrowserDependencies.unavailable("capture caller provenance") }
            let principal = try await service.principal(context)
            guard principal.managesWindows || session?.sessionId == principal.sessionID,
                  let target = bindings.named(window, session: window.uppercased().hasPrefix("B") ? session : nil) else {
                throw NativeRPCError(code: "access-denied", message: "This caller does not own that capture window.")
            }
            id = target.tabID
        }
        guard let tab = tabs.tab(id), let view = tab.webView, liveViews[id] === view,
              tab.handoverPrompt == nil, let url = requestedURLs[id] ?? view.url,
              BackendBrowserOrigin.exact(url.absoluteString) != nil else { throw NativeRPCError(code: "capture-target", message: "This capture has no current permitted HTTP(S) page.") }
        let profile = profileID(tab)
        if !tab.isolated { try await profiles.requireProfile(profile) }
        try await dependencies.authorizeScraping(caller, "browser.network.target", profile, url, args)
        return .init(tabID: id, profileID: profile, pageURL: url, title: tab.title)
    }
    private func baton(_ target: BackendBrowserCaptureTarget) throws -> BackendWebKitProfileArmingBaton {
        guard let tab = tabs.tab(target.tabID), liveViews[target.tabID] === tab.webView,
              profileID(tab) == target.profileID else { throw NativeRPCError(code: "capture-target", message: "This page's profile changed.") }
        if tab.handoverPrompt != nil { return .human }
        return bindings.owner(of: tab.id) == nil ? .unclaimed : .agent
    }
    private func safeText(_ caller: BackendBrowserScrapingCaller, target: BackendBrowserCaptureTarget, maximum: Int) async throws -> String {
        try await dependencies.authorizeScraping(caller, "browser.profile-arm.coverage", target.profileID, target.pageURL, .missing)
        guard try baton(target) == .unclaimed else { throw NativeRPCError(code: "access-denied", message: "The person cannot passively read an agent-held page.") }
        let raw = try await runtime.evaluate(target.tabID, BrowserDriverScripts.with(BrowserDriverScripts.outline, args: ["textLimit": maximum, "limit": 0]))
        let value = try NativeRPCValue.fromFoundation(raw)
        return value["text"].string ?? value["body"].string ?? ""
    }
    private func liftSource(_ caller: BackendBrowserScrapingCaller, tab: String?, profile: String?) async throws -> BackendBrowserSessionLiftSource {
        if let tab {
            guard let nativeTab = tabs.tab(tab), !nativeTab.isolated, nativeTab.handoverPrompt == nil else { throw NativeRPCError(code: "lift-source", message: "Select one regular native source page.") }
            _ = try await resolveProfile(caller, named: nativeTab.profile)
            return try liftAdapter.source(tabID: tab)
        }
        let id = try await resolveProfile(caller, named: profile)
        return try liftAdapter.source(profileID: id)
    }
    private func liftTargets(_ caller: BackendBrowserScrapingCaller, ids: [String]?, origin: String) async throws -> [BackendBrowserSessionLiftTarget] {
        let fleet = try await workers.view(caller)
        let visible = Set(fleet["workers"].elements?.compactMap { $0["profileId"].string } ?? [])
        let selected = ids ?? Array(visible).sorted()
        var result: [BackendBrowserSessionLiftTarget] = []
        for id in selected {
            guard visible.contains(id) else { throw NativeRPCError(code: "lift-target", message: "This profile is not a currently granted worker.") }
            _ = try await self.resolveProfile(caller, named: id)
            result.append(try self.liftAdapter.target(profileID: id, origin: origin))
        }
        return result
    }

    // Existing tabs/delegates keep presentation ownership and call these seams.
    func prepareConfiguration(_ configuration: WKWebViewConfiguration) {
        runtime.prepareConfiguration(configuration); passwordAdapter.install(into: configuration)
    }
    func attached(_ tab: NativeBrowserTab) {
        guard started, !stopping, let view = tab.webView else { return }
        do {
            try runtime.attachPage(tab.id); runtime.note(tab)
            liveViews[tab.id] = view
            try nativeDownloads?.bind(view)
            if !runtime.isTransientPopup(tab.id) {
                passwordAdapter.bind(view, tabID: tab.id)
                if !tab.isolated { try liftAdapter.bindPage(view, tabID: tab.id, profileID: profileID(tab)) }
            }
            let profile = profileID(tab)
            captures[tab.id] = NativeSafariCaptureBridge(webView: view, tabID: tab.id, profileID: profile,
                authorize: { [weak self] caller, id, frameURL, resourceURL in
                    guard let self else { throw NativeCompositionBrowserDependencies.unavailable("frame capture authority") }
                    try await self.authorizeCapture(caller, tabID: tab.id, profileID: id, frameURL: frameURL, resourceURL: resourceURL)
                }, safeSnapshot: { [weak self] caller, id, profile in
                    guard let self else { throw NativeCompositionBrowserDependencies.unavailable("privacy-safe snapshots") }
                    return try await self.safeSnapshot(caller, tabID: id, profileID: profile)
                })
            if let ruleStore {
                rules[tab.id] = NativeSafariProfileArmingRules(webView: view, tabID: tab.id, profileID: profile,
                    dataRoot: dataRoot, ruleStore: ruleStore, authorize: dependencies.authorizeScraping,
                    report: { [weak self] message in self?.report(.init(code: "browser-rules", message: message)) })
                lifecycles[tab.id] = NativeSafariProfileArming(webView: view, tabID: tab.id, profileID: profile,
                    manager: arming, caller: .native(dependencies.uiContext),
                    report: { [weak self] message in self?.report(.init(code: "browser-arming", message: message)) })
            }
        } catch { report(.wrapping(error)); view.stopLoading() }
    }
    func note(_ tab: NativeBrowserTab) {
        guard started, !stopping else { return }
        runtime.note(tab)
        if tabs.selectedID == tab.id, !tab.isolated {
            retainLifecycle { [weak self] in _ = try await self?.liftAdapter.applyQueuedSeed(tabID: tab.id) }
        }
    }
    func navigationStarted(_ tab: NativeBrowserTab) { runtime.navigationStarted(tab.id); responseStatus[tab.id] = nil }
    func prepareNavigation(_ tab: NativeBrowserTab, url: URL) async throws {
        guard started, !stopping, !runtime.isTransientPopup(tab.id) else { return }
        if let retirement = retirements[tab.id] { try await retirement.value; retirements[tab.id] = nil }
        if !tab.isolated { try await profiles.requireProfile(profileID(tab)) }
        requestedURLs[tab.id] = url
        if let lifecycle = lifecycles[tab.id] { try await lifecycle.start(); try await lifecycle.prepareNavigation(url, canvasHex: nil) }
    }
    func committed(_ tab: NativeBrowserTab) {
        guard let view = tab.webView else { return }
        passwordAdapter.didCommit(view, tabID: tab.id); liftAdapter.didCommit(view, tabID: tab.id)
        runtime.note(tab)
        retainLifecycle { [weak self] in
            guard let self else { return }
            try await self.lifecycles[tab.id]?.committed()
            if !tab.isolated, !self.runtime.isTransientPopup(tab.id), let url = view.url {
                try await self.profiles.remember(profileID: self.profileID(tab), url: url.absoluteString, title: tab.title)
                _ = try await self.liftAdapter.applyQueuedSeed(tabID: tab.id)
            }
        }
    }
    func titleChanged(_ tab: NativeBrowserTab) {
        guard !tab.isolated, !runtime.isTransientPopup(tab.id), let url = tab.webView?.url else { return }
        retainLifecycle { [profiles] in try await profiles.retitle(profileID: BackendBrowserProfiles.normalizedID(tab.profile), url: url.absoluteString, title: tab.title) }
    }
    func response(_ tab: NativeBrowserTab, response: URLResponse) { responseStatus[tab.id] = (response as? HTTPURLResponse)?.statusCode }
    func settled(_ tab: NativeBrowserTab, error: Error? = nil) {
        guard let url = requestedURLs[tab.id] ?? tab.webView?.url else { return }
        retainLifecycle { [weak self] in
            guard let self else { return }
            await self.lifecycles[tab.id]?.settled(requestedURL: url, httpStatus: self.responseStatus[tab.id], error: error)
            if !tab.isolated { _ = try await self.liftAdapter.applyQueuedSeed(tabID: tab.id) }
        }
        requestedURLs[tab.id] = nil
    }
    func detached(_ tab: NativeBrowserTab) {
        guard liveViews[tab.id] === tab.webView, liveViews[tab.id] != nil else { return }
        passwordAdapter.unbind(tabID: tab.id); liftAdapter.unbindPage(tab.id); runtime.detachedPage(tab.id)
        let task = beginRetirement(tab.id, reason: .tabClosed)
        retainLifecycle { try await task.value }
    }
    func adoptPopup(configuration: WKWebViewConfiguration, opener: NativeBrowserTab,
                    requestedURL: URL?, features: WKWindowFeatures) -> WKWebView? {
        let sized = features.width != nil || features.height != nil || features.x != nil || features.y != nil
        do {
            let view = try runtime.adoptPopup(configuration: configuration, openerID: opener.id, requestedURL: requestedURL, transientSignIn: sized)
            if sized, let tab = tabs.tabs.first(where: { $0.webView === view }) {
                passwordAdapter.unbind(tabID: tab.id); liftAdapter.unbindPage(tab.id)
                let task = beginRetirement(tab.id, reason: .profileChanged)
                retainLifecycle { try await task.value }
            }
            return view
        }
        catch { report(.wrapping(error)); return nil }
    }
    func suggest(profile: String, typed: String) async throws -> [BrowserVisit] {
        try await profiles.suggest(profileID: BackendBrowserProfiles.normalizedID(profile), typed: typed)
    }
    private func authorizeCapture(_ caller: BackendBrowserScrapingCaller, tabID: String, profileID: String,
                                  frameURL: URL, resourceURL: URL) async throws {
        guard let tab = tabs.tab(tabID), self.profileID(tab) == profileID, tab.handoverPrompt == nil,
              liveViews[tabID] === tab.webView else { throw NativeRPCError(code: "access-denied", message: "This capture page is no longer owned by the caller.") }
        try await dependencies.authorizeScraping(caller, "browser.capture.frame", profileID, frameURL, .object([.init("tabId", .string(tabID))]))
        try await dependencies.authorizeScraping(caller, "browser.capture.resource", profileID, resourceURL, .object([.init("tabId", .string(tabID))]))
    }
    private func safeSnapshot(_ caller: BackendBrowserScrapingCaller, tabID: String, profileID: String) async throws -> Data {
        guard let tab = tabs.tab(tabID), let view = tab.webView, let url = view.url else { throw NativeRPCError(code: "capture-target", message: "The captured page closed.") }
        try await authorizeCapture(caller, tabID: tabID, profileID: profileID, frameURL: url, resourceURL: url)
        let png = try await runtime.privacySnapshotPNG(tabID)
        try await authorizeCapture(caller, tabID: tabID, profileID: profileID, frameURL: url, resourceURL: url)
        guard tabs.tab(tabID)?.webView === view, view.url == url else { throw NativeRPCError(code: "capture-target", message: "The captured document changed before its image could be returned.") }
        return png.bytes
    }
    private func retirePage(_ id: String, reason: BackendBrowserNetworkCapture.CleanupReason) async throws {
        let task = retirements[id] ?? beginRetirement(id, reason: reason)
        try await task.value; retirements[id] = nil
    }
    private func noteCaptureHolder(_ holder: String, tabID: String) { captureHolders[tabID] = holder }
    private func beginRetirement(_ id: String, reason: BackendBrowserNetworkCapture.CleanupReason) -> Task<Void, Error> {
        if let existing = retirements[id] { return existing }
        let capture = captures.removeValue(forKey: id)
        let lifecycle = lifecycles.removeValue(forKey: id)
        let rules = rules.removeValue(forKey: id)
        let view = liveViews.removeValue(forKey: id)
        let profile = capture?.profileID
        let holder = captureHolders.removeValue(forKey: id) ?? BackendBrowserScrapingCaller.native(dependencies.uiContext).holder
        requestedURLs[id] = nil
        let task = Task { [network, nativeDownloads] in
            // Keep the exact retired page alive while public WebKit callbacks
            // drain. A replacement using the same tab ID awaits this barrier.
            _ = view
            if let view { await nativeDownloads?.stop(webView: view) }
            if let profile {
                do { _ = try await network.cleanup(tabID: id, profileID: profile, ownerHolder: holder, reason: reason) }
                catch let failure as NativeRPCError where failure.code == "not-armed" { }
            }
            try await lifecycle?.close(); await rules?.detach(); await capture?.detach()
        }
        retirements[id] = task; return task
    }
    private func stopProfileWork(_ id: String) async throws {
        guard let nativeDownloads, let stopDownloads = dependencies.stopProfileDownloads else {
            throw NativeCompositionBrowserDependencies.unavailable("scoped WKDownload retirement before clearing this profile")
        }
        retiringProfiles.insert(id); defer { retiringProfiles.remove(id) }
        let operations = assetOperations.values.filter { $0.profile == id }
        for operation in operations { operation.cancel() }
        try await liftAdapter.stop(profileID: id)
        try await stopDownloads(nativeDownloads, id)
        for operation in operations { await operation.drain() }
        await dataBridge.cancel(partition: id == "default" ? "persist:terminaldeck-browser" : "persist:terminaldeck-browser-" + id)
        for tab in tabs.tabs where !tab.isolated && profileID(tab) == id { try await retirePage(tab.id, reason: .profileChanged) }
        liftAdapter.unbindProfile(id); installedProfiles.remove(id)
        // Close every currently known page before the final download barrier,
        // including children created while earlier callbacks were draining.
        for tab in tabs.tabs where !tab.isolated && profileID(tab) == id { tabs.close(tab.id) }
        try await stopDownloads(nativeDownloads, id)
    }
    private func validateDownloadStart(_ binding: BackendBrowserDownloadBinding) async throws {
        guard let tab = tabs.tab(binding.tabID), profileID(tab) == binding.profileID,
              !retiringProfiles.contains(binding.profileID), !stopping else {
            throw NativeRPCError(code: "download-retiring", message: "This download's actual page or profile is being retired.")
        }
        if !tab.isolated { try await profiles.requireProfile(binding.profileID) }
    }
    private func clearProfile(_ id: String) async throws {
        try await profileAdapter.deleteWebsiteData(id); tabs.evictStore(for: id)
    }

    var invokeChannels: [String] {
        ["browser:create", "browser:bindings", "link:open", "browser-view:reveal", "browser:drive-status", "browser:frames"]
            + BackendBrowserFactories.nativePageChannels.keys.sorted() + BackendBrowserFactories.dataChannels
            + ["browser-session:info", "browser-session:cookies", "browser-session:clear-cookies", "browser-session:clear-storage", "browser-session:clear-cache"]
            + ["browser-store:list", "browser-store:install", "browser-store:remove"]
            + BackendBrowserProfilesChannels.channels + BackendBrowserDownloadsRPC.channels + BackendBrowserScrapingRPC.channels.sorted()
    }
    var sendChannels: [String] { ["browser:bind", "browser:unbind", "browser:drive-resume", "browser:bind-new-window"] }
    var eventChannels: [String] {
        ["browser:state", "browser:error", "browser:element", "browser:bindings", "browser:drive-state",
         "browser:signin-offer", "browser:password-offer", "browser-profile:state", "browser-profile:arming",
         "browser:downloads", "browser-scraping:changed", "browser-worker:lift-request", "browser-worker:seed-outcome"]
    }
    func snapshot(_ tab: NativeBrowserTab) async throws -> NativeBrowserShot {
        let principal = try await service.principal(dependencies.uiContext)
        let access = BackendBrowserAccess(tool: "browser-view:frame", principal: principal, tabID: tab.id, tier: .read)
        try await dependencies.authorizeBrowser(access)
        let png = try await runtime.privacySnapshotPNG(tab.id)
        try await dependencies.authorizeBrowser(access)
        guard let image = NSImage(data: png.bytes), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NativeRPCError(code: "browser-image", message: "The privacy-safe page image could not be decoded.")
        }
        return .init(image: image, cgImage: cg, url: tab.url, title: tab.title)
    }
    func saveShot(_ shot: NativeBrowserShot, tabID: String) async throws -> NativeBrowserShot {
        let rep = NSBitmapImageRep(cgImage: shot.cgImage)
        guard let bytes = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let result = try await service.nativePage(dependencies.uiContext, id: tabID,
            operation: "screenshot-marked", arguments: .object([.init("png", .bytes(bytes))]))
        var saved = shot; saved.path = try result["path"].requireString("path", nonempty: true); return saved
    }
    func pick(_ tab: NativeBrowserTab, x: Double, y: Double) async throws -> (rect: CGRect, element: BrowserAnnotatedElement?)? {
        let result = try await service.nativePage(dependencies.uiContext, id: tab.id, operation: "pick",
            arguments: .object([.init("x", .number(x)), .init("y", .number(y))]))
        guard let view = tab.webView, let fields = result.foundation as? [String: Any], !result.isNullish else { return nil }
        let viewport = CGSize(width: view.bounds.width / view.pageZoom, height: view.bounds.height / view.pageZoom)
        guard let rect = BrowserAnnotate.normalise(BrowserDriverEngine.rect(fields["rect"]), viewport: viewport) else { return nil }
        return (rect, BrowserAnnotatedElement.read(fields))
    }
    private func passwordOffered(_ id: String, summary: BackendBrowserLoginSummary) {
        guard let tab = tabs.tab(id) else { return }
        let epoch = tab.documentEpoch
        retainLifecycle { [weak self, weak tab] in
            guard let self, let tab,
                  let offer = try await self.passwords.pendingOffer(), offer.tabID == id, offer.login == summary,
                  tab.documentEpoch == epoch, !tab.isolated, !self.runtime.isTransientPopup(id) else { return }
            for other in self.tabs.tabs { other.savedPasswordOffer = nil }
            tab.savedPasswordOffer = offer
            self.publishUI("browser:password-offer", summary.wireValue.setting("tabId", .string(id)))
        }
    }
    func answerPassword(_ tab: NativeBrowserTab, keep: Bool) async throws -> BackendBrowserPasswordOutcome {
        guard let offered = tab.savedPasswordOffer else { return .init(ok: false, message: "Nothing to save.") }
        let epoch = tab.documentEpoch
        try await dependencies.authorizeProfiles(dependencies.uiContext, .init(domain: "passwords", action: "answer", tier: .alter,
            profileID: offered.login.profileID, tabID: tab.id, origin: offered.login.origin, username: offered.login.username,
            ownerMustAnswer: true, details: .bool(keep)))
        guard tab.documentEpoch == epoch, tab.savedPasswordOffer?.id == offered.id else {
            return .init(ok: false, message: "The page or offered sign-in changed. Nothing was saved.")
        }
        let outcome = try await passwords.answer(keep: keep, expectedOffer: offered.id)
        if outcome.ok { tab.savedPasswordOffer = nil }
        return outcome
    }
    func fillSavedLogin(_ tab: NativeBrowserTab, username: String) async throws -> Bool {
        guard let request = try await passwords.prepareFill(tabID: tab.id, username: username) else { return false }
        try await dependencies.authorizeProfiles(dependencies.uiContext, BackendBrowserProfilesChannels.fillOperation(request))
        return try await passwords.fill(request)
    }
}

@MainActor
private final class NativeCompositionBrowserLink {
    weak var owner: NativeCompositionBrowser?
}
