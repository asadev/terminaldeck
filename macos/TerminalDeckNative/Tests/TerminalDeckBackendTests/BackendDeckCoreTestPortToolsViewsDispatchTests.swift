import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckCoreTestPortToolsViewsDispatchTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private typealias Rig = BackendDeckCoreTestPortToolsCoreRig
    // TSCASE settings-write-visibility.test.ts:102
    func testSettingsVisibilityL102FullValuesPushedAndOnScreen() async throws {
        let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at:rig.directory) }
        let result = await rig.control.call(name:"settings_write",arguments:try F.json(#"{"scope":"preferences","patch":{"theme":"light"}}"#))
        XCTAssertTrue(result.ok); XCTAssertEqual(result.value["preferences"]["theme"],.string("light")); XCTAssertEqual(rig.surface.pushed(),[try F.json(#"{"scope":"preferences","values":{"theme":"light"}}"#)]); XCTAssertTrue(result.value["appliedToWindow"].string?.contains("on screen") == true); XCTAssertFalse(result.value["appliedToWindow"].string?.contains("next started") == true)
    }
    // TSCASE settings-write-visibility.test.ts:124
    func testSettingsVisibilityL124NoWindowSaysNextLaunch() async throws {
        let rig = try await Rig.make(window:false); defer { try? FileManager.default.removeItem(at:rig.directory) }
        let result = await rig.control.call(name:"settings_write",arguments:try F.json(#"{"scope":"preferences","patch":{"theme":"light"}}"#))
        XCTAssertTrue(result.ok); XCTAssertEqual(result.value["preferences"]["theme"],.string("light")); XCTAssertTrue(rig.surface.pushed().isEmpty); XCTAssertTrue(result.value["appliedToWindow"].string?.contains("next started") == true); XCTAssertFalse(result.value["appliedToWindow"].string?.contains("on screen") == true)
    }
    // TSCASE settings-write-visibility.test.ts:146
    func testSettingsVisibilityL146SettingsOwnScopePushed() async throws { let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at:rig.directory) }; _ = await rig.control.call(name:"settings_write",arguments:try F.json(#"{"scope":"settings","patch":{"appearance.density":"compact"}}"#)); XCTAssertEqual(rig.surface.pushed().map { $0["scope"] },[.string("settings")]) }
    // TSCASE settings-write-visibility.test.ts:158
    func testSettingsVisibilityL158FactsNeverImperatives() async throws { let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at:rig.directory) }; let result = await rig.control.call(name:"settings_write",arguments:try F.json(#"{"scope":"preferences","patch":{"theme":"light"}}"#)),said = try XCTUnwrap(result.value["appliedToWindow"].string).lowercased(); for imperative in ["say ","tell them","do not ","you should","make sure"] { XCTAssertFalse(said.contains(imperative),imperative) } }
    // TSCASE run-tool.test.ts:44
    func testRunL44OnlyNamedToolRowRecorded() async throws { let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at:rig.directory) }; let result = await rig.control.call(name:"tools.run",arguments:try F.json(#"{"name":"sessions_list","arguments":{}}"#)); XCTAssertTrue(result.ok); XCTAssertEqual(result.row["tool"],.string("sessions.list")); let rows = await rig.log.tail(10); XCTAssertEqual(rows.map { $0["tool"] },[.string("sessions.list")]) }
    // TSCASE run-tool.test.ts:52
    func testRunL52BothSpellingsAndStringArguments() async throws { let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at:rig.directory) }; let project = await rig.control.call(name:"tools_run",arguments:try F.json(#"{"name":"projects.list"}"#)),session = await rig.control.call(name:"tools.run",arguments:try F.json(#"{"name":"sessions_list","arguments":"{}"}"#)); XCTAssertEqual(project.row["tool"],.string("projects.list")); XCTAssertTrue(session.ok) }
    // TSCASE run-tool.test.ts:57
    func testRunL57HiddenAndMissingHaveSameRowShapeAndNoSpawn() async throws {
        let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at:rig.directory) }; let options = BackendDeckCoreSecurityCallOptions(granted:["tools.run","sessions.list","projects.list"])
        let hidden = await rig.control.call(name:"tools.run",arguments:try F.json(#"{"name":"sessions_start","arguments":{"cwd":"/work/api"}}"#),options:options),missing = await rig.control.call(name:"tools.run",arguments:try F.json(#"{"name":"sessions_teleport","arguments":{"cwd":"/work/api"}}"#),options:options)
        XCTAssertFalse(hidden.ok); XCTAssertEqual(hidden.error,"no tool called sessions_start"); XCTAssertEqual(missing.error,"no tool called sessions_teleport")
        func stripped(_ row: NativeRPCValue) -> NativeRPCValue { ["id","at","ms","args","detail","error"].reduce(row) { $0.removing($1) } }
        XCTAssertEqual(stripped(hidden.row),stripped(missing.row)); XCTAssertEqual(hidden.row["tool"],.string("tools.run")); XCTAssertEqual(hidden.row["args"],try F.json(#"{"name":"sessions_start"}"#)); XCTAssertTrue(rig.surface.starts().isEmpty)
    }
    // TSCASE run-tool.test.ts:72
    func testRunL72RefusedInnerArgumentsNeverLogged() async throws { let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at:rig.directory) }; let result = await rig.control.call(name:"tools.run",arguments:try F.json(#"{"name":"nothing_here","arguments":{"password":"hunter2","value":"typed-into-a-page"}}"#)); XCTAssertFalse(result.ok); XCTAssertFalse(result.row.compact.contains("typed-into-a-page")) }
    // TSCASE run-tool.test.ts:82
    func testRunL82InnerTierEnforcedAndSettingsUntouched() async throws { let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at:rig.directory) }; let caller = BackendDeckCoreSecurityCaller(kind:.key,tiers:[.read],keyID:"look",keyName:"x",askFirst:false),result = await rig.control.call(name:"tools.run",arguments:try F.json(#"{"name":"settings_write","arguments":{"scope":"settings","patch":{"appearance.density":"compact"}}}"#),options:.init(caller:caller)); XCTAssertEqual(result.refusal,.notGranted); XCTAssertEqual(result.row["tool"],.string("settings.write")); XCTAssertEqual(rig.surface.readSettings()["settings"]["appearance.density"],.string("comfortable")) }
    // TSCASE run-tool.test.ts:95
    func testRunL95CannotRunItself() async throws { let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at:rig.directory) }; let result = await rig.control.call(name:"tools.run",arguments:try F.json(#"{"name":"tools_run","arguments":{"name":"sessions_list"}}"#)); XCTAssertFalse(result.ok); XCTAssertTrue(result.error?.contains("runs other tools") == true) }
    // TSCASE run-tool.test.ts:101
    func testRunL101NameRequired() async throws { let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at:rig.directory) }; let result = await rig.control.call(name:"tools.run",arguments:.object([])); XCTAssertFalse(result.ok); XCTAssertTrue(result.error?.contains("name is required") == true) }
    // TSCASE run-tool.test.ts:109
    func testRunL109CopilotListingUnchanged() throws { let source = try BackendDeckCoreCatalogueDescribe.tools(catalogue:{ [] }).metadata; XCTAssertFalse(try BackendDeckCoreCatalogueDescribe.advertised(source).contains { $0.tool.id == "tools.run" }); XCTAssertTrue(try BackendDeckCoreCatalogueDescribe.advertised(source,run:true).contains { $0.tool.id == "tools.run" }) }
    private func wireListing(_ caller: BackendDeckCoreSecurityCaller) async throws -> NativeRPCValue {
        let rig = try await Rig.make(); defer { try? FileManager.default.removeItem(at:rig.directory) }
        let metadata = try BackendDeckCoreCatalogueLiterals.builtins()+BackendDeckCoreCatalogueDescribe.tools(catalogue:{ [] }).metadata
        let server = BackendDeckCoreSecurityServer(control:rig.control,ownPorts:.init(),listing:{ _,caller,granted in try BackendDeckCoreCatalogueDescribe.wireListing(metadata:metadata,caller:caller,granted:granted) })
        let response = await server.serve(parsed:try F.json(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#),headers:["content-type":"application/json","accept":"application/json, text/event-stream"],grant:.init(attended:true,caller:{ caller }),cancellation:.init())
        XCTAssertEqual(response.status,200); return try NativeRPCValue.parseJSON(response.body)["result"]
    }
    // TSCASE run-tool.test.ts:115
    func testRunL115WireHintsTruthfulForLookAndFullKeys() async throws { let look = try await wireListing(.init(kind:.key,tiers:[.read],keyID:"look",keyName:"t")),full = try await wireListing(.init(kind:.key,tiers:[.read,.act,.alter],keyID:"full",keyName:"t")); let a = try XCTUnwrap(look["tools"].elements?.first { $0["name"].string == "tools_run" }),b = try XCTUnwrap(full["tools"].elements?.first { $0["name"].string == "tools_run" }); XCTAssertEqual(a["annotations"]["readOnlyHint"],.bool(true)); XCTAssertEqual(a["annotations"]["destructiveHint"],.bool(false)); XCTAssertEqual(b["annotations"]["readOnlyHint"],.bool(false)); XCTAssertEqual(b["annotations"]["destructiveHint"],.bool(true)) }
    // TSCASE run-tool.test.ts:137
    func testRunL137CopilotWireListingHasNoWrapper() async throws { let result = try await wireListing(.local); XCTAssertFalse(result["tools"].elements?.contains { $0["name"].string == "tools_run" } == true) }
    // TSCASE run-tool.test.ts:153
    func testRunL153AdvertisedWrapperNameAndLocalCallerKind() throws { let tools = try BackendDeckCoreCatalogueDescribe.tools(catalogue:{ [] }).metadata,run = try XCTUnwrap(tools.first { $0.tool.id == "tools.run" }); XCTAssertEqual(run.advertisedValue["name"],.string("tools_run")); XCTAssertEqual(BackendDeckCoreSecurityCaller.local.kind,.local) }
    // TSCASE coverage-tool.test.ts:15
    func testCoverageL15CompleteSourceTablesIncludingWindow() { let source = BackendDeckCoreCatalogueCoverageLiterals.sourceRows; XCTAssertEqual(BackendDeckCoreCatalogueCoverage.rows.count,source.count); XCTAssertEqual(Set(source.map { $0.area+":"+$0.action }).count,source.count) }
    // TSCASE coverage-tool.test.ts:23
    func testCoverageL23CountsWithoutTableDump() throws { let value = try BackendDeckCoreCatalogueCoverage.answer(.object([])).value; XCTAssertEqual(value["counts"].fields?.map(\.key),["sessions","machines","agents","browser","devices","fixed","memory","window"]); XCTAssertEqual(value["counts"]["sessions"]["actions"].number,Double(BackendDeckCoreCatalogueCoverage.rows.filter { $0.area == "sessions" }.count)); XCTAssertEqual(value["rows"],.missing) }
    // TSCASE coverage-tool.test.ts:33
    func testCoverageL33PlainWordsIncludeSkipReasons() { let rows = BackendDeckCoreCatalogueCoverage.rows; XCTAssertTrue(BackendDeckCoreCatalogueCoverage.matching(rows,query:"held retry").contains { $0.action == "session:held-retry" }); let answering = BackendDeckCoreCatalogueCoverage.matching(rows,query:"approve its own request"); XCTAssertTrue(answering.contains { $0.action == "deck-control:consent-respond" }); XCTAssertTrue(answering.allSatisfy { $0.skip != nil }) }
    // TSCASE coverage-tool.test.ts:42
    func testCoverageL42OnlySkippedRowsHaveReasonsAndNoTools() throws { let value = try BackendDeckCoreCatalogueCoverage.answer(F.json(#"{"skippedOnly":true,"area":"sessions"}"#)).value; XCTAssertGreaterThan(value["matched"].number ?? 0,0); XCTAssertTrue((value["rows"].elements ?? []).allSatisfy { $0["skip"].string != nil && $0["tools"] == .missing }) }
    // TSCASE coverage-tool.test.ts:49
    func testCoverageL49SixtyRowCapAndNarrowNote() throws { let value = try BackendDeckCoreCatalogueCoverage.answer(F.json(#"{"area":"browser","query":"browser"}"#)).value; XCTAssertLessThanOrEqual(value["rows"].elements?.count ?? 0,BackendDeckCoreCatalogueCoverage.maxRows); if value["matched"].number ?? 0 > Double(BackendDeckCoreCatalogueCoverage.maxRows) { XCTAssertTrue(value["note"].string?.contains("narrow") == true) } }
    // TSCASE coverage-tool.test.ts:56
    func testCoverageL56ReadHeldBehindDescribe() throws { let value = try XCTUnwrap(BackendDeckCoreCatalogueCoverage.tools().metadata.first); XCTAssertEqual(value.tool.tier,.read); XCTAssertFalse(value.index?.isEmpty != false) }
    struct Window: BackendDeckCoreCatalogueWhereWindow { let value: NativeRPCValue; func read() -> NativeRPCValue { value } }
    struct Page: BackendDeckCoreCatalogueWherePage { let secret: Bool; let url: String; func status() -> NativeRPCValue { F.object([("url",.string(url))]) }; func textAt(selector: String?,limit: Int) -> NativeRPCValue { XCTAssertNil(selector); XCTAssertEqual(limit,BackendDeckCoreCatalogueWhere.pageTextChars); return F.object([("found",.bool(true)),("secret",.bool(secret)),("text",.string(secret ? "" : "Orders — 3 failed")),("truncated",.bool(false))]) } }
    private var window: NativeRPCValue { try! F.json(#"{"title":"Fix the parser","sessionId":"s1","pane":"terminal","copilotFront":false,"driving":true,"openSessions":["s1","s2"]}"#) }
    private func whereRig(answer: NativeRPCValue,page: (any BackendDeckCoreCatalogueWherePage)? = nil) async throws -> Rig { let bundle = try BackendDeckCoreCatalogueWhere.tools(dependencies:.init(window:Window(value:answer),page:{ page })); return try await Rig.make(extra:bundle.policies) }
    // TSCASE where-tool.test.ts:57
    func testWhereL57WindowFactsReadThroughDispatcher() async throws { let rig = try await whereRig(answer:window); defer { try? FileManager.default.removeItem(at:rig.directory) }; let result = await rig.control.call(name:"app.where",arguments:.object([])); XCTAssertTrue(result.ok); XCTAssertEqual(result.value["window"]["inFront"],.string("Fix the parser")); XCTAssertEqual(result.value["window"]["pane"],.string("terminal")); XCTAssertEqual(result.value["window"]["sessionId"],.string("s1")); XCTAssertEqual(result.value["window"]["driving"],.bool(true)) }
    // TSCASE where-tool.test.ts:67
    func testWhereL67MissingWindowIsNotFault() async throws { let rig = try await whereRig(answer:.missing); defer { try? FileManager.default.removeItem(at:rig.directory) }; let result = await rig.control.call(name:"app.where",arguments:.object([])); XCTAssertTrue(result.ok); XCTAssertEqual(result.value["window"],.null); XCTAssertTrue(result.value["note"].string?.contains("no window") == true) }
    // TSCASE where-tool.test.ts:81
    func testWhereL81DrivenPageAddressAndWholePageText() async throws { let rig = try await whereRig(answer:window,page:Page(secret:false,url:"https://example.test/orders")); defer { try? FileManager.default.removeItem(at:rig.directory) }; let result = await rig.control.call(name:"app.where",arguments:.object([])); XCTAssertEqual(result.value["page"]["url"],.string("https://example.test/orders")); XCTAssertEqual(result.value["page"]["text"],.string("Orders — 3 failed")) }
    // TSCASE where-tool.test.ts:97
    func testWhereL97CredentialPageTextWithheld() async throws { let rig = try await whereRig(answer:window,page:Page(secret:true,url:"https://bank.test/login")); defer { try? FileManager.default.removeItem(at:rig.directory) }; let result = await rig.control.call(name:"app.where",arguments:.object([])); XCTAssertEqual(result.value["page"]["url"],.string("https://bank.test/login")); XCTAssertEqual(result.value["page"]["text"],.null); XCTAssertTrue(result.value["page"]["why"].string?.contains("credential") == true) }
    // TSCASE where-tool.test.ts:115
    func testWhereL115NoSiblingPageGuessed() async throws { let rig = try await whereRig(answer:window); defer { try? FileManager.default.removeItem(at:rig.directory) }; let result = await rig.control.call(name:"app.where",arguments:.object([])); XCTAssertEqual(result.value["page"],.null) }
    // TSCASE where-tool.test.ts:124
    func testWhereL124PairedReadDoesNotDrive() async throws { let rig = try await whereRig(answer:window); defer { try? FileManager.default.removeItem(at:rig.directory) }; let result = await rig.control.call(name:"app.where",arguments:.object([]),options:.init(caller:.init(kind:.remote,tiers:[.read],deviceID:"phone-1"))); XCTAssertTrue(result.ok) }
    // TSCASE where-tool.test.ts:141
    func testWhereL141UnpublishedReaderExpressionIsOptional() { XCTAssertTrue(BackendDeckCoreCatalogueWhere.sourceWindowCall.contains("?.()")); XCTAssertTrue(BackendDeckCoreCatalogueWhere.sourceWindowCall.contains("?? null")) }
    // TSCASE where-tool.test.ts:154
    func testWhereL154ExactNarrowedShape() throws { XCTAssertEqual(BackendDeckCoreCatalogueWhere.readWhere(try F.json(#"{"title":"api","sessionId":42,"pane":"split"}"#)),try F.json(#"{"title":"api","sessionId":null,"pane":null,"copilotFront":false,"driving":false,"openSessions":[]}"#)) }
    // TSCASE where-tool.test.ts:165
    func testWhereL165NonanswersRejected() { for value in [NativeRPCValue.null,.string("somewhere"),.object([])] { XCTAssertNil(BackendDeckCoreCatalogueWhere.readWhere(value)) } }
}
