import Foundation
import TerminalDeckNativeCore

/// Resolve authorization from the authenticated native owner/paired-device/MCP
/// caller table. Never decode a grant from arguments or trust a raw machine ID.
public struct BackendBrowserProfilesOperation: Sendable {
    public let domain: String
    public let action: String
    public let tier: BackendMCPTier
    public let profileID: String?
    public let tabID: String?
    public let origin: String?
    public let username: String?
    public let documentID: String?
    public let ownerMustAnswer: Bool
    /// Input metadata for a concrete consent preview, never a vault password.
    public let details: NativeRPCValue
    public init(domain: String, action: String, tier: BackendMCPTier, profileID: String? = nil,
                tabID: String? = nil, origin: String? = nil, username: String? = nil, documentID: String? = nil,
                ownerMustAnswer: Bool = false, details: NativeRPCValue = .missing) {
        self.domain = domain; self.action = action; self.tier = tier; self.profileID = profileID; self.tabID = tabID
        self.origin = origin; self.username = username; self.documentID = documentID; self.ownerMustAnswer = ownerMustAnswer; self.details = details
    }
}

public struct BackendBrowserProfilesToolGrant: Sendable {
    public enum Kind: Sendable, Equatable { case ownerApplication, ordinarySession, pairedDevice }
    public let kind: Kind
    public let attended: Bool
    public let tiers: Set<BackendMCPTier>
    public let profileIDs: Set<String>
    public let tabIDs: Set<String>
    public let globalSettings: Bool
    /// A fresh answer for the operation named above, never "allow always".
    public let ownerAnswered: Bool
    public let stillPermitted: @Sendable () async -> Bool
    public init(kind: Kind, attended: Bool, tiers: Set<BackendMCPTier>, profileIDs: Set<String>, tabIDs: Set<String>,
                globalSettings: Bool, ownerAnswered: Bool, stillPermitted: @escaping @Sendable () async -> Bool) {
        self.kind = kind; self.attended = attended; self.tiers = tiers; self.profileIDs = profileIDs; self.tabIDs = tabIDs
        self.globalSettings = globalSettings; self.ownerAnswered = ownerAnswered; self.stillPermitted = stillPermitted
    }
}

