import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

// HOOT-TOOL-AUDIT group 2 (Asad, 11 Oct: Hoot may change everything "other than its own"): the access and
// security settings as tools. Each runs the settings screen's own engine call, behind the same consent gate
// (Hoot's permission mode decides asking; L6 keeps these refused for outside AI apps and agents).
// No secret ever comes back in a result: a new key's secret is shown only on the person's screen
// (Settings › Outside AI apps). Nothing here touches Hoot's own permission, the devices that may reach
// Hoot, its action log or its own confinement.

extension NativeCompositionProduction {
    func installAccessToolsThrowing() async throws {
        let owner = "native-composition:access-tools", mcp = root.mcp
        guard let authority else { return }
        let joins = self.joins
        let text = NativeRPCValue.object([.init("type", .string("string"))])
        let flag = NativeRPCValue.object([.init("type", .string("boolean"))])
        let number = NativeRPCValue.object([.init("type", .string("number"))])
        let texts = NativeRPCValue.object([.init("type", .string("array")), .init("items", text)])
        let nullableTexts = NativeRPCValue.object([.init("type", .array([.string("array"), .string("null")])), .init("items", text)])
        func schema(_ properties: [(String, NativeRPCValue)], required: [String]) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(properties.map { .init($0.0, $0.1) })),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        let definitions: [(String, BackendMCPTier, String, NativeRPCValue)] = [
            ("ai_apps.list", .read, "Outside AI app keys and the app's AI-app address: each key's id, name, access level, ask-first, tasks and folders, and whether the internet address is on. Secrets are never shown.",
             schema([], required: [])),
            ("ai_apps.create", .alter, "Make a key for an outside AI app (name, level, askFirst, folders). The secret is shown to the person on screen only, never returned here.",
             schema([("name", text), ("level", text), ("askFirst", flag), ("folders", nullableTexts)], required: ["name", "level"])),
            ("ai_apps.change", .alter, "Change one outside AI app key: name, level, askFirst, tasks, or folders (null = everywhere).",
             schema([("id", text), ("name", text), ("level", text), ("askFirst", flag), ("tasks", flag), ("folders", nullableTexts)], required: ["id"])),
            ("ai_apps.revoke", .alter, "Revoke an outside AI app key: it stops working at once.",
             schema([("id", text)], required: ["id"])),
            ("ai_apps.internet", .alter, "Turn the AI-app address on the internet on or off (Settings › Outside AI apps › From the internet).",
             schema([("on", flag)], required: ["on"])),
            ("servers.access", .alter, "A server's access settings: lookOnly (Look only / Look and change), aiKeys (outside AI app key ids allowed on it), shownApps (names, null = every app), folders (Files limits, null = only the home folder), allowMinutes (let sessions act there for that long).",
             schema([("server", text), ("lookOnly", flag), ("aiKeys", texts), ("shownApps", nullableTexts), ("folders", nullableTexts), ("allowMinutes", number)], required: ["server"])),
            ("plugins.manage", .alter, "Plugins: enable, disable, allow (capabilities, projects), remove, or open their folder, as Settings › Plugins does.",
             schema([("id", text), ("action", text.setting("enum", .array(["enable", "disable", "allow", "remove", "open_folder"].map(NativeRPCValue.string)))),
                     ("capabilities", texts), ("projects", texts)], required: ["action"])),
            ("app.debug_mode", .alter, "Turn the app's debug mode on or off (Settings › Advanced).",
             schema([("on", flag)], required: ["on"])),
        ]
        /// The screen's own engine call; plain values cross to the main actor and back. Secrets are taken out.
        @Sendable func engine(_ channel: String, _ arguments: [Any]) async throws -> NativeRPCValue {
            let wire = try arguments.map { try NativeRPCValue.fromFoundation($0) }
            let value = try await NativeWindowToolsBridge.invoke(channel, wire)
            if value["ok"].bool == false { throw NativeRPCError(code: "refused", message: value["message"].string ?? value["sentence"].string ?? "That did not go through.") }
            return NativeAccessToolsRedaction.clean(value)
        }
        let taken = Set(await mcp.registrations().map(\.0.id))
        for (id, tier, description, input) in definitions {
            if taken.contains(id) { NSLog("[native graph] access tool %@ is already registered by another owner; skipped", id); continue }
            let spec = try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: description, inputSchema: input, tier: tier)
            try await mcp.registerTool(spec, ownerID: owner) { caller, args in
                guard caller.allowedTiers.contains(tier) else { throw NativeRPCError(code: "not-granted", message: "This caller cannot change access settings.") }
                // Hoot only (Asad: "everything other than its own"): outside AI apps, sessions and phones are refused.
                guard BackendDeckCoreCatalogueRules.isHoot(try await authority.resolve(caller).caller) else {
                    throw NativeRPCError(code: "not-permitted", message: "Only Hoot may change access and security settings; the person changes them in Settings.")
                }
                func ask(_ sentence: String) async throws { try await joins.prepareNative(caller, tier: tier, sentence: sentence, ownerMustAnswer: false) }
                switch id {
                case "ai_apps.list":
                    return .value(try await engine("ai-apps:state", []))
                case "ai_apps.create":
                    let name = try args["name"].requireString("name", nonempty: true), level = try args["level"].requireString("level", nonempty: true)
                    try await ask("Make a key for the outside AI app “\(name)” (\(level))")
                    let request: [String: Any] = ["name": name, "level": level, "askFirst": args["askFirst"].bool ?? true,
                                                  "folders": args["folders"].elements.map { $0.compactMap(\.string) as Any } ?? NSNull()]
                    // The raw answer carries the secret: it goes to the person's screen and nowhere else.
                    let raw = try await NativeWindowToolsBridge.invoke("ai-apps:create", [try NativeRPCValue.fromFoundation(request)])
                    guard raw["ok"].bool == true, let key = raw["key"].string, let keyID = raw["id"].string else {
                        throw NativeRPCError(code: "refused", message: raw["message"].string ?? "The key was not made.")
                    }
                    let made: String? = keyID
                    await MainActor.run {
                        let model = AiAppsSettingsModel.shared
                        model.made = .init(key: key, id: keyID, name: name)
                        AppModel.shared.requestSettings(); AppModel.shared.selectSettingsSection("ai-apps")
                    }
                    return .value(.object([.init("id", made.map(NativeRPCValue.string) ?? .null), .init("name", .string(name)),
                                           .init("secret", .string("Shown to the person in Settings › Outside AI apps; never returned to an AI."))]))
                case "ai_apps.change":
                    let key = try args["id"].requireString("id", nonempty: true)
                    var did: [String] = []
                    try await ask("Change the outside AI app key \(key)")
                    if let name = args["name"].string { _ = try await engine("ai-apps:rename", [key, name]); did.append("name") }
                    if let level = args["level"].string { _ = try await engine("ai-apps:level", [key, level]); did.append("level") }
                    if let on = args["askFirst"].bool { _ = try await engine("ai-apps:ask-first", [key, on]); did.append("askFirst") }
                    if let on = args["tasks"].bool { _ = try await engine("ai-apps:tasks", [key, on]); did.append("tasks") }
                    if args.has("folders") { _ = try await engine("ai-apps:folders", [key, args["folders"].elements.map { $0.compactMap(\.string) as Any } ?? NSNull()]); did.append("folders") }
                    guard !did.isEmpty else { throw NativeRPCError.invalidArguments("pass name, level, askFirst, tasks or folders") }
                    return .value(.object([.init("id", .string(key)), .init("changed", .array(did.map(NativeRPCValue.string)))]))
                case "ai_apps.revoke":
                    let key = try args["id"].requireString("id", nonempty: true)
                    try await ask("Revoke the outside AI app key \(key)")
                    _ = try await engine("ai-apps:revoke", [key])
                    return .value(.object([.init("revoked", .string(key))]))
                case "ai_apps.internet":
                    let on = args["on"].bool ?? false
                    try await ask("Turn the AI-app address on the internet " + (on ? "on" : "off"))
                    return .value(try await engine("ai-apps:internet", [on]))
                case "servers.access":
                    let server = try args["server"].requireString("server", nonempty: true)
                    var did: [String] = []
                    try await ask("Change the access settings of the server \(server)")
                    if let look = args["lookOnly"].bool { _ = try await engine("servers:access:set", [server, ["lookOnly": look]]); did.append("lookOnly") }
                    if let keys = args["aiKeys"].elements { _ = try await engine("servers:ai-access:set", [server, keys.compactMap(\.string).sorted()]); did.append("aiKeys") }
                    if args.has("shownApps") { _ = try await engine("servers:shown-apps:set", [server, ["names": args["shownApps"].elements.map { $0.compactMap(\.string).sorted() as Any } ?? NSNull()]]); did.append("shownApps") }
                    if args.has("folders") { _ = try await engine("servers:files:folders:set", [server, ["folders": args["folders"].elements.map { $0.compactMap(\.string) as Any } ?? NSNull()]]); did.append("folders") }
                    if let minutes = args["allowMinutes"].number, minutes > 0 {
                        // Held at the longest grant before converting: Int(1e300 * 60_000) ends the app.
                        let most = BackendServersGrants.maximumGrantMilliseconds
                        _ = try await engine("servers:grant", [server, NativeNumber.clamped(min(minutes * 60_000, most), to: 1...Int(most), fallback: Int(most))]); did.append("allowMinutes")
                    }
                    guard !did.isEmpty else { throw NativeRPCError.invalidArguments("pass lookOnly, aiKeys, shownApps, folders or allowMinutes") }
                    return .value(.object([.init("server", .string(server)), .init("changed", .array(did.map(NativeRPCValue.string)))]))
                case "plugins.manage":
                    let action = args["action"].string ?? ""
                    if action == "open_folder" { _ = try await engine("plugins:open-folder", []); return .value(.object([.init("opened", .bool(true))])) }
                    let plugin = try args["id"].requireString("id", nonempty: true)
                    // A mistyped action is refused, never read as "remove".
                    let verbs = ["enable": "Turn on", "disable": "Turn off", "allow": "Change what may be done by", "remove": "Remove"]
                    guard let verb = verbs[action] else { throw NativeRPCError.invalidArguments("action must be enable, disable, allow, remove or open_folder") }
                    try await ask(verb + " the plugin \(plugin)")
                    switch action {
                    case "enable", "disable": return .value(try await engine("plugins:enable", [plugin, action == "enable"]))
                    case "allow": return .value(try await engine("plugins:allow", [plugin, ["capabilities": (args["capabilities"].elements ?? []).compactMap(\.string),
                                                                                          "projects": (args["projects"].elements ?? []).compactMap(\.string)]]))
                    default: return .value(try await engine("plugins:remove", [plugin]))
                    }
                default:
                    let on = args["on"].bool ?? false
                    try await ask("Turn debug mode " + (on ? "on" : "off"))
                    return .value(try await engine("settings:set", [["advanced.debugMode": on]]))
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

/// Takes every secret-looking field out of an answer before an AI sees it.
enum NativeAccessToolsRedaction {
    static let secretWords = ["secret", "token", "password", "privatekey", "bearer"]
    static func isSecret(_ name: String) -> Bool {
        let word = name.lowercased().replacingOccurrences(of: "_", with: "")
        return word == "key" || word == "apikey" || secretWords.contains { word.contains($0) }
    }
    static func clean(_ value: NativeRPCValue) -> NativeRPCValue {
        if let fields = value.fields {
            return .object(fields.filter { !isSecret($0.key) }.map { .init($0.key, clean($0.value)) })
        }
        if let items = value.elements { return .array(items.map(clean)) }
        return value
    }
}
