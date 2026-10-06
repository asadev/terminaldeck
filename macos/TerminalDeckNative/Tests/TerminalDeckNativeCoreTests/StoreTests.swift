import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors src/renderer/store/storefront.test.ts, store-nav.test.ts, StoreLogo.test.tsx
// and community/bridge.test.ts, CommunityRow.test.tsx, InstallSheet.test.tsx.

private func row(_ id: String, _ category: String = "privacy", name: String? = nil, summary: String = "", tags: [String] = [],
                 cost: String = "free", compat: StoreCompat = .works, installed: Bool = false, source: String = "chrome",
                 needs: [String] = []) -> StoreFacets {
    StoreFacets(id: id, name: name ?? id, summary: summary, category: category, categoryName: category.capitalized, tags: tags,
                cost: cost, compat: compat, installed: installed, source: source, needs: needs)
}

@Suite("Store — searching and filtering (storefront.ts)")
struct StoreFrontTests {
    @Test func searchIsForgiving() {
        let ublock = row("u", name: "uBlock Origin", summary: "An efficient blocker", tags: ["adblock"])
        #expect(StoreRules.matchesQuery(ublock, "UBLOCK"))
        #expect(StoreRules.matchesQuery(ublock, "ubl"))
        #expect(StoreRules.matchesQuery(ublock, "adblock"))
        #expect(StoreRules.matchesQuery(ublock, "privacy"))
        #expect(StoreRules.matchesQuery(ublock, "u-block"))
        #expect(StoreRules.matchesQuery(ublock, "ublock efficient"))
        #expect(!StoreRules.matchesQuery(ublock, "ublock postgres"))
        #expect(StoreRules.matchesQuery(ublock, "   "))
    }

    @Test func facetsFilterIndependently() {
        let rows = [row("a", cost: "free"), row("b", cost: "paid", installed: true), row("c", "dev", cost: "account", needs: ["node"])]
        #expect(rows.filter { StoreRules.matches($0, StoreFilter(cost: "paid")) }.map(\.id) == ["b"])
        #expect(rows.filter { StoreRules.matches($0, StoreFilter(installed: "yes")) }.map(\.id) == ["b"])
        #expect(rows.filter { StoreRules.matches($0, StoreFilter(installed: "no")) }.map(\.id) == ["a", "c"])
        #expect(rows.filter { StoreRules.matches($0, StoreFilter(category: "dev")) }.map(\.id) == ["c"])
        #expect(rows.filter { StoreRules.matches($0, StoreFilter(needs: StoreFront.needsNothing)) }.map(\.id) == ["a", "b"])
        #expect(rows.filter { StoreRules.matches($0, StoreFilter(needs: "node")) }.map(\.id) == ["c"])
        #expect(rows.filter { StoreRules.matches($0, StoreFilter(query: "a", cost: "free")) }.map(\.id) == ["a"])
        #expect(!StoreFilter.none.active)
        #expect(StoreFilter(query: " x ").active)
        #expect(StoreFilter(compat: "cannot").active)
        #expect(StoreFront.costWord("account") == "Free, needs an account")
        #expect(StoreFront.costWord("metered") == "Free to a limit, then paid")
    }

    @Test func chipsCountOverTheOtherFacets() {
        let vocabulary = FacetVocabulary(label: "Cost", anyName: "Any price", options: [("free", "Free"), ("paid", "Paid"), ("metered", "Metered"), ("ghost", "Ghost")])
        let rows = [row("a", cost: "free"), row("b", cost: "free"), row("c", cost: "paid", installed: true)]
        let control = StoreRules.facetControl(rows, StoreFilter(), .cost, vocabulary)!
        #expect(control.options.map(\.id) == ["free", "paid"])
        #expect(control.options.map(\.count) == [2, 1])
        #expect(control.total == 3)
        #expect(StoreRules.facetControl([row("a"), row("b")], StoreFilter(), .cost, vocabulary) == nil)
        let narrowed = StoreRules.facetControl(rows, StoreFilter(installed: "yes"), .cost, vocabulary)
        #expect(narrowed == nil)
        let kept = StoreRules.facetControl(rows, StoreFilter(cost: "metered"), .cost, vocabulary)!
        #expect(kept.options.map(\.id) == ["free", "paid", "metered"])
        #expect(!kept.options.contains { $0.id == StoreFront.any })
        let only = StoreRules.facetControls(rows, StoreFilter(), [.cost: vocabulary])
        #expect(only.map(\.facet) == [.cost])
    }

