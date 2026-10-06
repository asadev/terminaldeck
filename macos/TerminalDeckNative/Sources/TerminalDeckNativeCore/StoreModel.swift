import Foundation

// The Store: src/renderer/store/storefront.ts (facets, filter, chips, shelves),
// store-nav.ts (departments, the rail, the empty page), StoreLogo's monogram, and
// community/bridge.ts + its row and sheet words — ported one for one. Shared by the
// three departments: Browser extensions (lane B), MCP servers (lane E2), Community.

// MARK: - storefront.ts

public enum StoreFront {
    public static let any = "all"
    public static let needsNothing = "nothing"

    public static let costOrder = ["free", "account", "metered", "paid", "unknown"]
    public static func costWord(_ cost: String) -> String? {
        ["free": "Free", "account": "Free, needs an account", "metered": "Free to a limit, then paid",
         "paid": "Paid", "unknown": "Not known"][cost]
    }
}

public enum StoreCompat: String, Equatable, Sendable { case works, unknown, cannot }

public enum StoreFacet: String, Equatable, Sendable, CaseIterable {
    case category, cost, compat, installed, source, needs
}

public struct StoreFacets: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var category: String
    public var categoryName: String
    public var tags: [String]
    public var cost: String
    public var compat: StoreCompat
    public var installed: Bool
    public var source: String
    public var needs: [String]
    public init(id: String, name: String, summary: String = "", category: String, categoryName: String = "", tags: [String] = [],
                cost: String = "unknown", compat: StoreCompat = .unknown, installed: Bool = false, source: String = "", needs: [String] = []) {
        self.id = id; self.name = name; self.summary = summary; self.category = category; self.categoryName = categoryName
        self.tags = tags; self.cost = cost; self.compat = compat; self.installed = installed; self.source = source; self.needs = needs
    }
}

public struct StoreFilter: Equatable, Sendable {
    public var query: String
    public var category: String
    public var cost: String
    /// "works" / "unknown" / "cannot", or `StoreFront.any`.
    public var compat: String
    /// "yes" / "no", or `StoreFront.any`.
    public var installed: String
    public var source: String
    public var needs: String
    public init(query: String = "", category: String = StoreFront.any, cost: String = StoreFront.any, compat: String = StoreFront.any,
                installed: String = StoreFront.any, source: String = StoreFront.any, needs: String = StoreFront.any) {
        self.query = query; self.category = category; self.cost = cost; self.compat = compat
        self.installed = installed; self.source = source; self.needs = needs
    }
    /// `NO_FILTER`.
    public static let none = StoreFilter()

    public func value(_ facet: StoreFacet) -> String {
        switch facet {
        case .category: return category
        case .cost: return cost
        case .compat: return compat
        case .installed: return installed
        case .source: return source
        case .needs: return needs
        }
    }

    public func with(_ facet: StoreFacet, _ value: String) -> StoreFilter {
        var next = self
        switch facet {
        case .category: next.category = value
        case .cost: next.cost = value
        case .compat: next.compat = value
        case .installed: next.installed = value
        case .source: next.source = value
        case .needs: next.needs = value
        }
        return next
    }

    /// `filtering`: a search or any chip is on.
    public var active: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || StoreFacet.allCases.contains { value($0) != StoreFront.any }
    }
}

public struct FacetVocabulary: Equatable, Sendable {
    public var label: String
    public var anyName: String
    public var options: [(id: String, name: String)]
    public init(label: String, anyName: String, options: [(id: String, name: String)]) {
        self.label = label; self.anyName = anyName; self.options = options
    }
    public static func == (a: FacetVocabulary, b: FacetVocabulary) -> Bool {
        a.label == b.label && a.anyName == b.anyName && a.options.map(\.id) == b.options.map(\.id) && a.options.map(\.name) == b.options.map(\.name)
    }
}

public struct StoreOption: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var count: Int
}

public struct FacetControl: Equatable, Sendable, Identifiable {
    public var facet: StoreFacet
    public var label: String
    public var anyName: String
    public var total: Int
    public var options: [StoreOption]
    public var value: String
    public var id: String { facet.rawValue }
}

public struct StoreShelf<Row>: Identifiable {
    public var id: String
    public var name: String
    public var rows: [Row]
}

