import Foundation

// The Store's "Browser extensions" department — the readers and words of
// `browser/extensions-bridge.ts`, `browser/store-bridge.ts`, `ExtensionRow.tsx`,
// `ToolRow.tsx` and `StorePanel.tsx` (the shelves and the empty lines). The
// storefront (filter, facets, shelving, filter bar, detail page) is lane A's.
// Tests: BrowserStoreTests.swift mirrors extensions-bridge.test.ts and store-bridge.test.ts.

public struct BrowserStoreExtension: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var homepage: String
    public var licence: String
    public var version: String
    /// works, partly, no or unmeasured.
    public var works: String
    public var category: String
    public var tags: [String]
    public var needs: [String]
    /// free, account, metered, paid or unknown.
    public var cost: String
    public var costNote: String
    public var measured: String
    public var logo: String
    public var url: String
    public var sha256: String
    public var bytes: Int
    /// available, installed or damaged.
    public var state: String
    public var enabled: Bool
    public var reach: [String]
    public var mayAsk: [String]
    public var everywhere: Bool
    public var missing: [String]
    public var provides: [String]
    public var inert: [String]
    public var rulesetsSwitchedOn: Int
    public var popup: String
    public var optionsPage: String
    public var sideloaded: Bool
    public var origin: String
    public var crxId: String
    public var staticRulesets: Bool
    public var message: String

    public var isInstalled: Bool { state == "installed" }
    public var hasIt: Bool { state == "installed" || state == "damaged" }
}

public struct BrowserStoreExtensionsView: Equatable, Sendable {
    public var profileId = ""
    public var profileName = ""
    public var extensions: [BrowserStoreExtension] = []
    public var folder = ""
    public var orphans: [String] = []
    public var profiles: [(id: String, name: String)] = []
    public var limits: [String] = []

    public init() {}

    public static func == (a: BrowserStoreExtensionsView, b: BrowserStoreExtensionsView) -> Bool {
        a.profileId == b.profileId && a.profileName == b.profileName && a.extensions == b.extensions && a.folder == b.folder
            && a.orphans == b.orphans && a.profiles.map(\.id) == b.profiles.map(\.id) && a.limits == b.limits
    }
}

public struct BrowserStoreTool: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var homepage: String
    public var licence: String
    public var version: String
    public var grants: [String]
    public var origins: [String]
    public var url: String
    public var fetched: Bool
    public var sha256: String
    /// available, installed, damaged or outdated.
    public var state: String
    public var message: String
    public var reads: [String]
}

public struct BrowserStoreToolsView: Equatable, Sendable {
    public var tools: [BrowserStoreTool] = []
    public var folder = ""
    public var orphans: [String] = []
    public init() {}
}

public enum BrowserStore {
    public static let categoryOrder = ["blocking", "privacy", "appearance", "media", "scripting", "your-own"]
    public static let categoryNames: [String: String] = [
        "blocking": "Blocking ads and trackers",
        "privacy": "Privacy and cleaning up",
        "appearance": "How pages look",
        "media": "Video and audio",
        "scripting": "Scripting and the keyboard",
        "your-own": "Added by you",
    ]
    public static let builtInShelf = "built-in"
    public static let builtInName = "Built into this app"
    /// The department's shelves, in order (`BROWSER_SHELVES`).
    public static var shelves: [(id: String, name: String)] {
        categoryOrder.map { ($0, categoryNames[$0]!) } + [(builtInShelf, builtInName)]
    }
    public static let costWords: [String: String] = [
        "free": "Free", "account": "Free, needs an account", "metered": "Free to a limit, then paid",
        "paid": "Paid", "unknown": "Not known",
    ]

    static func words(_ raw: CodingAIJSON, _ limit: Int) -> [String] {
        Array((raw.array ?? []).compactMap(\.string).prefix(limit))
    }

    static func count(_ raw: CodingAIJSON) -> Int {
        guard let number = raw.number, number.isFinite, number >= 0, raw.bool == nil else { return 0 }
        return Int(number)
    }

    // MARK: Readers

