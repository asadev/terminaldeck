import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Authority is supplied by the root, independently of browser arguments. The
/// native UI factory below deliberately grants no session, device or MCP caller.
struct NativeCompositionBrowserDependencies: Sendable {
    let uiContext: NativeRPCContext
    let requireWriter: BackendBrowserProfiles.RequireWriter
    let resolve: BackendBrowserService.Resolve
    let resolveSession: BackendBrowserService.ResolveSession
    let authorizeBrowser: BackendBrowserService.Authorize
    let authorizeProfiles: BackendBrowserProfilesChannels.Authorize
    let authorizeScraping: BackendBrowserScrapingAuthorize
    let authorizeDownloads: BackendBrowserDownloadsDependencies.Authorization
    let isCurrentUI: @Sendable (NativeRPCContext) async -> Bool
    let report: @Sendable (NativeRPCError) -> Void
    let parentWindow: @MainActor @Sendable () -> NSWindow?
    var cipher: BackendBrowserPasswordsCipher?
    var mcpContext: BackendBrowserFactories.MCPContext?
    var authorizeProfileTool: BackendBrowserProfilesToolFactories.Authorize?
    var resolveToolWindow: BackendBrowserProfilesToolFactories.ResolveWindow?
    var authorizeScrapingTool: BackendBrowserScrapingMCP.AuthorizeCall?
    var resolveDownloadTool: (@Sendable (BackendMCPCallContext) async throws -> BackendBrowserDownloadsToolCaller)?
    var forward: BackendBrowserService.Forward?
    var readVersionOutput: (@Sendable (String) async throws -> String?)?
    var assetDirectory: (@Sendable (BackendBrowserScrapingCaller, String) async throws -> URL)?
    var assetFile: (@Sendable (BackendBrowserScrapingCaller, String) async throws -> URL)?
    var approveLift: (@Sendable (BackendBrowserScrapingCaller, BackendBrowserSessionLiftSource, [BackendBrowserSessionLiftTarget]) async throws -> BackendBrowserSessionLiftPermit)?
    var deliverDownload: (@Sendable (BackendBrowserDownloadDelivery) async throws -> BackendBrowserDownloadDeliveryOutcome)?
    /// Set by the root only after the real session/MCP supplier and Node
    /// ownership transfer are assembled. UI-only staging keeps this false.
    var transferredSessionAuthority = false
    var stopProfileDownloads: (@MainActor @Sendable (NativeSafariDownloads, String) async throws -> Void)? = { facade, profileID in
        try await facade.stop(profileID: profileID)
    }

    static func unavailable(_ supplier: String) -> NativeRPCError {
        .init(code: "unavailable", message: "The native browser needs \(supplier); that supplier is not connected yet.")
    }

    /// `isCurrentUI` must come from the actual app-owner lifecycle. Matching a
    /// caller enum alone is insufficient. No request can select this owner.
    static func nativeUI(context: NativeRPCContext,
                         requireWriter: @escaping BackendBrowserProfiles.RequireWriter,
                         isCurrentUI: @escaping @Sendable (NativeRPCContext) async -> Bool,
                         parentWindow: @escaping @MainActor @Sendable () -> NSWindow?,
                         report: @escaping @Sendable (NativeRPCError) -> Void) -> Self {
        let check: @Sendable (NativeRPCContext) async throws -> Void = { candidate in
            guard context.caller == .nativeApp, candidate.caller == .nativeApp,
                  candidate.ownerID == context.ownerID, await isCurrentUI(candidate) else {
                throw NativeRPCError(code: "access-denied", message: "This browser operation requires the current native app owner.")
            }
        }
        return Self(uiContext: context, requireWriter: requireWriter,
            resolve: { candidate in
                try await check(candidate)
                return .init(ownerID: candidate.ownerID, managesWindows: true)
            }, resolveSession: { _ in throw unavailable("the live session and machine authority") },
            authorizeBrowser: { access in
                guard access.principal.ownerID == context.ownerID,
                      access.principal.sessionID == nil, access.principal.machineID.isEmpty,
                      !access.principal.routesToOriginatingDevice else {
                    throw NativeRPCError(code: "access-denied", message: "Session and remote browser grants are not connected to the native app yet.")
                }
                try await check(context)
                if access.targetSession != nil { throw unavailable("the live session attachment authority") }
            }, authorizeProfiles: { candidate, _ in try await check(candidate) },
            authorizeScraping: { caller, _, _, _, _ in
                guard !caller.remote, caller.sessionID == nil, caller.machineID == nil,
                      let candidate = caller.rpc else { throw unavailable("authenticated session/device scraping grants") }
                try await check(candidate)
            }, authorizeDownloads: { candidate, access in
                try await check(candidate)
                if let destination = access.destination, !destination.machineId.isEmpty { throw unavailable("verified remote download delivery and grants") }
            }, isCurrentUI: isCurrentUI, report: report, parentWindow: parentWindow)
    }
}