public enum StoreRules {
    static let facets: [StoreFacet] = StoreFacet.allCases

    private static func haystack(_ f: StoreFacets) -> String {
        ([f.name, f.summary, f.categoryName] + f.tags).joined(separator: " ").lowercased()
    }

    private static func squash(_ text: String) -> String {
        String(text.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init))
    }

    public static func matchesQuery(_ facets: StoreFacets, _ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty { return true }
        let plain = haystack(facets)
        let tight = squash(plain)
        return needle.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            let w = String(word)
            return plain.contains(w) || (!squash(w).isEmpty && tight.contains(squash(w)))
        }
    }

    public static func matchesFacet(_ f: StoreFacets, _ filter: StoreFilter, _ facet: StoreFacet) -> Bool {
        let any = StoreFront.any
        switch facet {
        case .category: return filter.category == any || f.category == filter.category
        case .cost: return filter.cost == any || f.cost == filter.cost
        case .compat: return filter.compat == any || f.compat.rawValue == filter.compat
        case .installed: return filter.installed == any || f.installed == (filter.installed == "yes")
        case .source: return filter.source == any || f.source == filter.source
        case .needs:
            if filter.needs == any { return true }
            return filter.needs == StoreFront.needsNothing ? f.needs.isEmpty : f.needs.contains(filter.needs)
        }
    }

    public static func matches(_ f: StoreFacets, _ filter: StoreFilter) -> Bool {
        matchesQuery(f, filter.query) && facets.allSatisfy { matchesFacet(f, filter, $0) }
    }

    public static func facetControl(_ rows: [StoreFacets], _ filter: StoreFilter, _ facet: StoreFacet, _ vocabulary: FacetVocabulary) -> FacetControl? {
        let visible = rows.filter { row in
            matchesQuery(row, filter.query) && facets.allSatisfy { $0 == facet || matchesFacet(row, filter, $0) }
        }
        let chosen = filter.value(facet)
        let counted = vocabulary.options.filter { $0.id != StoreFront.any }.map { option in
            StoreOption(id: option.id, name: option.name,
                        count: visible.filter { matchesFacet($0, filter.with(facet, option.id), facet) }.count)
        }
        let options = counted.filter { $0.count > 0 || $0.id == chosen }
        if options.count < 2 { return nil }
        return FacetControl(facet: facet, label: vocabulary.label, anyName: vocabulary.anyName, total: visible.count, options: options, value: chosen)
    }

    public static func facetControls(_ rows: [StoreFacets], _ filter: StoreFilter, _ vocabularies: [StoreFacet: FacetVocabulary]) -> [FacetControl] {
        facets.compactMap { facet in vocabularies[facet].flatMap { facetControl(rows, filter, facet, $0) } }
    }

    /// `withoutShelf`: the department's vocabularies less the category one (the rail is the shelf picker).
    public static func withoutShelf(_ vocabularies: [StoreFacet: FacetVocabulary]) -> [StoreFacet: FacetVocabulary] {
        vocabularies.filter { $0.key != .category }
    }

    public static func shelve<Row>(_ rows: [Row], order: [(id: String, name: String)], facetsOf: (Row) -> StoreFacets,
                                   rank: (Row) -> Double) -> [StoreShelf<Row>] {
        order.compactMap { shelf in
            let kept = rows.enumerated().filter { facetsOf($0.element).category == shelf.id }
                .sorted { rank($0.element) != rank($1.element) ? rank($0.element) < rank($1.element) : $0.offset < $1.offset }
                .map(\.element)
            return kept.isEmpty ? nil : StoreShelf(id: shelf.id, name: shelf.name, rows: kept)
        }
    }
}

// MARK: - store-nav.ts

public enum StoreDepartmentId: String, Equatable, Sendable, CaseIterable { case extensions, servers, community }

public struct StoreDepartmentInput: Sendable {
    public var id: StoreDepartmentId
    public var name: String
    public var wired: Bool
    public var shelves: [(id: String, name: String)]
    public var rows: [StoreFacets]
    public var filter: StoreFilter
    public init(id: StoreDepartmentId, name: String, wired: Bool, shelves: [(id: String, name: String)], rows: [StoreFacets], filter: StoreFilter) {
        self.id = id; self.name = name; self.wired = wired; self.shelves = shelves; self.rows = rows; self.filter = filter
    }
}

