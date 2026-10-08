import Foundation
import TerminalDeckNativeCore

public struct BackendDeckCoreCatalogueCoverageRow: Sendable, Equatable {
    public let area: String
    public let action: String
    public let tools: [String]?
    public let skip: String?
    public init(area: String, action: String, tools: [String]? = nil, skip: String? = nil) {
        self.area = area; self.action = action; self.tools = tools; self.skip = skip
    }
    public var wireValue: NativeRPCValue {
        var fields = [NativeRPCValue.Field("area", .string(area)), .init("action", .string(action))]
        if let tools { fields.append(.init("tools", BackendDeckCoreCatalogueRules.strings(tools))) }
        if let skip { fields.append(.init("skip", .string(skip))) }
        return .object(fields)
    }
}

public enum BackendDeckCoreCatalogueCoverage {
    public static let areaNames = BackendUIGMemoryDiscovery.coverageAreas(["sessions", "machines", "agents", "browser", "devices", "fixed", "memory", "window"])
    public static let maxRows = 60
    /// Keep the full original map inspectable. Only Chrome-specific operations retire.
    public static var rows: [BackendDeckCoreCatalogueCoverageRow] {
        BackendUIGMemoryDiscovery.coverageRows(BackendDeckCoreCatalogueCoverageLiterals.sourceRows + [
            .init(area: "fixed", action: "staysfixed:setup-preview", tools: ["fixed.setup_preview"]),
            .init(area: "fixed", action: "staysfixed:setup-prepare", tools: ["fixed.setup_prepare"]),
            .init(area: "fixed", action: "staysfixed:setup-apply", tools: ["fixed.setup_apply"])
        ]).map { row in
            if row.tools?.contains(where: { ["browser.extensions", "browser.import"].contains($0) }) == true {
                return .init(area: row.area, action: row.action, skip: "Retired by Asad's Chrome removal. The native Mac browser uses Safari/WebKit; Chrome imports and Chrome extensions are removed.")
            }
            return row
        }
    }
    public static func matching(_ rows: [BackendDeckCoreCatalogueCoverageRow], query: String) -> [BackendDeckCoreCatalogueCoverageRow] {
        let words = BackendDeckCoreCatalogueRules.coverageWords(query)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in
            let text = (row.action + " " + (row.tools ?? []).joined(separator: " ") + " " + (row.skip ?? "")).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
    public static func answer(_ args: NativeRPCValue) throws -> BackendDeckCoreSecurityToolOutput {
        let area = try BackendDeckCoreCatalogueRules.optionalString(args, "area")
        let query = try BackendDeckCoreCatalogueRules.optionalString(args, "query")
        let skipped = try BackendDeckCoreCatalogueRules.optionalBool(args, "skippedOnly", fallback: false)
        let all = rows
        let counts = NativeRPCValue.object(areaNames.map { name in
            let inside = all.filter { $0.area == name }
            return .init(name, BackendDeckCoreCatalogueRules.object([
                ("actions", .number(Double(inside.count))), ("withTool", .number(Double(inside.filter { $0.tools != nil }.count)))
            ]))
        })
        if area == nil && query == nil && !skipped {
            return .init(value: BackendDeckCoreCatalogueRules.object([
                ("counts", counts), ("note", .string("Pass `query` to look an action up, or `skippedOnly: true` for every action with no tool and why."))
            ]), summary: .object([.init("rows", .number(0))]))
        }
        let scoped = all.filter { (area == nil || $0.area == area) && (!skipped || $0.skip != nil) }
        let found = query.map { matching(scoped, query: $0) } ?? scoped
        let kept = Array(found.prefix(maxRows))
        var value = BackendDeckCoreCatalogueRules.object([("counts", counts), ("rows", .array(kept.map(\.wireValue))), ("matched", .number(Double(found.count)))])
        if found.count > kept.count { value = value.setting("note", .string("More rows matched; narrow the query or the area.")) }
        if found.isEmpty && query != nil { value = value.setting("note", .string("Nothing in the table matches those words. Try fewer, or the name of the screen it is on.")) }
        return .init(value: value, summary: BackendDeckCoreCatalogueRules.object([("rows", .number(Double(kept.count))), ("matched", .number(Double(found.count)))]))
    }
    public static func tools() throws -> BackendDeckCoreCatalogueBundle {
        let schema = BackendDeckCoreCatalogueRules.object([("type", .string("object")), ("properties", BackendDeckCoreCatalogueRules.object([
            ("query", BackendDeckCoreCatalogueRules.object([("type", .string("string")), ("description", .string("Plain words for the action, e.g. \"switch account\"."))])),
            ("area", BackendDeckCoreCatalogueRules.object([("type", .string("string")), ("enum", BackendDeckCoreCatalogueRules.strings(areaNames))])),
            ("skippedOnly", BackendDeckCoreCatalogueRules.object([("type", .string("boolean")), ("description", .string("Only the actions with no tool, and why."))]))
        ])), ("additionalProperties", .bool(false))])
        let tool = try BackendMCPTool(id: "tools.coverage", wireName: "tools_coverage", description: "This app’s own table of every action a person can take in it — every button, menu, command and gesture — and for each, the tool that does the same thing, or one sentence on why there deliberately is no tool (it would hand back a password, answer its own confirmation, and so on). Pass `query` in plain words (\"rename a session\", \"saved passwords\") to find the rows; `area` narrows to sessions, machines, agents, browser or window. With nothing, it answers the counts. When a row says there is no tool, tell the person that and why, rather than looking for another way to do it. A tool it names may still be one you cannot see; tools.describe says.", inputSchema: schema, tier: .read)
        return try .init(metadata: [.init(tool: tool, title: "Can a tool do what a person does here?", index: "Whether a tool can do something a person does in this app — and if not, the reason. Ask before working around.")], policies: [
            .init(tool: tool, summary: { args, _ in
                try BackendDeckCoreCatalogueRules.optionalString(args, "query").map { "Look up whether a tool can “\($0)”" } ?? "Read what the tools cover"
            }, run: { args, _ in try answer(args) })
        ])
    }
}

/// A current native-window snapshot, supplied by the SwiftUI owner at call time.
public protocol BackendDeckCoreCatalogueWhereWindow: Sendable {
    func read() async throws -> NativeRPCValue
}
/// Safari's active drivable page only; never reads arbitrary sibling tabs.
public protocol BackendDeckCoreCatalogueWherePage: Sendable {
    func status() async -> NativeRPCValue
    func textAt(selector: String?, limit: Int) async throws -> NativeRPCValue
}
public struct BackendDeckCoreCatalogueWhereDependencies: Sendable {
    public let window: any BackendDeckCoreCatalogueWhereWindow
    public let page: @Sendable () -> (any BackendDeckCoreCatalogueWherePage)?
    public init(window: any BackendDeckCoreCatalogueWhereWindow, page: @escaping @Sendable () -> (any BackendDeckCoreCatalogueWherePage)?) {
        self.window = window; self.page = page
    }
}
public enum BackendDeckCoreCatalogueWhere {
    public static let pageTextChars = 1_200
    public static let sourceWindowCall = "globalThis.__terminaldeckWhere?.() ?? null"
    public static func readWhere(_ raw: NativeRPCValue) -> NativeRPCValue? {
        guard raw.fields != nil, let title = raw["title"].string else { return nil }
        let pane = raw["pane"].string.flatMap { ["terminal", "chat"].contains($0) ? $0 : nil }
        return BackendDeckCoreCatalogueRules.object([
            ("title", .string(title)), ("sessionId", raw["sessionId"].string.map(NativeRPCValue.string) ?? .null),
            ("pane", pane.map(NativeRPCValue.string) ?? .null), ("copilotFront", .bool(raw["copilotFront"] == .bool(true))),
            ("driving", .bool(raw["driving"] == .bool(true))),
            ("openSessions", BackendDeckCoreCatalogueRules.strings((raw["openSessions"].elements ?? []).compactMap(\.string)))
        ])
    }
    public static func answer(dependencies: BackendDeckCoreCatalogueWhereDependencies) async -> BackendDeckCoreSecurityToolOutput {
        let raw = (try? await dependencies.window.read()) ?? .null
        guard let view = readWhere(raw) else {
            return .init(value: BackendDeckCoreCatalogueRules.object([
                ("window", .null), ("note", .string("There is no window open to look at, so nothing is on screen. Answer from the session list instead, and do not describe a screen you cannot see."))
            ]), summary: .object([.init("window", .string("none"))]))
        }
        let page = dependencies.page()
        let url: String
        if let page {
            let status = await page.status()
            url = status["url"].string ?? ""
        } else { url = "" }
        var text: NativeRPCValue?
        if let page, !url.isEmpty, let read = try? await page.textAt(selector: nil, limit: pageTextChars),
           read["found"] == .bool(true), read["secret"] != .bool(true) { text = read }
        var pageValue = NativeRPCValue.null
        if !url.isEmpty {
            pageValue = BackendDeckCoreCatalogueRules.object([("url", .string(url)), ("text", text?["text"] ?? .null),
                ("textTruncated", text?["truncated"] ?? .bool(false))])
            if text == nil { pageValue = pageValue.setting("why", .string("The page’s text was not readable — it may be asking for a credential.")) }
        }
        var value = BackendDeckCoreCatalogueRules.object([
            ("window", BackendDeckCoreCatalogueRules.object([
                ("inFront", view["title"]), ("pane", view["pane"]), ("sessionId", view["sessionId"]),
                ("copilotWindowInFront", view["copilotFront"]), ("driving", view["driving"]), ("sessionsOpenInThisWindow", view["openSessions"])
            ])), ("page", pageValue)
        ])
        if view["sessionId"] == .null && view["pane"] == .string("chat") {
            value = value.setting("note", .string("A conversation is in front, and more than one session is live in that folder, so which one this pane is showing is genuinely ambiguous. Use the heading above and ask if it matters."))
        }
        var summary = NativeRPCValue.object([.init("inFront", view["title"])])
        if view["pane"] != .null { summary = summary.setting("pane", view["pane"]) }
        if !url.isEmpty { summary = summary.setting("page", .string(url)) }
        return .init(value: value, summary: summary)
    }
    public static func tools(dependencies: BackendDeckCoreCatalogueWhereDependencies) throws -> BackendDeckCoreCatalogueBundle {
        let schema = BackendDeckCoreCatalogueRules.object([("type", .string("object")), ("properties", .object([])), ("additionalProperties", .bool(false))])
        let tool = try BackendMCPTool(id: "app.where", wireName: "app_where", description: "What is on their screen right now: which window is in front, whether they are looking at a terminal or a conversation, which session it is, and — when a page is open in the browser you drive — that page’s address and its readable text. Read it before answering anything that says \"this\", \"here\", \"that page\" or \"what I am looking at\": those words mean whatever this returns, and guessing is how you answer confidently about the wrong screen. It is cheap and it changes nothing. It cannot see a browser tab you did not open, and it says so rather than guessing.", inputSchema: schema, tier: .read)
        return try .init(metadata: [.init(tool: tool, title: "See what they are looking at", keyIndex: "What is on the Mac’s screen right now: the window in front, the session, the open page.")], policies: [
            .init(tool: tool, summary: { _, _ in "Look at what is on their screen" }, run: { _, _ in await answer(dependencies: dependencies) })
        ])
    }
}
