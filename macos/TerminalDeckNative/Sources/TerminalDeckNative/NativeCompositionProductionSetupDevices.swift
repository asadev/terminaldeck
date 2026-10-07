import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    /// TS setup:status / prereq:check over the one native detection the diagnostics also use
    /// (agent CLIs, prerequisites, GitHub Copilot, hook endpoint); it serves setup.status too.
    func installSetup(detection: BackendMacAppSetupNativeDetection) async throws -> @Sendable (NativeRPCContext) async throws -> NativeRPCValue {
        let owner = "native-composition:setup", authority = self.authority!
        try await BackendMacAppSetupSnapshot.register(root.registry, detection: detection, ownerID: owner, authorize: { context in
            if context.caller == .nativeApp { try authority.requireLocalUI(context) } else { try authority.authorizeMetadata(context) }
        })
        try await root.retain(.init(name: "setup", domains: ["setup"], ownerID: owner, invokes: ["prereq:check", "setup:status"],
            stop: { [registry = root.registry] in await registry.removeOwner(owner) }))
        return { _ in try await BackendMacAppSetupSnapshot.read(detection) }
    }

    /// TS devices/ipc.ts: one device manager for the Devices page and the devices.* tools.
    func installDevices() async throws -> BackendCompositionDevices.Installed {
        var repo: URL?
        if case .checkout(let checkout) = engineConfiguration.source { repo = checkout }
        let installed = try await BackendCompositionDevices.install(registry: root.registry, authority: authority,
            providers: root.providers, environment: configuration.inheritedEnvironment, home: configuration.homeDirectory.path,
            resources: Bundle.main.resourceURL, repo: repo)
        do {
            try await root.retain(.init(name: "devices", domains: ["devices"], ownerID: installed.ownerID,
                invokes: installed.invokes, events: installed.events, stop: { await installed.stop() }))
        } catch { await installed.stop(); throw error }
        devices = installed
        return installed
    }

    /// TS remote/ipc.ts: the Remote settings page's own channels over the one host service.
    func installRemoteSettings(endpoint: BackendRemoteHost) async throws {
        guard let remoteHost else { throw NativeRPCError(code: "composition-incomplete", message: "Remote settings need the host service.") }
        let owner = "native-composition:remote-settings"
        let channels = try await BackendCompositionRemoteChannels.register(registry: root.registry, ownerID: owner, authority: authority,
            service: remoteHost, settings: state, dropConnection: { await endpoint.dropConnection($0) })
        // TS server.ts remote:device:revoke: the roster's one cascade, then the device list.
        guard let registration = remoteRegistration else { throw NativeRPCError(code: "composition-incomplete", message: "Remote serving is not registered.") }
        guard let trust = remoteTrust else { throw NativeRPCError(code: "composition-incomplete", message: "Remote trust is not open.") }
        let authority = self.authority!
        try await root.registry.register("remote:device:revoke", ownerID: owner, policy: { try authority.authorizeMutation($0) }) { context, args in
            if let id = context.argument(0, in: args).string, !id.isEmpty { _ = try await registration.revoke(id) }
            return .array(await trust.listDevices().map(\.value))
        }
        // server.ts settingsServe + the settings.changed push: the two machine-owned
        // settings for this machine's own phones, installed before any peer connects.
        let serverSettings = BackendCompositionRemoteSettings(state: state)
        let feature = try await endpoint.installFeatures(ownerID: owner, features: [serverSettings.feature()], connectionClosed: { _ in })
        let pushes = state.observePreferenceWrites { [report] patch in
            // Which preferences changed, when (walk-1 theme flip): keys, and the theme's new value.
            let keys = patch.fields?.map(\.key).sorted().joined(separator: ",") ?? "?"
            report("prefs written: " + keys + (patch["theme"].string.map { " theme=" + $0 } ?? ""))
            Task { try? await endpoint.remoteServePushToOwnDevices(message: try await serverSettings.changed(), claiming: BackendCompositionRemoteSettings.capability) }
        }
        try await root.retain(.init(name: "remote-settings", domains: ["remote-settings"], ownerID: owner, invokes: Set(channels + ["remote:device:revoke"]),
            stop: { [registry = root.registry] in await pushes.cancelAndWait(); await feature.cancelAndWait(); await registry.removeOwner(owner) }))
    }
}
