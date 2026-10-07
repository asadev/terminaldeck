import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// The app-tool families (TS app-tools, hooks, voice, copilot-admin, ui, memory,
    /// routines, usage, setup, github, fixed, tools-store, community, store) over the
    /// SAME owners their screens use; one access/gate for all of them.
    func appDefinitions(access: BackendDeckToolsAppAccess, gate: BackendCompositionDeckToolsGate, os: NativeCompositionOS.Services,
                        browser: NativeCompositionBrowser, sessions: BackendCompositionSessions,
                        usage: BackendCompositionUsage, setup: @escaping @Sendable (NativeRPCContext) async throws -> NativeRPCValue,
                        diagnostics: NativeCompositionDiagnostics.Services) throws -> [BackendDeckToolsDefinition] {
        guard let hoot, let routinesOwner, let github = clients.github, let githubAuth = clients.githubAuth, let fixed = clients.staysFixed else {
            throw NativeRPCError(code: "composition-incomplete", message: "The app tools need Hoot, routines, GitHub and Stays Fixed owners.")
        }
        let authority = self.authority!, registry = root.registry
        var definitions: [BackendDeckToolsDefinition] = []
        let updates = BackendCompositionDeckToolsAppUpdates(
            state: { try await Self.updater("update:get") }, check: { _ in try await Self.updater("update:check") },
            download: { try await Self.updater("update:download") }, installNow: { try await Self.updater("update:install") })
        let openFolder: @Sendable (String) async throws -> String = { path in
            await MainActor.run { NSWorkspace.shared.open(URL(fileURLWithPath: path)) ? "" : "macOS refused to open " + path + "." }
        }
        let application = BackendCompositionDeckToolsAppApplication(environment: NativeCompositionSettings.environment(backend: root,
            configuration: engineConfiguration), log: os.log, diagnostics: diagnostics.source, metrics: diagnostics.metrics,
            registry: registry, redaction: diagnostics.redaction, openFolder: openFolder, updater: updates)
        definitions += try BackendDeckToolsAppApplication.definitions(service: application,
            settings: BackendCompositionDeckToolsAppSettings(settings: root.settings, store: root.state,
                tellWindow: BackendCompositionDeckToolsAppSettings.registryWindow(registry, windowOpen: { (try? authority.localContext()) != nil })),
            access: access)
        let installation = sessions.hookInstallation, server = sessions.hookServer
        definitions += try BackendDeckToolsAppHooks.definitions(service: BackendDeckToolsAppHookAdapter(installation: installation, access: access,
            listener: { server.status() },
            synchronize: { context in try await installation.sync(context: context).map(\.wireValue) },
            acceptOffer: { context in try await installation.answerOffer(accept: true, context: context).elements ?? [] },
            declineOffer: { context in _ = try await installation.answerOffer(accept: false, context: context) }), access: access)
        definitions += try BackendDeckToolsAppVoice.definitions(service: BackendCompositionDeckToolsAppVoice(voice: os.voice), access: access)
        definitions += try BackendDeckToolsAppAdmin.definitions(copilot: hoot.registration.administrativeService,
            doors: BackendCompositionDeckToolsAppSmallDoors(core: { [weak self] in await MainActor.run { self?.core } },
                notifications: os.notifications, openURL: { url in await MainActor.run { NSWorkspace.shared.open(url) } }),
            access: access)
        definitions += try BackendDeckToolsAppUI.definitions(service: NativeCompositionDeckToolsUI.service(), access: access)
        definitions += try BackendDeckToolsAppMemory.definitions(service: clients.memory.map { BackendCompositionDeckToolsMemory(memory: $0, profiles: sessions.profiles) }, access: access)
        definitions += try BackendDeckToolsAppRoutines.definitions(service: BackendRoutinesRegisteredAppAdapter(api: routinesOwner.api), access: access)
        let metrics = BackendDeckToolsAppNativeMetricsAdapter(usage: usage.usage, cost: usage.cost, readiness: usage.readiness, access: access,
            setup: setup)
        definitions += try BackendDeckToolsAppUsage.definitions(service: metrics, access: access)
        definitions += try BackendDeckToolsAppSetup.definitions(service: metrics, access: access)
        definitions += try BackendDeckToolsAppGitHub.definitions(service: BackendCompositionDeckToolsGitHub(service: github, auth: githubAuth), access: access)
        definitions += try BackendDeckToolsAppFixed.definitions(service: BackendCompositionDeckToolsFixed(service: fixed,
            provisioning: staysFixedProvisioning), access: access)
        let recipes = browser.recipes, service = browser.service
        let rpc: @Sendable (BackendMCPCallContext) async throws -> NativeRPCContext = { [weak self] native in
            guard let access = await MainActor.run(body: { self?.browserAccess }) else { throw NativeRPCError(code: "unavailable", message: "The browser caller table is not installed.") }
            return try await access.rpc(native)
        }
        definitions += try BackendDeckToolsAppToolsStore.definitions(service: BackendDeckToolsAppNativeToolsStoreAdapter(recipes: recipes, access: access,
            removeOrphan: { context, id in try await recipes.removeOrphan(context, id: id) }), access: access)
        definitions += try BackendDeckToolsAppCommunity.definitions(service: BackendCompositionDeckToolsCommunity(store: clients.community,
            userData: root.dataRoot, probe: BackendCommunityNativeProbe(providers: root.providers)), access: access)
        definitions += try BackendDeckToolsAppExtraction.definitions(service: BackendCompositionDeckToolsExtraction(authority: authority,
            installed: { await recipes.installedRecipes() },
            origin: { native, args in try await service.extractionOrigin(try await rpc(native), arguments: args) },
            extract: { native, args in try await service.page(try await rpc(native), operation: "extract", arguments: args, sessionReader: true) }),
            access: access)
        _ = gate
        return definitions
    }

    /// The app's one update controller (NativeAppUpdater), answered in its own wire shape.
    @MainActor static func updater(_ channel: String) async throws -> NativeRPCValue {
        guard let raw = await NativeAppUpdater.shared.handle(channel) else {
            throw NativeRPCError(code: "unavailable", message: "this build has no updater running, so it cannot check for or install updates.")
        }
        return try NativeRPCValue.fromFoundation(raw)
    }
}