    @Test func shelvesInTheStoresOrder() {
        let rows = [row("b", "dev"), row("a", "privacy"), row("c", "privacy")]
        let shelves = StoreRules.shelve(rows, order: [("privacy", "Privacy"), ("empty", "Empty"), ("dev", "Developer")], facetsOf: { $0 }) { $0.id == "c" ? 0 : 1 }
        #expect(shelves.map(\.id) == ["privacy", "dev"])
        #expect(shelves[0].rows.map(\.id) == ["c", "a"])
        #expect(StoreRules.withoutShelf([.category: FacetVocabulary(label: "", anyName: "", options: []), .cost: FacetVocabulary(label: "", anyName: "", options: [])]).keys.sorted { $0.rawValue < $1.rawValue } == [.cost])
    }
}

@Suite("Store — the rail and the empty page (store-nav.ts)")
struct StoreNavTests {
    func departments(query: String = "", communityCost: String = StoreFront.any) -> [StoreDepartmentInput] {
        [
            StoreDepartmentInput(id: .extensions, name: "Browser extensions", wired: true, shelves: [("privacy", "Privacy"), ("dev", "Developer")],
                                 rows: [row("u", "privacy", name: "uBlock"), row("d", "dev", name: "React tools")], filter: StoreFilter(query: query)),
            StoreDepartmentInput(id: .servers, name: "MCP servers", wired: false, shelves: [], rows: [row("pg", "db")], filter: StoreFilter(query: query)),
            StoreDepartmentInput(id: .community, name: "Community", wired: true, shelves: [("skill", "Skill")],
                                 rows: [row("s", "skill", name: "deploy skill", cost: "free")], filter: StoreFilter(query: query, cost: communityCost)),
        ]
    }

    @Test func countsEveryDepartmentAndShelf() {
        let nav = StoreNav.nav(departments())
        #expect(nav.map(\.id) == [.extensions, .community])
        #expect(nav[0].count == 2)
        #expect(nav[0].shelves.map(\.count) == [1, 1])
        #expect(StoreNav.total(nav) == 3)
    }

    @Test func keepsTheShelfYouStandOn() {
        let searched = StoreNav.nav(departments(query: "ublock"), .shelf(.extensions, "dev"))
        #expect(searched[0].shelves.map(\.id) == ["privacy", "dev"])
        #expect(StoreNav.nav(departments(query: "ublock"))[0].shelves.map(\.id) == ["privacy"])
    }

    @Test func handsAShelfOnlyToItsDepartment() {
        let d = departments()
        #expect(StoreNav.filterFor(.shelf(.extensions, "dev"), d[0]).category == "dev")
        #expect(StoreNav.filterFor(.shelf(.extensions, "dev"), d[2]).category == StoreFront.any)
        #expect(StoreNav.shows(.all, .community))
        #expect(!StoreNav.shows(.department(.extensions), .community))
    }

