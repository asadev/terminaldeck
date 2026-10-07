import Foundation
import TerminalDeckNativeCore

/// The app assembly calls this before BackendCompositionRoot.seal. It retains
/// the complete feature through the shared area shutdown closure; there is no
/// second registry, MCP listener, session lease table or own-ports ledger.
public enum BackendServersComposition {
    public static let ownerID = "native-composition:servers"
    public static let invokeChannels = BackendServersIPC.channels.union(Set(BackendServersReachChannels.channels))
    public static let sendChannels: Set<String> = ["servers:shell:write"]
    public static let eventChannels: Set<String> = ["servers:shell:output", "servers:shell:closed", "servers:setup:changed", "servers:host:changed"]
    @discardableResult
    public static func install(in root: BackendCompositionRoot, inputs: BackendServersFeatureInputs,
                               oldServerOwnerDisabled: Bool) async throws -> BackendServersFeature {
        try await root.requireAssemblyOpen()
        guard oldServerOwnerDisabled, inputs.storagePolicy.mayRead, inputs.storagePolicy.mayWrite,
              inputs.sshPolicy.mayConnect, inputs.sshPolicy.helperDispatchInstalled else {
            throw NativeRPCError(code: "unavailable", message: "SSH Servers needs exclusive native ownership and the installed private helper dispatch before it can replace the existing backend.")
        }
        guard inputs.registry === root.registry, inputs.ownPorts === root.ownPorts,
              inputs.dataRoot.standardizedFileURL == root.dataRoot.appendingPathComponent("servers", isDirectory: true).standardizedFileURL else {
            throw NativeRPCError(code: "composition-root-conflict", message: "SSH Servers must share the app's registry, port ledger and original profile's servers directory.")
        }
        // A provisional owner is unique to this attempt. Duplicate area or
        // handler refusal can never roll back a previously retained feature.
        let installationOwner = ownerID + ":" + UUID().uuidString.lowercased()
        let feature = BackendServersFeature(inputs)
        do {
            try await feature.registerChannels(ownerID: installationOwner)
            try await feature.registerTools(on: root.mcp, ownerID: installationOwner + ":tools")
            try await root.retain(.init(name: "servers", domains: ["servers"], ownerID: installationOwner,
                invokes: invokeChannels, sends: sendChannels, events: eventChannels,
                stop: { await feature.stop() }))
            return feature
        } catch { await feature.stop(); throw error }
    }
}