public struct StoreNavShelf: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var count: Int
}

public struct StoreNavDepartment: Equatable, Sendable, Identifiable {
    public var id: StoreDepartmentId
    public var name: String
    public var count: Int
    public var shelves: [StoreNavShelf]
}

public enum StorePlace: Equatable, Sendable {
    case all
    case department(StoreDepartmentId)
    case shelf(StoreDepartmentId, String)

    public var department: StoreDepartmentId? {
        switch self {
        case .all: return nil
        case .department(let d), .shelf(let d, _): return d
        }
    }
}

public struct StoreEmpty: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var elsewhere: Int
}

public enum StoreNav {
    public static func shows(_ place: StorePlace, _ id: StoreDepartmentId) -> Bool { place.department == nil || place.department == id }

    public static func filterFor(_ place: StorePlace, _ department: StoreDepartmentInput) -> StoreFilter {
        if case .shelf(let d, let shelf) = place, d == department.id { return department.filter.with(.category, shelf) }
        return department.filter.with(.category, StoreFront.any)
    }

    private static func counting(_ department: StoreDepartmentInput) -> StoreFilter { department.filter.with(.category, StoreFront.any) }

    public static func nav(_ departments: [StoreDepartmentInput], _ place: StorePlace = .all) -> [StoreNavDepartment] {
        departments.filter(\.wired).map { department in
            let kept = department.rows.filter { StoreRules.matches($0, counting(department)) }
            var standing = ""
            if case .shelf(let d, let shelf) = place, d == department.id { standing = shelf }
            return StoreNavDepartment(
                id: department.id, name: department.name, count: kept.count,
                shelves: department.shelves.map { shelf in
                    StoreNavShelf(id: shelf.id, name: shelf.name, count: kept.filter { $0.category == shelf.id }.count)
                }.filter { $0.count > 0 || $0.id == standing })
        }
    }

    public static func total(_ nav: [StoreNavDepartment]) -> Int { nav.reduce(0) { $0 + $1.count } }

    public static func shown(_ departments: [StoreDepartmentInput], _ place: StorePlace) -> Int {
        departments.filter { $0.wired && shows(place, $0.id) }.reduce(0) { sum, department in
            sum + department.rows.filter { StoreRules.matches($0, filterFor(place, department)) }.count
        }
    }

    public static func empty(_ departments: [StoreDepartmentInput], _ place: StorePlace) -> StoreEmpty? {
        let wired = departments.filter(\.wired)
        if wired.isEmpty {
            return StoreEmpty(title: "Nothing to browse in this build",
                              detail: "None of the store’s departments is available here — the browser pane, MCP servers and the community catalogue are what stock it, and this window has none of them.",
                              elsewhere: 0)
        }
        if shown(wired, place) > 0 { return nil }
        let everywhere = wired.reduce(0) { sum, d in sum + d.rows.filter { StoreRules.matches($0, counting(d)) }.count }
        let stock = wired.reduce(0) { $0 + $1.rows.count }
        let query = (wired.first?.filter.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let elsewhere = "\(everywhere) \(everywhere == 1 ? "thing" : "things") elsewhere in the store \(everywhere == 1 ? "does" : "do"). The rail on the left says where."
        if case .shelf = place, everywhere > 0 {
            return StoreEmpty(title: query.isEmpty ? "Nothing on this shelf" : "Nothing here matches that", detail: elsewhere, elsewhere: everywhere)
        }
        if case .department = place, everywhere > 0 {
            return StoreEmpty(title: "Nothing in this department matches that", detail: elsewhere, elsewhere: everywhere)
        }
        return StoreEmpty(
            title: query.isEmpty ? "Nothing in the store" : "Nothing in the store matches that",
            detail: stock == 0 ? "The catalogues came back empty, which is not something you can fix from here."
                : "Searched all \(stock) of them, across \(wired.count == 1 ? "one department" : "all \(wired.count) departments").",
            elsewhere: 0)
    }

    /// `departmentOfRow`: which department a detail key belongs to.
    public static func departmentOfRow(_ key: String) -> StoreDepartmentId? {
        if key.hasPrefix("e:") || key.hasPrefix("t:") { return .extensions }
        if key.hasPrefix("m:") { return .servers }
        if key.hasPrefix("c:") { return .community }
        return nil
    }
}

// MARK: - StoreLogo

public enum StoreLogoRules {
    public static let monogramFills = 4

