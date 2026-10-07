import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// catalogue-cost.test.ts over the catalogue the native runtime assembles.
///
/// assembled-catalogue.fixture.ts builds the TS list with the app's own
/// constructor over every source's factory, with stand-in deps because "a
/// tool's id, wire name, description and schema are literals in its factory"
/// and nothing calls a run. This is the same, natively:
///
///  - the runtime-owned bundles (built-ins, app.where, tools.coverage,
///    notifications + MCP, tools.describe/run) exactly as
///    BackendDeckCoreRuntime.start builds them;
///  - deck-tools through the real registrar (BackendDeckToolsRegistration,
///    which refuses an incomplete set) and BackendDeckCoreAreaIntegration;
///    each definition carries the fields its factory copies from the
///    production descriptor tables (Files/Projects/Assets/TourStage,
///    SessionsArea, AppKit, MachinesFactory);
///  - Safari: specs collected from the real registration entry points on a
///    non-listening BackendNativeMCPServer, as NativeCompositionBrowser does,
///    decorated by BackendDeckCoreBrowserMetadata with requireComplete (seam 8);
///  - tasks/knowledge/servers: BackendTaskMCP.register (with the CRM API and
///    delegation, so crm.task and tasks.delegate exist), BackendKnowledgeMCP
///    and BackendServersTools specs, decorated by
///    BackendDeckCoreSupplementMetadata with requireComplete.
///
/// Every handler is a stand-in that throws; nothing here dispatches. The
/// runtime itself is booted over the same contributions (fake listener and
/// clocks) so its status() figure is the one measured.
///
/// Deliberate native difference: browser.extensions (and browser.import) are
/// retired with Chrome (BackendDeckCoreBrowserMetadata.retiredIDs), so L89's
/// `browser_extensions` is asserted absent rather than present.
private func backendDeckCoreTestPortS1CatalogueCostUnused(_ what: String) -> NativeRPCError {
    NativeRPCError(code: "test-fixture", message: "The assembled catalogue is definitions; it does not \(what).")
}

enum BackendDeckCoreTestPortS1CatalogueCostSources {
    typealias M = BackendDeckCoreCatalogueMetadata
    typealias Bundle = BackendDeckCoreCatalogueBundle

    struct Assembly: Sendable {
        let root: URL
        let surface: BackendDeckCoreTestPortS1IndexSurface
        let contributions: [Bundle]
        /// What the runtime fixes at start: its own bundles, the contributions, then tools.describe/run.
        let shipped: [M]
    }

    /// A stand-in policy: the tool's real identity, aliases, audience and key grant; a run that refuses.
    static func policy(_ entry: M) -> BackendDeckCoreSecurityToolPolicy {
        let id = entry.tool.id
        return BackendDeckCoreSecurityToolPolicy(tool: entry.tool, aliases: entry.aliases, audience: entry.audience,
            keyRequiresTasks: entry.keyGrant == "tasks", summary: { _, _ in id },
            run: { _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("run \(id)") })
    }
    static func bundle(_ metadata: [M]) throws -> Bundle { try Bundle(metadata: metadata, policies: metadata.map(policy)) }

    /// The deck-tools definitions, each with the fields its factory copies
    /// from the production descriptor table, and a handler that never runs.
    static func deckToolDefinitions() throws -> [BackendDeckToolsDefinition] {
        let handler: BackendNativeMCPServer.Handler = { _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("dispatch a deck tool") }
        var definitions: [BackendDeckToolsDefinition] = []
        // BackendDeckToolsFiles/Projects/Assets/TourStage: (entry.spec, title, index).
        for entry in try BackendDeckToolsCatalogue.entries() {
            definitions.append(BackendDeckToolsDefinition(spec: entry.spec, title: entry.title, index: entry.index, handler: handler))
        }
        // BackendDeckToolsSessionsArea.definitions: (entry.spec(), title, index).
        for entry in BackendDeckToolsSessionsCatalogue.entries {
            definitions.append(BackendDeckToolsDefinition(spec: try entry.spec(), title: entry.title, index: entry.index, handler: handler))
        }
        // BackendDeckToolsAppKit.definitions: (spec, title, index, aliases, audience).
        for entry in try BackendDeckToolsAppMetadata.entries() {
            definitions.append(BackendDeckToolsDefinition(spec: entry.spec, title: entry.title, index: entry.index,
                aliases: entry.aliases, audience: entry.audience, handler: handler))
        }
        // BackendDeckToolsMachinesFactory.definitions: the row's spec (not advertised), title, index.
        for row in try BackendDeckToolsMachinesCatalogue.rows() {
            let id = try row["id"].requireString("tool id")
            guard let tier = BackendMCPTier(rawValue: row["tier"].string ?? "") else {
                throw NativeRPCError.invalidArguments("Unknown native machine-area tool tier")
            }
            let spec = try BackendMCPTool(id: id, wireName: row["wire"].requireString("wire name"),
                description: row["description"].requireString("description"), inputSchema: row["inputSchema"], tier: tier, advertised: false)
            definitions.append(BackendDeckToolsDefinition(spec: spec, title: row["title"].string ?? "", index: row["index"].string, handler: handler))
        }
        return definitions
    }

