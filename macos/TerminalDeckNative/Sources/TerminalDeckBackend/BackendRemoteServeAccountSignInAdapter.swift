import Foundation
import TerminalDeckNativeCore

/// Reuses the newly supplied local account owner and its thirty-second cache.
/// Constructing this adapter never probes a CLI or reads a credential.
public struct BackendRemoteServeAccountSignInAdapter: BackendRemoteServeAccountSignInReader {
    private let service: BackendAppAccountSignInService
    public init(service: BackendAppAccountSignInService) { self.service = service }
    public func readSignIn(_ profile: BackendAccountProfile) async throws -> BackendRemoteServeAccountSignIn {
        try Self.project(await service.read(profile))
    }
    public static func project(_ report: BackendAppAccountSignInReport) throws -> BackendRemoteServeAccountSignIn {
        guard let state = BackendRemoteServeAccountSignIn.State(rawValue: report.state) else {
            throw NativeRPCError(code: "unavailable", message: "The local account probe returned an unsupported sign-in state.")
        }
        return .init(state: state, account: report.account, plan: report.plan, detail: report.detail)
    }
}

/// The real local sign-out is available. Sign-in is a launch operation and is
/// supplied explicitly from the authorized lifecycle owner, never mapped to
/// profiles:signin (that channel only reads the sign-in state).
public struct BackendRemoteServeAccountLoginAdapter: BackendRemoteServeAccountLoginLifecycle {
    private let service: BackendAppAccountSignInService
    private let start: @Sendable (String) async throws -> BackendRemoteServeAccountOutcome
    public init(service: BackendAppAccountSignInService, signIn: @escaping @Sendable (String) async throws -> BackendRemoteServeAccountOutcome) {
        self.service = service; start = signIn
    }
    public func signIn(accountID: String) async throws -> BackendRemoteServeAccountOutcome { try await start(accountID) }
    public func signOut(accountID: String) async throws -> BackendRemoteServeAccountOutcome {
        let result = await service.signOut(accountID)
        guard let ok = result["ok"].bool, let message = result["message"].string,
              result["session"] == .null || result["session"].string != nil else {
            throw NativeRPCError(code: "unavailable", message: "The local account sign-out runner returned no usable outcome.")
        }
        return .init(ok: ok, message: message, session: result["session"].string)
    }
}
