import Foundation

/// The Store's MCP servers department, as data: a port of `mcp-store-bridge.ts`
/// and the pure parts of `McpStore.tsx` / `McpStoreRow.tsx`. Same narrowing, same words.

public enum McpStoreCatalog {
    /// `MCP_CATEGORY_ORDER` with `MCP_CATEGORY_NAMES`: the shelves, in order.
    public static let shelves: [(id: String, name: String)] = [
        ("files", "Files on this machine"),
        ("code", "Code and repositories"),
        ("work", "Issues, projects and tickets"),
        ("data", "Databases"),
        ("cloud", "Hosting, cloud and what is running"),
        ("web", "Searching and reading the web"),
        ("browser", "Driving a browser"),
        ("knowledge", "Notes and documentation"),
        ("design", "Design"),
        ("business", "Payments and customers"),
        ("thinking", "What the agent remembers"),
        ("messaging", "Mail, chat and calendars"),
        ("utility", "Time, testing and odds and ends"),
        ("your-own", "Added by you"),
    ]

    public static func shelfName(_ id: String) -> String? { shelves.first { $0.id == id }?.name }

    public static let customSource = "custom"

    /// `ORIGIN_WORDS`.
    public static func originWords(_ origin: String) -> String {
        switch origin {
        case "reference": return "Reference server"
        case "reference-archived": return "Archived reference server"
        case "vendor": return "From the vendor"
        case "hosted": return "Runs on the vendor’s servers"
        default: return "Third party"
        }
    }

    /// `RUNTIME_WORDS`.
    public static func runtimeWords(_ runtime: String) -> String {
        switch runtime {
        case "python": return "uvx — fetched from PyPI the first time it runs"
        case "docker": return "docker — pulled as a container image"
        default: return "npx — fetched from npm the first time it runs"
        }
    }

    /// `MCP_FACETS`: every facet's words. The category one is the shelf rail's (`withoutShelf`).
    public static let vocabularies: [StoreFacet: FacetVocabulary] = [
        .category: FacetVocabulary(label: "Category", anyName: "Everything", options: shelves),
        .cost: FacetVocabulary(label: "What it costs", anyName: "Any price",
                               options: StoreFront.costOrder.map { ($0, StoreFront.costWord($0) ?? $0) }),
        .compat: FacetVocabulary(label: "On this machine", anyName: "Any",
                                 options: [("unknown", "Its runtime is here"), ("cannot", "Runtime missing")]),
        .installed: FacetVocabulary(label: "Installed", anyName: "Any",
                                    options: [("yes", "In your configuration"), ("no", "Not configured")]),
        .source: FacetVocabulary(label: "Where it comes from", anyName: "Anywhere", options: [
            (customSource, "Added by you"), ("reference", "Official reference"), ("vendor", "From the vendor"),
            ("hosted", "Runs on the vendor’s servers"), ("third-party", "Community"),
            ("reference-archived", "Archived — unmaintained"),
        ]),
        .needs: FacetVocabulary(label: "What it needs", anyName: "Any", options: [
            (StoreFront.needsNothing, "Nothing"), ("token", "A key or token"), ("setting", "A path or setting"), ("docker", "Docker"),
        ]),
    ]
}

