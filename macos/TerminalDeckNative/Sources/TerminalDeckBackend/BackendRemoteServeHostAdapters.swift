import Foundation
import TerminalDeckNativeCore

/// Reuses the GitHub worker's authenticator; no duplicate login/token store.
public struct BackendRemoteServeNativeGitHub: BackendRemoteServeGitHubAuthenticator {
    public let authenticator: BackendGitHubAuthenticator
    public init(authenticator: BackendGitHubAuthenticator) { self.authenticator = authenticator }
    public func status() async throws -> NativeRPCValue { await authenticator.status() }
    public func connect() async throws { _ = await authenticator.connect() }
    public func cancelConnect() async throws -> NativeRPCValue { await authenticator.cancelConnect() }
    public func disconnect() async throws -> NativeRPCValue { await authenticator.disconnect() }
    public func flowFailure() async -> String? { await authenticator.flowFailure()?["message"].string }
    public func gitCredential() async -> BackendRemoteServeCredentials.Login? {
        guard let value = await authenticator.gitCredential() else { return nil }
        return .init(username: value.username, password: value.password)
    }
}
