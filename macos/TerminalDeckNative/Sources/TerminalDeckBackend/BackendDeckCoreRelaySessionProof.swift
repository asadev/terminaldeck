import Foundation
import TerminalDeckNativeCore

/// A backend-minted, one-call identity bridge for an authenticated helper relay. It is not a
/// registration, credential, serialized caller claim, or wider session grant. Only the relay
/// factory can supply the live-adoption validator; ordinary callers still need their endpoint.
public final class BackendDeckCoreRelaySessionProof: @unchecked Sendable {
    /// Backend-retained helper launch binding, never an argument's claimed agent ID.
    public let agentProfileID: String?
    private let caller: BackendDeckCoreSecurityCaller
    private let tools: Set<String>
    private let tool: String
    private let arguments: NativeRPCValue
    private let cancellation: BackendMCPCancellation
    private let attended: Bool
    private let refresh: @Sendable () async throws -> BackendDeckCoreSecurityCaller
    private let lock = NSLock()
    private var callID: String?
    private var ended = false
    init(caller: BackendDeckCoreSecurityCaller, tools: Set<String>, tool: String, arguments: NativeRPCValue,
         cancellation: BackendMCPCancellation, attended: Bool, agentProfileID: String?, refresh: @escaping @Sendable () async throws -> BackendDeckCoreSecurityCaller) {
        self.caller = caller; self.tools = tools; self.tool = tool; self.arguments = arguments
        self.cancellation = cancellation; self.refresh = refresh
        self.agentProfileID = agentProfileID
        self.attended = attended
    }
    func end() { lock.withLock { ended = true } }
    /// Called only after tools_run and aliases resolve to the actual canonical inner tool.
    func claim(callID: String, caller: BackendDeckCoreSecurityCaller, native: BackendMCPCallContext,
               granted: Set<String>?, tool: String, arguments: NativeRPCValue) throws {
        guard !cancellation.isCancelled, matches(caller: caller, native: native, granted: granted),
              tool == self.tool, arguments == self.arguments else { throw refused() }
        try lock.withLock {
            guard !ended, self.callID == nil else { throw refused() }
            self.callID = callID
        }
    }
    public func currentCaller(for context: BackendDeckCoreSecurityCallContext) async throws -> BackendDeckCoreSecurityCaller {
        guard live(context), context.attended == attended, matches(caller: context.caller, native: context.native, granted: context.granted) else { throw refused() }
        let latest = try await refresh()
        guard live(context), Self.same(latest, caller), matches(caller: latest, native: context.native, granted: context.granted) else { throw refused() }
        return latest
    }
    private func live(_ context: BackendDeckCoreSecurityCallContext) -> Bool {
        !cancellation.isCancelled && !context.cancellation.isCancelled && lock.withLock { !ended && callID == context.callID }
    }
    private func matches(caller value: BackendDeckCoreSecurityCaller, native: BackendMCPCallContext, granted: Set<String>?) -> Bool {
        Self.same(value, caller) && native.sessionID == caller.sessionID && native.machineID == (caller.machineID ?? "") &&
            native.projectRoot == caller.projectRoot && native.attended == attended && native.allowedTiers == caller.tiers && native.allowedTools == tools && granted == tools
    }
    private static func same(_ a: BackendDeckCoreSecurityCaller, _ b: BackendDeckCoreSecurityCaller) -> Bool {
        a.kind == .session && b.kind == .session && a.sessionID == b.sessionID && a.machineID == b.machineID &&
            a.tiers == b.tiers && a.projectRoot == b.projectRoot && a.taskProject == b.taskProject &&
            a.keyID == b.keyID && a.deviceID == b.deviceID && a.keyName == b.keyName &&
            a.tasks == b.tasks && a.folders == b.folders && a.askFirst == b.askFirst
    }
    private func refused() -> BackendDeckCoreSecurityRefusal { .init(.notGranted, "The authenticated helper session proof is no longer current for this exact tool call.") }
}
