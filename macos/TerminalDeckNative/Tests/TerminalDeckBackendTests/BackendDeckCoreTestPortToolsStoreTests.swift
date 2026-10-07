import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor BackendDeckCoreTestPortToolsExtractionFake: BackendDeckToolsAppExtractionService {
    nonisolated static let recipe = try! BackendDeckCoreTestPortToolsFixture.json(#"{"id":"demo","name":"Demo","summary":"A recipe for the tests.","version":"1.0.0","grants":["page-read"],"origins":["portal.example"],"fields":[{"name":"headline","selector":"h1","op":"text"}],"rows":{"selector":".row","fields":[{"name":"price","selector":".p","op":"text"}]},"stated":{"name":"total","selector":".count","op":"number"}}"#)
    let address: String?
    let recipes: [NativeRPCValue]
    let onPage: Int,returned: Int,stated: Double?
    private var plans: [NativeRPCValue] = []
    init(origin: String? = "https://portal.example",empty: Bool = false,onPage: Int = 1,returned: Int = 1,stated: Double? = nil) { address = origin; recipes = empty ? [] : [Self.recipe]; self.onPage = onPage; self.returned = returned; self.stated = stated }
    func installed() -> [NativeRPCValue] { recipes }
    func origin(_ caller: BackendMCPCallContext,arguments: NativeRPCValue) -> String? { address }
    func extract(_ caller: BackendMCPCallContext,arguments: NativeRPCValue,recipe: NativeRPCValue,limit: Int?) -> NativeRPCValue { plans.append(recipe); return BackendDeckCoreTestPortToolsFixture.object([("url",.string("https://portal.example/list")),("title",.string("Listings")),("fields",BackendDeckCoreTestPortToolsFixture.object([("headline",.string("Listings"))])),("rows",.array([BackendDeckCoreTestPortToolsFixture.object([("price",.string("1"))])])),("rowsOnPage",.number(Double(onPage))),("rowsReturned",.number(Double(returned))),("counts",.object([])),("stated",stated.map(NativeRPCValue.number) ?? .null),("next",.null)]) }
    func planCount() -> Int { plans.count }
}

@MainActor
final class BackendDeckCoreTestPortToolsStoreTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private typealias E = BackendDeckToolsAppExtraction
    private func tools(_ fake: BackendDeckCoreTestPortToolsExtractionFake,audit: BackendDeckCoreTestPortToolsAudit = .init()) throws -> [BackendDeckToolsDefinition] { try E.definitions(service:fake,access:F.access(audit)) }
    // TSCASE store-tools.test.ts:120
    func testStoreL120InstalledFieldsAndBoundHost() async throws { let value = try F.value(await F.call(tools(.init()),"browser.extract")); let first = try XCTUnwrap(value["tools"].elements?.first); XCTAssertEqual(first["tool"],.string("demo")); XCTAssertEqual(first["runsOn"],.string("portal.example")); XCTAssertTrue(first["fields"].elements?.contains(.string("headline")) == true); XCTAssertTrue(first["fields"].elements?.contains(.string("price (per row)")) == true) }
    // TSCASE store-tools.test.ts:131
    func testStoreL131EmptyShelfNamesActualInstallDoor() async throws { let value = try F.value(await F.call(tools(.init(empty:true)),"browser.extract")); XCTAssertEqual(value["tools"].elements?.count,0); XCTAssertTrue(value["note"].string?.contains(E.storePlace) == true) }
    // TSCASE store-tools.test.ts:142
    func testStoreL142UninstalledNameRefusedWithInstallDoor() async throws { F.error(try await F.call(tools(.init(empty:true)),"browser.extract",#"{"tool":"whatever"}"#),contains:E.storePlace) }
    // TSCASE store-tools.test.ts:150
    func testStoreL150UnknownNamesWhichRecipeExists() async throws { F.error(try await F.call(tools(.init()),"browser.extract",#"{"tool":"whatever"}"#),contains:"demo") }
    // TSCASE store-tools.test.ts:159
    func testStoreL159OwnHostRunsOnce() async throws { let fake = BackendDeckCoreTestPortToolsExtractionFake(); _ = try F.value(await F.call(tools(fake),"browser.extract",#"{"tool":"demo"}"#)); let plans = await fake.planCount(); XCTAssertEqual(plans,1) }
    // TSCASE store-tools.test.ts:167
    func testStoreL167OtherHostRefusedBeforeExtractor() async throws { let fake = BackendDeckCoreTestPortToolsExtractionFake(origin:"https://bank.example"); F.error(try await F.call(tools(fake),"browser.extract",#"{"tool":"demo"}"#),contains:"portal.example"); let plans = await fake.planCount(); XCTAssertEqual(plans,0) }
    // TSCASE store-tools.test.ts:177
    func testStoreL177UnreadableAddressRefusedBeforeExtractor() async throws { let fake = BackendDeckCoreTestPortToolsExtractionFake(origin:nil); let reply = try await F.call(tools(fake),"browser.extract",#"{"tool":"demo"}"#); XCTAssertTrue(reply.isError); let plans = await fake.planCount(); XCTAssertEqual(plans,0) }
    // TSCASE store-tools.test.ts:187
    func testStoreL187AgreementHasNoCompletenessWarning() { XCTAssertEqual(E.completenessNote(stated:10,onPage:10,returned:10),""); XCTAssertEqual(E.completenessNote(stated:nil,onPage:3,returned:3),"") }
    // TSCASE store-tools.test.ts:192
    func testStoreL192PageTotalLargerNamesPartialSet() { let note = E.completenessNote(stated:1248,onPage:200,returned:200); XCTAssertTrue(note.contains("1248")); XCTAssertTrue(note.contains("not the whole set")) }
    // TSCASE store-tools.test.ts:198
    func testStoreL198LimitWarningSeparateFromPageShortfall() { XCTAssertTrue(E.completenessNote(stated:nil,onPage:500,returned:200).contains("limit")) }
    // TSCASE store-tools.test.ts:203
    func testStoreL203SmallerStatedTotalNeverTrustedAsComplete() { XCTAssertNil(E.complete(1,returned:20)); XCTAssertNil(E.trustedStated(1,returned:20)); XCTAssertTrue(E.completenessNote(stated:1,onPage:20,returned:20).contains("not believed")) }
    // TSCASE store-tools.test.ts:215
    func testStoreL215RowsAndListFieldsUseTheirOwnCounts() throws { let result = try F.json(#"{"rowsOnPage":40,"rowsReturned":20,"counts":{"images":{"matched":240,"returned":200},"alts":{"matched":12,"returned":12}}}"#); let rows = E.collected(hasRows:true,result:result),fields = E.collected(hasRows:false,result:result); XCTAssertEqual(rows.onPage,40); XCTAssertEqual(rows.returned,20); XCTAssertEqual(fields.onPage,240); XCTAssertEqual(fields.returned,200) }
    // TSCASE store-tools.test.ts:232
    func testStoreL232StatedAndThreeValuedCompletenessInReply() async throws { let value = try F.value(await F.call(tools(.init(onPage:200,returned:200,stated:1248)),"browser.extract",#"{"tool":"demo"}"#)); XCTAssertEqual(value["stated"],.number(1248)); XCTAssertEqual(value["complete"],.bool(false)); XCTAssertTrue(value["note"].string?.contains("1248") == true) }
    // TSCASE store-tools.test.ts:245
    func testStoreL245NoTotalLeavesCompleteNull() async throws { let value = try F.value(await F.call(tools(.init(stated:nil)),"browser.extract",#"{"tool":"demo"}"#)); XCTAssertEqual(value["complete"],.null) }
    // TSCASE store-tools.test.ts:251
    func testStoreL251LogOnlyCountsNeverExtractedPayload() async throws { let audit = BackendDeckCoreTestPortToolsAudit(); _ = try await F.call(tools(.init(onPage:9,returned:4,stated:9),audit:audit),"browser.extract",#"{"tool":"demo"}"#); let rows = await audit.completed(),summary = rows[0]["summary"]; XCTAssertEqual(summary["tool"],.string("demo")); XCTAssertEqual(summary["rows"],.number(4)); XCTAssertEqual(summary["onPage"],.number(9)); XCTAssertEqual(summary["stated"],.number(9)); XCTAssertEqual(summary["short"],.bool(true)); XCTAssertFalse(rows[0].compact.contains("Listings")) }
    // TSCASE store-tools.test.ts:260
    func testStoreL260OneWrittenDownGrantRegardlessOfInstalledNames() { XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains("browser.extract")); XCTAssertTrue(BackendDeckToolsSessionsGrants.ordinary.contains("browser_extract")); XCTAssertFalse(BackendDeckToolsSessionsGrants.ordinary.contains(BackendDeckCoreTestPortToolsExtractionFake.recipe["id"].string!)) }
    // TSCASE store-tools.test.ts:270
    func testStoreL270ExtractionReadTier() throws { XCTAssertEqual(try tools(.init(origin:nil))[0].spec.tier,.read) }
    // TSCASE store-tools.test.ts:275
    func testStoreL275WhatItReadsAndWhereListedWithoutRunning() { let value = E.listInstalled([BackendDeckCoreTestPortToolsExtractionFake.recipe]); XCTAssertEqual(value[0]["reads"],.string("A recipe for the tests.")); XCTAssertEqual(value[0]["runsOn"],.string("portal.example")) }
}
