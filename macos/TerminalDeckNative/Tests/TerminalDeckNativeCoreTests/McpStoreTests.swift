import Foundation
import Testing
@testable import TerminalDeckNativeCore

// The Store's MCP servers department, native. Mirrors mcp-store-bridge.test.ts and the
// pure half of McpStore.test.tsx / McpStoreRow.test.tsx.

private func json(_ text: String) -> OrderedJSON {
    guard let value = OrderedJSON.parse(text) else { fatalError("bad fixture: \(text)") }
    return value
}

private func row(_ fields: String) -> McpStoreRow {
    guard let read = McpStoreView.from(json(#"{"rows":[{\#(fields)}]}"#)).rows.first else { fatalError("no row: \(fields)") }
    return read
}

private let token = #"{"key":"GITHUB_TOKEN","label":"Personal access token","kind":"secret","required":true}"#
private let folder = #"{"key":"ROOT","label":"Folder","kind":"path","required":true,"into":"arg"}"#
private let optional = #"{"key":"MODE","label":"Mode","kind":"text"}"#

@Test func mcpStoreNarrowsEverythingAndDropsWhatHasNoId() {
    let view = McpStoreView.from(json(#"""
    {"rows": [{"id": "gh", "name": "GitHub", "category": "nonsense", "cost": "cheap", "origin": "?", "runtime": "go",
               "state": "weird", "scope": "global", "transport": "ws", "tags": ["a", 3]},
              {"name": "no id"}, 7],
     "runtimes": [{"id": "node", "binary": "npx", "found": true, "path": "/usr/bin/npx"}, {"id": "ruby"}],
     "writer": {"found": true, "path": "/bin/claude"}, "environmentSource": "bogus", "projectPath": "/w"}
    """#))
    #expect(view.rows.map(\.id) == ["gh"])
    let gh = view.rows[0]
    #expect(gh.category == "utility" && gh.cost == "account" && gh.origin == "third-party" && gh.runtime == "node")
    #expect(gh.state == .available && gh.scope == "" && gh.transport == .stdio && gh.tags == ["a"])
    #expect(view.runtimes.map(\.id) == ["node"])
    #expect(view.writerFound && view.writerPath == "/bin/claude")
    #expect(view.environmentSource == "unavailable")
    #expect(McpStoreView.from(.string("x")) == McpStoreView())
}

@Test func mcpStoreWillNotLetAnArgumentClaimToBeInTheEnvironment() {
    let read = row(#""id":"x","inputs":[{"key":"A","into":"arg","inEnvironment":true},{"key":"B","inEnvironment":true},{"label":"no key"}]"#)
    #expect(read.inputs.map(\.key) == ["A", "B"])
    #expect(read.inputs[0].inEnvironment == false)
    #expect(read.inputs[1].inEnvironment == true)
    #expect(read.inputs[0].label == "A")
}

@Test func mcpStoreResultsAreFailuresUnlessTheySayOtherwise() {
    #expect(McpStoreResults.read(.null) == McpAddResult(ok: false, message: "That did not work."))
    #expect(McpStoreResults.read(json(#"{"ok":true}"#)) == McpAddResult(ok: true, message: "Done."))
    #expect(McpStoreResults.read(json(#"{"ok":"yes","message":"Nope"}"#)) == McpAddResult(ok: false, message: "Nope"))
    let imported = McpStoreResults.readImport(json(#"{"ok":true,"message":"Read","draft":{"name":"x","transport":"http","url":"https://x","env":["K",1]}}"#))
    #expect(imported.result.ok && imported.draft?.name == "x" && imported.draft?.transport == .http && imported.draft?.env == ["K"])
    #expect(McpStoreResults.readImport(json(#"{"ok":true,"draft":{"name":""}}"#)).draft == nil)
}

@Test func mcpStoreNamesWhatIsNeededBeforeAnythingIsPressed() {
    #expect(row(#""id":"a","inputs":[\#(token),\#(folder)]"#).needsWords == "Personal access token, Folder")
    #expect(row(#""id":"a""#).needsWords == "Nothing")
    #expect(row(#""id":"a","inputs":[\#(optional)]"#).needsWords == "Nothing required")
    let gh = row(#""id":"a","inputs":[\#(token),\#(folder)]"#)
    #expect(gh.unfilled([:]) == ["Personal access token", "Folder"])
    #expect(gh.unfilled(["GITHUB_TOKEN": " x ", "ROOT": "  "]) == ["Folder"])
    let shell = row(#""id":"a","inputs":[{"key":"T","label":"T","kind":"secret","required":true,"inEnvironment":true}]"#)
    #expect(shell.unfilled([:]).isEmpty)
    #expect(shell.inputs[0].placeholder == "Leave blank to use T from your shell")
    #expect(shell.inputs[0].keptLabel == "T is already in your shell")
}

@Test func mcpStoreFacetsNeverClaimAServerWorks() {
    let ok = row(#""id":"a","name":"A","category":"data","cost":"metered","origin":"vendor","state":"installed""#)
    let facets = ok.facets
    #expect(facets.compat == .unknown && facets.installed && facets.source == "vendor" && facets.categoryName == "Databases")
    #expect(facets.cost == "metered")
    let missing = row(#""id":"b","runtimeMissing":true,"custom":true,"origin":"vendor""#)
    #expect(missing.facets.compat == .cannot)
    #expect(missing.facets.source == "custom")
    #expect(missing.sourceWords == "Added by you")
    #expect(row(#""id":"c""#).costLabel == "Free, needs an account")
    #expect(row(#""id":"d","state":"taken""#).facets.installed == false)
}

@Test func mcpStoreReportsEveryNeedNotTheFirst() {
    #expect(row(#""id":"a","runtime":"docker","inputs":[\#(token),\#(folder),\#(optional)]"#).needs == ["token", "setting", "docker"])
    #expect(row(#""id":"a","runtime":"python""#).needs.isEmpty)
    #expect(row(#""id":"a","inputs":[\#(optional)]"#).needs.isEmpty)
}

@Test func mcpStoreRowsSayHowTheyRunAndWhatTheyOffer() {
    #expect(row(#""id":"a","runtime":"python""#).runsWords == "uvx — fetched from PyPI the first time it runs")
    #expect(row(#""id":"a","custom":true,"runsWords":"/usr/local/bin/serve — found here""#).runsWords == "/usr/local/bin/serve — found here")
    let installed = row(#""id":"a","state":"installed","scope":"local""#)
    #expect(installed.actionLabel(busy: false) == "Remove" && installed.installedWords == "Installed · local")
    #expect(row(#""id":"a""#).actionLabel(busy: true) == "Working…")
    #expect(!row(#""id":"a","state":"unavailable","blocked":"needs docker""#).hasAction)
    #expect(row(#""id":"a","inputs":[\#(optional)]"#).asks)
    #expect(!row(#""id":"a","state":"taken","blocked":"taken","inputs":[\#(token)]"#).asks)
    #expect(row(#""id":"a","name":"GitHub","inputs":[\#(token)]"#).askHead == "GitHub needs Personal access token. Nothing is written until you press Install.")
    #expect(row(#""id":"a","envKeys":["K"]"#).envWords == "K — its value is in your configuration and is not shown here.")
}

@Test func mcpStoreLinksOutOnlyWhereThereIsNoInstall() {
    let blocked = #""id":"a","state":"unavailable","blocked":"no docker","homepage":"https://github.com/x/y""#
    #expect(row(blocked).linkOut == "https://github.com/x/y")
    #expect(row(#""id":"a","homepage":"https://x""#).linkOut == "")
    #expect(row(#""id":"a","state":"unavailable","blocked":"b","homepage":"javascript:alert(1)""#).linkOut == "")
    #expect(row(#""id":"a","state":"unavailable","blocked":"b","custom":true,"homepage":"https://x""#).linkOut == "")
}

@Test func mcpStoreShelvesByWhatAServerDoes() {
    let rows = McpStoreView.from(json(#"""
    {"rows": [
      {"id": "pg", "name": "Postgres", "category": "data", "state": "unavailable", "blocked": "b"},
      {"id": "sqlite", "name": "SQLite", "category": "data", "tags": ["embedded"]},
      {"id": "fs", "name": "Filesystem", "category": "files", "state": "installed"},
      {"id": "mine", "name": "Mine", "category": "your-own", "custom": true, "state": "installed"}]}
    """#)).rows
    let all = McpStoreShelving(rows: rows, filter: .none)
    #expect(all.shelves.map(\.id) == ["data"])
    #expect(all.shelves[0].rows.map(\.id) == ["sqlite", "pg"]) // installable first
    #expect(all.installed.map(\.id) == ["fs"])
    #expect(all.own.map(\.id) == ["mine"])
    #expect(all.emptyWords == nil)
    #expect(McpStoreCatalog.shelves.first?.id == "files" && McpStoreCatalog.shelves.last?.id == "your-own")
    #expect(!all.controls.contains { $0.facet == .category })

    let tag = McpStoreShelving(rows: rows, filter: StoreFilter(query: "embedded"))
    #expect(tag.kept.map(\.id) == ["sqlite"])
    #expect(tag.ownHidden == "The one you added does not match that.")

    let nothing = McpStoreShelving(rows: rows, filter: StoreFilter(query: "zzz"))
    #expect(nothing.emptyWords == "Nothing in the catalogue matches that.")
    let onlyInstalled = McpStoreShelving(rows: rows, filter: StoreFilter(query: "filesystem"))
    #expect(onlyInstalled.emptyWords == "Everything that matches is already in your configuration — it is above.")
}

@Test func mcpStoreOffersEveryPriceAndNamesTheArchivedOne() {
    #expect(McpStoreCatalog.vocabularies[.cost]?.options.map(\.id) == ["free", "account", "metered", "paid", "unknown"])
    #expect(McpStoreCatalog.vocabularies[.source]?.options.first { $0.id == "reference-archived" }?.name == "Archived — unmaintained")
    #expect(McpStoreCatalog.vocabularies[.needs]?.options.first?.id == StoreFront.needsNothing)
}