    static func extensionRow(_ raw: CodingAIJSON) -> BrowserStoreExtension? {
        guard raw.isObject, let id = raw["id"].string, !id.isEmpty else { return nil }
        let works = raw["works"].string ?? ""
        let category = raw["category"].string ?? ""
        let cost = raw["cost"].string ?? ""
        let state = raw["state"].string ?? ""
        let name = raw["name"].string ?? ""
        return BrowserStoreExtension(
            id: id, name: name.isEmpty ? id : name, summary: raw["summary"].string ?? "",
            homepage: raw["homepage"].string ?? "", licence: raw["licence"].string ?? "", version: raw["version"].string ?? "",
            works: ["works", "partly", "unmeasured"].contains(works) ? works : "no",
            category: categoryOrder.contains(category) ? category : "scripting",
            tags: words(raw["tags"], 16),
            needs: words(raw["needs"], 4).filter { $0 == "account" || $0 == "companion-app" },
            cost: costWords[cost] != nil ? cost : "unknown",
            costNote: raw["costNote"].string ?? "", measured: raw["measured"].string ?? "", logo: raw["logo"].string ?? "",
            url: raw["url"].string ?? "", sha256: raw["sha256"].string ?? "", bytes: count(raw["bytes"]),
            state: state == "installed" || state == "damaged" ? state : "available",
            enabled: raw["enabled"].isTrue, reach: words(raw["reach"], 40), mayAsk: words(raw["mayAsk"], 12),
            everywhere: raw["everywhere"].isTrue, missing: words(raw["missing"], 24), provides: words(raw["provides"], 24),
            inert: words(raw["inert"], 12), rulesetsSwitchedOn: count(raw["rulesetsSwitchedOn"]),
            popup: raw["popup"].string ?? "", optionsPage: raw["optionsPage"].string ?? "", sideloaded: raw["sideloaded"].isTrue,
            origin: raw["origin"].string ?? "", crxId: raw["crxId"].string ?? "", staticRulesets: raw["staticRulesets"].isTrue,
            message: raw["message"].string ?? "")
    }

    /// `readExtensionsView` (`browser-extension:list`).
    public static func extensions(_ raw: CodingAIJSON) -> BrowserStoreExtensionsView {
        var view = BrowserStoreExtensionsView()
        guard raw.isObject else { return view }
        let inner = raw["view"]
        view.profileId = inner["profileId"].string ?? ""
        view.profileName = inner["profileName"].string ?? ""
        view.extensions = (inner["extensions"].array ?? []).compactMap(extensionRow)
        view.folder = inner["folder"].string ?? ""
        view.orphans = words(raw["orphans"], 40)
        view.profiles = (raw["profiles"].array ?? []).compactMap { one in
            guard let id = one["id"].string, !id.isEmpty else { return nil }
            let name = one["name"].string ?? ""
            return (id, name.isEmpty ? id : name)
        }
        view.limits = words(raw["limits"], 12)
        return view
    }

    /// `readStoreView` (`browser-store:list`).
    public static func tools(_ raw: CodingAIJSON) -> BrowserStoreToolsView {
        var view = BrowserStoreToolsView()
        guard raw.isObject else { return view }
        view.tools = (raw["view"]["tools"].array ?? []).compactMap { tool in
            guard let id = tool["id"].string, !id.isEmpty else { return nil }
            let state = tool["state"].string ?? ""
            let name = tool["name"].string ?? ""
            return BrowserStoreTool(id: id, name: name.isEmpty ? id : name, summary: tool["summary"].string ?? "",
                                    homepage: tool["homepage"].string ?? "", licence: tool["licence"].string ?? "",
                                    version: tool["version"].string ?? "", grants: words(tool["grants"], 8),
                                    origins: words(tool["origins"], 40), url: tool["url"].string ?? "",
                                    fetched: tool["fetched"].isTrue, sha256: tool["sha256"].string ?? "",
                                    state: ["installed", "damaged", "outdated"].contains(state) ? state : "available",
                                    message: tool["message"].string ?? "", reads: words(tool["reads"], 24))
        }
        view.folder = raw["view"]["folder"].string ?? ""
        view.orphans = words(raw["orphans"], 40)
        return view
    }

    /// `readExtensionResult` / `readStoreResult`.
    public static func result(_ raw: CodingAIJSON) -> (ok: Bool, message: String) {
        guard raw.isObject else { return (false, "The app did not answer.") }
        return (raw["ok"].isTrue, raw["message"].string ?? "")
    }

    // MARK: Words on a row

    public static func reachWords(_ reach: [String], everywhere: Bool) -> String {
        if everywhere { return "every page you open in this profile" }
        if reach.isEmpty { return "no pages of its own" }
        return reach.joined(separator: ", ")
    }

    public static func extensionVerb(_ ext: BrowserStoreExtension) -> String { ext.hasIt ? "remove" : "install" }

    public static func extensionActionLabel(_ ext: BrowserStoreExtension, busy: Bool) -> String {
        busy ? "Working…" : ext.hasIt ? "Remove" : "Install"
    }

    public static func toolVerb(_ tool: BrowserStoreTool) -> String {
        tool.state == "installed" || tool.state == "damaged" ? "remove" : "install"
    }