    public static func monogramFill(_ id: String) -> Int {
        (id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % monogramFills) + 1
    }

    public static func monogram(_ name: String) -> String {
        for scalar in name.unicodeScalars where CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
            return String(scalar).uppercased()
        }
        return "?"
    }

    /// The bytes of a logo's data URL (base64 PNG or URL-encoded SVG).
    public static func imageData(_ src: String) -> Data? {
        guard src.hasPrefix("data:"), let comma = src.firstIndex(of: ",") else { return nil }
        let head = src[src.startIndex..<comma]
        let body = String(src[src.index(after: comma)...])
        if head.hasSuffix(";base64") { return Data(base64Encoded: body) }
        return body.removingPercentEncoding?.data(using: .utf8)
    }
}

// MARK: - Community (community/bridge.ts, CommunityRow, InstallSheet)

public struct CommunityAgent: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var found: Bool
    public var note: String
}

public struct CommunityItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var publisher: String
    public var handle: String
    public var profileUrl: String
    public var kind: String
    public var name: String
    public var summary: String
    public var version: String
    public var licence: String
    public var tags: [String]
    public var agents: [String]
    public var tier: Int
    public var needs: [String]
    public var missing: [String]
    public var cost: String
    public var costNote: String
    public var offSite: Bool
    public var offsiteUrl: String
    public var repo: String
    public var commit: String
    public var artifactUrl: String
    public var sha256: String
    public var bytes: Double
    public var network: [String]
    public var updatedAt: String
    public var stars: Double
    public var openIssues: Double
    public var ratingScore: Double
    public var ratingCount: Double
    public var state: String
    public var installedVersion: String
    public var message: String
    public var reason: String
    public var lands: [String]
    public var command: String
    public var variables: [String]
    public var trigger: String
    public var reach: [String]
    public var logo: String
}

public struct CommunityView: Equatable, Sendable {
    public var kept: Bool
    public var at: String
    public var stale: String
    public var because: String
    public var problem: String
    public var items: [CommunityItem]
    public var folder: String
    public var agents: [CommunityAgent]
    public static let none = CommunityView(kept: false, at: "", stale: "", because: "", problem: "", items: [], folder: "", agents: [])
}

public enum CommunityRules {
    public static let listChannel = "community:list"
    public static let installChannel = "community:install"
    public static let removeChannel = "community:remove"

    public static let kinds = ["skill", "instructions", "hooks", "mcp", "extension", "routine", "tool"]
    public static let agentIds = ["claude", "codex", "gemini"]
    public static let source = "community"

    public static func kindName(_ kind: String) -> String {
        ["skill": "Skill", "instructions": "Instructions", "hooks": "Hooks", "mcp": "MCP server",
         "extension": "Browser extension", "routine": "Routine", "tool": "Open-source tool"][kind] ?? kind
    }

    public static func tierWord(_ tier: Int) -> String {
        [1: "Text only — nothing runs", 2: "Ships scripts the agent may run", 3: "Runs a program on this machine"][tier] ?? ""
    }

    public static func tierNote(_ tier: Int) -> String {
        [1: "Nothing in it is a program. The files sit on your disk and an agent reads them when it needs them. This app never runs any of it.",
         2: "It ships scripts. This app does not run them; your agent may, during a session, as you, with everything you can reach.",
         3: "It starts a program on this machine when a session begins. That program runs as you, with everything you can reach, and it keeps running until the session ends."][tier] ?? ""
    }

    public static func needWord(_ need: String) -> String {
        ["runs-scripts": "Runs scripts on this machine", "node": "Needs Node.js", "python": "Needs Python",
         "api-key": "Needs a key you supply", "account": "Needs an account somewhere", "local-app": "Needs another app installed"][need] ?? need
    }

    public static func agentLabel(_ id: String) -> String {
        ["claude": "Claude Code", "codex": "Codex CLI", "gemini": "Gemini CLI"][id] ?? id
    }

    public static var shelves: [(id: String, name: String)] { kinds.map { ($0, kindName($0)) } }

