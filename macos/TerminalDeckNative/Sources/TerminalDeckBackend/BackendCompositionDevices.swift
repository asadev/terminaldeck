import Foundation
import TerminalDeckNativeCore

/// The native devices area: devices/ipc.ts over the one BackendAppDeviceManager
/// (the same manager `BackendAppDeviceToolService` hands the deck tools).
/// Every page channel is the app window's; mutations also pass the
/// authority's mutation check, as BackendAppDeviceChannels asks.
public enum BackendCompositionDevices {
    public static let ownerID = "native-composition:devices"
    /// ipc.ts "Pushed to the window": `devices:frame` (id, bytes), `devices:closed` (id, reason).
    public static let events: Set<String> = ["devices:frame", "devices:closed"]
    /// The engine as build-app.sh stages it, relative to Contents/Resources.
    /// The Node-free bundle stages SimView's native core here (O1 packaging, D14).
    public static let stagedEngine = "simview/bin"

    public struct Installed: Sendable {
        public let manager: BackendAppDeviceManager
        /// For `BackendDeckToolsMachinesDevices(service:)`: the same manager, never a second one.
        public let tools: BackendAppDeviceToolService
        public let ownerID: String
        public let invokes: Set<String>
        public let events: Set<String>
        /// ipc.ts L127-133: the window was destroyed, or its page did a full
        /// reload — the new page never asked for the old one's pictures.
        public let pageGone: @Sendable () async -> Void
        /// ipc.ts `will-quit`: stop every engine and the event pump.
        public let stop: @Sendable () async -> Void
    }

    /// ipc.ts picturesDir: the same Pictures/<brand> folder as the browser's screenshots.
    public static func picturesDirectory(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent(BackendSharedBrand.name, isDirectory: true)
    }

    /// engine.ts locate: the standalone app's staged engine first (trusted
    /// `nativeBin`), then a dev checkout's node_modules, the
    /// TD_DEVICE_ENGINE_BIN override and the process folder.
    public static func engine(resources: URL?, repo: URL?, environment: [String: String],
                              cwd: String = FileManager.default.currentDirectoryPath) -> BackendAppDeviceEngineAnswer {
        let staged = resources.map { $0.appendingPathComponent(stagedEngine, isDirectory: true).path }
        let appPath = repo?.path ?? resources?.appendingPathComponent("engine", isDirectory: true).path ?? cwd
        return BackendAppDeviceEngineLocator.locate(resourcesPath: nil, appPath: appPath, cwd: repo?.path ?? cwd,
                                                    environment: environment, nativeBin: staged)
    }

    private struct Push: Sendable { let channel: String; let arguments: [NativeRPCValue] }
    private final class Lifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false
        var stopped: Bool { lock.withLock { ended } }
        func stop() { lock.withLock { ended = true } }
    }

    /// Registers all sixteen `BackendAppDeviceChannels.channels` under `ownerID`
    /// (no engine starts here; the locator runs on first use). The caller
    /// retains the area with the returned invokes/events and stop.
    public static func install(registry: NativeChannelRegistry, authority: BackendCompositionAuthority,
                               providers: BackendNativeProviders, environment: [String: String], home: String,
                               resources: URL?, repo: URL?, pictures: URL? = nil) async throws -> Installed {
        // The measured login PATH; a failed lookup keeps the inherited PATH.
        var launch = environment
        if let path = try? await providers.loginPath(), !path.isEmpty { launch["PATH"] = path }
        let platform = BackendAppDevicePlatform(environment: launch, home: home, executor: BackendAppSessionCommandExecutor())
        let folder = pictures ?? picturesDirectory(home: home)
        let manager = BackendAppDeviceManager(locate: {
            BackendCompositionDevices.engine(resources: resources, repo: repo, environment: environment)
        }, platform: platform, picturesDirectory: { folder })

        // One ordered pump: coded pictures reach the window in engine order and are never thinned.
        let lifetime = Lifetime()
        let (stream, sink) = AsyncStream.makeStream(of: Push.self)
        let pump = Task {
            for await push in stream {
                try? await registry.publish(push.channel, arguments: push.arguments, ownerID: BackendCompositionRoot.appOwnerID)
            }
        }
        let window = NativeRPCContext(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID)
        let gone: @Sendable () -> Bool = {
            if lifetime.stopped { return true }
            let alive = (try? authority.requireLocalUI(window)) != nil
            return !alive
        }
        // ipc.ts viewerOf: the app window, sent to only while it is alive.
        let viewer = BackendAppDeviceViewer(id: BackendCompositionRoot.appOwnerID, send: { channel, arguments in
            guard !gone() else { return }
            sink.yield(Push(channel: channel, arguments: arguments))
        }, isDestroyed: gone)

        let channels = BackendAppDeviceChannels(manager: manager, authorizeMutation: { try authority.authorizeMutation($0) })
        do {
            for channel in BackendAppDeviceChannels.channels.sorted() {
                try await registry.register(channel, ownerID: ownerID, policy: { try authority.requireLocalUI($0) }) { context, arguments in
                    try await channels.invoke(channel, args: arguments, context: context, viewer: viewer)
                }
            }
        } catch {
            lifetime.stop(); sink.finish(); pump.cancel()
            await registry.removeOwner(ownerID)
            throw error
        }
        return Installed(manager: manager, tools: BackendAppDeviceToolService(manager: manager), ownerID: ownerID,
            invokes: BackendAppDeviceChannels.channels, events: events,
            pageGone: { await manager.forgetViewer(BackendCompositionRoot.appOwnerID) },
            stop: {
                lifetime.stop()
                await manager.closeAll()
                sink.finish(); pump.cancel()
            })
    }
}