    public static func toolActionLabel(_ tool: BrowserStoreTool, busy: Bool) -> String {
        if busy { return "Working…" }
        if tool.state == "installed" || tool.state == "damaged" { return "Remove" }
        return tool.fetched ? "Download" : "Install"
    }

    public static func originWords(_ origins: [String]) -> String {
        if origins.isEmpty { return "nowhere" }
        if origins.contains("*") { return "any page" }
        return origins.joined(separator: ", ")
    }

    /// The bold half of a tool's line: its grants as sentences, or "Reads nothing".
    public static func grantWords(_ grants: [String]) -> String {
        let text = grants.map { $0 == "page-read" ? "Reads the page you point it at" : $0 }.joined(separator: ". ")
        return text.isEmpty ? "Reads nothing" : text
    }

    public static func bytesExactly(_ bytes: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        return " — \(formatter.string(from: NSNumber(value: bytes)) ?? String(bytes)) bytes, exactly"
    }

    /// `extensionCompat`: works / unknown / cannot.
    public static func compat(_ ext: BrowserStoreExtension) -> String {
        ext.works == "works" ? "works" : ext.works == "no" ? "cannot" : "unknown"
    }

    /// `extensionSource`.
    public static func source(_ ext: BrowserStoreExtension) -> String { ext.sideloaded ? "your-own" : "release" }

    /// The line where the shelves would be when there are none (`StoreBody`).
    public static func emptyShelvesLine(kept: Int, filtering: Bool) -> String {
        if kept == 0 { return filtering ? "Nothing in the store matches that." : "There is nothing in the store to browse." }
        return filtering ? "Everything that matches is already installed in this profile — it is above."
            : "Everything this app can install is already installed in this profile."
    }

    public static func limitsSummary(_ count: Int) -> String {
        "What an extension can and cannot do in this browser — \(count) things, every one of them measured by running something here."
    }
}

// MARK: - On lane A's storefront (StoreModel.swift)

extension BrowserStore {
    /// `extensionFacets`.
    public static func facets(_ ext: BrowserStoreExtension) -> StoreFacets {
        StoreFacets(id: ext.id, name: ext.name, summary: ext.summary, category: ext.category,
                    categoryName: categoryNames[ext.category] ?? ext.category, tags: ext.tags, cost: ext.cost,
                    compat: StoreCompat(rawValue: compat(ext)) ?? .unknown, installed: ext.hasIt,
                    source: source(ext), needs: ext.needs)
    }

    /// `builtInFacets`.
    public static func facets(_ tool: BrowserStoreTool) -> StoreFacets {
        StoreFacets(id: tool.id, name: tool.name, summary: tool.summary, category: builtInShelf, categoryName: builtInName,
                    tags: [], cost: "free", compat: .works, installed: tool.state == "installed", source: builtInShelf, needs: [])
    }

    /// `EXTENSION_FACETS`: what the filter bar offers for this department.
    public static let facetVocabularies: [StoreFacet: FacetVocabulary] = [
        .category: FacetVocabulary(label: "Category", anyName: "Everything",
                                   options: categoryOrder.map { ($0, categoryNames[$0]!) }),
        .cost: FacetVocabulary(label: "What it costs", anyName: "Any price",
                               options: StoreFront.costOrder.map { ($0, StoreFront.costWord($0) ?? $0) }),
        .compat: FacetVocabulary(label: "In this browser", anyName: "Any",
                                 options: [("works", "Works here"), ("unknown", "Not measured"), ("cannot", "Cannot work here")]),
        .installed: FacetVocabulary(label: "Installed", anyName: "Any", options: [("yes", "Installed"), ("no", "Not installed")]),
        .source: FacetVocabulary(label: "Where it comes from", anyName: "Anywhere",
                                 options: [("release", "The project’s own releases"), ("your-own", "Added by you")]),
        .needs: FacetVocabulary(label: "What it needs", anyName: "Any",
                                options: [(StoreFront.needsNothing, "Nothing"), ("account", "An account"), ("companion-app", "Another app running here")]),
    ]

    /// The department is drawn when the browser feature is on (both bridges always exist here).
    public static func wired(featureState: String?) -> Bool {
        SettingsFeatures.isOn("browser", state: featureState)
    }

    /// The built-in tools a filter keeps: only on the built-in shelf or Everything, by the query; installed ones first.
    public static func builtIn(_ tools: [BrowserStoreTool], filter: StoreFilter) -> [BrowserStoreTool] {
        tools.enumerated()
            .filter { (filter.category == StoreFront.any || filter.category == builtInShelf) && StoreRules.matchesQuery(facets($0.element), filter.query) }
            .sorted { a, b in
                let ai = a.element.state != "available", bi = b.element.state != "available"
                return ai != bi ? ai : a.offset < b.offset
            }
            .map(\.element)
    }
}
