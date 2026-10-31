import Foundation
import TerminalDeckNativeCore

/// ACCOUNTS: Hoot is the orchestrator seat, so its sessions follow the Hoot row of Settings › Coding AIs ›
/// "Who uses what": Hoot's own pick if it has one → the orchestrator seat → the project → the whole app →
/// this Mac's login. One answer, the same in both build modes.
public enum BackendHootAccountSeat {
    public static let key = "orchestrator"
    static func input(ownPick: String?, projectPath: String, provider: String) -> NativeRPCValue {
        .object([.init("provider", .string(provider)), .init("projectPath", .string(projectPath)),
                 .init("sessionProfileId", ownPick.map(NativeRPCValue.string) ?? .null), .init("seat", .string(key))])
    }
    public static func resolve(sessions: BackendCompositionSessions, ownPick: String? = nil, projectPath: String, provider: String) async throws -> BackendAccountProfile {
        #if TD_HOST_ACCOUNT_BRIDGE
        // The bridged account reader knows no seat; the account channel does and gives the same answer.
        // Asking for the seat must never stop Hoot from starting: an older running session host does not know this
        // channel (seen on 11 Oct, it kept the dev copy from starting). Then the answer without the seat stands, as before.
        if let context = try? BackendHOSTProfileScope.requireCurrent(),
           let id = try? await sessions.accountRPC.invoke("profiles:effective", args: [input(ownPick: ownPick, projectPath: projectPath, provider: provider)],
                                                          context: context)["accountId"].string, !id.isEmpty,
           let profile = try? await sessions.profiles.resolve(sessionProfileID: id, projectPath: projectPath, provider: provider) {
            return profile
        }
        return try await sessions.profiles.resolve(sessionProfileID: ownPick, projectPath: projectPath, provider: provider)
        #else
        return try await sessions.profiles.resolve(sessionProfileID: ownPick, projectPath: projectPath, provider: provider, seat: key)
        #endif
    }
}
