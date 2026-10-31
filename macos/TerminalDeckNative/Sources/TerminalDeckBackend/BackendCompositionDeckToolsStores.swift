import Foundation
import TerminalDeckNativeCore

/// store.community over the Store's one verified installer
/// (browser-area-tools.ts:404-408 → store-install-ipc.ts:154-179): the same
/// projection the `community:list` channel returns, and the same
/// signature/digest/tier-checked install and ledger removal. The factory owns
/// consent (install/remove `alter`, tier sentence) and redacts `values`.
///
/// `store` is optional exactly as in the source (`store === null`): the list
/// then says why it is empty and install/remove answer NO_STORE
/// (store-install-ipc.ts:91-108), which the factory refuses with its message.
/// `probe` should be the Store channel's probe (store-install-ipc.ts:119 keeps
/// one per run); `BackendCommunityNativeProbe(providers:)` otherwise.
public struct BackendCompositionDeckToolsCommunity: BackendDeckToolsAppCommunityService, Sendable {
    private let store: (any BackendCommunityStoreProviding)?
    private let userData: String
    private let probe: any BackendCommunityMachineProbing
    public init(store: (any BackendCommunityStoreProviding)?, userData: URL, probe: any BackendCommunityMachineProbing) {
        self.store = store; self.userData = userData.path; self.probe = probe
    }
    private static let noStore = NativeRPCValue.object([.init("ok", .bool(false)), .init("message", .string(BackendCommunityChannels.unavailable))])

    public func view() async throws -> NativeRPCValue {
        let raw: NativeRPCValue
        if let store { raw = try await store.view() }
        // store-install-ipc.ts:97 emptyView. Its homes/folder only shape item
        // rows, and there are none.
        else { raw = .object([.init("ok", .bool(false)), .init("why", .string(BackendCommunityChannels.unavailable)), .init("items", .array([])), .init("homes", .object([])), .init("folder", .string(""))]) }
        return try await BackendCommunityProjection.projectView(raw, userData: userData, probe: probe)
    }
    public func install(_ id: String, choice: NativeRPCValue) async throws -> NativeRPCValue {
        guard let store else { return Self.noStore }
        return try await store.install(id: id, choice: choice)
    }
    public func remove(_ id: String) async throws -> NativeRPCValue {
        guard let store else { return Self.noStore }
        return try await store.remove(id: id)
    }
}

/// browser.extract (store-tools.ts:244-390) over the Safari browser that
/// `browser.read` uses. The factory resolves the installed recipe, refuses a
/// page outside the recipe's origins before anything runs (store-tools.ts:327)
/// and does the completeness arithmetic; this adapter supplies the three facts
/// only the Safari owner has. Nothing here executes downloaded code: a recipe
/// is digest-verified declarative data run by the app's own closed script.
///
/// App-target closures (NativeCompositionBrowser; `BackendMCPCallContext` is
/// mapped through the browser's own `mcpContext`, i.e. its
/// NativeCompositionBrowserAuthority.rpc, so its principal resolution holds):
/// - `installed`: `{ await recipes.installedRecipes() }` — every parsed,
///   digest-verified install, read per call (store-tools.ts:79-82,
///   browser-store.ts:527-534); damaged installs are left out. No grant check of
///   its own: the central gate has accepted this read already.
/// - `origin`: `{ native, args in try await service.extractionOrigin(try await mcpContext(native), arguments: args) }`
///   — store-tools.ts:315-327 `deps.drive.origin(boundOf(args, context).target)`.
/// - `extract`: `{ native, args in try await service.page(try await mcpContext(native), operation: "extract", arguments: args, sessionReader: true) }`
///   — the exact closure `BackendBrowserRecipes` is built with
///   (NativeCompositionBrowser.swift:175): same target, baton, isolated world,
///   secret guard and origin re-check as browser.read. `args` are the tool's
///   arguments plus `recipe` (the verified recipe object) and `limit`
///   (1...2000); the answer is the Safari ExtractResult
///   {url,title,fields,rows,rowsOnPage,rowsReturned,counts,stated,next,...}.
///
/// The service's own pieces live with their owners: `BackendBrowserRecipes.installedRecipes()`
/// and `removeOrphan(_:id:)`, and `BackendBrowserService.extractionOrigin(_:arguments:)`.
public struct BackendCompositionDeckToolsExtraction: BackendDeckToolsAppExtractionService, Sendable {
    public typealias Installed = @Sendable () async throws -> [NativeRPCValue]
    public typealias Origin = @Sendable (_ caller: BackendMCPCallContext, _ arguments: NativeRPCValue) async throws -> String?
    public typealias Extract = @Sendable (_ caller: BackendMCPCallContext, _ arguments: NativeRPCValue) async throws -> NativeRPCValue
    /// browser-store-script.ts:76 DEFAULT_EXTRACT_LIMIT, used when no limit is given.
    public static let defaultExtractLimit = 200
    private let authority: BackendCompositionAuthority
    private let readInstalled: Installed
    private let readOrigin: Origin
    private let runRecipe: Extract
    public init(authority: BackendCompositionAuthority, installed: @escaping Installed,
                origin: @escaping Origin, extract: @escaping Extract) {
        self.authority = authority; readInstalled = installed; readOrigin = origin; runRecipe = extract
    }
    public func installed() async throws -> [NativeRPCValue] { try await readInstalled() }
    public func origin(_ caller: BackendMCPCallContext, arguments: NativeRPCValue) async throws -> String? {
        _ = try await authority.resolve(caller)
        return try await readOrigin(caller, arguments)
    }
    public func extract(_ caller: BackendMCPCallContext, arguments: NativeRPCValue, recipe: NativeRPCValue, limit: Int?) async throws -> NativeRPCValue {
        _ = try await authority.resolve(caller)
        let bounded = min(BackendDeckToolsAppExtraction.maxExtractLimit, max(1, limit ?? Self.defaultExtractLimit))
        return try await runRecipe(caller, arguments.setting("recipe", recipe).setting("limit", .number(Double(bounded))))
    }
}
