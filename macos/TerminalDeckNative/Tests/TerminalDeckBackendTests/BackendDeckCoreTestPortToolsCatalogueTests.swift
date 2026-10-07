import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckCoreTestPortToolsCatalogueTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private typealias Rules = BackendDeckCoreCatalogueRules
    private func builtins() throws -> [BackendDeckCoreCatalogueMetadata] { try BackendDeckCoreCatalogueLiterals.builtins() }
    // TSCASE catalogue.test.ts:31
    func testCatalogueL31() throws { XCTAssertEqual(try builtins().map { $0.tool.id }.sorted(), ["alerts.list","git.diff","git.status","log.note","projects.list","sessions.get","sessions.list","sessions.result","sessions.send","sessions.start","sessions.stop","sessions.transcript","settings.read","settings.write"]) }
    // TSCASE catalogue.test.ts:50
    func testCatalogueL50() throws { XCTAssertFalse(try builtins().contains { $0.tool.id.hasPrefix("routines.") }) }
    // TSCASE catalogue.test.ts:57
    func testCatalogueL57() throws { for spec in try builtins() { let wire = spec.tool.wireName; XCTAssertEqual(wire,spec.tool.id.replacingOccurrences(of:".",with:"_")); XCTAssertNotNil(wire.range(of:#"^[a-zA-Z0-9_-]{1,64}$"#,options:.regularExpression)); XCTAssertNotNil(("mcp__deck-control__"+wire).range(of:#"^[a-zA-Z0-9_-]{1,128}$"#,options:.regularExpression)) } }
    // TSCASE catalogue.test.ts:73
    func testCatalogueL73() throws { for spec in try builtins() { XCTAssertEqual(spec.tool.inputSchema["type"],.string("object")); XCTAssertEqual(spec.tool.inputSchema["additionalProperties"],.bool(false)) } }
    // TSCASE catalogue.test.ts:82
    func testCatalogueL82() throws { XCTAssertEqual(try builtins().filter { $0.tool.tier == .alter }.map { $0.tool.id },["settings.write"]) }
    // TSCASE catalogue.test.ts:91
    func testCatalogueL91() throws { let tools = try builtins(); for id in ["sessions.list","sessions.get","sessions.transcript","projects.list","git.status","sessions.result","git.diff","alerts.list","settings.read"] { XCTAssertEqual(tools.first { $0.tool.id == id }?.tool.tier,.read,id) }; for id in ["sessions.start","sessions.send","sessions.stop","log.note"] { XCTAssertEqual(tools.first { $0.tool.id == id }?.tool.tier,.act,id) } }
    // TSCASE catalogue.test.ts:127
    func testCatalogueL127() throws { XCTAssertThrowsError(try Rules.sanitizeNote(String(repeating:"x",count:Rules.maxNoteChars+1))) { XCTAssertTrue($0.localizedDescription.contains("characters or fewer")) }; XCTAssertEqual(try Rules.sanitizeNote(String(repeating:"x",count:Rules.maxNoteChars)).utf16.count,Rules.maxNoteChars) }
    // TSCASE catalogue.test.ts:135
    func testCatalogueL135() throws { XCTAssertThrowsError(try Rules.sanitizeNote("")) { XCTAssertTrue($0.localizedDescription.contains("must not be empty")) }; XCTAssertThrowsError(try Rules.sanitizeNote("   \t ")) }
    // TSCASE catalogue.test.ts:140
    func testCatalogueL140() throws { for text in ["two\nlines","tab\there","esc\u{1b}[2J","null\u{00}byte"] { XCTAssertThrowsError(try Rules.sanitizeNote(text)) { XCTAssertTrue($0.localizedDescription.contains("single line of printable text")) } } }
    // TSCASE catalogue.test.ts:153
    func testCatalogueL153() throws { XCTAssertTrue(try Rules.sanitizeNote("Session 4 has been retrying the same migration — told him").contains("—")); XCTAssertEqual(try Rules.sanitizeNote("ملاحظة عن الجلسة"),"ملاحظة عن الجلسة") }
    // TSCASE catalogue.test.ts:158
    func testCatalogueL158() throws { XCTAssertTrue(try BackendDeckCoreCatalogueBuiltins.summary(id:"log.note",arguments:F.json(#"{"note":"the build is green"}"#)).contains("the build is green")) }
    // TSCASE catalogue.test.ts:166
    func testCatalogueL166() throws { XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.precheck(id:"log.note",arguments:F.object([("note",.string(String(repeating:"x",count:Rules.maxNoteChars+1)))]),context:BackendDeckCoreTestPortToolsCoreRig.context(),surface:BackendDeckCoreTestPortToolsCoreSurface())) }
    // TSCASE catalogue.test.ts:183
    func testCatalogueL183() throws { let cost = BackendDeckCoreCatalogueCost.measure(try builtins()); XCTAssertLessThanOrEqual(cost.tools,Rules.maxCatalogueTools); XCTAssertLessThanOrEqual(cost.tokens,Rules.maxCatalogueTokens); XCTAssertFalse(cost.overBudget) }
    // TSCASE catalogue.test.ts:224
    func testCatalogueL224() throws { let tools = try builtins(),original = tools[0]; let tool = try BackendMCPTool(id:"sessions.verbose",wireName:"sessions_verbose",description:String(repeating:"This tool does a thing, and here is every consideration. ",count:540),inputSchema:original.tool.inputSchema,tier:original.tool.tier),verbose = BackendDeckCoreCatalogueMetadata(tool:tool,title:original.title); let cost = BackendDeckCoreCatalogueCost.measure(tools+[verbose]); XCTAssertLessThanOrEqual(cost.tools,Rules.maxCatalogueTools); XCTAssertGreaterThan(cost.tokens,Rules.maxCatalogueTokens); XCTAssertTrue(cost.overBudget) }
    // TSCASE catalogue.test.ts:240
    func testCatalogueL240() throws { let tools = try builtins(); let extra = try (0..<4).map { n -> BackendDeckCoreCatalogueMetadata in let old = tools[0]; return .init(tool:try BackendMCPTool(id:"routines.contributed\(n)",wireName:"routines_contributed\(n)",description:old.tool.description,inputSchema:old.tool.inputSchema,tier:old.tool.tier),title:old.title) }; let cost = BackendDeckCoreCatalogueCost.measure(tools+extra); XCTAssertEqual(cost.tools,tools.count+4); XCTAssertGreaterThan(cost.tokens,BackendDeckCoreCatalogueCost.measure(tools).tokens) }
    // TSCASE catalogue.test.ts:254
    func testCatalogueL254() throws { let tools = try builtins(); XCTAssertEqual(tools[0].advertisedValue.fields?.map(\.key).sorted(),["annotations","description","inputSchema","name","title"]); XCTAssertEqual(BackendDeckCoreCatalogueCost.measure(tools).chars,F.object([("tools",.array(tools.map(\.advertisedValue)))]).compact.utf16.count) }
    // TSCASE catalogue.test.ts:272
    func testCatalogueL272() throws { for tool in try builtins() { let cost = Rules.estimateTokens(tool.advertisedValue.compact); XCTAssertGreaterThan(cost,80,tool.tool.id); XCTAssertLessThan(cost,600,tool.tool.id) } }
    // TSCASE catalogue.test.ts:284
    func testCatalogueL284() throws { XCTAssertEqual(Rules.estimateTokens(""),0); XCTAssertEqual(Rules.estimateTokens("x"),1); XCTAssertEqual(Rules.estimateTokens(String(repeating:"x",count:7)),2) }
    // TSCASE catalogue.test.ts:292
    func testCatalogueL292() throws { for text in ["run the tests please","テストを実行してください","اجرا کن"] { XCTAssertEqual(try Rules.sanitizeSendText(text),text) } }
    // TSCASE catalogue.test.ts:298
    func testCatalogueL298() throws { for text in ["\u{1b}[2J","ok\u{1b}]0;pwned\u{07}"] { XCTAssertThrowsError(try Rules.sanitizeSendText(text)) { XCTAssertTrue($0.localizedDescription.lowercased().contains("control")) } } }
    // TSCASE catalogue.test.ts:305
    func testCatalogueL305() throws { for text in ["\u{03}","\u{04}","\u{1a}","\u{7f}"] { XCTAssertThrowsError(try Rules.sanitizeSendText(text)) } }
    // TSCASE catalogue.test.ts:312
    func testCatalogueL312() throws { for text in ["ls\nrm -rf /","ls\rrm -rf /"] { XCTAssertThrowsError(try Rules.sanitizeSendText(text)) { XCTAssertTrue($0.localizedDescription.lowercased().contains("submit")) } }; XCTAssertThrowsError(try Rules.sanitizeSendText("a\tb")) }
    // TSCASE catalogue.test.ts:318
    func testCatalogueL318() throws { XCTAssertThrowsError(try Rules.sanitizeSendText("a\u{9b}m")) { XCTAssertTrue($0.localizedDescription.lowercased().contains("control")) } }
    // TSCASE catalogue.test.ts:322
    func testCatalogueL322() throws { XCTAssertThrowsError(try Rules.sanitizeSendText("")); XCTAssertThrowsError(try Rules.sanitizeSendText(String(repeating:"x",count:Rules.maxSendChars+1))) { XCTAssertTrue($0.localizedDescription.contains("characters or fewer")) }; XCTAssertEqual(try Rules.sanitizeSendText(String(repeating:"x",count:Rules.maxSendChars)).utf16.count,Rules.maxSendChars) }
    // TSCASE catalogue.test.ts:330
    func testCatalogueL330() throws { for key in ["remote.enabled","remote.somethingAddedLater","security.anything","confine.anything"] { XCTAssertTrue(Rules.isProtectedSetting(key),key) } }
    // TSCASE catalogue.test.ts:339
    func testCatalogueL339() throws { for key in ["copilot.enabled","copilot.permissions.alterNeedsConfirmation","deckControl.anything"] { XCTAssertTrue(Rules.isProtectedSetting(key),key) } }
    // TSCASE catalogue.test.ts:345
    func testCatalogueL345() throws { XCTAssertTrue(Rules.isProtectedSetting("browser.persistSession")); XCTAssertTrue(Rules.isProtectedSetting("advanced.debugMode")) }
    // TSCASE catalogue.test.ts:350
    func testCatalogueL350() throws { for key in ["appearance.theme","notifications.onComplete","general.language"] { XCTAssertFalse(Rules.isProtectedSetting(key),key) } }
    // TSCASE catalogue.test.ts:356
    func testCatalogueL356() throws { XCTAssertFalse(Rules.isProtectedSetting("appearance.remoteLook")); XCTAssertTrue(Rules.protectedPrefixes.allSatisfy { $0.hasSuffix(".") }); XCTAssertTrue(Rules.protectedKeys.allSatisfy { $0.contains(".") }) }
}
