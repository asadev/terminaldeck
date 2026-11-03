import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor BackendDeckToolsAppPortExtractionFake: BackendDeckToolsAppExtractionService {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private var recipes: [NativeRPCValue], address: String?, result: NativeRPCValue, runs = 0
    init(address: String? = "https://portal.example/list", empty: Bool = false, stated: Double? = nil, onPage: Int = 1, returned: Int = 1) {
        self.address = address
        recipes = empty ? [] : [try! F.json(#"{"id":"demo","name":"Demo","summary":"A recipe for the tests.","version":"1.0.0","grants":["page-read"],"origins":["portal.example"],"fields":[{"name":"headline","selector":"h1","op":"text"}],"rows":{"selector":".row","fields":[{"name":"price","selector":".p","op":"text"}]}}"#)]
        result = F.object([("url", .string("https://portal.example/list")), ("title", .string("Listings")), ("fields", .object([.init("headline", .string("Listings"))])), ("rows", .array([.object([.init("price", .string("1"))])])), ("rowsOnPage", .number(Double(onPage))), ("rowsReturned", .number(Double(returned))), ("counts", .object([])), ("stated", stated.map(NativeRPCValue.number) ?? .null), ("next", .null)])
    }
    func installed() async throws -> [NativeRPCValue] { recipes }
    func origin(_ caller: BackendMCPCallContext, arguments: NativeRPCValue) async throws -> String? { address }
    func extract(_ caller: BackendMCPCallContext, arguments: NativeRPCValue, recipe: NativeRPCValue, limit: Int?) async throws -> NativeRPCValue { runs += 1; return result }
    func runCount() -> Int { runs }
}
@MainActor
final class BackendDeckToolsAppPortStoreTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private func tools(_ fake: BackendDeckToolsAppPortExtractionFake, audit: BackendDeckCoreTestPortToolsAudit = .init()) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppExtraction.definitions(service: fake, access: F.access(audit)) }
    // TSCASE store-tools.test.ts:121
    func testInstalledListingNamesReadsHostsAndPerRowFields() async throws { let fake = BackendDeckToolsAppPortExtractionFake(), value = try F.value(await F.call(tools(fake), "browser.extract")), first = value["tools"].elements![0]; XCTAssertEqual(first["tool"], .string("demo")); XCTAssertEqual(first["runsOn"], .string("portal.example")); XCTAssertTrue(first["fields"].elements!.contains(.string("headline"))); XCTAssertTrue(first["fields"].elements!.contains(.string("price (per row)"))) }
    // TSCASE store-tools.test.ts:132
    func testEmptyStoreNamesActualInstallationPlace() async throws { let value = try F.value(await F.call(tools(.init(empty: true)), "browser.extract")); XCTAssertEqual(value["tools"], .array([])); XCTAssertTrue(value["note"].string!.contains(BackendDeckToolsAppExtraction.storePlace)); XCTAssertEqual(value["empty"], .bool(true)); XCTAssertFalse(value["emptyReason"].string!.isEmpty) }
    // TSCASE store-tools.test.ts:142
    func testMissingToolNamesInstallationPlace() async throws { F.error(try await F.call(tools(.init(empty: true)), "browser.extract", #"{"tool":"whatever"}"#), contains: BackendDeckToolsAppExtraction.storePlace) }
    // TSCASE store-tools.test.ts:149
    func testMissingToolNamesInstalledAlternatives() async throws { F.error(try await F.call(tools(.init()), "browser.extract", #"{"tool":"whatever"}"#), contains: "These are: demo.") }
    // TSCASE store-tools.test.ts:158
    func testRecipeRunsOnlyInsideItsHosts() async throws { let fake = BackendDeckToolsAppPortExtractionFake(); let reply = try await F.call(tools(fake), "browser.extract", #"{"tool":"demo"}"#); XCTAssertFalse(reply.isError); let runs = await fake.runCount(); XCTAssertEqual(runs, 1) }
    // TSCASE store-tools.test.ts:166
    func testOtherHostRefusedBeforeAnyExtraction() async throws { let fake = BackendDeckToolsAppPortExtractionFake(address: "https://bank.example"), reply = try await F.call(tools(fake), "browser.extract", #"{"tool":"demo"}"#); F.error(reply, contains: "portal.example"); let runs = await fake.runCount(); XCTAssertEqual(runs, 0) }
    // TSCASE store-tools.test.ts:176
    func testUnknownPageAddressRefusedBeforeExtraction() async throws { let fake = BackendDeckToolsAppPortExtractionFake(address: nil), reply = try await F.call(tools(fake), "browser.extract", #"{"tool":"demo"}"#); XCTAssertTrue(reply.isError); let runs = await fake.runCount(); XCTAssertEqual(runs, 0) }
    // TSCASE store-tools.test.ts:186
    func testMatchingPageAndAnswerHaveNoWarning() { XCTAssertEqual(BackendDeckToolsAppExtraction.completenessNote(stated: 10, onPage: 10, returned: 10), ""); XCTAssertEqual(BackendDeckToolsAppExtraction.completenessNote(stated: nil, onPage: 3, returned: 3), "") }
    // TSCASE store-tools.test.ts:191
    func testStatedLargerTotalSaysReadIsPartial() { let note = BackendDeckToolsAppExtraction.completenessNote(stated: 1248, onPage: 200, returned: 200); XCTAssertTrue(note.contains("1248")); XCTAssertTrue(note.contains("not the whole set")) }
    // TSCASE store-tools.test.ts:197
    func testLimitWarningWithoutStatedTotal() { XCTAssertTrue(BackendDeckToolsAppExtraction.completenessNote(stated: nil, onPage: 500, returned: 200).contains("limit")) }
    // TSCASE store-tools.test.ts:202 — helper result additionally checked by original 19 tests
    func testImpossibleStatedTotalIsNotBelieved() { XCTAssertNil(BackendDeckToolsAppExtraction.complete(1, returned: 20)); XCTAssertNil(BackendDeckToolsAppExtraction.trustedStated(1, returned: 20)); XCTAssertTrue(BackendDeckToolsAppExtraction.completenessNote(stated: 1, onPage: 20, returned: 20).contains("not believed")) }
    // TSCASE store-tools.test.ts:225 — old helper test covers count-shape expectations
    // TSCASE store-tools.test.ts:227
    func testOutputCarriesCountsAndFalseCompleteness() async throws { let value = try F.value(await F.call(tools(.init(stated: 1248, onPage: 200, returned: 200)), "browser.extract", #"{"tool":"demo"}"#)); XCTAssertEqual(value["stated"], .number(1248)); XCTAssertEqual(value["complete"], .bool(false)); XCTAssertTrue(value["note"].string!.contains("1248")) }
    // TSCASE store-tools.test.ts:239
    func testNoStatedTotalKeepsCompletenessNull() async throws { let value = try F.value(await F.call(tools(.init()), "browser.extract", #"{"tool":"demo"}"#)); XCTAssertEqual(value["complete"], .null) }
    // TSCASE store-tools.test.ts:245
    func testLogKeepsCountsAndNeverThePayload() async throws { let audit = BackendDeckCoreTestPortToolsAudit(); _ = try await F.call(tools(.init(stated: 9, onPage: 9, returned: 4), audit: audit), "browser.extract", #"{"tool":"demo"}"#); let records = await audit.completed(), summary = records[0]["summary"]; XCTAssertEqual(summary["tool"], .string("demo")); XCTAssertEqual(summary["rows"], .number(4)); XCTAssertEqual(summary["onPage"], .number(9)); XCTAssertEqual(summary["stated"], .number(9)); XCTAssertEqual(summary["short"], .bool(true)); XCTAssertFalse(NativeRPCValue.array(records).compact.contains("Listings")) }
    // TSCASE store-tools.test.ts:259
    func testOneSessionGrantDoesNotExpandWithInstalledReaders() { let names = BackendDeckToolsSessionsGrants.ordinary; XCTAssertTrue(names.contains("browser.extract")); XCTAssertTrue(names.contains("browser_extract")); XCTAssertFalse(names.contains("demo")) }
    // TSCASE store-tools.test.ts:269
    func testExtractionKeepsReadTier() throws { let tool = try XCTUnwrap(tools(.init()).first); XCTAssertEqual(tool.spec.tier, .read) }
    // TSCASE store-tools.test.ts:274
    func testListingDoesNotRunAndKeepsWhatRecipeReads() async throws { let fake = BackendDeckToolsAppPortExtractionFake(), value = try F.value(await F.call(tools(fake), "browser.extract")), first = value["tools"].elements![0], runs = await fake.runCount(); XCTAssertEqual(first["reads"], .string("A recipe for the tests.")); XCTAssertEqual(first["runsOn"], .string("portal.example")); XCTAssertEqual(runs, 0) }
}

extension BackendDeckToolsAppPortStoreTests {
    func testRowRecipeCountsTheRowsOnPage() throws {
        let result = try F.json(#"{"rowsOnPage":40,"rowsReturned":20,"counts":{"images":{"matched":240,"returned":200},"alts":{"matched":12,"returned":12}}}"#)
        XCTAssertEqual(BackendDeckToolsAppExtraction.collected(hasRows: true, result: result).onPage, 40)
    }
}