    public static var vocabularies: [StoreFacet: FacetVocabulary] {
        [
            .category: FacetVocabulary(label: "Kind", anyName: "Everything", options: shelves),
            .cost: FacetVocabulary(label: "What it costs", anyName: "Any price", options: StoreFront.costOrder.map { ($0, StoreFront.costWord($0) ?? $0) }),
            .compat: FacetVocabulary(label: "On this machine", anyName: "Any", options: [("unknown", "Nothing missing"), ("cannot", "Needs something you do not have")]),
            .installed: FacetVocabulary(label: "Installed", anyName: "Any", options: [("yes", "On this machine"), ("no", "Not installed")]),
            .needs: FacetVocabulary(label: "What it needs", anyName: "Any", options: [
                (StoreFront.needsNothing, "Nothing"), ("runs-scripts", "To run scripts"), ("node", "Node"), ("python", "Python"),
                ("api-key", "A key or token"), ("account", "An account somewhere"), ("local-app", "Another program"),
            ]),
        ]
    }

    private static func text(_ raw: Any?) -> String { raw as? String ?? "" }
    private static func number(_ raw: Any?, _ floor: Double = 0) -> Double {
        guard let n = raw as? NSNumber, !(raw is Bool), n.doubleValue.isFinite else { return floor }
        return n.doubleValue
    }
    private static func words(_ raw: Any?, _ limit: Int) -> [String] { Array(((raw as? [Any]) ?? []).compactMap { $0 as? String }.prefix(limit)) }

    static func item(_ raw: Any?) -> CommunityItem? {
        guard let r = raw as? [String: Any] else { return nil }
        let id = text(r["id"])
        let kind = text(r["kind"])
        guard !id.isEmpty, kinds.contains(kind) else { return nil }
        let publisher = text(r["publisher"])
        let handle = text(r["handle"])
        let tierRaw = r["tier"] as? NSNumber
        let tier = tierRaw.map { [1, 2, 3].contains($0.intValue) && Double($0.intValue) == $0.doubleValue ? $0.intValue : 3 } ?? 3
        let states = ["available", "installed", "outdated", "damaged", "withdrawn", "unsupported"]
        let state = text(r["state"])
        let cost = text(r["cost"])
        return CommunityItem(
            id: id, publisher: publisher, handle: handle.isEmpty ? publisher : handle, profileUrl: text(r["profileUrl"]),
            kind: kind, name: text(r["name"]).isEmpty ? id : text(r["name"]), summary: text(r["summary"]), version: text(r["version"]),
            licence: text(r["licence"]), tags: words(r["tags"], 16), agents: words(r["agents"], 99).filter(agentIds.contains), tier: tier,
            needs: words(r["needs"], 12), missing: words(r["missing"], 12), cost: StoreFront.costOrder.contains(cost) ? cost : "unknown",
            costNote: text(r["costNote"]), offSite: text(r["delivery"]) == "off-site", offsiteUrl: text(r["offsiteUrl"]),
            repo: text(r["repo"]), commit: text(r["commit"]), artifactUrl: text(r["artifactUrl"]), sha256: text(r["sha256"]),
            bytes: number(r["bytes"]), network: words(r["network"], 40), updatedAt: text(r["updatedAt"]),
            stars: number(r["stars"], -1), openIssues: number(r["openIssues"], -1), ratingScore: number(r["ratingScore"]),
            ratingCount: number(r["ratingCount"]), state: states.contains(state) ? state : "available",
            installedVersion: text(r["installedVersion"]), message: text(r["message"]), reason: text(r["reason"]),
            lands: words(r["lands"], 24), command: text(r["command"]), variables: words(r["variables"], 24),
            trigger: text(r["trigger"]), reach: words(r["reach"], 40), logo: text(r["logo"]))
    }

    public static func view(_ raw: Any?) -> CommunityView {
        guard let r = raw as? [String: Any] else { return .none }
        return CommunityView(
            kept: text(r["from"]) == "kept", at: text(r["at"]), stale: text(r["stale"]), because: text(r["because"]),
            problem: text(r["problem"]), items: ((r["items"] as? [Any]) ?? []).compactMap(item), folder: text(r["folder"]),
            agents: ((r["agents"] as? [Any]) ?? []).compactMap { raw in
                guard let a = raw as? [String: Any], let id = a["id"] as? String, agentIds.contains(id) else { return nil }
                return CommunityAgent(id: id, name: text(a["name"]).isEmpty ? id : text(a["name"]), found: (a["found"] as? Bool) == true, note: text(a["note"]))
            })
    }

