import Foundation

/// The MCP servers page, as data: a port of the pure parts of
/// `components/McpInspector.tsx`, `McpSchemaForm.tsx`, `McpAddForm.tsx`,
/// `mcp-machines.ts` and `chat/attach/McpServers.ts`. Same narrowing, same words.

extension OrderedJSON {
    /// A Foundation value (an engine push), keys sorted — pushes carry no order the screen reads.
    public init(foundation any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let text as String: self = .string(text)
        case let list as [Any]: self = .array(list.map { OrderedJSON(foundation: $0) })
        case let map as [String: Any]:
            self = .object(map.keys.sorted().map { Field($0, OrderedJSON(foundation: map[$0])) })
        default: self = .null
        }
    }
}

// MARK: - Servers

public enum McpConnectionState: String, Sendable {
    case idle, connecting, ready, failed, closed

    /// `STATE_LABEL`.
    public var label: String {
        switch self {
        case .idle: return "Not connected"
        case .connecting: return "Connecting"
        case .ready: return "Connected"
        case .failed: return "Failed"
        case .closed: return "Exited"
        }
    }
}

public struct McpServerStatus: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var scope: String
    public var transport: String
    public var command: String?
    public var args: [String]
    public var url: String?
    public var source: String
    public var enabled: Bool
    public var disabledReason: String?
    public var unsupported: String?
    public var state: McpConnectionState
    public var error: String?
    public var serverInfo: (name: String, version: String)?
    public var capabilities: [String]
    public var instructions: String?
    public var pid: Int?
    public var connectedAt: Double?
    public var stderr: String

    public static func == (a: McpServerStatus, b: McpServerStatus) -> Bool {
        a.id == b.id && a.name == b.name && a.scope == b.scope && a.transport == b.transport && a.command == b.command
            && a.args == b.args && a.url == b.url && a.source == b.source && a.enabled == b.enabled
            && a.disabledReason == b.disabledReason && a.unsupported == b.unsupported && a.state == b.state
            && a.error == b.error && a.serverInfo?.name == b.serverInfo?.name && a.serverInfo?.version == b.serverInfo?.version
            && a.capabilities == b.capabilities && a.instructions == b.instructions && a.pid == b.pid
            && a.connectedAt == b.connectedAt && a.stderr == b.stderr
    }

    /// One server as the engine sends it. Nil without an id.
    public static func from(_ raw: OrderedJSON) -> McpServerStatus? {
        guard raw.isObject, let id = raw["id"]?.string else { return nil }
        let info = raw["serverInfo"]
        return McpServerStatus(
            id: id,
            name: raw["name"]?.string ?? id,
            scope: raw["scope"]?.string ?? "user",
            transport: raw["transport"]?.string ?? "stdio",
            command: raw["command"]?.string,
            args: (raw["args"]?.array ?? []).compactMap(\.string),
            url: raw["url"]?.string,
            source: raw["source"]?.string ?? "",
            enabled: raw["enabled"]?.bool ?? true,
            disabledReason: raw["disabledReason"]?.string,
            unsupported: raw["unsupported"]?.string,
            state: McpConnectionState(rawValue: raw["state"]?.string ?? "") ?? .idle,
            error: raw["error"]?.string,
            serverInfo: info?.isObject == true ? (info?["name"]?.string ?? "", info?["version"]?.string ?? "") : nil,
            capabilities: (raw["capabilities"]?.array ?? []).compactMap(\.string),
            instructions: raw["instructions"]?.string,
            pid: raw["pid"]?.number.map { Int($0) },
            connectedAt: raw["connectedAt"]?.number,
            stderr: raw["stderr"]?.string ?? ""
        )
    }

    /// `{ ...server, ...status }`: a push or an inventory's status over what is held.
    public func merging(_ raw: OrderedJSON) -> McpServerStatus {
        guard let fields = raw.fields else { return self }
        var held = OrderedJSON.object([])
        // Rebuild the held value as JSON, lay the new fields over it, read it back.
        for (key, value) in json() { held = held.setting(key, value) }
        for field in fields { held = held.setting(field.key, field.value) }
        return McpServerStatus.from(held) ?? self
    }

    private func json() -> [(String, OrderedJSON)] {
        var out: [(String, OrderedJSON)] = [
            ("id", .string(id)), ("name", .string(name)), ("scope", .string(scope)), ("transport", .string(transport)),
            ("command", command.map(OrderedJSON.string) ?? .null), ("args", .array(args.map(OrderedJSON.string))),
            ("url", url.map(OrderedJSON.string) ?? .null), ("source", .string(source)), ("enabled", .bool(enabled)),
            ("disabledReason", disabledReason.map(OrderedJSON.string) ?? .null),
            ("unsupported", unsupported.map(OrderedJSON.string) ?? .null), ("state", .string(state.rawValue)),
            ("error", error.map(OrderedJSON.string) ?? .null),
            ("capabilities", .array(capabilities.map(OrderedJSON.string))),
            ("instructions", instructions.map(OrderedJSON.string) ?? .null),
            ("pid", pid.map { .number(Double($0)) } ?? .null), ("connectedAt", connectedAt.map(OrderedJSON.number) ?? .null),
            ("stderr", .string(stderr)),
        ]
        out.append(("serverInfo", serverInfo.map { .object([.init("name", .string($0.name)), .init("version", .string($0.version))]) } ?? .null))
        return out
    }

    /// `formatCommand`: the command line for a local server, the URL for a remote one.
    public var commandLine: String {
        if transport != "stdio" { return url ?? "" }
        return ([command ?? ""] + args).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The ⓘ under a row: why it is off, or why it cannot be opened.
    public var why: String? { disabledReason ?? unsupported }
    public var whyLabel: String { disabledReason != nil ? "Why it is off" : "Why it cannot be opened" }
}