    /// BackendCompositionRoot.installDeckTools: the registrar, then one bundle per area.
    static func deckTools() async throws -> [Bundle] {
        let installed = try await BackendDeckToolsRegistration.register(on: BackendNativeMCPServer(), definitions: try deckToolDefinitions())
        return try installed.areas.map { area in
            let ids = Set(area.tools.map(\.id))
            let metadata = installed.metadata.filter { ids.contains($0.tool.id) }
            return try BackendDeckCoreAreaIntegration.bundle(area: area, metadata: metadata, policies: metadata.map(policy))
        }
    }

    /// NativeCompositionBrowser.registerTools over stand-in services; the
    /// scraping owner's install() registers exactly BackendBrowserScrapingMCP.tools()
    /// (BackendBrowserScrapingMCP.swift:75), whose RPC needs live WebKit profiles.
    @MainActor
    static func safari(root: URL) async throws -> [M] {
        let browser = BackendDeckCoreTestPortSessionsBrowserFixture(), staging = BackendNativeMCPServer()
        let context: BackendBrowserFactories.MCPContext = { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("resolve a browser caller") }
        try await BackendBrowserFactories.registerTools(staging, service: browser.service, context: context)
        let website = BackendBrowserWebsiteData(runtime: browser.host,
            resolveProfile: { _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("read a profile") },
            authorize: { _, _, _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("authorize site data") })
        try await website.registerTools(staging, context: context)
        let profiles = try BackendBrowserProfiles(dataRoot: root,
            requireWriter: { throw backendDeckCoreTestPortS1CatalogueCostUnused("write browser profiles") },
            deleteWebsiteData: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("delete website data") })
        let passwords = try BackendBrowserPasswords(dataRoot: root,
            cipher: BackendBrowserPasswordsCipher(available: { false },
                decrypt: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("decrypt a login") },
                encrypt: { _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("encrypt a login") }),
            host: BackendBrowserPasswordsHost(tab: { _ in nil }, fill: { _, _, _ in false },
                copy: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("copy a password") },
                reveal: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("reveal the logins file") }),
            requireWriter: { throw backendDeckCoreTestPortS1CatalogueCostUnused("write saved logins") },
            requireProfile: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("check a profile") })
        let signIn = BackendBrowserSignIn(openExternal: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("open the system browser") },
            readVersionOutput: { _ in nil })
        try await BackendBrowserProfilesToolFactories.register(in: staging, profiles: profiles, passwords: passwords, signIn: signIn,
            authorize: { _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("grant a profile action") },
            resolveWindow: { _, _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("resolve a window") },
            changed: { _ in })
        let downloads = try BackendBrowserDownloads(dataRoot: root, defaultFolder: root.appendingPathComponent("Downloads", isDirectory: true),
            applicationName: "Terminal Deck", dependencies: BackendBrowserDownloadsDependencies(
                authorize: { _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("authorize a download") },
                open: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("open a download") },
                reveal: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("reveal a download") },
                chooseFolder: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("choose a folder") }))
        let downloadsRPC = BackendBrowserDownloadsRPC(downloads: downloads, attended: { _ in false })
        try await downloadsRPC.registerMCP(in: staging, resolveCaller: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("resolve a download caller") })
        let registered = await staging.registrations().map(\.0) + (try BackendBrowserScrapingMCP.tools())
        let rows = Set(try BackendDeckCoreBrowserMetadata.sourceDescriptors().compactMap { $0["id"].string })
        return try BackendDeckCoreBrowserMetadata.entries(specs: registered.filter { rows.contains($0.id) }, requireComplete: true)
    }

    /// BackendTaskMCP.register over the CRM parity stores, with the CRM API, a
    /// key resolver and delegation, so every task tool the source lists exists.
    static func taskSpecs() async throws -> [BackendMCPTool] {
        let f = try await BackendCrmTaskDetailParityFixture.make()
        return try await BackendTaskClockContext.withClock(f.clock) {
            let access = BackendTaskSessionAccess(readiness: .ready, sessions: { [] },
                start: { _, _, _, _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("launch a task session") },
                send: { _, _ in }, stop: { _ in }, setControl: { _, _, _ in }, check: { _, _ in (false, "not checked") }, tellHoot: { _ in })
            let engine = try BackendTaskEngine(store: f.store, configuration: f.config, goals: f.goals, access: access, workspace: { $0.project }, problem: { _ in })
            let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/private/tmp/s1j-catalogue-cost-inert"), ownership: .memory)
            let outbox = BackendTaskOutbox(persistence: persistence, target: { _ in nil },
                post: { _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("post to a CRM") }, onCommentID: { _, _ in }, problem: { _ in })
            let view = BackendTaskStateView(store: f.store, configuration: f.config, goals: f.goals, outbox: outbox, keyViews: { [] })
            let planning = BackendGoalPlanning(goals: f.goals, tasks: f.store, configuration: f.config, local: f.local, detail: f.detail)
            let authority = BackendTaskToolAuthority(
                requireTasks: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("grant tasks") },
                requireHoot: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("grant Hoot") },
                visible: { _, _ in false },
                project: { _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("check a project") },
                authorize: { _, _, _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("authorize a task call") },
                actorName: { _ in "Hoot" },
                crmKeyID: { _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("resolve a CRM key") })
            let delegation = BackendTaskDelegation(store: f.store, configuration: f.config, local: f.local, engine: engine,
                outgoing: { _, _ in throw backendDeckCoreTestPortS1CatalogueCostUnused("send a delegation") })
            let server = BackendNativeMCPServer()
            _ = try await BackendTaskMCP.register(server: server, view: view, local: f.local, engine: engine, detail: f.detail, planning: planning,
                api: BackendTaskAPI(store: f.store, configuration: f.config, engine: engine), delegation: delegation, indexed: true, authority: authority)
            return await server.registrations().map(\.0)
        }
    }

    /// Tasks, knowledge and the server room (BackendKnowledgeMCP.register and
    /// BackendServersTools.register register exactly these specifications).
    static func supplement() async throws -> [M] {
        let specs = try await taskSpecs() + (try BackendKnowledgeMCP.specifications()) + (try BackendServersTools.definitions())
        let rows = Set(try BackendDeckCoreSupplementMetadata.sourceDescriptors().compactMap { $0["id"].string })
        return try BackendDeckCoreSupplementMetadata.entries(specs: specs.filter { rows.contains($0.id) }, requireComplete: true)
    }

    static func typingClock(_ clock: BackendDeckCoreTestPortSecurityClock) -> BackendDeckCoreBriefClock {
        BackendDeckCoreBriefClock(now: { clock.now() }, sleep: { clock.advance($0) })
    }

    /// The four bundles BackendDeckCoreRuntime.start builds itself.
    static func runtimeBundles(surface: BackendDeckCoreTestPortS1IndexSurface) throws -> [Bundle] {
        let clock = BackendDeckCoreTestPortSecurityClock()
        let mcp = try BackendDeckCoreMCPPolicies.resolve(provider: BackendDeckCoreTestPortSecurityMCPProvider())
        return try [
            BackendDeckCoreCatalogueBuiltins.tools(surface: surface, typingClock: typingClock(clock)),
            BackendDeckCoreCatalogueWhere.tools(dependencies: BackendDeckCoreCatalogueWhereDependencies(window: BackendDeckCoreTestPortS1IndexNoWindow(), page: { nil })),
            BackendDeckCoreCatalogueCoverage.tools(),
            BackendDeckCoreAreaIntegration.eventsBundle(policies: BackendDeckCoreEventsTools.notificationPolicies(hub: { nil }) + mcp),
        ]
    }

    @MainActor
    static func assemble(root: URL) async throws -> Assembly {
        let surface = BackendDeckCoreTestPortS1IndexSurface(root: root)
        let browserRoot = root.appendingPathComponent("browser", isDirectory: true)
        try FileManager.default.createDirectory(at: browserRoot, withIntermediateDirectories: true)
        let contributions = try await deckTools() + [bundle(try await safari(root: browserRoot)), bundle(try await supplement())]
        let bundles = try runtimeBundles(surface: surface) + contributions
        let describe = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] })
        let shipped = bundles.flatMap(\.metadata) + describe.metadata
        // The runtime's own duplicate-name refusal, over the whole list.
        _ = try BackendDeckCoreCatalogueRegistry(metadata: shipped)
        return Assembly(root: root, surface: surface, contributions: contributions, shipped: shipped)
    }

    /// The real registration over the same contributions; fake listener and clocks.
    static func boot(_ assembly: Assembly) async throws -> BackendDeckCoreRuntime {
        let clock = BackendDeckCoreTestPortSecurityClock()
        let window = BackendDeckCoreWindowConsent(isApprover: { _ in false }, send: { _, _, _ in false }, broadcast: { _, _ in })
        let providers = BackendDeckCoreRegistration.Providers(surface: assembly.surface, window: window,
            whereDependencies: BackendDeckCoreCatalogueWhereDependencies(window: BackendDeckCoreTestPortS1IndexNoWindow(), page: { nil }),
            mcp: BackendDeckCoreTestPortSecurityMCPProvider(), features: BackendDeckCoreTestPortS1IndexFeatures(),
            contributions: assembly.contributions, channelBridge: { nil })
        let options = BackendDeckCoreRegistration.Options(ownership: .exclusive, port: 0,
            listenerFactory: { BackendDeckCoreTestPortSecurityListener(handler: $0) },
            consentClock: clock, notificationClock: clock, typingClock: typingClock(clock))
        return try await BackendDeckCoreRegistration.register(registry: NativeChannelRegistry(), ownPorts: BackendDevOwnPorts(),
            dataDirectory: assembly.root, providers: providers, options: options)
    }
}

