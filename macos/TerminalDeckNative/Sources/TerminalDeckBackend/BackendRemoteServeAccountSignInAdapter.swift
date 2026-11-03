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