public struct McpTool: Equatable, Sendable, Identifiable {
    public let name: String
    public let title: String?
    public let description: String?
    public let inputSchema: OrderedJSON
    public let outputSchema: OrderedJSON?
    public var id: String { name }
}

public struct McpResource: Equatable, Sendable, Identifiable {
    public let uri: String
    public let name: String
    public let description: String?
    public let mimeType: String?
    public var id: String { uri }
}

public struct McpResourceTemplate: Equatable, Sendable, Identifiable {
    public let uriTemplate: String
    public let name: String
    public let description: String?
    public var id: String { uriTemplate }
}

public struct McpPrompt: Equatable, Sendable, Identifiable {
    public struct Argument: Equatable, Sendable { public let name: String; public let description: String?; public let required: Bool }
    public let name: String
    public let description: String?
    public let arguments: [Argument]
    public var id: String { name }
}

public enum McpSection: String, CaseIterable, Sendable, Identifiable {
    case tools, resources, prompts
    public var id: String { rawValue }
}

public struct McpInventory: Equatable, Sendable {
    public let serverId: String
    public let tools: [McpTool]
    public let resources: [McpResource]
    public let resourceTemplates: [McpResourceTemplate]
    public let prompts: [McpPrompt]
    /// In the order the engine sent them.
    public let errors: [(key: String, message: String)]
    public let status: OrderedJSON

    public static func == (a: McpInventory, b: McpInventory) -> Bool {
        a.serverId == b.serverId && a.tools == b.tools && a.resources == b.resources && a.resourceTemplates == b.resourceTemplates
            && a.prompts == b.prompts && a.errors.map(\.key) == b.errors.map(\.key) && a.errors.map(\.message) == b.errors.map(\.message)
            && a.status == b.status
    }

