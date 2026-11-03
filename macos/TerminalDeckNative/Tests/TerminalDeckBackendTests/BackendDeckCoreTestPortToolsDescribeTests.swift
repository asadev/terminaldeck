import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckCoreTestPortToolsDescribeTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private typealias D = BackendDeckCoreCatalogueDescribe
    private func spec(_ id: String,index: String? = nil) throws -> BackendDeckCoreCatalogueMetadata { .init(tool:try BackendMCPTool(id:id,wireName:id.replacingOccurrences(of:".",with:"_"),description:"the full description of \(id), which is long",inputSchema:F.json(#"{"type":"object","properties":{},"additionalProperties":false}"#),tier:.read),title:id,index:index) }
    private func meta() throws -> BackendDeckCoreCatalogueMetadata { try D.tools(catalogue:{ [] }).metadata[0] }
    private func simple() throws -> [BackendDeckCoreCatalogueMetadata] { try [spec("a.first"),spec("b.second",index:"what b is for"),meta()] }
    private func limited() throws -> [BackendDeckCoreCatalogueMetadata] { try [spec("browser.open"),spec("assets.ledger",index:"the resume ledger"),spec("sessions.send"),spec("tour.play",index:"drive the screen"),meta()] }
    private var grant: Set<String> { ["browser.open","browser_open","assets.ledger","assets_ledger",D.id,D.wire] }
    private func many() throws -> [BackendDeckCoreCatalogueMetadata] { try [spec("sessions.list"),spec("sessions.wait",index:"block until the turn ends")] + (0..<D.inlineIndexMax).map { try spec("browser.thing\($0)",index:"browser thing \($0)") } + [spec("machines.look",index:"other computers"),meta()] }
    private func answer(_ args: NativeRPCValue,catalogue: [BackendDeckCoreCatalogueMetadata],granted: Set<String>? = nil) throws -> NativeRPCValue { try D.answer(args,catalogue:catalogue,granted:granted,caller:.local).value }
    private func names(_ names: [String],catalogue: [BackendDeckCoreCatalogueMetadata]? = nil,granted: Set<String>? = nil) throws -> NativeRPCValue { try answer(F.object([("tools",.array(names.map(NativeRPCValue.string)))]),catalogue:catalogue ?? simple(),granted:granted) }
    // TSCASE describe-tool.test.ts:59
    func testDescribeL59() throws { let catalogue = try [spec("a.first"),spec("b.second",index:"what b is for"),spec("c.third"),meta()],listed = try D.advertised(catalogue); XCTAssertEqual(listed.map { $0.tool.id },["a.first","c.third",D.id]); let text = try XCTUnwrap(listed.first { $0.tool.id == D.id }?.tool.description); XCTAssertTrue(text.contains("b_second — what b is for")); XCTAssertFalse(text.contains("the full description of b.second")) }
    // TSCASE describe-tool.test.ts:69
    func testDescribeL69() throws { XCTAssertEqual(try D.advertised([spec("a.first"),spec("c.third"),meta()]).map { $0.tool.id },["a.first","c.third"]) }
    // TSCASE describe-tool.test.ts:77
    func testDescribeL77() throws { XCTAssertFalse(try spec("b.second",index:"what b is for").advertisedValue.has("index")) }
    // TSCASE describe-tool.test.ts:86
    func testDescribeL86() throws { XCTAssertEqual(try D.advertised([spec("a.first"),spec("b.second",index:"what b is for")]).map { $0.tool.id },["a.first","b.second"]) }
    // TSCASE describe-tool.test.ts:101
    func testDescribeL101() throws { let value = try names(["b_second"]); XCTAssertEqual(value["tools"],.array([try spec("b.second",index:"what b is for").advertisedValue])); XCTAssertEqual(value["unknown"],.missing) }
    // TSCASE describe-tool.test.ts:115
    func testDescribeL115() throws { for name in ["b.second","b_second"] { XCTAssertEqual(try names([name])["tools"].elements?.first?["name"],.string("b_second")) } }
    // TSCASE describe-tool.test.ts:120
    func testDescribeL120() throws { XCTAssertEqual(try names(["a.first"])["tools"].elements?.first?["name"],.string("a_first")) }
    // TSCASE describe-tool.test.ts:126
    func testDescribeL126() throws { XCTAssertEqual(try names(["a.first","b.second"])["tools"].elements?.map { $0["name"] },[.string("a_first"),.string("b_second")]) }
    // TSCASE describe-tool.test.ts:131
    func testDescribeL131() throws { XCTAssertEqual(try answer(F.json(#"{"tools":"b.second"}"#),catalogue:simple())["tools"].elements?.first?["name"],.string("b_second")) }
    // TSCASE describe-tool.test.ts:135
    func testDescribeL135() throws { XCTAssertThrowsError(try names([])) { XCTAssertTrue($0 is BackendDeckCoreSecurityRefusal) }; XCTAssertThrowsError(try names(Array(repeating:"a.first",count:D.maxNames+1))) { XCTAssertTrue($0.localizedDescription.contains("at most")) } }
    // TSCASE describe-tool.test.ts:143
    func testDescribeL143() throws { XCTAssertEqual(try meta().advertisedValue["annotations"]["readOnlyHint"],.bool(true)) }
    // TSCASE describe-tool.test.ts:148
    func testDescribeL148() throws { let catalogue = try BackendDeckCoreCatalogueLiterals.builtins()+[meta()]; XCTAssertEqual(try names(["settings_write"],catalogue:catalogue)["tools"].elements?.first?["name"],.string("settings_write")) }
    // TSCASE describe-tool.test.ts:177
    func testDescribeL177() throws { let real = try names(["sessions_send"],catalogue:limited(),granted:grant),invented = try names(["sessions_teleport"],catalogue:limited(),granted:grant); XCTAssertEqual(real["tools"],.array([])); XCTAssertEqual(real["unknown"],.array([.string("no tool called sessions_send")])); XCTAssertEqual(real.compact,invented.compact.replacingOccurrences(of:"sessions_teleport",with:"sessions_send")) }
    // TSCASE describe-tool.test.ts:196
    func testDescribeL196() throws { let value = try names(["assets_ledger","tour_play"],catalogue:limited(),granted:grant); XCTAssertEqual(value["tools"].elements?.map { $0["name"] },[.string("assets_ledger")]); XCTAssertEqual(value["unknown"],.array([.string("no tool called tour_play")])) }
    // TSCASE describe-tool.test.ts:202
    func testDescribeL202() throws { let visible = try limited().filter { $0.visible(to:grant,caller:.local) },text = try XCTUnwrap(D.advertised(visible).first { $0.tool.id == D.id }?.tool.description); XCTAssertTrue(text.contains("assets_ledger — the resume ledger")); XCTAssertFalse(text.contains("tour_play")) }
    // TSCASE describe-tool.test.ts:213
    func testDescribeL213() throws { XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains(D.id)); XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains(D.wire)) }
    // TSCASE describe-tool.test.ts:229
    func testDescribeL229() throws { let held = try BackendDeckCoreCatalogueLiterals.builtins().filter { $0.index != nil }; XCTAssertGreaterThan(held.count,0); for spec in held { let line = try XCTUnwrap(spec.index); XCTAssertGreaterThan(line.utf16.count,60,spec.tool.id); XCTAssertLessThan(line.utf16.count,200,spec.tool.id); XCTAssertNotEqual(line,spec.title); XCTAssertTrue(line.trimmingCharacters(in:.whitespacesAndNewlines).hasSuffix(".")) } }
    // TSCASE describe-tool.test.ts:268
    func testDescribeL268() throws { let text = try XCTUnwrap(D.advertised(many()).first { $0.tool.id == D.id }?.tool.description); XCTAssertTrue(text.contains("browser — "+D.covers("browser")+" (\(D.inlineIndexMax) tools)")); for phrase in ["sessions — ","(1 tools)","machines — "] { XCTAssertTrue(text.contains(phrase)) }; for phrase in ["browser_thing0","block until the turn ends"] { XCTAssertFalse(text.contains(phrase)) } }
    // TSCASE describe-tool.test.ts:279
    func testDescribeL279() throws { let value = try answer(F.json(#"{"area":"sessions"}"#),catalogue:many()); XCTAssertEqual(value["area"],.string("sessions")); XCTAssertEqual(value["held"],try F.json(#"[{"name":"sessions_wait","tier":"read","does":"block until the turn ends"}]"#)); XCTAssertEqual(value["alreadyListed"],.array([.string("sessions_list")])); XCTAssertEqual(value["tools"],.missing) }
    // TSCASE describe-tool.test.ts:289
    func testDescribeL289() throws { let value = try answer(F.json(#"{"area":"machines","tools":["sessions_wait"]}"#),catalogue:many()); XCTAssertEqual(value["held"],try F.json(#"[{"name":"machines_look","tier":"read","does":"other computers"}]"#)); XCTAssertEqual(value["tools"].elements?.map { $0["name"] },[.string("sessions_wait")]) }
    // TSCASE describe-tool.test.ts:295
    func testDescribeL295() throws { XCTAssertEqual(try answer(F.json(#"{"area":"  Machines "}"#),catalogue:many())["area"],.string("machines")) }
    // TSCASE describe-tool.test.ts:299
    func testDescribeL299() throws { let catalogue = try many(),grant = Set([D.id,"sessions.wait"]+catalogue.filter { $0.tool.id.hasPrefix("browser.") }.map { $0.tool.id }); let hidden = try answer(F.json(#"{"area":"machines"}"#),catalogue:catalogue,granted:grant),invented = try answer(F.json(#"{"area":"teleports"}"#),catalogue:catalogue,granted:grant); XCTAssertEqual(hidden,try F.json(#"{"unknown":["no area called machines"]}"#)); XCTAssertEqual(hidden.compact,invented.compact.replacingOccurrences(of:"teleports",with:"machines")) }
    // TSCASE describe-tool.test.ts:307
    func testDescribeL307() throws { let catalogue = try many(),grant = Set([D.id,"sessions.wait"]+catalogue.filter { $0.tool.id.hasPrefix("browser.") }.map { $0.tool.id }),text = try XCTUnwrap(D.advertised(catalogue.filter { $0.visible(to:grant,caller:.local) }).first { $0.tool.id == D.id }?.tool.description); XCTAssertTrue(text.contains("browser — ")); XCTAssertTrue(text.contains("sessions — ")); XCTAssertFalse(text.contains("machines — ")) }
    // TSCASE describe-tool.test.ts:316
    func testDescribeL316() throws { let text = try XCTUnwrap(D.advertised([spec("sessions.list"),spec("sessions.wait",index:"block until the turn ends"),meta()]).first { $0.tool.id == D.id }?.tool.description); XCTAssertTrue(text.contains("sessions_wait — block until the turn ends")); XCTAssertFalse(text.contains("sessions — ")) }
    // TSCASE describe-tool.test.ts:323
    func testDescribeL323() throws { XCTAssertThrowsError(try answer(.object([]),catalogue:many())) { XCTAssertTrue($0.localizedDescription.contains("name an area")) } }
    // TSCASE describe-tool.test.ts:328
    func testDescribeL328() throws { XCTAssertEqual(D.areaOf("sessions.wait"),"sessions"); XCTAssertEqual(D.areaOf("chats.read"),"sessions"); XCTAssertEqual(D.areaOf("teleport.go"),"teleport") }
}