final class BackendDeckCoreTestPortS1CatalogueCostTests: BackendDeckCoreTestPortSecurityCase {
    private typealias Sources = BackendDeckCoreTestPortS1CatalogueCostSources
    private typealias Describe = BackendDeckCoreCatalogueDescribe
    private typealias Cost = BackendDeckCoreCatalogueCost

    /// Every tool the native app serves, built the way the runtime builds it.
    private func assembly() async throws -> Sources.Assembly { try await Sources.assemble(root: scratch()) }
    /// What tools/list puts on the wire for the copilot, which holds every tool.
    private func advertised(_ shipped: [Sources.M]) throws -> [Sources.M] { try Describe.advertised(shipped) }
    /// What an AI app on an access key is listed: the same, plus tools.run.
    private func keyListing(_ shipped: [Sources.M]) throws -> [Sources.M] { try Describe.advertised(shipped, run: true) }
    /// control.cost(): the figure the status channel shows, from the booted runtime.
    private func runtimeCost(_ assembly: Sources.Assembly) async throws -> (cost: V, tools: [String]) {
        let runtime = try await Sources.boot(assembly)
        do {
            let status = try await runtime.status()
            await runtime.stop()
            return (status["catalogue"], (status["tools"].elements ?? []).compactMap { $0["id"].string })
        } catch { await runtime.stop(); throw error }
    }

