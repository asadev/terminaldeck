import Foundation
import TerminalDeckNativeCore

/// Source catalogue metadata absent from the small shared MCP tool type.
public struct BackendDeckCoreCatalogueMetadata: Sendable {
    public let tool: BackendMCPTool
    public let title: String
    public let aliases: [String]
    public let index: String?
    public let audience: String?
    public let keyIndex: String?
    public let keyGrant: String?
    public init(tool: BackendMCPTool, title: String, aliases: [String] = [], index: String? = nil,
                audience: String? = nil, keyIndex: String? = nil, keyGrant: String? = nil) {
        self.tool = tool; self.title = title; self.aliases = aliases; self.index = index
        self.audience = audience; self.keyIndex = keyIndex; self.keyGrant = keyGrant
    }
    public var advertisedValue: NativeRPCValue {
        BackendDeckCoreCatalogueRules.object([
            ("name", .string(tool.wireName)), ("title", .string(title)), ("description", .string(tool.description)),
            ("inputSchema", tool.inputSchema), ("annotations", BackendDeckCoreCatalogueRules.object([
                ("title", .string(title)), ("readOnlyHint", .bool(tool.tier == .read)),
                ("destructiveHint", .bool(tool.tier == .alter)), ("openWorldHint", .bool(false))
            ]))
        ])
    }
    public func visible(to granted: Set<String>?, caller: BackendDeckCoreSecurityCaller) -> Bool {
        if audience == "keys" && caller.kind != .key { return false }
        if audience == "copilot" && caller.kind == .key { return false }
        if keyGrant != nil && caller.kind == .key && !(keyGrant == "tasks" && caller.tasks) { return false }
        return granted == nil || granted!.contains(tool.id) || granted!.contains(tool.wireName) || aliases.contains { granted!.contains($0) }
    }
    public func asListed(keyCaller: Bool) -> Self? {
        if audience == "keys" && !keyCaller || audience == "copilot" && keyCaller { return nil }
        return Self(tool: tool, title: title, aliases: aliases, index: index ?? (keyCaller ? keyIndex : nil),
                    audience: audience, keyIndex: keyIndex, keyGrant: keyGrant)
    }
    public func replacingDescription(_ description: String) throws -> Self {
        let replacement = try BackendMCPTool(id: tool.id, wireName: tool.wireName, description: description,
            inputSchema: tool.inputSchema, tier: tool.tier, advertised: tool.advertised, implementation: tool.implementation)
        return Self(tool: replacement, title: title, aliases: aliases, index: index, audience: audience, keyIndex: keyIndex, keyGrant: keyGrant)
    }
}

public struct BackendDeckCoreCatalogueCost: Sendable, Equatable {
    public let tools: Int
    public let chars: Int
    public let tokens: Int
    public let overBudget: Bool
    public var wireValue: NativeRPCValue {
        BackendDeckCoreCatalogueRules.object([("tools", .number(Double(tools))), ("chars", .number(Double(chars))),
            ("tokens", .number(Double(tokens))), ("overBudget", .bool(overBudget))])
    }
    public static func measure(_ tools: [BackendDeckCoreCatalogueMetadata]) -> Self {
        let payload = NativeRPCValue.object([.init("tools", .array(tools.map(\.advertisedValue)))]).compact
        let tokens = BackendDeckCoreCatalogueRules.estimateTokens(payload)
        return Self(tools: tools.count, chars: payload.utf16.count, tokens: tokens,
            overBudget: tools.count > BackendDeckCoreCatalogueRules.maxCatalogueTools || tokens > BackendDeckCoreCatalogueRules.maxCatalogueTokens)
    }
}

/// Alias resolution uses the same metadata describe returns, including late tool areas.
public struct BackendDeckCoreCatalogueRegistry: Sendable {
    public let metadata: [BackendDeckCoreCatalogueMetadata]
    public init(metadata: [BackendDeckCoreCatalogueMetadata]) throws {
        var seen = Set<String>()
        for spec in metadata {
            for name in [spec.tool.id, spec.tool.wireName] + spec.aliases {
                guard seen.insert(name).inserted else { throw NativeRPCError.invalidArguments("duplicate tool name: \(name)") }
            }
        }
        self.metadata = metadata
    }
    public func resolve(_ name: String) -> BackendDeckCoreCatalogueMetadata? {
        metadata.first { $0.tool.id == name || $0.tool.wireName == name || $0.aliases.contains(name) }
    }
    public func listing(granted: Set<String>? = nil, caller: BackendDeckCoreSecurityCaller = .local) throws -> [BackendDeckCoreCatalogueMetadata] {
        try BackendDeckCoreCatalogueDescribe.advertised(metadata.filter { $0.visible(to: granted, caller: caller) }, run: caller.kind == .key)
    }
}

