import Foundation

/// Source remote/server.ts `open()` / `autoStart` / `remote:start` in the native preview:
/// relay only. The direct half (a Tailscale address, port, `tailscale serve`) is refused with
/// BackendOSNativeMode.directRefusal and neither the tailnet reader nor serve is ever called.
public struct BackendS3FillRemoteStatus: Equatable, Sendable { public let running: Bool; public let reason: String? }

public actor BackendS3FillPreviewRemote {
    public typealias Tailnet = @Sendable () async -> Bool          // true when a tailnet is up
    public typealias ServeOn = @Sendable () async throws -> Void
    private let preview: Bool, relayAvailable: Bool
    private let readTailnet: Tailnet, serveOn: ServeOn
    private let onStartFailure: @Sendable (String) -> Void
    private var running = false
    public init(preview: Bool, relayAvailable: Bool, readTailnet: @escaping Tailnet, serveOn: @escaping ServeOn,
                onStartFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.preview = preview; self.relayAvailable = relayAvailable; self.readTailnet = readTailnet
        self.serveOn = serveOn; self.onStartFailure = onStartFailure
    }
    /// `remote:start`: with no relay to fall back on the preview reports why it cannot start.
    public func start() async -> BackendS3FillRemoteStatus {
        let reason: String?
        if preview { reason = BackendOSNativeMode.directRefusal }
        else if await readTailnet() { do { try await serveOn(); reason = nil } catch { reason = error.localizedDescription } }
        else { reason = "Tailscale is not running on this Mac." }
        if reason != nil && !relayAvailable { running = false; return .init(running: false, reason: reason) }
        running = relayAvailable || reason == nil
        return .init(running: running, reason: preview ? reason : (reason == nil ? nil : reason))
    }
    /// The launch dial: not awaited by the window; a start that did not take reports through onStartFailure.
    public func launch(autoStart: Bool = true) async {
        guard autoStart else { return }
        let status = await start()
        if !status.running { onStartFailure(status.reason ?? "Remote access did not start, and did not say why.") }
    }
}