public struct McpStoreInput: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case secret, path, text }
    public let key: String
    public let label: String
    public let hint: String
    public let kind: Kind
    /// "env" or "arg".
    public let into: String
    public let required: Bool
    public let inEnvironment: Bool
    public var id: String { key }

    static func from(_ raw: OrderedJSON) -> McpStoreInput? {
        guard raw.isObject, let key = raw["key"]?.text else { return nil }
        let into = raw["into"]?.string == "arg" ? "arg" : "env"
        return McpStoreInput(key: key, label: raw["label"]?.text ?? key, hint: raw["hint"]?.string ?? "",
                             kind: Kind(rawValue: raw["kind"]?.string ?? "") ?? .text, into: into,
                             required: raw["required"]?.isTrue == true,
                             inEnvironment: into == "env" && raw["inEnvironment"]?.isTrue == true)
    }

    /// The ⓘ beside an env field: kept in your shell, or where a typed value is kept.
    public var keptLabel: String { inEnvironment ? "\(key) is already in your shell" : "Where this is kept" }
    public var keptText: String {
        inEnvironment
            ? "\(key) is exported by your login shell, which is where sessions run, so leaving this blank writes nothing down at all. One thing that comes with that: opening this server from the servers list starts it from this app rather than from a shell, and this app may not carry that variable — so it can report a missing key there while working perfectly in a session."
            : "Typed here, it is written into your Claude Code configuration as \(key)=…, in plain text, in a file that only your account can read. That is where the server reads it from, so there is nowhere better for it to be — encrypting it inside this app would put it somewhere nothing could decrypt it at the moment it is needed."
    }
    /// Whether the field carries that ⓘ at all (not for a path, not for an argument).
    public var showsKept: Bool { kind != .path && into == "env" }
    public var placeholder: String { inEnvironment ? "Leave blank to use \(key) from your shell" : key }
}

public struct McpStoreRow: Equatable, Sendable, Identifiable {
    public enum State: String, Sendable { case available, installed, taken, unavailable }
    public let id: String
    public let name: String
    public let summary: String
    public let category: String
    public let tags: [String]
    public let homepage: String
    public let registry: String
    public let licence: String
    public let version: String
    public let runtime: String
    public let runtimeBinary: String
    public let origin: String
    public let cost: String
    public let costNote: String
    public let command: String
    public let inputs: [McpStoreInput]
    public let state: State
    /// "", "user", "project" or "local".
    public let scope: String
    public let custom: Bool
    public let transport: McpAddTransport
    public let envKeys: [String]
    public let runsWordsRaw: String
    public let runtimeMissing: Bool
    public let taken: String
    public let blocked: String
    public let caveat: String
    public let logo: String

    static func from(_ raw: OrderedJSON) -> McpStoreRow? {
        guard raw.isObject, let id = raw["id"]?.text else { return nil }
        func text(_ key: String) -> String { raw[key]?.string ?? "" }
        func oneOf(_ key: String, _ allowed: [String], _ fallback: String) -> String {
            let value = raw[key]?.string ?? ""
            return allowed.contains(value) ? value : fallback
        }
        let scope = raw["scope"]?.string ?? ""
        return McpStoreRow(
            id: id,
            name: raw["name"]?.text ?? id,
            summary: text("summary"),
            category: oneOf("category", McpStoreCatalog.shelves.map(\.id), "utility"),
            tags: Array((raw["tags"]?.array ?? []).compactMap(\.string).prefix(16)),
            homepage: text("homepage"),
            registry: text("registry"),
            licence: text("licence"),
            version: text("version"),
            runtime: oneOf("runtime", ["node", "python", "docker"], "node"),
            runtimeBinary: text("runtimeBinary"),
            origin: oneOf("origin", ["reference", "reference-archived", "vendor", "hosted", "third-party"], "third-party"),
            cost: oneOf("cost", StoreFront.costOrder, "account"),
            costNote: text("costNote"),
            command: text("command"),
            inputs: (raw["inputs"]?.array ?? []).compactMap(McpStoreInput.from),
            state: State(rawValue: raw["state"]?.string ?? "") ?? .available,
            scope: ["user", "project", "local"].contains(scope) ? scope : "",
            custom: raw["custom"]?.isTrue == true,
            transport: McpAddTransport(rawValue: raw["transport"]?.string ?? "") ?? .stdio,
            envKeys: Array((raw["envKeys"]?.array ?? []).compactMap(\.string).prefix(32)),
            runsWordsRaw: text("runsWords"),
            runtimeMissing: raw["runtimeMissing"]?.isTrue == true,
            taken: text("taken"),
            blocked: text("blocked"),
            caveat: text("caveat"),
            logo: text("logo")
        )
    }

    // MARK: words