    @Test func emptyPages() {
        #expect(StoreNav.empty(departments(), .all) == nil)
        let shelf = StoreNav.empty(departments(query: "deploy"), .shelf(.extensions, "privacy"))!
        #expect(shelf.title == "Nothing here matches that")
        #expect(shelf.detail == "1 thing elsewhere in the store does. The rail on the left says where.")
        #expect(shelf.elsewhere == 1)
        let department = StoreNav.empty(departments(query: "deploy"), .department(.extensions))!
        #expect(department.title == "Nothing in this department matches that")
        let whole = StoreNav.empty(departments(query: "zzz"), .all)!
        #expect(whole.title == "Nothing in the store matches that")
        #expect(whole.detail == "Searched all 3 of them, across all 2 departments.")
        var none = departments()
        for i in none.indices { none[i].wired = false }
        #expect(StoreNav.empty(none, .all)?.title == "Nothing to browse in this build")
        #expect(StoreNav.shown(departments(), .all) == 3)
        #expect(StoreNav.shown(departments(communityCost: "paid"), .all) == 2)
        #expect(StoreNav.departmentOfRow("t:x") == .extensions)
        #expect(StoreNav.departmentOfRow("m:pg") == .servers)
        #expect(StoreNav.departmentOfRow("c:s") == .community)
        #expect(StoreNav.departmentOfRow("") == nil)
    }
}

@Suite("Store — logos")
struct StoreLogoTests {
    @Test func everyBundledLogoIsInlineAndReadable() {
        #expect(!StoreLogoData.assets.isEmpty)
        for (key, asset) in StoreLogoData.assets {
            #expect(asset.src.hasPrefix("data:image/"), "\(key)")
            #expect(StoreLogoRules.imageData(asset.src) != nil, "\(key)")
        }
    }

    @Test func monograms() {
        #expect(StoreLogoRules.monogram("  (uBlock)") == "U")
        #expect(StoreLogoRules.monogram("") == "?")
        #expect(StoreLogoRules.monogram("---") == "?")
        let fills = Set(["a", "b", "c", "d", "ublock", "notion"].map(StoreLogoRules.monogramFill))
        #expect(fills.allSatisfy { (1...4).contains($0) })
        #expect(fills.count > 1)
        #expect(StoreLogoRules.monogramFill("ublock") == StoreLogoRules.monogramFill("ublock"))
    }
}

@Suite("Store — Community (bridge, row, install sheet)")
struct CommunityTests {
    let now = StaysFixedRules.parse("2026-08-29T12:00:00Z")!

    func item(_ change: (inout [String: Any]) -> Void = { _ in }) -> CommunityItem {
        var raw: [String: Any] = ["id": "deploy", "kind": "skill", "name": "Deploy", "publisher": "asad", "tier": 1, "cost": "free"]
        change(&raw)
        return CommunityRules.view(["items": [raw]]).items[0]
    }

    @Test func readsTheCatalogueForgivingly() {
        let view = CommunityRules.view(["from": "kept", "at": "2026-08-29T09:00:00.000Z", "items": [
            ["id": "a", "kind": "skill"], ["id": "b", "kind": "spaceship"], ["kind": "skill"], ["id": "c", "kind": "mcp", "tier": 7, "cost": "lots"],
        ], "agents": [["id": "claude", "found": true], ["id": "cursor"]]])
        #expect(view.items.map(\.id) == ["a", "c"])
        #expect(view.items[1].tier == 3)
        #expect(view.items[1].cost == "unknown")
        #expect(view.items[0].name == "a")
        #expect(view.items[0].stars == -1)
        #expect(view.kept)
        #expect(view.agents.map(\.id) == ["claude"])
        #expect(CommunityRules.view(nil) == .none)
        #expect(CommunityRules.view("junk") == .none)
        #expect(CommunityRules.result(nil).message == "The app did not answer.")
        #expect(CommunityRules.catalogueDate("2026-08-29T09:00:00.000Z") == "29 August")
        #expect(CommunityRules.catalogueDate("nonsense") == "")
    }

    @Test func facetsOfARow() {
        let skill = item { $0["handle"] = "asadev"; $0["installedVersion"] = "1.0.0"; $0["missing"] = ["api-key"] }
        let facets = CommunityRules.facets(skill)
        #expect(facets.category == "skill")
        #expect(facets.installed)
        #expect(facets.compat == .unknown)
        #expect(facets.source == "community")
        #expect(facets.tags.contains("asadev"))
        #expect(CommunityRules.facets(item { $0["missing"] = ["node"] }).compat == .cannot)
        #expect(CommunityRules.vocabularies[.source] == nil)
        #expect(StoreRules.withoutShelf(CommunityRules.vocabularies)[.category] == nil)
    }