    public static func from(_ raw: OrderedJSON) -> McpInventory {
        func text(_ value: OrderedJSON?) -> String? { value?.string }
        return McpInventory(
            serverId: raw["serverId"]?.string ?? "",
            tools: (raw["tools"]?.array ?? []).compactMap { one in
                guard let name = one["name"]?.string else { return nil }
                return McpTool(name: name, title: text(one["title"]), description: text(one["description"]),
                               inputSchema: one["inputSchema"] ?? .null,
                               outputSchema: one["outputSchema"].flatMap { $0 == .null ? nil : $0 })
            },
            resources: (raw["resources"]?.array ?? []).compactMap { one in
                guard let uri = one["uri"]?.string else { return nil }
                return McpResource(uri: uri, name: one["name"]?.string ?? uri, description: text(one["description"]), mimeType: text(one["mimeType"]))
            },
            resourceTemplates: (raw["resourceTemplates"]?.array ?? []).compactMap { one in
                guard let template = one["uriTemplate"]?.string else { return nil }
                return McpResourceTemplate(uriTemplate: template, name: one["name"]?.string ?? template, description: text(one["description"]))
            },
            prompts: (raw["prompts"]?.array ?? []).compactMap { one in
                guard let name = one["name"]?.string else { return nil }
                let args: [McpPrompt.Argument] = (one["arguments"]?.array ?? []).compactMap { arg in
                    guard let argName = arg["name"]?.string else { return nil }
                    return McpPrompt.Argument(name: argName, description: text(arg["description"]), required: arg["required"]?.isTrue == true)
                }
                return McpPrompt(name: name, description: text(one["description"]), arguments: args)
            },
            errors: (raw["errors"]?.fields ?? []).compactMap { field in
                field.value.string.map { (field.key, $0) }
            },
            status: raw["status"] ?? .null
        )
    }

    /// `countFor`.
    public func count(_ section: McpSection) -> Int {
        switch section {
        case .tools: return tools.count
        case .prompts: return prompts.count
        case .resources: return resources.count + resourceTemplates.count
        }
    }

    /// `sectionErrors`: this tab's own failures, and the ones that belong to no tab.
    public func errors(for section: McpSection) -> [String] {
        let owned: [McpSection: [String]] = [.tools: ["tools"], .resources: ["resources", "resourceTemplates"], .prompts: ["prompts"]]
        let all = Set(owned.values.flatMap { $0 })
        let mine = owned[section] ?? []
        var out: [String] = []
        for (key, message) in errors where !message.isEmpty && (mine.contains(key) || !all.contains(key)) {
            if !out.contains(message) { out.append(message) }
        }
        return out
    }
}

public struct McpCallResult: Equatable, Sendable {
    public let ok: Bool
    public let result: OrderedJSON
    public let error: String?
    public let durationMs: Int
    public let truncated: Bool

    public static func from(_ raw: OrderedJSON) -> McpCallResult {
        McpCallResult(ok: raw["ok"]?.isTrue == true, result: raw["result"] ?? .null, error: raw["error"]?.string,
                      durationMs: Int(raw["durationMs"]?.number ?? 0), truncated: raw["truncated"]?.isTrue == true)
    }

    public static func failed(_ message: String) -> McpCallResult {
        McpCallResult(ok: false, result: .null, error: message, durationMs: 0, truncated: false)
    }

