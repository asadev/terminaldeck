import Foundation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Node-free page server (night plan step 4, D14). The same `/__td` API, page
/// files and per-launch token the Node engine's native-shell bridge served
/// (native-shell/bridge-server.ts, ported as `BackendOSNativeBridge`), answered
/// by the one in-process registry. Every registry event is pushed to the pages'
/// event stream. The port is remembered in `native-shell-port`, as before, so
/// the pages keep their origin (and their saved local state) across launches.
@MainActor
final class NativeNodelessBridge {
    static let shared = NativeNodelessBridge()
    private var bridge: BackendOSNativeBridge?
    private var events: NativeRPCSubscription?
    private var url: URL?
    private init() {}

    func start(assets: NativeWebAssets, root: BackendCompositionRoot) async throws -> URL {
        if let url { return url }
        let bridge = try BackendOSNativeBridge(options: .init(rendererDirectory: assets.renderer, shimFile: assets.shim,
            portFile: root.dataRoot.appendingPathComponent("native-shell-port"),
            log: { NSLog("[native bridge] %@", $0) }),
            dispatcher: BackendOSTraceDispatcher(registry: root.registry), ownPorts: root.ownPorts,
            ownerID: BackendCompositionRoot.appOwnerID)
        let endpoint = try await bridge.start()
        do {
            events = try await root.registry.subscribeAll(ownerID: BackendCompositionRoot.appOwnerID) { event in
                _ = await bridge.emit(channel: event.channel, arguments: event.arguments)
            }
        } catch { await bridge.close(); throw error }
        guard let page = URL(string: endpoint.url) else {
            await events?.cancelAndWait(); events = nil; await bridge.close()
            throw NativeRPCError(code: "unavailable", message: "The native page bridge returned an invalid address.")
        }
        self.bridge = bridge; url = page
        return page
    }

    func stop() async {
        await events?.cancelAndWait(); events = nil
        await bridge?.close(); bridge = nil; url = nil
    }
}
