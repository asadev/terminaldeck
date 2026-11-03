import Foundation
import TerminalDeckNativeCore

/// github.look / github.connect over the Git panel's own owners
/// (`BackendCompositionClients.github` / `.githubAuth`), exactly what the nine
/// channels github-tools.ts:35-44 reaches through the channel tap do
/// (github.ts:1287-1308, github-auth.ts:1770-1786). Folder grants, hereOnly and
/// consent are the factory's; the token never crosses this seam, and the
/// device code is scrubbed from reads by `BackendDeckToolsAppGitHub.withoutCode`.
public struct BackendCompositionDeckToolsGitHub: BackendDeckToolsAppGitHubService, Sendable {
    private let service: BackendGitHubService
    private let auth: BackendGitHubAuthenticator
    /// The clients graph has already bound `auth` to `service`
    /// (`BackendGitHubChannels.register` → `useAuthenticator`).
    public init(service: BackendGitHubService, auth: BackendGitHubAuthenticator) {
        self.service = service; self.auth = auth
    }

    /// github.ts:1225 `asPath`: a non-empty absolute path, else none.
    private static func asPath(_ folder: String) -> String? { !folder.isEmpty && folder.hasPrefix("/") ? folder : nil }
    /// github.ts:1284 `badPath`.
    private static func badPath(_ folder: String) -> NativeRPCValue {
        BackendGitHubRules.failure("error", "Project path must be absolute.", detail: folder)
    }

    public func overview(_ folder: String) async throws -> NativeRPCValue {
        guard let path = Self.asPath(folder) else { return Self.badPath(folder) }
        return await service.overview(cwd: path)
    }
    /// github.ts:1292 `github:refresh`: the overview with the cache bypassed.
    public func refresh(_ folder: String) async throws -> NativeRPCValue {
        guard let path = Self.asPath(folder) else { return Self.badPath(folder) }
        return await service.overview(cwd: path, options: .missing, refresh: true)
    }
    public func repo(_ folder: String) async throws -> NativeRPCValue {
        guard let path = Self.asPath(folder) else { return Self.badPath(folder) }
        return await service.resolveRepo(path)
    }
    /// github.ts:1303-1308: takes no folder — entries are keyed by repository,
    /// and two folders can be worktrees of one repo, so the whole cache goes.
    public func clearCache(_ folder: String) async throws { await service.cache.clear() }
    /// github-auth.ts:1770 `withFlowReason(auth.status(asPath(cwd)))`.
    public func authStatus(_ folder: String) async throws -> NativeRPCValue {
        await auth.status(cwd: Self.asPath(folder), foldFlowFailure: true)
    }
    /// github-auth.ts:1774: the prompt (with its one-time code) for the call
    /// that started it; the factory keeps the code out of the summary.
    public func connect() async throws -> NativeRPCValue { await auth.connect() }
    /// github-auth.ts:1776. The factory's 120 s ceiling releases the tool only;
    /// the sign-in itself carries on in the authenticator.
    public func awaitAuth(_ folder: String) async throws -> NativeRPCValue { await auth.awaitConnect(cwd: Self.asPath(folder)) }
    public func cancel(_ folder: String) async throws -> NativeRPCValue { await auth.cancelConnect(cwd: Self.asPath(folder)) }
    public func disconnect(_ folder: String) async throws -> NativeRPCValue { await auth.disconnect(cwd: Self.asPath(folder)) }
}
