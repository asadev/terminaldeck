import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

// ACCOUNTS-SPEC (Asad, 11 Oct): accounts at every level. This file installs the tools that let
// Hoot, sessions and connected AI apps do what the Settings page does, and the asker for the
// Claude model list fetched with a login the app keeps. No login is read here.
// A seat's account at launch is NOT applied here: the launcher picks an agent's account before the
// agent-settings step, so the seat has to be passed there (see READY FORK-L1 ACCOUNTS).

extension NativeCompositionProduction {
    /// Never fatal: a problem here leaves accounts working as before (session → project → app).
    func installAccountLevels() async {
        // The live Claude model list is fetched with a login the app keeps, beside its own store.
        BackendAccountModelList.install { await NativeAccountModelListAsker.ask() }
        do { try await installAccountLevelTools() }
        catch { NSLog("[native graph] account level tools were not installed: %@", error.localizedDescription) }
        do { try await installAccounts18ProofTool() }
        catch { NSLog("[native graph] isolated account proof tool was not installed: %@", error.localizedDescription) }
        do { try await installAPIAccountTools() }
        catch { NSLog("[native graph] API account tools were not installed: %@", error.localizedDescription) }
    }

    private func installAccountLevelTools() async throws {
        let owner = "native-composition:account-levels", mcp = root.mcp
        guard let authority, let sessions else { return }
        let joins = self.joins
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        let nullable = text.setting("type", .array([.string("string"), .string("null")]))
        let flag = NativeRPCValue.object([.init("type", .string("boolean"))])
        let level: [(String, NativeRPCValue)] = [
            ("level", text.setting("enum", .array(["app", "project", "seat"].map(NativeRPCValue.string)))),
            ("projectPath", text), ("seat", text), ("ai", text)]
        func schema(_ properties: [(String, NativeRPCValue)], required: [String]) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let definitions: [(String, BackendMCPTier, String, NativeRPCValue)] = [
            ("accounts.levels", .read,
             "Which account each level uses, per AI: the whole app, each project folder and each seat (Hoot is seat \"orchestrator\", a project's lead is \"lead:<project id>\", a role is \"role:<project id>/<role>\"). A level with nothing set uses the level above it. Read-only.",
             schema([], required: [])),
            ("accounts.effective", .read,
             "The account that applies for one AI at a place, and where it comes from (session, seat, project, app, or the AI's own login on this Mac). Read-only.",
             schema([("ai", text), ("projectPath", text), ("seat", text), ("sessionAccount", text)], required: [])),
            ("accounts.set_level", .alter,
             "Set the account one level uses for one AI, for everything started from now on. account null means \"same as the level above\". Runs at once when the calling AI's permission mode allows it; the action is logged. Running sessions are not moved; use accounts.switch_level_now for that.",
             schema(level + [("account", nullable)], required: ["level", "ai", "account"])),
            ("accounts.switch_level_now", .alter,
             "Move the sessions already running under a level to the account now set for them, in place (same terminal, same conversation, no restart). Sessions listed in keep are left alone. Runs at once when the calling AI's permission mode allows it; the action is logged. Returns each session's result.",
             schema(level + [("keep", .object([.init("type", .string("array")), .init("items", text)])), ("dryRun", flag)], required: ["level", "ai"])),
        ]
        for (id, tier, description, input) in definitions {
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: input, tier: tier)
            try await mcp.registerTool(spec, ownerID: owner) { caller, args in
                guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot change accounts.") }
                _ = try await authority.resolve(caller)
                let context = try await authority.rpc(caller)
                let provider = args["ai"].string ?? "claude"
                switch id {
                case "accounts.levels":
                    return .value(try await sessions.accountRPC.invoke("profiles:levels", args: [], context: context))
                case "accounts.effective":
                    let input = NativeRPCValue.object([.init("provider", .string(provider)), .init("projectPath", args["projectPath"]),
                        .init("seat", args["seat"]), .init("sessionProfileId", args["sessionAccount"])])
                    return .value(try await sessions.accountRPC.invoke("profiles:effective", args: [input], context: context))
                case "accounts.set_level":
                    let wire = try NativeAccountLevelWire.wire(args)
                    try await joins.prepareNative(caller, tier: tier, sentence: "Change which " + CodingAICatalog.label(provider) + " account is used", ownerMustAnswer: true)
                    _ = try await sessions.accountRPC.invoke("profiles:set-level", args: [wire, .string(provider), args["account"].string.map(NativeRPCValue.string) ?? .null], context: context)
                    return .value(try await sessions.accountRPC.invoke("profiles:levels", args: [], context: context))
                default:
                    let wire = try NativeAccountLevelWire.wire(args), keep = Set((args["keep"].elements ?? []).compactMap(\.string))
                    // The sessions under the level, each with the account now in effect for it. A session
                    // that fills a seat (Hoot's, a lead's, a role's; every extra hand too) follows its seat.
                    guard let seatOf = await NativeAccountSeatSessions.current() else {
                        throw NativeRPCError(code: "not-ready", message: "The team list is still loading, so no session was moved. Try again in a moment.")
                    }
                    var moves: [(id: String, title: String, target: String)] = []
                    for session in sessions.manager.list() where session.exitCode == nil && session.provider == provider {
                        switch wire["kind"].string {
                        case "project":
                            let folder = wire["path"].string ?? ""
                            guard session.cwd == folder || session.cwd.hasPrefix(folder + "/") else { continue }
                        case "seat": guard seatOf[session.id] == wire["key"].string else { continue }
                        default: break
                        }
                        var fields: [NativeRPCValue.Field] = [.init("provider", .string(provider)), .init("projectPath", .string(session.cwd))]
                        if let seat = seatOf[session.id] { fields.append(.init("seat", .string(seat))) }
                        let target = try await sessions.accountRPC.invoke("profiles:effective", args: [.object(fields)], context: context)["accountId"].string ?? ""
                        let now = session.profileId ?? (provider == "claude" ? "system" : "system:" + provider)
                        if !target.isEmpty, target != now, !keep.contains(session.id) { moves.append((session.id, session.title, target)) }
                    }
                    if args["dryRun"].bool == true {
                        return .value(.object([.init("wouldMove", .array(moves.map { .object([.init("session", .string($0.id)), .init("title", .string($0.title)), .init("account", .string($0.target))]) }))]))
                    }
                    try await joins.prepareNative(caller, tier: tier, sentence: "Move \(moves.count) running session" + (moves.count == 1 ? "" : "s") + " to another account, in place", ownerMustAnswer: true)
                    var results: [NativeRPCValue] = []
                    for move in moves {
                        do {
                            _ = try await sessions.sessionRPC.invoke("session:switch-account", args: [.string(move.id), .string(move.target)], context: context)
                            results.append(.object([.init("session", .string(move.id)), .init("title", .string(move.title)), .init("result", .string("switched")), .init("account", .string(move.target))]))
                        } catch {
                            results.append(.object([.init("session", .string(move.id)), .init("title", .string(move.title)), .init("result", .string("failed")), .init("why", .string(error.localizedDescription))]))
                        }
                    }
                    return .value(.object([.init("results", .array(results)), .init("kept", .array(keep.sorted().map(NativeRPCValue.string)))]))
                }
            }
        }
        let ids = Set(definitions.map(\.0))
        let registered = await mcp.registrations().filter { ids.contains($0.0.id) }
        let metadata = registered.map { BackendDeckCoreCatalogueMetadata(tool: $0.0, title: $0.0.description, index: $0.0.description) }
        let policies = zip(metadata, registered).map { joins.mcpPolicy($0.0, handler: $0.1.1) }
        try joins.replaceContributions(owner: owner, [try .init(metadata: metadata, policies: policies)], policiesWrapped: true)
    }
}

