import Foundation
import TerminalDeckNativeCore

/// The account tools' extra operations over the SAME owners the account screens
/// use (TS agents-area-live.ts accounts deps): sign-in reading and sign-out
/// through the native sign-in service, shared history through the one
/// BackendAppSharedProjects the session switch also uses. The context is the
/// credential-resolved core-call ticket; reads need it current, changes need
/// the accepted effect (authorizeMetadata / authorizeMutation).
public struct BackendCompositionDeckToolsAccountExtras: BackendDeckToolsSessionsAccountExtras, Sendable {
    private let signIn: BackendAppAccountSignInService
    private let shared: BackendAppSharedProjects
    private let profiles: BackendAccountProfileStore
    private let authority: BackendCompositionAuthority
    public init(signIn: BackendAppAccountSignInService, shared: BackendAppSharedProjects,
                profiles: BackendAccountProfileStore, authority: BackendCompositionAuthority) {
        self.signIn = signIn; self.shared = shared; self.profiles = profiles; self.authority = authority
    }
    private func profile(_ id: String) async throws -> BackendAccountProfile {
        guard let found = try await profiles.find(id) else { throw BackendAccountFailure("no account with id \(id)") }
        return found
    }
    /// TS readSignIn(account, { refresh }).
    public func signInStatus(accountID: String, refresh: Bool, context: NativeRPCContext) async throws -> NativeRPCValue {
        try authority.authorizeMetadata(context)
        return try await signIn.invoke("profiles:signin", args: [.string(accountID), .object([.init("refresh", .bool(refresh))])], context: context)
    }
    /// TS history(id): { state, share, unshare, remove } sentences.
    public func history(accountID: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        try authority.authorizeMetadata(context)
        let state = await shared.state(try await profile(accountID))
        return .object([.init("state", state.wire), .init("share", .string(BackendAppSharedProjects.describeShare(state))),
            .init("unshare", .string(BackendAppSharedProjects.describeUnshare(state))), .init("remove", .string(BackendAppSharedProjects.describeDelete(state)))])
    }
    /// TS signOutAccount(id).
    public func signOut(accountID: String, context: NativeRPCContext) async throws -> NativeRPCValue {
        try authority.authorizeMutation(context)
        return try await signIn.invoke("profiles:signout", args: [.string(accountID)], context: context)
    }
    /// TS shareProjects / unshareProjects(account(id)).
    public func shareHistory(accountID: String, share: Bool, context: NativeRPCContext) async throws -> NativeRPCValue {
        try authority.authorizeMutation(context)
        let account = try await profile(accountID)
        return share ? try await shared.share(account) : try await shared.unshare(account).wire
    }
}