    @Test func ratingsDomainsAndInstallability() {
        #expect(CommunityRules.ratingChip(item { $0["ratingScore"] = 4.62; $0["ratingCount"] = 4 }) == "")
        #expect(CommunityRules.ratingChip(item { $0["ratingScore"] = 4.62; $0["ratingCount"] = 12 }) == "Rated 4.6 · 12")
        #expect(CommunityRules.ratingChip(item { $0["cost"] = "paid"; $0["ratingCount"] = 50 }) == "")
        #expect(CommunityRules.domainOf("https://www.example.com/x") == "example.com")
        #expect(CommunityRules.domainOf("not a url") == "")
        #expect(!CommunityRules.installable(item { $0["delivery"] = "off-site" }))
        #expect(!CommunityRules.installable(item { $0["state"] = "unsupported" }))
        #expect(CommunityRules.tierWord(2) == "Ships scripts the agent may run")
    }

    @Test func oneActionAtATime() {
        #expect(CommunityRules.rowAction(item()) == .install)
        #expect(CommunityRules.rowAction(item { $0["state"] = "outdated"; $0["installedVersion"] = "1" }) == .update)
        #expect(CommunityRules.rowAction(item { $0["installedVersion"] = "1" }) == .remove)
        #expect(CommunityRules.rowAction(item { $0["delivery"] = "off-site" }) == nil)
    }

    @Test func updatedWords() {
        #expect(CommunityRules.updatedWords("2026-08-29T00:00:00.000Z", now: now) == "updated today")
        #expect(CommunityRules.updatedWords("2026-08-28T00:00:00.000Z", now: now) == "updated yesterday")
        #expect(CommunityRules.updatedWords("2026-08-26T00:00:00.000Z", now: now) == "updated 3 days ago")
        #expect(CommunityRules.updatedWords("2026-04-29T00:00:00.000Z", now: now) == "updated 4 months ago")
        #expect(CommunityRules.updatedWords("2022-08-29T00:00:00.000Z", now: now) == "updated 4 years ago")
        #expect(CommunityRules.updatedWords("", now: now) == "")
        #expect(CommunityRules.updatedWords("2030-01-01T00:00:00.000Z", now: now) == "")
        #expect(CommunityRules.githubLine(item { $0["stars"] = 1204; $0["openIssues"] = 2; $0["updatedAt"] = "2026-08-26T00:00:00.000Z" }, now: now)
            == "★ 1,204 · updated 3 days ago · 2 open")
        #expect(CommunityRules.githubLine(item(), now: now) == "")
    }

    @Test func theInstallSheet() {
        #expect(CommunityRules.confirmLabel(item { $0["tier"] = 3; $0["handle"] = "pub" }, busy: false) == "Install from @pub")
        #expect(CommunityRules.confirmLabel(item(), busy: false) == "Install")
        #expect(CommunityRules.confirmLabel(item(), busy: true) == "Installing…")
        let agents = [CommunityAgent(id: "claude", name: "Claude Code", found: true, note: ""),
                      CommunityAgent(id: "codex", name: "Codex", found: false, note: ""),
                      CommunityAgent(id: "gemini", name: "Gemini", found: true, note: "")]
        #expect(CommunityRules.defaultChoice(item { $0["agents"] = ["claude", "codex"] }, agents: agents) == ["claude"])
        #expect(CommunityRules.needWord("api-key") == "Needs a key you supply")
        #expect(CommunityRules.agentIds.map(CommunityRules.agentLabel) == ["Claude Code", "Codex CLI", "Gemini CLI"])
        #expect(CommunityRules.tierNote(3).hasPrefix("It starts a program on this machine"))
    }
}