    public static func result(_ raw: Any?) -> (ok: Bool, message: String) {
        guard let r = raw as? [String: Any] else { return (false, "The app did not answer.") }
        return ((r["ok"] as? Bool) == true, text(r["message"]))
    }

    public static func facets(_ item: CommunityItem) -> StoreFacets {
        let runtime: Set<String> = ["node", "python", "local-app", "runs-scripts"]
        return StoreFacets(id: item.id, name: item.name, summary: item.summary, category: item.kind, categoryName: kindName(item.kind),
                           tags: item.tags + [item.handle, item.publisher], cost: item.cost,
                           compat: item.missing.contains(where: runtime.contains) ? .cannot : .unknown,
                           installed: !item.installedVersion.isEmpty, source: source, needs: item.needs)
    }

    public static func domainOf(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// "5 October" — when a kept catalogue was fetched.
    public static func catalogueDate(_ iso: String) -> String {
        guard let ms = StaysFixedRules.parse(iso) else { return "" }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: Locale(identifier: "en_GB")).day().month(.wide)
        style.timeZone = .current
        return Date(timeIntervalSince1970: ms / 1000).formatted(style)
    }

    public static func ratingChip(_ item: CommunityItem) -> String {
        if item.cost == "paid" || item.ratingCount < 5 { return "" }
        return "Rated \(String(format: "%.1f", item.ratingScore)) · \(Int(item.ratingCount))"
    }

    public static func installable(_ item: CommunityItem) -> Bool { !item.offSite && item.state != "unsupported" }

    public enum RowAction: Equatable, Sendable { case install, update, remove }

    public static func rowAction(_ item: CommunityItem) -> RowAction? {
        if !installable(item) { return nil }
        if item.state == "outdated" { return .update }
        if !item.installedVersion.isEmpty { return .remove }
        return .install
    }

    public static func updatedWords(_ iso: String, now: Double) -> String {
        guard let at = StaysFixedRules.parse(iso), at <= now else { return "" }
        let days = Int(((now - at) / 86_400_000).rounded(.down))
        if days <= 0 { return "updated today" }
        if days == 1 { return "updated yesterday" }
        if days < 45 { return "updated \(days) days ago" }
        let months = Int((Double(days) / 30).rounded())
        if months < 24 { return "updated \(months) months ago" }
        return "updated \(Int((Double(days) / 365).rounded())) years ago"
    }

    /// "★ 1,204 · updated 3 days ago · 2 open"
    public static func githubLine(_ item: CommunityItem, now: Double) -> String {
        let updated = updatedWords(item.updatedAt, now: now)
        var parts: [String] = []
        if item.stars >= 0 { parts.append("★ \(Int(item.stars).formatted(.number.locale(Locale(identifier: "en_GB"))))") }
        if !updated.isEmpty { parts.append(updated) }
        if item.openIssues >= 0 { parts.append("\(Int(item.openIssues)) open") }
        return parts.joined(separator: " · ")
    }

    public static func confirmLabel(_ item: CommunityItem, busy: Bool) -> String {
        if busy { return "Installing…" }
        return item.tier == 3 ? "Install from @\(item.handle)" : "Install"
    }

    /// The agents ticked when the sheet opens: the ones here that the publisher tested.
    public static func defaultChoice(_ item: CommunityItem, agents: [CommunityAgent]) -> [String] {
        agents.filter { $0.found && item.agents.contains($0.id) }.map(\.id)
    }

    public static func downloadLine(_ item: CommunityItem) -> String {
        item.bytes > 0 ? "\(item.artifactUrl) — exactly \(Int(item.bytes).formatted(.number.locale(Locale(identifier: "en_GB")))) bytes" : item.artifactUrl
    }

    public static func shaLine(_ item: CommunityItem) -> String {
        item.installedVersion.isEmpty ? " — the download must match this, or nothing is saved." : " — the download matched this before it was unpacked."
    }
}
