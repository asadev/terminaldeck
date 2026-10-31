import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreCatalogueViewsTests: XCTestCase {
    private typealias Rules = BackendDeckCoreCatalogueRules
    private typealias Describe = BackendDeckCoreCatalogueDescribe
    private func spec(_ id: String, index: String? = nil, audience: String? = nil, keyIndex: String? = nil, keyGrant: String? = nil, aliases: [String] = []) throws -> BackendDeckCoreCatalogueMetadata {
        .init(tool: try BackendMCPTool(id: id, wireName: id.replacingOccurrences(of: ".", with: "_"), description: "the full description of \(id), which is long", inputSchema: Rules.object([("type", .string("object")), ("properties", .object([])), ("additionalProperties", .bool(false))]), tier: .read),
            title: id, aliases: aliases, index: index, audience: audience, keyIndex: keyIndex, keyGrant: keyGrant)
    }
    private func meta() throws -> BackendDeckCoreCatalogueMetadata { try Describe.tools(catalogue: { [] }).metadata[0] }
    func testListingDropsHeldSchemaButMakesItsLineReachable() throws {
        let first = try spec("a.first"), held = try spec("b.second", index: "what b is for"), third = try spec("c.third")
        let listing = try Describe.advertised([first, held, third, meta()])
        XCTAssertEqual(listing.map { $0.tool.id }, ["a.first", "c.third", Describe.id])
        XCTAssertTrue(listing.last!.tool.description.contains("b_second — what b is for"))
        XCTAssertFalse(listing.last!.tool.description.contains("the full description of b.second"))
        XCTAssertFalse(held.advertisedValue.has("index"))
        XCTAssertEqual(try Describe.advertised([first, third, meta()]).map { $0.tool.id }, ["a.first", "c.third"])
        XCTAssertEqual(try Describe.advertised([first, held]).map { $0.tool.id }, ["a.first", "b.second"])
    }
    func testDescribeMatchesAdvertisedSchemasAndAliasGrantAndMixedUnknowns() throws {
        let held = try spec("hoot.state", index: "the assistant", aliases: ["copilot.state", "copilot_state"])
        let catalogue = [held, try spec("sessions.send"), try meta()]
        let args = Rules.object([("tools", Rules.strings(["copilot_state", "sessions_send", "sessions_teleport"]))])
        let output = try Describe.answer(args, catalogue: catalogue, granted: ["copilot.state", Describe.id], caller: .local)
        XCTAssertEqual(output.value["tools"], .array([held.advertisedValue]))
        XCTAssertEqual(output.value["unknown"], Rules.strings(["no tool called sessions_send", "no tool called sessions_teleport"]))
        XCTAssertEqual(output.summary?["described"], .number(1))
    }
    func testBareNameToleranceIsInHandlerButAdvertisedSchemaStillChecksArray() throws {
        let tool = try spec("sessions.get"), args = Rules.object([("tools", .string("sessions_get"))])
        XCTAssertEqual(try Describe.answer(args, catalogue: [tool], granted: nil, caller: .local).value["tools"], .array([tool.advertisedValue]))
        XCTAssertThrowsError(try BackendDeckCoreCatalogueSchema.check(tool: meta().tool, arguments: args))
    }
    func testDescribeRejectsEmptyAndOverTwentyNames() throws {
        XCTAssertThrowsError(try Describe.answer(.object([]), catalogue: [], granted: nil, caller: .local))
        XCTAssertThrowsError(try Describe.answer(Rules.object([("tools", Rules.strings(Array(repeating: "x", count: 21)))]), catalogue: [], granted: nil, caller: .local))
    }
    func testAreaDisclosureCountsOnlyGrantedToolsAndUnknownAreaIsIndistinguishable() throws {
        let many = try (0..<13).map { try spec("browser.thing\($0)", index: "browser thing \($0)") }
        let wait = try spec("sessions.wait", index: "block until the turn ends"), machines = try spec("machines.look", index: "other computers")
        let catalogue = [try spec("sessions.list"), wait, machines] + many + [try meta()]
        let granted = Set(many.map { $0.tool.id } + [wait.tool.id, Describe.id])
        let registry = try BackendDeckCoreCatalogueRegistry(metadata: catalogue)
        let listing = try registry.listing(granted: granted)
        let description = listing.last!.tool.description
        XCTAssertTrue(description.contains("browser — "))
        XCTAssertTrue(description.contains("(13 tools)"))
        XCTAssertFalse(description.contains("machines — "))
        XCTAssertFalse(description.contains("browser_thing0"))
        let answer = try Describe.answer(Rules.object([("area", .string("  Sessions "))]), catalogue: catalogue, granted: nil, caller: .local).value
        XCTAssertEqual(answer["area"], .string("sessions"))
        XCTAssertEqual(answer["alreadyListed"], Rules.strings(["sessions_list"]))
        XCTAssertEqual(answer["held"].elements?.first?["name"], .string("sessions_wait"))
        let hidden = try Describe.answer(Rules.object([("area", .string("machines"))]), catalogue: catalogue, granted: granted, caller: .local).value
        let invented = try Describe.answer(Rules.object([("area", .string("teleports"))]), catalogue: catalogue, granted: granted, caller: .local).value
        XCTAssertEqual(hidden.compact, invented.compact.replacingOccurrences(of: "teleports", with: "machines"))
        XCTAssertEqual(Describe.areaOf("chats.read"), "sessions")
        XCTAssertEqual(Describe.areaOf("teleport.go"), "teleport")
    }
    func testKeyAudienceTaskSwitchAndKeyIndexAllUseSamePredicate() throws {
        let key = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read])
        let notifications = try spec("notifications.wait", audience: "keys")
        let crm = try spec("crm.verify", audience: "copilot")
        let tasks = try spec("tasks.local", index: "tasks", keyGrant: "tasks")
        let whereAt = try spec("app.where", keyIndex: "screen")
        XCTAssertFalse(notifications.visible(to: nil, caller: .local))
        XCTAssertFalse(crm.visible(to: nil, caller: key))
        XCTAssertFalse(tasks.visible(to: nil, caller: key))
        XCTAssertTrue(tasks.visible(to: nil, caller: BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read], tasks: true)))
        let registry = try BackendDeckCoreCatalogueRegistry(metadata: [notifications, crm, tasks, whereAt, meta()])
        let listing = try registry.listing(caller: key)
        XCTAssertEqual(listing.map { $0.tool.id }, ["notifications.wait", Describe.id])
        XCTAssertTrue(listing.last!.tool.description.contains("app_where — screen"))
        XCTAssertFalse(listing.last!.tool.description.contains("tasks_local"))
    }
    func testRunListingHasCallerSpecificTruthfulHintsAndIsAbsentForCopilot() throws {
        let tools = try Describe.tools(catalogue: { [] }).metadata
        XCTAssertFalse(try Describe.advertised(tools).contains { $0.tool.id == Describe.runID })
        let look = try Describe.wireListing(metadata: tools, caller: .init(kind: .key, tiers: [.read]), granted: nil)
        XCTAssertEqual(look.first?["annotations"]["readOnlyHint"], .bool(true))
        XCTAssertEqual(look.first?["annotations"]["destructiveHint"], .bool(false))
        let full = try Describe.wireListing(metadata: tools, caller: .init(kind: .key, tiers: [.read, .act, .alter]), granted: nil)
        XCTAssertEqual(full.first?["annotations"]["readOnlyHint"], .bool(false))
        XCTAssertEqual(full.first?["annotations"]["destructiveHint"], .bool(true))
    }
    func testCoverageCompleteMapAndNativeRetirementsNeverClaimChromeTools() throws {
        let source = BackendDeckCoreCatalogueCoverageLiterals.sourceRows
        XCTAssertEqual(source.count, 599)
        XCTAssertEqual(Set(source.map { "\($0.area):\($0.action)" }).count, source.count)
        XCTAssertTrue(source.allSatisfy { ($0.tools?.isEmpty == false) != ($0.skip != nil) })
        let retired = BackendDeckCoreCatalogueCoverage.rows.filter { $0.skip?.contains("Retired by Asad's Chrome removal") == true }
        XCTAssertEqual(retired.count, 16)
        XCTAssertTrue(retired.allSatisfy { $0.tools == nil })
        let rows = BackendDeckCoreCatalogueCoverage.rows
        let sourceKeys = Set(source.map { "\($0.area):\($0.action)" })
        let pausedKeys = Set(source.filter { $0.area == "memory" }.map { "\($0.area):\($0.action)" })
        let setupKeys: Set<String> = ["fixed:staysfixed:setup-preview", "fixed:staysfixed:setup-prepare", "fixed:staysfixed:setup-apply"]
        // Retain the raw 599-row map; discovery omits seven paused Memory rows
        // and includes the three guided Stays Fixed setup actions.
        XCTAssertEqual(pausedKeys.count, 7)
        XCTAssertEqual(rows.count, 595)
        XCTAssertEqual(Set(rows.map { "\($0.area):\($0.action)" }), sourceKeys.subtracting(pausedKeys).union(setupKeys))
        XCTAssertEqual(Set(rows.map { "\($0.area):\($0.action)" }).count, rows.count)
        XCTAssertTrue(rows.allSatisfy { ($0.tools?.isEmpty == false) != ($0.skip != nil) })
        XCTAssertFalse(rows.contains { $0.area == "memory" || $0.action.hasPrefix("memory:") || ($0.tools ?? []).contains(where: UIGMemoryVisibility.isMemoryToolName) })
        let counts = try BackendDeckCoreCatalogueCoverage.answer(.object([])).value
        XCTAssertEqual(counts["counts"].fields?.map(\.key), BackendDeckCoreCatalogueCoverage.areaNames)
        XCTAssertFalse(counts.has("rows"))
    }
    func testCoverageWordMatchingSkipsAndSixtyRowCap() throws {
        let rows = BackendDeckCoreCatalogueCoverage.rows
        XCTAssertTrue(BackendDeckCoreCatalogueCoverage.matching(rows, query: "held retry").contains { $0.action == "session:held-retry" })
        XCTAssertTrue(BackendDeckCoreCatalogueCoverage.matching(rows, query: "approve its own request").contains { $0.action == "deck-control:consent-respond" })
        let skipped = try BackendDeckCoreCatalogueCoverage.answer(Rules.object([("skippedOnly", .bool(true)), ("area", .string("sessions"))])).value
        XCTAssertTrue((skipped["rows"].elements ?? []).allSatisfy { $0["skip"].string != nil && !$0.has("tools") })
        let browser = try BackendDeckCoreCatalogueCoverage.answer(.object([.init("area", .string("browser"))])).value
        XCTAssertEqual(browser["rows"].elements?.count, 60)
        XCTAssertTrue(browser["note"].string?.contains("narrow") == true)
        let none = try BackendDeckCoreCatalogueCoverage.answer(.object([.init("query", .string("no-such-galaxy"))])).value
        XCTAssertEqual(none["matched"], .number(0))
        XCTAssertTrue(none["note"].string?.contains("Try fewer") == true)
    }
    func testCoverageDetectsPreloadChannelsAndUICommandDriftWhenCombinedGateRuns() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let preload = try String(contentsOf: root.appendingPathComponent("src/preload/index.ts"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"ipcRenderer\.(?:invoke|send)\('([^']+)'"#)
        let range = NSRange(preload.startIndex..<preload.endIndex, in: preload)
        let actual = Set(regex.matches(in: preload, range: range).compactMap { match in Range(match.range(at: 1), in: preload).map { String(preload[$0]) } })
        let mapped = BackendDeckCoreCatalogueCoverageLiterals.sourceRows.filter { $0.area != "window" }.map(\.action)
        XCTAssertGreaterThan(actual.count, 300)
        XCTAssertEqual(Set(mapped), actual)
        XCTAssertEqual(Set(mapped).count, mapped.count)
        XCTAssertTrue(BackendDeckCoreCatalogueCoverageLiterals.sourceRows.compactMap(\.skip).allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 })
        let app = try String(contentsOf: root.appendingPathComponent("src/renderer/App.tsx"), encoding: .utf8)
        let menu = try String(contentsOf: root.appendingPathComponent("src/main/menu.ts"), encoding: .utf8)
        let keymap = try String(contentsOf: root.appendingPathComponent("src/renderer/keymap.ts"), encoding: .utf8)
        let start = try XCTUnwrap(app.range(of: "const commands = useMemo<PaletteCommand[]>"))
        let end = try XCTUnwrap(app.range(of: "window.deck.onMenuCommand", range: start.upperBound..<app.endIndex))
        let region = String(app[start.lowerBound..<end.lowerBound])
        func captures(_ source: String, pattern: String) throws -> Set<String> {
            let regex = try NSRegularExpression(pattern: pattern)
            return Set(regex.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)).compactMap { match in
                Range(match.range(at: 1), in: source).map { String(source[$0]) }
            })
        }
        var commands = try captures(region, pattern: #"\bid: '([a-z][\w.]*)'"#)
        commands.formUnion(try captures(region, pattern: #"\bcase '([a-z][\w.]*)':"#))
        commands.formUnion(try captures(menu, pattern: #"\bsend\('([a-z][\w.]*)'\)"#))
        commands.formUnion(try captures(keymap, pattern: #"\bid: '([a-z]+\.[\w.]+)'"#))
        if region.contains("`features.install.") { commands.insert("features.install.*") }
        let mappedCommands = Set(BackendDeckCoreCatalogueCoverageLiterals.sourceRows.filter { $0.area == "window" && !$0.action.contains(" ") }.map(\.action))
        XCTAssertGreaterThan(commands.count, 40)
        XCTAssertEqual(mappedCommands, commands)
    }
    func testWhereNarrowingRejectsInvalidWindowAndKeepsOnlyRealFields() {
        XCTAssertNil(BackendDeckCoreCatalogueWhere.readWhere(.null))
        XCTAssertNil(BackendDeckCoreCatalogueWhere.readWhere(.object([])))
        let narrowed = BackendDeckCoreCatalogueWhere.readWhere(Rules.object([("title", .string("api")), ("sessionId", .number(42)), ("pane", .string("split"))]))
        XCTAssertEqual(narrowed?["sessionId"], .null)
        XCTAssertEqual(narrowed?["pane"], .null)
        XCTAssertEqual(narrowed?["openSessions"], .array([]))
    }
    func testWhereNoWindowIsTruthfulAndCredentialPageWithholdsText() async {
        let noWindow = await BackendDeckCoreCatalogueWhere.answer(dependencies: .init(window: BackendDeckCoreCatalogueViewsTestWindow(value: .null), page: { nil }))
        XCTAssertEqual(noWindow.value["window"], .null)
        XCTAssertTrue(noWindow.value["note"].string?.contains("no window") == true)
        let window = BackendDeckCoreCatalogueViewsTestWindow(value: Rules.object([("title", .string("Fix parser")), ("pane", .string("chat")), ("sessionId", .null)]))
        let secret = await BackendDeckCoreCatalogueWhere.answer(dependencies: .init(window: window, page: { BackendDeckCoreCatalogueViewsTestPage(secret: true) }))
        XCTAssertEqual(secret.value["page"]["url"], .string("https://bank.test/login"))
        XCTAssertEqual(secret.value["page"]["text"], .null)
        XCTAssertTrue(secret.value["page"]["why"].string?.contains("credential") == true)
        XCTAssertTrue(secret.value["note"].string?.contains("ambiguous") == true)
        let readable = await BackendDeckCoreCatalogueWhere.answer(dependencies: .init(window: window, page: { BackendDeckCoreCatalogueViewsTestPage(secret: false) }))
        XCTAssertEqual(readable.value["page"]["text"], .string("Orders — 3 failed"))
    }
}

private struct BackendDeckCoreCatalogueViewsTestWindow: BackendDeckCoreCatalogueWhereWindow {
    let value: NativeRPCValue
    func read() async throws -> NativeRPCValue { value }
}
private struct BackendDeckCoreCatalogueViewsTestPage: BackendDeckCoreCatalogueWherePage {
    let secret: Bool
    func status() async -> NativeRPCValue { .object([.init("url", .string("https://bank.test/login"))]) }
    func textAt(selector: String?, limit: Int) async throws -> NativeRPCValue {
        XCTAssertNil(selector); XCTAssertEqual(limit, 1_200)
        return .object([.init("found", .bool(true)), .init("secret", .bool(secret)), .init("text", .string("Orders — 3 failed")), .init("truncated", .bool(false))])
    }
}