    /// `resultText`: the text blocks of an MCP result, joined; nil when there are none.
    public var text: String? {
        guard ok, let content = result["content"]?.array else { return nil }
        let parts = content.compactMap { block -> String? in
            guard block["type"]?.string == "text" else { return nil }
            return block["text"]?.string
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// "Succeeded in 12ms".
    public var summary: String { "\(ok ? "Succeeded" : "Failed") in \(durationMs)ms" }
}

/// `folderName` on the MCP page.
public func mcpFolderName(_ path: String?) -> String {
    guard let path, !path.isEmpty else { return "" }
    return path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
}

// MARK: - Another machine's servers

/// `McpRow` (`readServers`): a server as another machine reports it. The type itself is shared,
/// declared in TerminalHeaderModel.swift; this reads it from an ordered answer.
extension McpRow {
    /// Nil when the answer is not a list at all (the machine did not answer).
    public static func list(_ raw: OrderedJSON?) -> [McpRow]? {
        guard let items = raw?.array else { return nil }
        return items.compactMap { one in
            guard let id = one["id"]?.string, let name = one["name"]?.string else { return nil }
            return McpRow(id: id, name: name, scope: one["scope"]?.string, transport: one["transport"]?.string,
                          enabled: one["enabled"]?.bool != false, disabledReason: one["disabledReason"]?.string)
        }
    }
}

/// `MachineTarget`: a paired machine whose servers can be read, through one of its sessions.
public struct McpMachineTarget: Equatable, Sendable, Identifiable {
    public let machineId: String
    public let name: String
    public let sessionId: String
    public let sessionTitle: String
    public let cwd: String
    public var id: String { machineId }

    /// `reportableMachines`: online, offering `controls`, with a session to ask through.
    public static func reportable(_ view: OrderedJSON) -> [McpMachineTarget] {
        var links: [String: OrderedJSON] = [:]
        for link in view["links"]?.array ?? [] { if let id = link["id"]?.string { links[id] = link } }
        return (view["machines"]?.array ?? []).compactMap { machine in
            guard let id = machine["id"]?.string, let link = links[id], link["state"]?.string == "online",
                  (link["capabilities"]?.array ?? []).contains(.string("controls")),
                  let session = link["sessions"]?.array?.first, let sessionId = session["id"]?.string else { return nil }
            let title = session["title"]?.string ?? ""
            return McpMachineTarget(machineId: id, name: machine["name"]?.string ?? "", sessionId: sessionId,
                                    sessionTitle: title.isEmpty ? "a session" : title, cwd: session["cwd"]?.string ?? "")
        }
    }

    /// `pickSurvives`.
    public static func pickSurvives(_ pick: String?, _ targets: [McpMachineTarget]) -> Bool {
        pick == nil || targets.contains(where: { $0.machineId == pick })
    }

    /// `hereName`: this computer's own name, or "This Mac".
    public static func hereName(_ view: OrderedJSON) -> String {
        let named = (view["here"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        return named.isEmpty ? "This Mac" : named
    }
}

// MARK: - Adding a server

public enum McpAddScope: String, Sendable, CaseIterable { case user, project, local }
public enum McpAddTransport: String, Sendable, CaseIterable {
    case stdio, http, sse
    /// The options of "How it is reached".
    public var label: String {
        switch self {
        case .stdio: return "A command on this machine"
        case .http: return "An HTTP server"
        case .sse: return "An SSE server"
        }
    }
}

public struct McpAddDraft: Equatable, Sendable {
    public var name = ""
    public var scope: McpAddScope = .user
    public var transport: McpAddTransport = .stdio
    public var command = ""
    public var url = ""
    public var extras = ""
    public init() {}

    /// `missingFrom`.
    public var missing: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the server a name first." }
        if transport == .stdio, command.trimmingCharacters(in: .whitespaces).isEmpty { return "Say which command starts it." }
        if transport != .stdio, url.trimmingCharacters(in: .whitespaces).isEmpty { return "Say which URL it is reached at." }
        return nil
    }

    /// `draftToRequest`.
    public func request(projectPath: String?) -> [String: Any] {
        [
            "name": name.trimmingCharacters(in: .whitespaces),
            "scope": scope.rawValue,
            "transport": transport.rawValue,
            "command": transport == .stdio ? command.trimmingCharacters(in: .whitespaces) : "",
            "url": transport == .stdio ? "" : url.trimmingCharacters(in: .whitespaces),
            "extras": extras.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            "projectPath": projectPath as Any? ?? NSNull(),
        ]
    }
}

public struct McpScopeChoice: Equatable, Sendable {
    public let value: McpAddScope
    public let label: String
    public let help: String

    /// `scopeChoices`.
    public static func choices(projectPath: String?) -> [McpScopeChoice] {
        var out = [McpScopeChoice(value: .user, label: "All projects", help: "Available everywhere.")]
        if let projectPath, !projectPath.isEmpty {
            out.append(McpScopeChoice(value: .local, label: "This project only", help: "Private to this folder. Not committed."))
            out.append(McpScopeChoice(value: .project, label: "This project, shared", help: "Stays inactive until Claude Code asks you to approve it."))
        }
        return out
    }

    /// The "Save it for" ⓘ.
    public static func note(scope: McpAddScope, projectPath: String?) -> String {
        let help = choices(projectPath: projectPath).first(where: { $0.value == scope })?.help ?? ""
        return help + ((projectPath ?? "").isEmpty ? " Open a project to save one for that project alone." : "")
    }
}

/// `McpFormStart`: an edit's or an import's starting point.
public struct McpFormStart: Equatable, Sendable {
    public var draft: McpAddDraft
    public var savedKeys: [String]

    /// `editStart`.
    public static func edit(name: String, scope: McpAddScope, transport: McpAddTransport, command: String, envKeys: [String]) -> McpFormStart {
        var draft = McpAddDraft()
        draft.name = name
        draft.scope = scope
        draft.transport = transport
        draft.command = transport == .stdio ? command : ""
        draft.url = transport == .stdio ? "" : command
        draft.extras = envKeys.map { "\($0)=" }.joined(separator: "\n")
        return McpFormStart(draft: draft, savedKeys: envKeys)
    }

    /// `importStart`.
    public static func `import`(name: String, transport: McpAddTransport, command: String, url: String, env: [String], scope: McpAddScope) -> McpFormStart {
        var draft = McpAddDraft()
        draft.name = name
        draft.scope = scope
        draft.transport = transport
        draft.command = command
        draft.url = url
        draft.extras = env.map { "\($0)=" }.joined(separator: "\n")
        return McpFormStart(draft: draft, savedKeys: [])
    }

    /// The ⓘ beside "Environment variables" when editing with saved values.
    public var savedNote: String? {
        guard !savedKeys.isEmpty else { return nil }
        return "\(savedKeys.joined(separator: ", ")) already \(savedKeys.count == 1 ? "has a value" : "have values") in your configuration, and this app is never sent them — so they are shown with nothing after the =. A line left that way keeps what is saved. Type something to replace it. Delete the whole line to drop the variable."
    }
}

/// What `mcp:add` / `mcp:remove` answer.
public struct McpAddResult: Equatable, Sendable {
    public let ok: Bool
    public let message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }

    public static func from(_ raw: OrderedJSON) -> McpAddResult {
        McpAddResult(ok: raw["ok"]?.isTrue == true, message: raw["message"]?.string ?? "")
    }
}

// MARK: - A tool's arguments as a form (McpSchemaForm)

public enum McpFieldKind: String, Sendable { case string, number, integer, boolean, `enum`, array, object, json }

public struct McpEnumOption: Equatable, Sendable {
    public let value: OrderedJSON
    public let label: String
}

public struct McpSchemaField: Equatable, Sendable, Identifiable {
    public let name: String
    public let kind: McpFieldKind
    public let description: String?
    public let required: Bool
    public let inferred: Bool
    public let options: [McpEnumOption]?
    public let itemKind: McpFieldKind?
    public let itemOptions: [McpEnumOption]?
    public let fields: [McpSchemaField]?
    public let defaultValue: OrderedJSON?
    public var id: String { name }

    /// The small type word beside the name.
    public var typeWord: String { inferred ? "text (type not declared)" : kind.rawValue }
}

public struct McpSchemaDescription: Equatable, Sendable {
    public let fields: [McpSchemaField]
    public let fallback: String?
}

public enum McpSchema {
    static let maxDepth = 3

    private static func readType(_ raw: OrderedJSON) -> String? {
        if let type = raw["type"]?.string { return type }
        if let list = raw["type"]?.array { return list.compactMap(\.string).first(where: { $0 != "null" }) }
        return nil
    }

    private static func label(_ value: OrderedJSON) -> String { value.string ?? value.compact }

    private static func readOptions(_ raw: OrderedJSON) -> [McpEnumOption]? {
        if let list = raw["enum"]?.array, !list.isEmpty { return list.map { McpEnumOption(value: $0, label: label($0)) } }
        if raw.has("const"), let value = raw["const"] { return [McpEnumOption(value: value, label: label(value))] }
        guard let union = raw["anyOf"]?.array ?? raw["oneOf"]?.array, !union.isEmpty else { return nil }
        var consts: [McpEnumOption] = []
        for member in union {
            guard member.isObject else { return nil }
            if member.has("const"), let value = member["const"] { consts.append(McpEnumOption(value: value, label: label(value))) }
            else if let list = member["enum"]?.array { consts += list.map { McpEnumOption(value: $0, label: label($0)) } }
            else if readType(member) == "null" { continue }
            else { return nil }
        }
        return consts.isEmpty ? nil : consts
    }

    private static func field(_ name: String, _ raw: OrderedJSON, required: Bool, depth: Int) -> McpSchemaField {
        func make(_ kind: McpFieldKind, description: String? = nil, defaultValue: OrderedJSON? = nil, inferred: Bool = false,
                  options: [McpEnumOption]? = nil, itemKind: McpFieldKind? = nil, itemOptions: [McpEnumOption]? = nil,
                  fields: [McpSchemaField]? = nil) -> McpSchemaField {
            McpSchemaField(name: name, kind: kind, description: description, required: required, inferred: inferred,
                           options: options, itemKind: itemKind, itemOptions: itemOptions, fields: fields, defaultValue: defaultValue)
        }
        guard raw.isObject else { return make(.json) }
        let description = raw["description"]?.text
        let defaultValue = raw.has("default") ? raw["default"] : nil
        let type = readType(raw)
        if let options = readOptions(raw) { return make(.enum, description: description, defaultValue: defaultValue, options: options) }
        if type == "boolean" { return make(.boolean, description: description, defaultValue: defaultValue) }
        if type == "number" { return make(.number, description: description, defaultValue: defaultValue) }
        if type == "integer" { return make(.integer, description: description, defaultValue: defaultValue) }
        if type == "string" { return make(.string, description: description, defaultValue: defaultValue) }
        if type == "array" || (type == nil && raw.has("items")) {
            let items = raw["items"].flatMap { $0.isObject ? $0 : nil }
            let itemOptions = items.flatMap(readOptions)
            let itemType = items.flatMap(readType)
            let itemKind: McpFieldKind = itemOptions != nil ? .enum
                : itemType == "number" ? .number : itemType == "integer" ? .integer
                : itemType == "boolean" ? .boolean : itemType == "string" ? .string : .json
            let primitive: Set<McpFieldKind> = [.string, .number, .integer, .boolean, .enum]
            return make(.array, description: description, defaultValue: defaultValue,
                        itemKind: primitive.contains(itemKind) ? itemKind : nil, itemOptions: itemOptions)
        }
        if type == "object" || (type == nil && raw["properties"]?.isObject == true) {
            let nested = describe(raw, depth: depth + 1)
            if nested.fallback != nil || nested.fields.isEmpty { return make(.json, description: description, defaultValue: defaultValue) }
            return make(.object, description: description, defaultValue: defaultValue, fields: nested.fields)
        }
        if type == nil { return make(.string, description: description, defaultValue: defaultValue, inferred: true) }
        return make(.json, description: description, defaultValue: defaultValue)
    }

    /// `describeSchema`.
    public static func describe(_ schema: OrderedJSON?, depth: Int = 0) -> McpSchemaDescription {
        guard let schema, schema != .null else { return McpSchemaDescription(fields: [], fallback: "This tool did not describe its arguments.") }
        guard schema.isObject else { return McpSchemaDescription(fields: [], fallback: "This tool’s schema is not an object.") }
        if depth > maxDepth { return McpSchemaDescription(fields: [], fallback: "Nested too deeply to lay out as a form.") }
        let declared = readType(schema)
        if let declared, declared != "object" {
            return McpSchemaDescription(fields: [], fallback: "This tool’s schema describes a \(declared), not an argument object.")
        }
        guard let properties = schema["properties"] else {
            return McpSchemaDescription(fields: [], fallback: declared == "object" ? nil : "This tool did not list any arguments.")
        }
        guard let props = properties.fields else { return McpSchemaDescription(fields: [], fallback: "This tool’s argument list is malformed.") }
        let required = Set((schema["required"]?.array ?? []).compactMap(\.string))
        return McpSchemaDescription(fields: props.map { field($0.key, $0.value, required: required.contains($0.key), depth: depth) }, fallback: nil)
    }

    /// `initialValues`: each default, and nested objects' defaults.
    public static func initialValues(_ fields: [McpSchemaField]) -> OrderedJSON {
        var values = OrderedJSON.object([])
        for field in fields {
            if let value = field.defaultValue { values = values.setting(field.name, value) }
            else if field.kind == .object, let nested = field.fields {
                let inner = initialValues(nested)
                if !(inner.fields ?? []).isEmpty { values = values.setting(field.name, inner) }
            }
        }
        return values
    }

    /// `pruneArguments`: unset and empty-string values out, empty nested objects out, unset array items out.
    public static func prune(_ values: OrderedJSON) -> OrderedJSON {
        var out: [OrderedJSON.Field] = []
        for field in values.fields ?? [] {
            switch field.value {
            case .string(let text) where text.isEmpty: continue
            case .array(let items): out.append(.init(field.key, .array(items.filter { $0 != .null })))
            case .object:
                let nested = prune(field.value)
                if !(nested.fields ?? []).isEmpty { out.append(.init(field.key, nested)) }
            default: out.append(field)
            }
        }
        return .object(out)
    }

    /// `missingRequired`: required fields with nothing in them, nested as `parent.child`.
    public static func missingRequired(_ fields: [McpSchemaField], _ values: OrderedJSON) -> [String] {
        var missing: [String] = []
        for field in fields {
            let value = values[field.name]
            if field.kind == .object, let nested = field.fields {
                let inner = value?.isObject == true ? value! : .object([])
                missing += missingRequired(nested, inner).map { "\(field.name).\($0)" }
                continue
            }
            guard field.required else { continue }
            switch value {
            case nil, .null?: missing.append(field.name)
            case .string(let text)? where text.isEmpty: missing.append(field.name)
            case .array(let items)? where items.isEmpty: missing.append(field.name)
            default: break
            }
        }
        return missing
    }

    /// `selectIndexOf`: which option a value is, by identity then by its JSON.
    public static func selectIndex(_ options: [McpEnumOption], _ value: OrderedJSON?) -> Int? {
        guard let value else { return nil }
        if let same = options.firstIndex(where: { $0.value == value }) { return same }
        return options.firstIndex(where: { $0.value.compact == value.compact })
    }

    /// `coerceNumber`: a typed number, or nothing.
    public static func number(_ text: String, integer: Bool) -> OrderedJSON? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if integer {
            // parseInt(text, 10): an optional sign, then the leading digits; the rest is ignored.
            var rest = Substring(trimmed)
            var sign = ""
            if let first = rest.first, first == "+" || first == "-" { sign = first == "-" ? "-" : ""; rest = rest.dropFirst() }
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let n = Double(sign + digits) else { return nil }
            return .number(n)
        }
        guard let n = Double(trimmed), n.isFinite else { return nil }
        return .number(n)
    }

    /// What a JSON box reads: nil and no error for empty text, the value, or the parse error.
    public static func readJSONBox(_ text: String) -> (value: OrderedJSON?, error: String?) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (nil, nil) }
        if let parsed = OrderedJSON.parse(text) { return (parsed, nil) }
        return (nil, "Invalid JSON")
    }
}

// MARK: - Deadlines (deadline.ts)

public enum McpDeadline {
    /// `LIST_DEADLINE_MS`, `INVENTORY_DEADLINE_MS`, `SERVERS_FRESH_MS`, in seconds.
    public static let list = 12.0
    public static let inventory = 45.0
    public static let fresh = 30.0

    /// `describeMs`.
    public static func describe(seconds: Double) -> String {
        let ms = seconds * 1000
        if ms < 1000 { return "\(Int(ms.rounded())) ms" }
        let rounded = seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
        return "\(rounded) second\(rounded == "1" ? "" : "s")"
    }

    /// `Overdue`'s sentence.
    public static func overdue(_ what: String, seconds: Double) -> String {
        "\(what) did not answer within \(describe(seconds: seconds))."
    }

    /// `readFailure`: the engine's sentence without Electron's prefix.
    public static func failure(_ raw: String) -> String {
        guard let range = raw.range(of: #"^Error invoking remote method '[^']*':\s*"#, options: .regularExpression) else { return raw }
        return String(raw[range.upperBound...])
    }
}
