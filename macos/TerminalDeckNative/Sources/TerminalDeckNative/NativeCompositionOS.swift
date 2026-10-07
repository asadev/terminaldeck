import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Supplies the selected OS bodies with the existing app's real assertion,
/// notification and file-manager owners. Constructors perform no OS work.
@MainActor
enum NativeCompositionOS {
    struct Services: Sendable {
        let power: BackendOSPowerControl
        let voice: BackendOSVoiceService
        let notifications: BackendOSNotificationEvidence
        let log: BackendOSAppLog
    }
    static func make(backend: BackendCompositionRoot, home: String,
                     executor: BackendDevProcessExecutor, cipher: BackendAccountKeychainCipher,
                     bundleIdentifier: String?) throws -> Services {
        let policy: @Sendable (NativeRPCContext) throws -> Void = BackendCompositionRoot.requireLocalUI
        let registry = backend.registry
        let power = BackendOSPowerControl(power: NativeOSBridge.shared.powerBindings(), executor: executor,
            home: home, authorizeChange: policy, push: { channel, value in
                do { try await registry.publish(channel, arguments: [value]) }
                catch { NSLog("[native power] %@", error.localizedDescription) }
            })
        let voice = try BackendOSVoiceService(userData: backend.dataRoot, store: backend.state, cipher: cipher,
            authorize: { context, _ in try policy(context) })
        let notifications = BackendOSNotificationEvidence(home: home, runner: executor,
            bundleIdentifier: { bundleIdentifier }, openExternal: { text in
                guard let url = URL(string: text) else { throw NativeRPCError.invalidArguments("The settings URL is invalid.") }
                return await MainActor.run { NSWorkspace.shared.open(url) }
            }, authorize: policy)
        let log = try BackendOSAppLog(directory: backend.dataRoot.appendingPathComponent("logs", isDirectory: true),
            fileName: BackendSharedBrand.id + ".log", redaction: .init(), openPath: { path in
                let opened = await MainActor.run { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                return opened ? "" : "macOS refused to open the log folder."
            }, authorize: { context, _ in try policy(context) })
        return Services(power: power, voice: voice, notifications: notifications, log: log)
    }
    /// The new-owner flag is supplied by the root's startup plan before the Node
    /// child launches. It cannot be set from a renderer request or MCP arguments.
    static func install(backend: BackendCompositionRoot, services: Services,
                        oldOwnersDisabled: Bool) async throws {
        try await backend.requireAssemblyOpen()
        guard oldOwnersDisabled else { throw NativeRPCError(code: "ownership-required", message: "The old OS writers must stop before native registration.") }
        let owner = "native-composition:os"
        do {
            try await services.voice.activate(oldVoiceOwnerDisabled: true)
            try await services.log.activate(oldLogOwnerDisabled: true)
            let channels = try await BackendOSKeptChannels.register(registry: backend.registry, ownerID: owner,
                power: services.power, voice: services.voice, notifications: services.notifications, log: services.log,
                authorize: { context, _, _ in try BackendCompositionRoot.requireLocalUI(context) })
            try await backend.retain(.init(name: "os", domains: ["os-power", "voice", "notification-evidence", "app-log"], ownerID: owner,
                invokes: Set(channels), events: ["power:lid-awake:state"], stop: { await services.power.stop() }))
            try await services.power.start()
        } catch { await services.power.stop(); await backend.registry.removeOwner(owner); throw error }
    }
}
