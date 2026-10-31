#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

public protocol BackendHOSTOrdinaryToolLeaseOwner: BackendLaunchCapability {
    var count: Int { get async }
    func prepareOrdinary(restricting: [String]?, deniedTools: [String], taskID: String?, taskProject: String?) async throws -> BackendPreparedToolLease?
    func bind(_ id: UUID, sessionID: String, machineID: String) async throws
    func abandon(_ id: UUID) async
    func release(sessionID: String) async
    func agentSettingsConfiguration(_ id: UUID) async throws -> NativeRPCValue
    func reserveAgentSettingsFiles() async throws -> BackendAGSLaunchFileLease
    func stop() async
}
public protocol BackendHOSTProjectToolLeaseOwner: BackendLaunchCapability {
    func prepare(provider: String, cwd: String, loginPath: String, allowedTools: [String]?, deniedTools: [String], taskID: String?, taskProject: String?) async throws -> BackendPreparedProjectTools?
    func agentSettingsServerName(provider: String, cwd: String, loginPath: String) async throws -> String?
    func agentSettingsConfiguration(_ id: UUID) async throws -> NativeRPCValue
    func bind(_ id: UUID, sessionID: String) async throws
    func abandon(_ id: UUID) async
    func release(sessionID: String) async
    func stop() async
}
extension BackendSessionToolLeases: BackendHOSTOrdinaryToolLeaseOwner {}
extension BackendHOSTToolLeaseProxy: BackendHOSTOrdinaryToolLeaseOwner {}
extension BackendProjectToolComposition: BackendHOSTProjectToolLeaseOwner {}
extension BackendHOSTProjectToolProxy: BackendHOSTProjectToolLeaseOwner {}
extension BackendAccountRPC: BackendHOSTAccountChannelInvoking {}
extension BackendAppAccountSignInService: BackendHOSTAccountChannelInvoking {}
#endif