public struct BackendDeckCoreCatalogueBundle: Sendable {
    public let metadata: [BackendDeckCoreCatalogueMetadata]
    public let policies: [BackendDeckCoreSecurityToolPolicy]
    public init(metadata: [BackendDeckCoreCatalogueMetadata], policies: [BackendDeckCoreSecurityToolPolicy]) throws {
        _ = try BackendDeckCoreCatalogueRegistry(metadata: metadata)
        guard Set(metadata.map { $0.tool.id }) == Set(policies.map { $0.tool.id }),
              policies.count == metadata.count else { throw NativeRPCError.invalidArguments("Every catalogue tool needs its real policy and handler.") }
        self.metadata = metadata; self.policies = policies
    }
    /// All area handlers re-enter the supplied central gate. Never register raw policy.run closures.
    public func area(id: String, describeText: String, dispatch: @escaping @Sendable (String, BackendMCPCallContext, NativeRPCValue) async throws -> BackendMCPToolReply) throws -> BackendDeckCoreToolArea {
        var handlers: [String: BackendNativeMCPServer.Handler] = [:]
        for entry in metadata {
            let name = entry.tool.id
            handlers[name] = { context, arguments in try await dispatch(name, context, arguments) }
        }
        return try BackendDeckCoreToolArea(id: id, tools: metadata.map(\.tool), describeText: describeText, handlers: handlers)
    }
}

public struct BackendDeckCoreCatalogueToolArea: Sendable {
    public let id: String
    public let covers: String
    public let prefixes: [String]
}