    /// `sourceWords`.
    public var sourceWords: String { custom ? "Added by you" : McpStoreCatalog.originWords(origin) }
    /// `runsWords`.
    public var runsWords: String { runsWordsRaw.isEmpty ? McpStoreCatalog.runtimeWords(runtime) : runsWordsRaw }
    /// `COST_LABELS`.
    public var costLabel: String { StoreFront.costWord(cost) ?? "Not known" }

    /// `needsWords`.
    public var needsWords: String {
        let required = inputs.filter(\.required)
        if required.isEmpty { return inputs.isEmpty ? "Nothing" : "Nothing required" }
        return required.map(\.label).joined(separator: ", ")
    }

    /// `unfilled`: required fields still empty and not already in the shell.
    public func unfilled(_ values: [String: String]) -> [String] {
        inputs.filter { $0.required }
            .filter { (values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.inEnvironment }
            .map(\.label)
    }

    /// "Installed" or "Installed · user".
    public var installedWords: String { "Installed" + (scope.isEmpty ? "" : " · \(scope)") }

    /// `hasAction`: Remove on an installed row, Install on one that nothing blocks.
    public var hasAction: Bool { state == .installed || blocked.isEmpty }
    /// `actionVerb`.
    public var removes: Bool { state == .installed }
    /// `actionLabel`.
    public func actionLabel(busy: Bool) -> String { busy ? "Working…" : removes ? "Remove" : "Install" }
    /// Install opens the ask when the row has fields (`asks`).
    public var asks: Bool { hasAction && !removes && !inputs.isEmpty }
    /// The sentence over the ask.
    public var askHead: String {
        inputs.contains(where: \.required)
            ? "\(name) needs \(needsWords). Nothing is written until you press Install."
            : "\(name) requires nothing, and these are what it can be pointed at. Nothing is written until you press Install."
    }
    /// `RANK`: on a shelf, rows that can be installed first.
    public var rank: Double {
        switch state {
        case .available, .installed: return 0
        case .taken: return 1
        case .unavailable: return 2
        }
    }

    /// "Environment": names only, never a value.
    public var envWords: String? {
        guard !envKeys.isEmpty else { return nil }
        let one = envKeys.count == 1
        return "\(envKeys.joined(separator: ", ")) — \(one ? "its value is" : "their values are") in your configuration and \(one ? "is" : "are") not shown here."
    }

    // MARK: storefront

    /// `mcpNeeds`.
    public var needs: [String] {
        var out: [String] = []
        if inputs.contains(where: { $0.required && $0.kind == .secret }) { out.append("token") }
        if inputs.contains(where: { $0.required && $0.kind != .secret }) { out.append("setting") }
        if runtime == "docker" { out.append("docker") }
        return out
    }

    /// `mcpFacets`.
    public var facets: StoreFacets {
        StoreFacets(id: id, name: name, summary: summary, category: category,
                    categoryName: McpStoreCatalog.shelfName(category) ?? category, tags: tags, cost: cost,
                    compat: runtimeMissing ? .cannot : .unknown, installed: state == .installed,
                    source: custom ? McpStoreCatalog.customSource : origin, needs: needs)
    }

    /// `mcpLinkOut`: the project's page, for a row this store cannot install; "" otherwise.
    public var linkOut: String {
        if state == .installed || blocked.isEmpty || custom { return "" }
        let lower = homepage.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") ? homepage : ""
    }
}

public struct McpRuntimeReport: Equatable, Sendable, Identifiable {
    public let id: String
    public let binary: String
    public let found: Bool
    public let path: String
    public let needs: String
}

public struct McpStoreView: Equatable, Sendable {
    public var rows: [McpStoreRow] = []
    public var runtimes: [McpRuntimeReport] = []
    public var writerFound = false
    public var writerPath = ""
    /// "login-shell", "process" or "unavailable".
    public var environmentSource = "unavailable"
    public var projectPath = ""
    public init() {}

