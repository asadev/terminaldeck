import Foundation
import TerminalDeckNativeCore

/// Applies the final preview policy to the real direct-access provider while
/// leaving the host's authenticated relay path alone. No command runs at init.
public actor BackendCompositionPreviewDirect: BackendRemoteServeHostServiceDirectAccess {
    private let preview: Bool
    private let relayAvailable: Bool
    private let actual: any BackendRemoteServeHostServiceDirectAccess
    private var planned: [UInt16: BackendRemoteServeHostServiceDirectPlan] = [:]
    private var reported: [UInt16: String] = [:]
    public init(preview: Bool, relayAvailable: Bool, actual: any BackendRemoteServeHostServiceDirectAccess) {
        self.preview = preview; self.relayAvailable = relayAvailable; self.actual = actual
    }
    public func plan(port: UInt16) async throws -> BackendRemoteServeHostServiceDirectPlan {
        if preview {
            let policy = BackendS3FillPreviewRemote(preview: true, relayAvailable: relayAvailable,
                readTailnet: { throwIfUsedInPreview() }, serveOn: { throw NativeRPCError(code: "unavailable", message: "Preview direct access must not invoke Serve.") })
            let status = await policy.start()
            throw BackendRemoteServeHostServiceFailure(message: status.reason ?? BackendOSNativeMode.directRefusal)
        }
        let result = try await actual.plan(port: port); planned[port] = result; return result
    }
    public func serve(port: UInt16) async throws -> String {
        guard !preview, planned[port] != nil else { throw BackendRemoteServeHostServiceFailure(message: BackendOSNativeMode.directRefusal) }
        // HostService has already opened and verified the listener before this
        // step. The gate therefore performs the actual Serve exactly once.
        let policy = BackendS3FillPreviewRemote(preview: false, relayAvailable: false,
            readTailnet: { true }, serveOn: { [actual, weak self] in
                let url = try await actual.serve(port: port)
                await self?.note(url: url, port: port)
            })
        let result = await policy.start()
        guard result.running, let url = reported[port], !url.isEmpty else {
            throw BackendRemoteServeHostServiceFailure(message: result.reason ?? "The direct provider did not report its served URL.")
        }
        return url
    }
    private func note(url: String, port: UInt16) { reported[port] = url }
    public func stop(port: UInt16) async {
        planned[port] = nil; reported[port] = nil
        if !preview { await actual.stop(port: port) }
    }
}

private func throwIfUsedInPreview() -> Bool {
    // A preview gate's source policy never calls this callback. Refuse a
    // mistaken call rather than run a command or invent a positive reading.
    false
}