public enum BackendBrowserProfilesChannels {
    public typealias Authorize = @Sendable (NativeRPCContext, BackendBrowserProfilesOperation) async throws -> Void
    public static let channels = [
        "browser-profile:list", "browser-profile:create", "browser-profile:rename", "browser-profile:avatar", "browser-profile:activate", "browser-profile:delete",
        "browser-history:list", "browser-history:suggest", "browser-history:forget", "browser-history:clear",
        "browser-password:available", "browser-password:state", "browser-password:show-file", "browser-password:list", "browser-password:forget",
        "browser-password:forget-all", "browser-password:copy", "browser-password:offer", "browser-password:answer", "browser-password:fill",
        "browser-signin:diagnose", "browser-signin:handover", "browser-signin:agents"
    ]
    /// Register once after explicit store open and app-owned policy setup.
    /// changed must publish browser-profile:state only to authorized app hosts.
    public static func register(in registry: NativeChannelRegistry, ownerID: String, profiles: BackendBrowserProfiles,
                                passwords: BackendBrowserPasswords, signIn: BackendBrowserSignIn,
                                authorize: @escaping Authorize,
                                changed: @escaping @Sendable (BackendBrowserProfileState) async throws -> Void) async throws {
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, arguments in
                guard context.caller != .page else { throw NativeRPCError(code: "access-denied", message: "Website pages cannot access browser settings or saved logins.") }
                let suffix = channel.split(separator: ":").last.map(String.init) ?? ""
                let prefix = channel.split(separator: ":").first.map(String.init) ?? ""
                let id = context.argument(0, in: arguments).string ?? "default"
                if prefix == "browser-profile" {
                    try context.requireCount(arguments, suffix == "list" ? 0...0 : ["rename", "avatar"].contains(suffix) ? 2...2 : 1...1)
                    try await authorize(context, .init(domain: "profiles", action: suffix, tier: suffix == "list" ? .read : .alter,
                        profileID: ["list", "create"].contains(suffix) ? nil : id, details: .array(arguments)))
                    let state: BackendBrowserProfileState
                    switch suffix {
                    case "list": return try await profiles.state().wireValue
                    case "create": _ = try await profiles.create(name: arguments[0].string); state = try await profiles.state()
                    case "rename": state = try await profiles.rename(id: id, name: try arguments[1].requireString("name"))
                    case "avatar": state = try await profiles.avatar(id: id, avatar: try arguments[1].requireString("avatar"))
                    case "activate": state = try await profiles.activate(id: id)
                    case "delete": state = try await profiles.delete(id: id)
                    default: throw NativeRPCError.invalidArguments("Unknown profile channel.")
                    }
                    try await changed(state); return state.wireValue
                }
                if prefix == "browser-history" {
                    try context.requireCount(arguments, ["list", "suggest"].contains(suffix) ? 1...2 : suffix == "forget" ? 2...2 : 1...1)
                    try await authorize(context, .init(domain: "history", action: suffix, tier: ["forget", "clear"].contains(suffix) ? .alter : .read, profileID: id, details: .array(arguments)))
                    let second = context.argument(1, in: arguments).string ?? ""
                    let rows: [BrowserVisit]
                    switch suffix {
                    case "list": rows = try await profiles.history(profileID: id, query: second)
                    case "suggest": rows = try await profiles.suggest(profileID: id, typed: second)
                    case "forget": rows = try await profiles.forget(profileID: id, url: second)
                    case "clear": rows = try await profiles.clearHistory(profileID: id)
                    default: throw NativeRPCError.invalidArguments("Unknown history channel.")
                    }
                    return .array(rows.map(BackendBrowserProfiles.visitValue))
                }
                if prefix == "browser-password" {
                    let exactCount: ClosedRange<Int> = ["forget", "copy"].contains(suffix) ? 3...3 : suffix == "fill" ? 1...2 : ["list", "answer"].contains(suffix) ? 1...1 : 0...0
                    try context.requireCount(arguments, exactCount)
                    if suffix == "copy", context.caller != .nativeApp {
                        throw NativeRPCError(code: "access-denied", message: "Only the native saved-password manager can copy a password.")
                    }
                    if suffix == "fill" {
                        let tabID = try arguments[0].requireString("tabId", nonempty: true)
                        try await authorize(context, .init(domain: "passwords", action: "fill-target", tier: .read, tabID: tabID))
                        guard let request = try await passwords.prepareFill(tabID: tabID, username: context.argument(1, in: arguments).string) else { return .bool(false) }
                        try await authorize(context, fillOperation(request))
                        return .bool(try await passwords.fill(request))
                    }
                    let offer = suffix == "answer" ? try await passwords.pendingOffer() : nil
                    let tier: BackendMCPTier = ["forget", "forget-all", "answer", "copy"].contains(suffix) ? .alter : suffix == "show-file" ? .act : .read
                    try await authorize(context, .init(domain: "passwords", action: suffix, tier: tier,
                        profileID: ["list", "forget", "copy"].contains(suffix) ? id : offer?.login.profileID,
                        origin: ["forget", "copy"].contains(suffix) ? context.argument(1, in: arguments).string : offer?.login.origin,
                        username: ["forget", "copy"].contains(suffix) ? context.argument(2, in: arguments).string : offer?.login.username, details: .array(arguments)))
                    switch suffix {
                    case "available": return .bool(try await passwords.available())
                    case "state": return try await passwords.storeState()
                    case "show-file": return .bool(try await passwords.reveal())
                    case "list": return .array(try await passwords.summaries(profileID: id).map(\.wireValue))
                    case "forget": return try await passwords.forget(profileID: id, origin: try arguments[1].requireString("origin"), username: try arguments[2].requireString("username")).wireValue
                    case "forget-all": return try await passwords.forgetAll().wireValue
                    case "copy": return .bool(try await passwords.copy(profileID: id, origin: try arguments[1].requireString("origin"), username: try arguments[2].requireString("username")))
                    case "offer": return try await passwords.pendingOffer()?.wireValue ?? .null
                    case "answer":
                        guard let offer else { return BackendBrowserPasswordOutcome(ok: false, message: "Nothing to save.").wireValue }
                        guard let keep = arguments[0].bool else { throw NativeRPCError.invalidArguments("keep must be true or false.") }
                        return try await passwords.answer(keep: keep, expectedOffer: offer.id).wireValue
                    default: throw NativeRPCError.invalidArguments("Unknown saved-password channel.")
                    }
                }
                try context.requireCount(arguments, suffix == "agents" ? 0...0 : 1...1)
                try await authorize(context, .init(domain: "signin", action: suffix, tier: suffix == "handover" ? .act : .read, details: .array(arguments)))
                switch suffix {
                case "diagnose": return BackendBrowserSignIn.diagnose(try arguments[0].requireString("url"))?.wireValue ?? .null
                case "handover": return try await signIn.handover(try arguments[0].requireString("url"))?.wireValue ?? .null
                case "agents": return .array(try await signIn.agents().map(\.wireValue))
                default: throw NativeRPCError.invalidArguments("Unknown sign-in channel.")
                }
            }
        }
    }
    public static func fillOperation(_ request: BackendBrowserPasswordFill) -> BackendBrowserProfilesOperation {
        .init(domain: "passwords", action: "fill", tier: .alter, profileID: request.profileID, tabID: request.tabID,
            origin: request.origin, username: request.username, documentID: request.documentID, ownerMustAnswer: true)
    }
    /// Every browser.passwords action but a fill, exactly as the tool builds it
    /// (BackendBrowserProfilesToolFactories.register): never the owner's to
    /// answer, because only a fill is (browser-password-tools.ts
    /// fillMustBeAnswered; key-reach.test.ts L242). `site` is forget's required
    /// site, already read; `offer` the pending save offer offer/answer are about.
    /// A fill is fillOperation's, built from its prepared request, so not here.
    public static func passwordOperation(action: String, arguments: NativeRPCValue, profileID: String?, site: String? = nil,
                                         offer: BackendBrowserPasswordOffer? = nil) throws -> BackendBrowserProfilesOperation {
        guard action != "fill" else { throw NativeRPCError.invalidArguments("A saved-login fill is built from its prepared request.") }
        if action == "forget", site == nil { throw NativeRPCError.invalidArguments("site is required.") }
        let tier: BackendMCPTier = ["forget", "forgetall", "answer"].contains(action) ? .alter : action == "reveal" ? .act : .read
        return .init(domain: "passwords", action: action, tier: tier, profileID: profileID ?? offer?.login.profileID,
            origin: action == "forget" ? site : offer?.login.origin,
            username: action == "forget" ? arguments["username"].string ?? "" : offer?.login.username, details: arguments)
    }
}