/// Asks the account store (in the session helper when there is one) for the Claude model list
/// fetched with a login Terminal Deck keeps. No login passes through here, only the list.
@MainActor
enum NativeAccountModelListAsker {
    static func ask() async -> BackendAccountModelList.Answer {
        do {
            let raw = try await EngineBridge.shared.invoke("profiles:claude-models", [["seat": AGTSeat.orchestrator.key]]) as? [String: Any] ?? [:]
            if raw["source"] as? String == "system" { return .system }
            if let body = raw["body"] as? String { return .body(Data(body.utf8)) }
            return .failure(raw["failure"] as? String ?? "no list came back")
        } catch {
            // A session helper started before this update does not know the question. It can still
            // say which account is the default: this Mac's own login gives no list (it is never
            // read), and any other account waits for the updated helper instead.
            guard let old = try? await EngineBridge.shared.invoke("profiles:resolve", [["provider": "claude"]]) as? [String: Any],
                  old["system"] as? Bool == true else { return .failure("the account store could not be asked for the model list") }
            return .system
        }
    }
}

/// Which seat each running session fills, as the Agents side knows it (read only).
@MainActor
enum NativeAccountSeatSessions {
    /// Nil while the team list has not answered yet, so a caller refuses instead of moving nothing.
    static func current() async -> [String: String]? {
        AGTLeads.startSeatReads()
        // 18 Oct (#614): the seat and hand lists are read here and awaited. The agents and who is live come
        // through their own stores: wait for those first answers (up to ten seconds), never a guessed half second.
        await AGTSeatsStore.shared.refresh()
        await AGTHandsStore.shared.refresh()
        for _ in 0..<100 where !teamListed { try? await Task.sleep(for: .milliseconds(100)) }
        guard teamListed else { return nil }
        var map: [String: String] = [:]
        for seat in AGTLeads.roster() {
            for id in NativeAccountLevelsModel.sessionsFilling(seat) { map[id] = seat.seat.key }
        }
        return map
    }
    private static var teamListed: Bool {
        AGTAgentsStore.shared.fixture != nil || (TasksStore.shared.state != nil && AGTAgentsStore.shared.liveLoaded)
    }
}

/// A tool's level arguments as the account store's level.
enum NativeAccountLevelWire {
    nonisolated static func wire(_ args: NativeRPCValue) throws -> NativeRPCValue {
        switch args["level"].string {
        case "app": return .object([.init("kind", .string("app"))])
        case "project": return .object([.init("kind", .string("project")), .init("path", .string(try args["projectPath"].requireString("project folder", nonempty: true)))])
        case "seat": return .object([.init("kind", .string("seat")), .init("key", .string(try args["seat"].requireString("seat", nonempty: true)))])
        default: throw NativeRPCError.invalidArguments("Choose a level: app, project or seat.")
        }
    }
}
