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
/// Requested additions (INT), reusing those owners' private helpers:
/// ```swift
/// // BackendBrowserRecipes
/// public func installedRecipes() -> [NativeRPCValue] { entries.compactMap { try? installed($0) } }
/// /// browser-store.ts remove() of an orphanIds() folder: same safe-path rules as remove, read back after.
/// public func removeOrphan(_ context: NativeRPCContext, id: String) async throws -> NativeRPCValue {
///     try await authorize(context, "remove", id)
///     guard !entries.contains(where: { $0.id == id }) else { throw NativeRPCError.invalidArguments("That browser reader is still offered; remove it from its row.") }
///     let directory = try folder(id); try safeTree(directory)
///     guard FileManager.default.fileExists(atPath: directory.path) else { return .object([.init("ok", .bool(true)), .init("message", .string("It was not installed."))]) }
///     for name in ["recipe.json", "installed.json"] {
///         let file = directory.appendingPathComponent(name); try noSymlink(file)
///         if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
///     }
///     if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true { try FileManager.default.removeItem(at: directory) }
///     guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("recipe.json").path) else {
///         return .object([.init("ok", .bool(false)), .init("message", .string("It could not be removed: the folder is still on disk."))])
///     }
///     return .object([.init("ok", .bool(true)), .init("message", .string("The withdrawn browser reader was removed. Other files in its folder were preserved."))])
/// }
/// // BackendBrowserService (same rules as page(operation: "extract", sessionReader: true); no consent, no page command)
/// public func extractionOrigin(_ context: NativeRPCContext, arguments: NativeRPCValue) async throws -> String? {
///     let who = try await principal(context)
///     guard context.caller != .pairedDevice else { throw NativeRPCError(code: "not-permitted", message: "A paired device may not drive this Mac's browser.") }
///     if who.routesToOriginatingDevice { return nil }
///     let id: String
///     if who.managesWindows, let named = arguments["window"].string, named.uppercased().hasPrefix("W") {
///         guard let window = bindings.named(named) else { throw NativeRPCError(code: "not-permitted", message: "No browser window by that name is available.") }
///         id = window.tabID
///     } else {
///         let selectedSession = try await commandSession(who, verb: .read, arguments: arguments)
///         let envelope: [String: Any] = ["id": context.requestID.uuidString, "verb": BrowserDriverVerb.read.rawValue,
///             "args": arguments.foundation ?? [:], "session": selectedSession.map { ["sessionId": $0.sessionId, "machineId": $0.machineId] } as Any? ?? NSNull()]
///         guard let command = BrowserDriverCommand.decode([envelope]) else { throw NativeRPCError.invalidArguments("Invalid target.") }
///         switch try Self.resolveTarget(command, bindings: bindings.bindings(for: who)) {
///         case .own: guard let own = bindings.ownTab(who.ownerID) else { return nil }; id = own
///         case .window(let window, _): id = window.tabID
///         case .newWindow: return nil
///         }
///     }
///     guard runtime.handoverPrompt(id) == nil else { throw NativeRPCError(code: "not-permitted", message: "The person has this page right now.") }
///     guard bindings.window(id)?.hostMachineID.isEmpty != false else { return nil }
///     let url = runtime.pageURL(id); return url.isEmpty ? nil : url
/// }
/// ```
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