    /// `readMcpStoreView`.
    public static func from(_ raw: OrderedJSON) -> McpStoreView {
        var view = McpStoreView()
        guard raw.isObject else { return view }
        view.rows = (raw["rows"]?.array ?? []).compactMap(McpStoreRow.from)
        view.runtimes = (raw["runtimes"]?.array ?? []).compactMap { one in
            guard let id = one["id"]?.string, ["node", "python", "docker"].contains(id) else { return nil }
            return McpRuntimeReport(id: id, binary: one["binary"]?.string ?? "", found: one["found"]?.isTrue == true,
                                    path: one["path"]?.string ?? "", needs: one["needs"]?.string ?? "")
        }
        view.writerFound = raw["writer"]?["found"]?.isTrue == true
        view.writerPath = raw["writer"]?["path"]?.string ?? ""
        let source = raw["environmentSource"]?.string ?? ""
        view.environmentSource = ["login-shell", "process", "unavailable"].contains(source) ? source : "unavailable"
        view.projectPath = raw["projectPath"]?.string ?? ""
        return view
    }

    /// The `environment` line under the runtimes.
    public var environmentWords: String {
        switch environmentSource {
        case "login-shell": return "read from your login shell, by name only — no value ever reaches this app"
        case "process": return "read from this app’s own environment, which on Windows is yours"
        default: return "your login shell could not be asked, so no field claims a value is already there"
        }
    }
}

public enum McpStoreResults {
    /// `readMcpStoreResult`.
    public static func read(_ raw: OrderedJSON) -> McpAddResult {
        guard raw.isObject else { return McpAddResult(ok: false, message: "That did not work.") }
        let ok = raw["ok"]?.isTrue == true
        let message = raw["message"]?.string ?? ""
        return McpAddResult(ok: ok, message: message.isEmpty ? (ok ? "Done." : "That did not work.") : message)
    }

    /// `readMcpImport`: the result, and the draft a file carried when it carried one.
    public static func readImport(_ raw: OrderedJSON) -> (result: McpAddResult, draft: (name: String, transport: McpAddTransport, command: String, url: String, env: [String])?) {
        let result = read(raw)
        guard let draft = raw["draft"], draft.isObject, let name = draft["name"]?.text else { return (result, nil) }
        return (result, (name, McpAddTransport(rawValue: draft["transport"]?.string ?? "") ?? .stdio,
                         draft["command"]?.string ?? "", draft["url"]?.string ?? "",
                         Array((draft["env"]?.array ?? []).compactMap(\.string).prefix(32))))
    }
}

/// `StoreBody`'s arithmetic: what the filter keeps, and where each kept row goes.
public struct McpStoreShelving {
    public let kept: [McpStoreRow]
    public let own: [McpStoreRow]
    public let installed: [McpStoreRow]
    public let shelves: [StoreShelf<McpStoreRow>]
    public let ownTotal: Int
    public let controls: [FacetControl]
    public let filtering: Bool

    public init(rows: [McpStoreRow], filter: StoreFilter) {
        let facets = rows.map(\.facets)
        kept = rows.filter { StoreRules.matches($0.facets, filter) }
        own = kept.filter(\.custom)
        installed = kept.filter { $0.state == .installed && !$0.custom }
        let browsing = kept.filter { $0.state != .installed }
        ownTotal = rows.filter(\.custom).count
        shelves = StoreRules.shelve(browsing, order: McpStoreCatalog.shelves, facetsOf: \.facets, rank: \.rank)
        controls = StoreRules.facetControls(facets, filter, StoreRules.withoutShelf(McpStoreCatalog.vocabularies))
        filtering = filter.active
    }

    /// Under the "Added by you" shelf, when the filter hides every one of yours.
    public var ownHidden: String? {
        guard own.isEmpty, ownTotal > 0 else { return nil }
        return ownTotal == 1 ? "The one you added does not match that." : "None of the \(ownTotal) you added match that."
    }

    /// Where the shelves would be, when there are none.
    public var emptyWords: String? {
        guard shelves.isEmpty else { return nil }
        if kept.isEmpty { return filtering ? "Nothing in the catalogue matches that." : "There is nothing in the catalogue to browse." }
        return filtering
            ? "Everything that matches is already in your configuration — it is above."
            : "Everything in the catalogue is already in your configuration."
    }
}