public enum BackendDeckCoreCatalogueDescribe {
    public static let id = "tools.describe"
    public static let wire = "tools_describe"
    public static let runID = "tools.run"
    public static let runWire = "tools_run"
    public static let maxNames = 20
    public static let inlineIndexMax = 12
    public static let areas: [BackendDeckCoreCatalogueToolArea] = [
        .init(id: "sessions", covers: "sessions beyond the listed tools (wait for an answer, press keys, read the screen, rename, switch account, held sessions), past conversations, projects, files, git, dev servers, the overview, and Stays Fixed checks (that nothing which already worked has changed)", prefixes: ["sessions", "chats", "projects", "files", "git", "dev", "dashboard", "artifacts", "alerts", "log", "tour", "fixed"]),
        // Asad retired Chrome imports/extensions; the native index names the Safari features that remain.
        .init(id: "browser", covers: "the built-in browser beyond the listed verbs: windows, toolbar, downloads, history, profiles, saved logins, site data, sign-in help, scraping, worker profiles and downloading files", prefixes: ["browser", "assets"]),
        .init(id: "machines", covers: "other paired computers and their sessions, servers (sites, logs, terminals), who can reach this computer, and GitHub", prefixes: ["machines", "servers", "remote", "github"]),
        .init(id: "agents", covers: "the coding agents, their logins, models and controls, their MCP servers and hooks, routines, usage and cost, dictation, setup and readiness checks, the community store, and tasks — your own and CRM tasks — with the task agents", prefixes: ["agents", "accounts", "mcp", "hooks", "routines", "usage", "voice", "setup", "readiness", "store", "tasks", "crm"]),
        .init(id: "knowledge", covers: "what is known about a project and how sure: verified results, claims, decisions, constraints, architecture, what is stale or in conflict — and recording or replacing it", prefixes: ["knowledge"]),
        .init(id: "devices", covers: "iOS Simulators, Android emulators and USB Android phones on this Mac: list, start, see, tap, swipe, type, buttons, the elements on screen, and what a person marked with Annotate", prefixes: ["devices"]),
        .init(id: "memory", covers: "your own memory notes — the ones your agent keeps and reads at the start — searched and read, with their links", prefixes: ["memory"]),
        .init(id: "app", covers: "this app itself: version, logs, diagnostics, updates, settings, notifications, Hoot, clicks in its window, sessions in windows of their own and the monitors, opening links, and what this tool server covers", prefixes: ["app", "settings", "updates", "notifications", "hoot", "ui", "windows", "links", "tools"])
    ]
    public static let description = "Get the full schema for one of the tools listed below. They are real tools you can call; their arguments are fetched here rather than sent on every turn. Ask for the ones you need, then call them."
    public static let areaDescription = "Most of this server’s tools are held back to keep this list short, grouped into the areas below. Call this with an area to list what it has, then with the tool names you want to get their arguments, then call them."
    public static func areaOf(_ id: String) -> String {
        let prefix = id.split(separator: ".", maxSplits: 1).first.map(String.init) ?? id
        return areas.first { $0.prefixes.contains(prefix) }?.id ?? prefix
    }
    public static func covers(_ id: String) -> String { areas.first { $0.id == id }?.covers ?? "the \(id) tools" }
    public static func index(_ behind: [BackendDeckCoreCatalogueMetadata]) -> String {
        behind.map { "\($0.tool.wireName) — \($0.index ?? $0.title)" }.joined(separator: "\n")
    }
    public static func areaIndex(_ behind: [BackendDeckCoreCatalogueMetadata]) -> String {
        var counts: [String: Int] = [:]
        for spec in behind { counts[areaOf(spec.tool.id), default: 0] += 1 }
        let order = areas.map(\.id)
        return counts.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? order.count, ib = order.firstIndex(of: b) ?? order.count
            return ia == ib ? a.localizedCompare(b) == .orderedAscending : ia < ib
        }.map { "\($0) — \(covers($0)) (\(counts[$0]!) tools)" }.joined(separator: "\n")
    }
    public static func advertised(_ visible: [BackendDeckCoreCatalogueMetadata], run: Bool = false) throws -> [BackendDeckCoreCatalogueMetadata] {
        let mine = visible.compactMap { $0.asListed(keyCaller: run) }
        let behind = mine.filter { $0.index != nil }
        let full = mine.filter { $0.index == nil && $0.tool.id != id && ($0.tool.id != runID || run) }
        guard !behind.isEmpty else { return full }
        guard let describe = mine.first(where: { $0.tool.id == id }) else { return full + behind }
        let how = run ? " Your client can only call listed tools, so call these through tools_run." : ""
        let text = behind.count > inlineIndexMax ? areaDescription + how + "\n\n" + areaIndex(behind) : describe.tool.description + how + "\n\n" + index(behind)
        return full + [try describe.replacingDescription(text)]
    }
    /// server.ts's actual tools/list mapping, including honest wrapper hints for this key.
    public static func wireListing(metadata: [BackendDeckCoreCatalogueMetadata], caller: BackendDeckCoreSecurityCaller, granted: Set<String>?) throws -> [NativeRPCValue] {
        try advertised(metadata.filter { $0.visible(to: granted, caller: caller) }, run: caller.kind == .key).map { spec in
            guard spec.tool.id == runID else { return spec.advertisedValue }
            let value = spec.advertisedValue
            let annotations = value["annotations"]
                .setting("readOnlyHint", .bool(!caller.tiers.contains(.act) && !caller.tiers.contains(.alter)))
                .setting("destructiveHint", .bool(caller.tiers.contains(.alter)))
            return value.setting("annotations", annotations)
        }
    }
    public static func names(_ args: NativeRPCValue) -> [String] {
        if let name = args["tools"].string { return name.isEmpty ? [] : [name] }
        return (args["tools"].elements ?? []).compactMap(\.string).filter { !$0.isEmpty }
    }
    public static func requestedArea(_ args: NativeRPCValue) -> String? {
        guard let raw = args["area"].string else { return nil }
        let area = BackendDeckCoreCatalogueRules.trim(raw).lowercased()
        return area.isEmpty ? nil : area
    }
    public static func answer(_ args: NativeRPCValue, catalogue: [BackendDeckCoreCatalogueMetadata], granted: Set<String>?, caller: BackendDeckCoreSecurityCaller) throws -> BackendDeckCoreSecurityToolOutput {
        let names = names(args), area = requestedArea(args)
        guard !names.isEmpty || area != nil else { throw BackendDeckCoreSecurityRefusal(.notPermitted, "name an area to see what it has, or tools to get their arguments") }
        guard names.count <= maxNames else { throw BackendDeckCoreSecurityRefusal(.notPermitted, "describe at most \(maxNames) tools in one call") }
        var answer = NativeRPCValue.object([]), unknown: [String] = [], described: [NativeRPCValue] = [], heldCount = 0
        if let area {
            let inside = catalogue.compactMap { $0.asListed(keyCaller: caller.kind == .key) }.filter {
                $0.tool.id != id && areaOf($0.tool.id) == area && $0.visible(to: granted, caller: caller)
            }
            if inside.isEmpty { unknown.append("no area called \(area)") }
            else {
                let held = inside.filter { $0.index != nil }
                heldCount = held.count
                answer = BackendDeckCoreCatalogueRules.object([
                    ("area", .string(area)), ("covers", .string(covers(area))),
                    ("held", .array(held.map { spec in BackendDeckCoreCatalogueRules.object([
                        ("name", .string(spec.tool.wireName)), ("tier", .string(spec.tool.tier.rawValue)), ("does", .string(spec.index ?? spec.title))
                    ]) })), ("alreadyListed", BackendDeckCoreCatalogueRules.strings(inside.filter { $0.index == nil }.map { $0.tool.wireName }))
                ])
            }
        }
        for name in names {
            guard let found = catalogue.first(where: { $0.tool.id == name || $0.tool.wireName == name || $0.aliases.contains(name) }),
                  let spec = found.asListed(keyCaller: caller.kind == .key), spec.visible(to: granted, caller: caller) else {
                unknown.append("no tool called \(name)"); continue
            }
            described.append(spec.advertisedValue)
        }
        if !names.isEmpty { answer = answer.setting("tools", .array(described)) }
        if !unknown.isEmpty { answer = answer.setting("unknown", BackendDeckCoreCatalogueRules.strings(unknown)) }
        var summary = NativeRPCValue.object([])
        if let area { summary = summary.setting("area", .string(area)).setting("held", .number(Double(heldCount))) }
        summary = summary.setting("described", .number(Double(described.count))).setting("unknown", .number(Double(unknown.count)))
        return .init(value: answer, summary: summary)
    }
    public static func tools(catalogue: @escaping @Sendable () -> [BackendDeckCoreCatalogueMetadata]) throws -> BackendDeckCoreCatalogueBundle {
        let schema = BackendDeckCoreCatalogueRules.object([("type", .string("object")), ("properties", BackendDeckCoreCatalogueRules.object([
            ("area", BackendDeckCoreCatalogueRules.object([("type", .string("string")), ("description", .string("One area from the list below, to see the tools in it."))])),
            ("tools", BackendDeckCoreCatalogueRules.object([("type", .string("array")), ("items", .object([.init("type", .string("string"))])), ("description", .string("Tool names, to get their full arguments."))]))
        ])), ("additionalProperties", .bool(false))])
        let tool = try BackendMCPTool(id: id, wireName: wire, description: description, inputSchema: schema, tier: .read)
        let runSchema = BackendDeckCoreCatalogueRules.object([("type", .string("object")), ("properties", BackendDeckCoreCatalogueRules.object([
            ("name", BackendDeckCoreCatalogueRules.object([("type", .string("string")), ("description", .string("The tool to run, e.g. sessions_get. See tools_describe."))])),
            ("arguments", BackendDeckCoreCatalogueRules.object([("type", .string("object")), ("description", .string("That tool’s arguments, exactly as tools_describe lists them.")), ("additionalProperties", .bool(true))]))
        ])), ("required", BackendDeckCoreCatalogueRules.strings(["name"])), ("additionalProperties", .bool(false))])
        let run = try BackendMCPTool(id: runID, wireName: runWire, description: "Call one of the tools held behind tools_describe, by name. Find it by area and get its arguments there first, then pass them here as `arguments`. It runs with exactly the same permissions, confirmations and limits as calling the tool directly, and answers with that tool’s own result.", inputSchema: runSchema, tier: .read)
        return try .init(metadata: [.init(tool: tool, title: "Get a tool’s arguments"), .init(tool: run, title: "Run a tool by name")], policies: [
            .init(tool: tool, summary: { args, _ in
                let names = names(args), area = requestedArea(args)
                if let area, names.isEmpty { return "Describe the \(area) tools" }
                return names.isEmpty ? "Describe tools" : "Describe \(names.joined(separator: ", "))"
            }, run: { args, context in try answer(args, catalogue: catalogue(), granted: context.granted, caller: context.caller) }),
            .init(tool: run, summary: { args, _ in (try? BackendDeckCoreCatalogueRunTarget.parse(args)).map { "Run \($0.name)" } ?? "Run a tool" }, run: { _, _ in
                throw NativeRPCError(code: "internal", message: "deck-control: tools.run must be dispatched by DeckControl.call, never run directly")
            })
        ])
    }
}