/// Exact source tool IDs and action schemas. BackendNativeMCPServer validates
/// only the catalogue's base tier, so this factory always asks the supplied
/// authority for the action tier, owner consent and profile/tab scope anew.
public enum BackendBrowserProfilesToolFactories {
    public typealias Authorize = @Sendable (BackendMCPCallContext, BackendBrowserProfilesOperation) async throws -> BackendBrowserProfilesToolGrant
    public typealias ResolveWindow = @Sendable (BackendMCPCallContext, String, String?) async throws -> String
    public static func register(in server: BackendNativeMCPServer, profiles: BackendBrowserProfiles,
                                passwords: BackendBrowserPasswords, signIn: BackendBrowserSignIn,
                                authorize: @escaping Authorize, resolveWindow: @escaping ResolveWindow,
                                changed: @escaping @Sendable (BackendBrowserProfileState) async throws -> Void) async throws {
        for domain in ["history", "profiles", "passwords", "signin"] {
            let spec = try BackendMCPTool(id: "browser." + domain, wireName: "browser_" + domain,
                description: descriptions[domain]!, inputSchema: schemas[domain]!, tier: .read)
            try await server.registerTool(spec) { context, raw in
                do {
                    let args = try raw.requireObject("arguments")
                    let valid = Set(schemas[domain]!["properties"].fields?.map(\.key) ?? [])
                    guard (args.fields ?? []).allSatisfy({ valid.contains($0.key) }) else { throw NativeRPCError.invalidArguments("Unexpected browser-tool argument.") }
                    let action = try readAction(args, domain: domain)
                    // Eligibility runs before resolving names or reading any
                    // private metadata, so even a refused request cannot learn
                    // profile names through a validation error.
                    try await checkEntry(context, domain: domain, action: action, authorize: authorize)
                    let value: NativeRPCValue
                    if domain == "profiles" {
                        let state = try await profiles.state()
                        let named = ["list", "create"].contains(action) ? nil : try state.resolve(try requiredString(args, "profile"))
                        try await check(context, .init(domain: domain, action: action, tier: action == "list" ? .read : .alter, profileID: named?.id, details: args), authorize)
                        var current = state
                        switch action {
                        case "list": value = .object([.init("profiles", current.toolProfiles)])
                        case "create":
                            let made = try await profiles.create(name: try optionalString(args, "name")); current = try await profiles.state()
                            value = .object([.init("created", made.toolValue.setting("on", .bool(made.id == current.activeID))), .init("note", .string(savedNote))])
                        case "rename": current = try await profiles.rename(id: named!.id, name: try requiredString(args, "name")); value = .object([.init("profiles", current.toolProfiles), .init("note", .string(savedNote))])
                        case "avatar": current = try await profiles.avatar(id: named!.id, avatar: try args["avatar"].requireString("avatar")); value = .object([.init("profiles", current.toolProfiles), .init("note", .string(savedNote))])
                        case "activate": current = try await profiles.activate(id: named!.id); value = .object([.init("on", .string(named!.name)), .init("profiles", current.toolProfiles), .init("note", .string("New browser windows use this profile. Windows already open keep their existing profile."))])
                        case "delete": current = try await profiles.delete(id: named!.id); value = .object([.init("deleted", .string(named!.name)), .init("profiles", current.toolProfiles)])
                        default: throw NativeRPCError.invalidArguments("Unknown profile action.")
                        }
                        if action != "list" { try await changed(current) }
                    } else if domain == "history" {
                        let profile = try await profiles.state().resolve(try optionalString(args, "profile"))
                        try await check(context, .init(domain: domain, action: action, tier: ["forget", "clear"].contains(action) ? .alter : .read, profileID: profile.id, details: args), authorize)
                        switch action {
                        case "list":
                            let rows = try await profiles.history(profileID: profile.id, query: try optionalString(args, "query") ?? "", limit: try limit(args["limit"]))
                            value = .object([.init("profile", .string(profile.name)), .init("visits", .array(rows.map(visitToolValue))), .init("returned", .number(Double(rows.count)))])
                        case "suggest": let rows = try await profiles.suggest(profileID: profile.id, typed: try requiredString(args, "typed")); value = .object([.init("profile", .string(profile.name)), .init("suggestions", .array(rows.map(visitToolValue)))])
                        case "forget":
                            let url = try requiredString(args, "url")
                            guard try await profiles.history(profileID: profile.id, limit: 5000).contains(where: { $0.url == url }) else { throw NativeRPCError.invalidArguments("The address is not in this profile's history.") }
                            _ = try await profiles.forget(profileID: profile.id, url: url)
                            value = .object([.init("profile", .string(profile.name)), .init("forgotten", .string(url)), .init("note", .string(savedNote))])
                        case "clear": _ = try await profiles.clearHistory(profileID: profile.id); value = .object([.init("profile", .string(profile.name)), .init("cleared", .bool(true)), .init("note", .string(savedNote))])
                        default: throw NativeRPCError.invalidArguments("Unknown history action.")
                        }
                    } else if domain == "passwords" {
                        if action == "fill" {
                            let tabID = try await resolveWindow(context, try requiredString(args, "window"), try optionalString(args, "sessionId"))
                            try await check(context, .init(domain: domain, action: "fill-target", tier: .read, tabID: tabID), authorize)
                            guard let request = try await passwords.prepareFill(tabID: tabID, username: try optionalString(args, "username")) else { throw NativeRPCError.invalidArguments("The window has no matching saved login on a sign-in form.") }
                            try await check(context, BackendBrowserProfilesChannels.fillOperation(request), authorize)
                            guard try await passwords.fill(request) else { throw NativeRPCError(code: "page-changed", message: "Nothing was filled: the page or sign-in form changed after consent.") }
                            value = .object([.init("filled", .bool(true)), .init("window", .string(try requiredString(args, "window"))), .init("site", .string(request.origin)), .init("username", .string(request.username))])
                        } else {
                            let profile = ["list", "forget"].contains(action) ? try await profiles.state().resolve(try optionalString(args, "profile")) : nil
                            let offer = ["offer", "answer"].contains(action) ? try await passwords.pendingOffer() : nil
                            let site = action == "forget" ? try requiredString(args, "site") : nil
                            try await check(context, try BackendBrowserProfilesChannels.passwordOperation(action: action, arguments: args,
                                profileID: profile?.id, site: site, offer: offer), authorize)
                            switch action {
                            case "list":
                                let rows = try await passwords.summaries(profileID: profile!.id), store = try await passwords.storeState()
                                let logins = rows.map { $0.wireValue.removing("profileId").removing("origin").setting("site", .string($0.origin)) }
                                value = .object([.init("profile", .string(profile!.name)), .init("canStore", store["available"]), .init("file", store["path"]), .init("fileExists", store["exists"]), .init("problem", store["message"]), .init("logins", .array(logins))])
                            case "forget":
                                let site = try requiredString(args, "site"), username = args["username"].string ?? ""
                                guard try await passwords.summaries(profileID: profile!.id).contains(where: { $0.origin == site && $0.username == username }) else { throw NativeRPCError.invalidArguments("This profile has no saved login for that site and username.") }
                                let outcome = try await passwords.forget(profileID: profile!.id, origin: site, username: username); try requireOutcome(outcome)
                                value = .object([.init("forgotten", .bool(true)), .init("message", .string(outcome.message))])
                            case "forgetall": let outcome = try await passwords.forgetAll(); try requireOutcome(outcome); value = .object([.init("forgotten", .string("all")), .init("message", .string(outcome.message))])
                            case "reveal": guard try await passwords.reveal() else { throw NativeRPCError.invalidArguments("Nothing has been saved yet, so there is no file to show.") }; value = .object([.init("shown", .bool(true))])
                            case "offer": value = offer.map { .object([.init("waiting", .bool(true)), .init("site", .string($0.login.origin)), .init("username", .string($0.login.username))]) } ?? .object([.init("waiting", .bool(false))])
                            case "answer":
                                guard let offer, let save = args["save"].bool else { throw NativeRPCError.invalidArguments("answer needs a pending offer and save: true or false.") }
                                let outcome = try await passwords.answer(keep: save, expectedOffer: offer.id); try requireOutcome(outcome)
                                value = .object([.init("saved", .bool(save)), .init("message", .string(outcome.message))])
                            default: throw NativeRPCError.invalidArguments("Unknown saved-password action.")
                            }
                        }
                    } else {
                        try await check(context, .init(domain: domain, action: action, tier: action == "handover" ? .act : .read, details: args), authorize)
                        switch action {
                        case "diagnose":
                            if let trouble = BackendBrowserSignIn.diagnose(try requiredString(args, "url")) { value = trouble.wireValue.removing("domains").setting("known", .bool(true)).setting("sites", .array(trouble.domains.map(NativeRPCValue.string))) }
                            else { value = .object([.init("known", .bool(false)), .init("note", .string("No known refusal was detected from this address. This is not a sign-in success check."))]) }
                        case "handover":
                            guard let plan = try await signIn.handover(try requiredString(args, "url")) else { throw NativeRPCError.invalidArguments("The address is not an http or https sign-in page.") }
                            value = .object([.init("opened", .string(plan.url.absoluteString)), .init("bringBack", .array(plan.domains.map(NativeRPCValue.string))), .init("note", .string(BackendBrowserSignIn.externalReturnLimitation))])
                        case "agents":
                            let checked = try await signIn.checkedAgents(), stale = checked.filter(\.stale), unknown = checked.filter { $0.version == nil }
                            value = .object([.init("stale", .array(stale.map(\.wireValue))), .init("checked", .array(checked.map(\.wireValue))),
                                .init("note", .string(!unknown.isEmpty ? "The installed version could not be read; compatibility is unverified." : stale.isEmpty ? "No installed agent CLI is below the recorded compatibility floor." : ""))])
                        default: throw NativeRPCError.invalidArguments("Unknown sign-in action.")
                        }
                    }
                    try Task.checkCancellation(); guard !context.cancellation.isCancelled else { throw CancellationError() }
                    return .value(value)
                } catch is CancellationError { throw CancellationError() }
                catch { return .failure(error.localizedDescription) }
            }
        }
    }
    private static func check(_ context: BackendMCPCallContext, _ operation: BackendBrowserProfilesOperation, _ authorize: Authorize) async throws {
        try Task.checkCancellation()
        guard !context.cancellation.isCancelled else { throw CancellationError() }
        let grant = try await authorize(context, operation)
        guard grant.kind != .ordinarySession, grant.tiers.contains(operation.tier), await grant.stillPermitted() else {
            throw NativeRPCError(code: "access-denied", message: "This caller is not permitted to use browser settings.")
        }
        if operation.domain == "passwords" || (operation.domain == "signin" && operation.action == "handover") {
            guard grant.kind == .ownerApplication, grant.attended, context.attended else { throw NativeRPCError(code: "access-denied", message: "This operation requires the owner at the desktop.") }
        }
        if let id = operation.profileID { guard grant.profileIDs.contains(id) else { throw NativeRPCError(code: "access-denied", message: "The browser profile is outside this caller's grant.") } }
        if let id = operation.tabID { guard grant.tabIDs.contains(id) else { throw NativeRPCError(code: "access-denied", message: "The browser window is outside this caller's grant.") } }
        if operation.profileID == nil && operation.tabID == nil { guard grant.globalSettings else { throw NativeRPCError(code: "access-denied", message: "Global browser settings access was not granted.") } }
        if operation.ownerMustAnswer { guard grant.ownerAnswered else { throw NativeRPCError(code: "consent-required", message: "The owner must answer this exact saved-login fill request.") } }
        try Task.checkCancellation(); guard !context.cancellation.isCancelled else { throw CancellationError() }
    }
    private static func checkEntry(_ context: BackendMCPCallContext, domain: String, action: String, authorize: Authorize) async throws {
        try Task.checkCancellation(); guard !context.cancellation.isCancelled else { throw CancellationError() }
        // "access" is an internal read-only eligibility query, not a new tool
        // action. The host must answer it without displaying a change dialog.
        let grant = try await authorize(context, .init(domain: domain, action: "access", tier: .read))
        guard grant.kind != .ordinarySession, grant.tiers.contains(.read), await grant.stillPermitted() else {
            throw NativeRPCError(code: "access-denied", message: "This caller is not permitted to access browser settings.")
        }
        if domain == "passwords" || (domain == "signin" && action == "handover") {
            guard grant.kind == .ownerApplication, grant.attended, context.attended else {
                throw NativeRPCError(code: "access-denied", message: "This operation requires the owner at the desktop.")
            }
        }
    }
    /// Internal (not private) so key-reach.test.ts L242's `{}` can be read the way the tool reads it.
    static func readAction(_ args: NativeRPCValue, domain: String) throws -> String {
        let actions = schemas[domain]!["properties"]["action"]["enum"].elements?.compactMap(\.string) ?? []
        let raw = args["action"]
        let value = raw == .missing || raw == .null || raw.string == "" ? (domain == "signin" ? "diagnose" : "list") : try raw.requireString("action")
        guard actions.contains(value) else { throw NativeRPCError.invalidArguments("action must be one of: \(actions.joined(separator: ", "))") }
        return value
    }
    private static func requiredString(_ args: NativeRPCValue, _ key: String) throws -> String {
        let text = try args[key].requireString(key, nonempty: true)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeRPCError.invalidArguments("\(key) is required.") }; return text
    }
    private static func optionalString(_ args: NativeRPCValue, _ key: String) throws -> String? {
        let raw = args[key]; if raw == .missing || raw == .null || raw.string == "" { return nil }; return try raw.requireString(key)
    }
    private static func limit(_ raw: NativeRPCValue) throws -> Int {
        if raw == .missing || raw == .null { return 100 }
        guard let number = raw.number, number.isFinite else { throw NativeRPCError.invalidArguments("limit must be a number.") }
        return Int(max(1, min(500, number.rounded(.towardZero))))
    }
    private static func requireOutcome(_ outcome: BackendBrowserPasswordOutcome) throws { guard outcome.ok else { throw NativeRPCError(code: "password-store-refused", message: outcome.message) } }
    private static func visitToolValue(_ visit: BrowserVisit) -> NativeRPCValue { BackendBrowserProfiles.visitValue(visit).removing("profileId") }
    private static let savedNote = "Saved. A browser panel that is already open shows it when it next reads its list."
    private static func field(_ type: String, _ description: String, values: [String]? = nil) -> NativeRPCValue {
        var result = NativeRPCValue.object([.init("type", .string(type)), .init("description", .string(description))])
        if let values { result = result.setting("enum", .array(values.map(NativeRPCValue.string))) }; return result
    }
    private static func schema(_ fields: [NativeRPCValue.Field]) -> NativeRPCValue {
        .object([.init("type", .string("object")), .init("properties", .object(fields)), .init("additionalProperties", .bool(false))])
    }
    public static let schemas: [String: NativeRPCValue] = [
        "history": schema([.init("action", field("string", "Default list.", values: ["list", "suggest", "forget", "clear"])),
            .init("profile", field("string", "A profile name or id. Omit for the one switched on.")),
            .init("query", field("string", "For list: only visits whose address or title contains this.")),
            .init("limit", field("integer", "For list. Default 100, max 500.")), .init("typed", field("string", "For suggest: what has been typed into the address bar so far.")),
            .init("url", field("string", "For forget: the address to forget, exactly as listed."))]),
        "profiles": schema([.init("action", field("string", "Default list.", values: ["list", "create", "rename", "avatar", "activate", "delete"])),
            .init("profile", field("string", "For rename, avatar, activate and delete: a name or id.")),
            .init("name", field("string", "For create and rename. Up to 40 characters.")),
            .init("avatar", field("string", "For avatar: one character, such as an emoji. Empty puts the initial back."))]),
        "passwords": schema([.init("action", field("string", "Default list.", values: ["list", "forget", "forgetall", "reveal", "offer", "answer", "fill"])),
            .init("profile", field("string", "For list and forget: a profile name or id. Omit for the one switched on.")),
            .init("site", field("string", "For forget: the site exactly as listed, like https://github.com.")),
            .init("username", field("string", "For forget: whose login. For fill: which saved login to use; omit for the newest.")),
            .init("save", field("boolean", "For answer: true keeps the offered login, false turns it down.")),
            .init("window", field("string", "For fill: W3 from browser.windows, or a session slot like B1 with sessionId.")),
            .init("sessionId", field("string", "For fill with a B slot."))]),
        "signin": schema([.init("action", field("string", "Default diagnose.", values: ["diagnose", "handover", "agents"])),
            .init("url", field("string", "For diagnose and handover: the sign-in page’s address."))])
    ]
    private static let descriptions = [
        "history": "The in-app browser's history, kept per profile: list, query, address-bar suggestions, forget one address or clear a profile. Changes require the person's permission.",
        "profiles": "The in-app browser's separate profiles: list, create, rename, set a badge, activate for new windows or delete with its website data. The default cannot be deleted. Every change requires permission.",
        "passwords": "Saved-login sites and usernames only. Passwords are never returned or copied here. List, forget, forgetall, reveal the encrypted file, inspect a pending offer, answer it or fill an exact saved login into the visible sign-in form. Each fill requires a fresh owner answer at the desktop.",
        "signin": "Diagnose sign-in refusal by URL, open a sign-in in the system browser, or check agent CLI versions against the recorded compatibility floor. Safari cookies cannot be copied back through public APIs; external opening does not prove the app is signed in."
    ]
}