    // TSCASE catalogue-cost.test.ts:89
    func testCatalogueCostL89IsEverySourceTheAppAssembles() async throws {
        let a = try await assembly()
        let wire = a.shipped.map { $0.tool.wireName }
        XCTAssertEqual(Set(wire).count, wire.count, "two tools share a wire name")
        // Named rather than counted: one from each source.
        for name in ["tour_play", "app_where", "browser_open", "browser_network", "browser_workers", "assets_ledger", "browser_extract",
                     "servers_look", "machines_look", "agents_list", "browser_windows", "store_community", "sessions_wait", "files_read",
                     "hoot_state", "ui_do", "tools_coverage", Describe.runWire, "tools_describe"] {
            XCTAssertTrue(wire.contains(name), name)
        }
        // Retired with Chrome on the native side (BackendDeckCoreBrowserMetadata.retiredIDs).
        XCTAssertFalse(wire.contains("browser_extensions"))
        XCTAssertFalse(wire.contains("browser_import"))
        // Well over a hundred: the release that made "everything" reachable.
        XCTAssertGreaterThan(a.shipped.count, 140)
        // And it is the runtime's own list, not a second one assembled beside it.
        let (_, tools) = try await runtimeCost(a)
        XCTAssertEqual(tools.count, a.shipped.count)
        XCTAssertEqual(Set(tools), Set(a.shipped.map { $0.tool.id }))
    }

    // TSCASE catalogue-cost.test.ts:122
    func testCatalogueCostL122CostsWhatItCosts() async throws {
        let (cost, _) = try await runtimeCost(try await assembly())
        /*
         * The count is the source's, with no slack: 19 tools advertised (the
         * ten unindexed built-ins, app_where, the six browser verbs,
         * servers_look and tools_describe), exactly as measured in TS.
         *
         * The characters are pinned the way the source pins them — the measured
         * figure with its slack (TS: 19,869 inside 18,000..23,000, i.e. -9% /
         * +16%) — but around the native measurement, 17,344 (~4,956 tokens) on
         * 2026-10-07. The ~2,500 characters between the two are the six Safari
         * verbs: their descriptions and schemas are the Safari owner's own WebKit
         * texts (BackendBrowserFactories.descriptions/schema(for:)), deliberately
         * not the Electron ones (BackendDeckCoreBrowserMetadata keeps "capability
         * descriptions" as the Safari owner's actual values). Every other
         * advertised tool carries the source literal.
         */
        XCTAssertEqual(cost["tools"].number, 19, cost.compact)
        let chars = cost["chars"].number ?? 0
        XCTAssertGreaterThan(chars, 15_700, cost.compact)
        XCTAssertLessThan(chars, 20_100, cost.compact)
    }

    // TSCASE catalogue-cost.test.ts:148
    func testCatalogueCostL148IsInsideBothCeilings() async throws {
        let a = try await assembly()
        let (cost, _) = try await runtimeCost(a)
        XCTAssertLessThanOrEqual(cost["tools"].number ?? .infinity, Double(BackendDeckCoreCatalogueRules.maxCatalogueTools), cost.compact)
        XCTAssertLessThanOrEqual(cost["tokens"].number ?? .infinity, Double(BackendDeckCoreCatalogueRules.maxCatalogueTokens), cost.compact)
        XCTAssertEqual(cost["overBudget"], .bool(false))
        // And cost() is this listing, not a different one.
        XCTAssertEqual(cost, Cost.measure(try advertised(a.shipped)).wireValue)
    }

    // TSCASE catalogue-cost.test.ts:157
    func testCatalogueCostL157NamesTheAreasNotEveryHeldTool() async throws {
        let a = try await assembly()
        let description = try advertised(a.shipped).first { $0.tool.wireName == Describe.wire }?.tool.description ?? ""
        for area in Describe.areas { XCTAssertTrue(description.contains("\(area.id) — "), area.id) }
        // No per-tool lines: that is the bill this replaced.
        XCTAssertFalse(description.contains("sessions_wait —"))
        XCTAssertFalse(description.contains("browser_passwords —"))
    }

    // TSCASE catalogue-cost.test.ts:166
    func testCatalogueCostL166KeepsAnAccessKeyCallerInsideBothCeilings() async throws {
        let a = try await assembly()
        let listing = try keyListing(a.shipped), cost = Cost.measure(listing)
        let wire = listing.map { $0.tool.wireName }
        XCTAssertTrue(wire.contains(Describe.runWire))
        XCTAssertTrue(wire.contains("notifications_wait"))
        XCTAssertFalse(wire.contains("app_where"))
        // The copilot's listing has neither the inbox nor any line about it.
        let copilot = try advertised(a.shipped).map { $0.tool.wireName }
        XCTAssertEqual(copilot.filter { $0.hasPrefix("notifications_") }, [])
        XCTAssertTrue(copilot.contains("app_where"))
        XCTAssertEqual(cost.tools, 20, "\(wire)")
        XCTAssertLessThanOrEqual(cost.tools, BackendDeckCoreCatalogueRules.maxCatalogueTools)
        XCTAssertLessThanOrEqual(cost.tokens, BackendDeckCoreCatalogueRules.maxCatalogueTokens)
        XCTAssertFalse(cost.overBudget)
    }

    // TSCASE catalogue-cost.test.ts:192
    func testCatalogueCostL192CostsASessionLessStill() async throws {
        let a = try await assembly()
        // SESSION_TOOLS' native positive grant (session-tools.ts; Chrome extension controls retired).
        let names = BackendOrdinarySessionToolGrant.names
        let visible = a.shipped.filter { names.contains($0.tool.id) || names.contains($0.tool.wireName) }
        let held = visible.filter { $0.index != nil }
        XCTAssertGreaterThan(held.count, Describe.inlineIndexMax)
        let listing = try advertised(visible), cost = Cost.measure(listing)
        XCTAssertEqual(cost.tools, 7, "\(listing.map { $0.tool.wireName })")
        XCTAssertLessThan(cost.tokens, 3_000)
        XCTAssertFalse(cost.overBudget)
        // The areas are this caller's: the two it holds tools in, and not the
        // sessions, machines, agents or app areas it cannot reach.
        let description = listing.first { $0.tool.id == Describe.id }?.tool.description ?? ""
        XCTAssertTrue(description.contains("browser — "))
        XCTAssertTrue(description.contains("devices — "))
        for hidden in ["sessions — ", "machines — ", "agents — ", "app — "] { XCTAssertFalse(description.contains(hidden), hidden) }
    }
}
