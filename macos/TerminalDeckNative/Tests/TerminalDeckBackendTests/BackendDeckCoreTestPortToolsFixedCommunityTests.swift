import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor BackendDeckCoreTestPortToolsFixedFake: BackendDeckToolsAppFixedService {
    nonisolated static let result = try! BackendDeckCoreTestPortToolsFixture.json(#"{"runId":"r1","at":"2026-10-04T00:00:00.000Z","durationMs":3000,"verdict":"differences","headline":"1 difference nobody asked for.","against":"1.0.0","checked":"1.0.0 with uncommitted changes","differences":[{"id":"f-1","title":"The total changed.","needsPerson":true,"needsPersonWhy":"It touches money.","count":1,"changes":[{"what":"What it printed.","before":"Total: 10.00","after":"Total: 10.0","kind":"changed"}],"more":0,"journeys":["greet --help"]}],"unchanged":"Everything else it looked at — 11 things — is unchanged.","notChecked":null,"unsteady":0,"detail":"The engine’s paragraph.","gaps":[],"pictures":{"f-1":[{"journey":"greet --help","before":"data:image/png;base64,AAAA","after":"data:image/png;base64,BBBB"}]}}"#)
    private var calls: [String] = []
    private var waited = -1
    let gate: BackendDeckCoreTestPortToolsGate?
    init(gate: BackendDeckCoreTestPortToolsGate? = nil) { self.gate = gate }
    func trace() -> [String] { calls }
    func waitMilliseconds() -> Int { waited }
    func status(_ project: String) -> NativeRPCValue { calls.append("status "+project); return (try! BackendDeckCoreTestPortToolsFixture.json(#"{"projectPath":"/work/api","available":true,"unavailable":null,"versionNote":"","setUp":true,"configFile":"staysfixed.config.js","git":true,"agents":true,"guards":[{"name":"the total keeps its pennies","because":"It printed 10.0 once.","file":"/x"}],"guardProblem":null,"reference":{"buildId":"b","name":"1.0.0","setAt":"2026-10-01T00:00:00Z","setBy":"staysfixed ship","forced":false},"running":null}"#)).setting("last",Self.result) }
    func readiness(_ project: String,refresh: Bool) -> NativeRPCValue { try! BackendDeckCoreTestPortToolsFixture.json(#"{"ready":["web apps and sites"],"gaps":[],"notHere":[],"summary":"","git":true}"#) }
    func setup(_ project: String) -> NativeRPCValue { calls.append("setup "+project); return try! BackendDeckCoreTestPortToolsFixture.json(#"{"ok":true,"wrote":["staysfixed.config.js"],"problem":null,"readiness":null}"#) }
    func check(_ project: String,by: String) async -> NativeRPCValue { calls.append("check \(project) by \(by)"); if let gate { return await gate.wait() }; return Self.result }
    func progress(_ project: String) -> NativeRPCValue? { gate == nil ? nil : try! BackendDeckCoreTestPortToolsFixture.json(#"{"startedAt":1,"step":"Booting 1.0.0.","steps":4,"by":"Hoot"}"#) }
    func stop(_ project: String) -> Bool { true }
    func waitFor(_ project: String,milliseconds: Int) -> NativeRPCValue? { waited = milliseconds; return Self.result }
    func results(_ project: String,full: Bool) -> NativeRPCValue? { Self.result }
    func markGood(_ project: String,anyway: Bool) -> NativeRPCValue { calls.append("mark \(project) \(anyway)"); return try! BackendDeckCoreTestPortToolsFixture.json(#"{"ok":true,"marked":true,"already":false,"refused":null,"refusedFor":null,"summary":"Marked as good."}"#) }
    func setAgents(_ project: String,on: Bool) -> NativeRPCValue { calls.append("agents \(project) \(on)"); return (try! BackendDeckCoreTestPortToolsFixture.json(#"{"setUp":true}"#)).setting("agents",.bool(on)) }
}

actor BackendDeckCoreTestPortToolsCommunityFake: BackendDeckToolsAppCommunityService,BackendDeckToolsAppToolsStoreService {
    private var calls: [NativeRPCValue] = []
    func trace() -> [NativeRPCValue] { calls }
    func view() -> NativeRPCValue { try! BackendDeckCoreTestPortToolsFixture.json(#"{"from":"store","at":"","stale":"","because":"","problem":"","items":[{"id":"acme/search-mcp","publisher":"Acme","handle":"acme","kind":"mcp","name":"Search","summary":"Search the web from your agent","version":"1.0.0","licence":"MIT","tags":["web"],"agents":["claude"],"tier":3,"needs":["node"],"missing":[],"cost":"free","repo":"https://github.com/acme/search","network":["api.acme.test"],"state":"available","installedVersion":"","message":"","lands":["~/.claude.json"],"variables":["ACME_KEY"],"trigger":""},{"id":"bob/notes","publisher":"Acme","handle":"acme","kind":"skill","name":"Notes","summary":"Keep notes","version":"1.0.0","licence":"MIT","tags":[],"agents":["claude"],"tier":1,"needs":["node"],"missing":[],"cost":"free","repo":"https://github.com/acme/search","network":["api.acme.test"],"state":"available","installedVersion":"","message":"","lands":["~/.claude.json"],"variables":[],"trigger":""}],"folder":"/x","agents":[]}"#) }
    func install(_ id: String,choice: NativeRPCValue) -> NativeRPCValue { calls.append(BackendDeckCoreTestPortToolsFixture.object([("id",.string(id)),("choice",choice)])); return try! BackendDeckCoreTestPortToolsFixture.json(#"{"ok":true,"message":"Installed."}"#) }
    func remove(_ id: String) -> NativeRPCValue { try! BackendDeckCoreTestPortToolsFixture.json(#"{"ok":true,"message":"Removed."}"#) }
    func list(_ caller: BackendMCPCallContext) -> NativeRPCValue {
        let row = (try! BackendDeckCoreTestPortToolsFixture.json(#"{"id":"listings","name":"Listings","summary":"Reads property listings","licence":"MIT","version":"1","origins":["example.com"],"state":"available","installedVersion":"","message":"","reads":[]}"#)).setting("sha256",.string(String(repeating:"a",count:64)))
        return BackendDeckCoreTestPortToolsFixture.object([("view",BackendDeckCoreTestPortToolsFixture.object([("tools",.array([row])),("folder",.string("/x"))])),("orphans",.array([]))])
    }
    func install(_ id: String,caller: BackendMCPCallContext) -> NativeRPCValue { calls.append(BackendDeckCoreTestPortToolsFixture.object([("id",.string(id))])); return try! BackendDeckCoreTestPortToolsFixture.json(#"{"ok":true,"message":"Installed."}"#) }
    func remove(_ id: String,caller: BackendMCPCallContext) -> NativeRPCValue { remove(id) }
}

@MainActor
final class BackendDeckCoreTestPortToolsFixedCommunityTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private func fixed(_ fake: BackendDeckCoreTestPortToolsFixedFake,audit: BackendDeckCoreTestPortToolsAudit = .init(),clock: BackendDeckCoreTestPortToolsClock = .init()) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppFixed.definitions(service:fake,access:F.access(audit),clock:clock) }
    private func community(_ fake: BackendDeckCoreTestPortToolsCommunityFake,audit: BackendDeckCoreTestPortToolsAudit = .init(),identity: BackendDeckToolsAppCaller = .init(kind:.local)) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppCommunity.definitions(service:fake,access:F.access(audit,identity:identity)) }
    private func store(_ fake: BackendDeckCoreTestPortToolsCommunityFake,audit: BackendDeckCoreTestPortToolsAudit = .init()) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppToolsStore.definitions(service:fake,access:F.access(audit)) }
    // TSCASE fixed-tools.test.ts:100
    func testFixedL100ExactSevenTiers() throws { let defs = try fixed(.init()); let value = NativeRPCValue.object(defs.map { .init($0.spec.id,.string($0.spec.tier.rawValue)) }); XCTAssertEqual(value,try F.json(#"{"fixed.status":"read","fixed.setup":"alter","fixed.check":"act","fixed.results":"read","fixed.stop":"act","fixed.mark_good":"alter","fixed.agents":"alter"}"#)) }
    // TSCASE fixed-tools.test.ts:113
    func testFixedL113OwnerAlwaysAnswersAndAcceptingDifferencesNamed() async throws { let fake = BackendDeckCoreTestPortToolsFixedFake(),audit = BackendDeckCoreTestPortToolsAudit(); _ = try await F.call(fixed(fake,audit:audit),"fixed.mark_good",#"{"project":"/work/api","anyway":true}"#); let rows = await audit.consent(); XCTAssertEqual(rows[0]["owner"],.bool(true)); XCTAssertTrue(rows[0]["sentence"].string?.contains("accepting the differences") == true) }
    // TSCASE fixed-tools.test.ts:119
    func testFixedL119AllHeldBehindDescribeAndExactWireNames() throws { for spec in try fixed(.init()) { XCTAssertFalse(try XCTUnwrap(spec.index).isEmpty,spec.spec.id); XCTAssertEqual(spec.spec.wireName,spec.spec.id.replacingOccurrences(of:".",with:"_")) } }
    // TSCASE fixed-tools.test.ts:126
    func testFixedL126UnknownFolderRefusedBeforeServiceRuns() async throws { let fake = BackendDeckCoreTestPortToolsFixedFake(); F.error(try await F.call(fixed(fake),"fixed.check",#"{"project":"/etc"}"#),contains:"not a folder this app has open"); let calls = await fake.trace(); XCTAssertTrue(calls.isEmpty) }
    // TSCASE fixed-tools.test.ts:133
    func testFixedL133FinishedCheckDifferencesWithoutPictureBytes() async throws { let fake = BackendDeckCoreTestPortToolsFixedFake(),value = try F.value(await F.call(fixed(fake),"fixed.check",#"{"project":"/work/api","wait":5}"#)); XCTAssertEqual(value["verdict"],.string("differences")); XCTAssertEqual(value["differences"].elements?.first?["picturesKept"],.number(1)); XCTAssertFalse(value.compact.contains("base64")); let calls = await fake.trace(); XCTAssertEqual(calls,["check /work/api by Hoot"]) }
    // TSCASE fixed-tools.test.ts:143
    func testFixedL143PendingCheckAtZeroWaitSaysRunningAndNextTool() async throws { let gate = BackendDeckCoreTestPortToolsGate(),fake = BackendDeckCoreTestPortToolsFixedFake(gate:gate),clock = BackendDeckCoreTestPortToolsClock(),defs = try fixed(fake,clock:clock),call = Task { try await F.call(defs,"fixed.check",#"{"project":"/work/api","wait":0}"#) }; await clock.waitUntilScheduled(); await gate.waitUntilBegan(); clock.advance(0); let value = try F.value(await call.value); XCTAssertEqual(value["running"],.bool(true)); XCTAssertEqual(value["progress"]["step"],.string("Booting 1.0.0.")); XCTAssertTrue(value["next"].string?.contains("fixed.results") == true); await gate.release(BackendDeckCoreTestPortToolsFixedFake.result) }
    // TSCASE fixed-tools.test.ts:153
    func testFixedL153MaximumWaitPassedToService() async throws { let fake = BackendDeckCoreTestPortToolsFixedFake(); _ = try await F.call(fixed(fake),"fixed.results",#"{"project":"/work/api","wait":9999}"#); let waited = await fake.waitMilliseconds(); XCTAssertEqual(waited,BackendDeckToolsAppFixed.maxCheckWaitSeconds*1000) }
    // TSCASE fixed-tools.test.ts:165
    func testFixedL165EngineSummaryOnlyWhenAskedAndNilSaysNotRun() { let result = BackendDeckCoreTestPortToolsFixedFake.result; XCTAssertEqual(BackendDeckToolsAppFixed.resultsForModel(result,full:true)["engineSummary"],.string("The engine’s paragraph.")); XCTAssertEqual(BackendDeckToolsAppFixed.resultsForModel(result)["engineSummary"],.missing); XCTAssertEqual(BackendDeckToolsAppFixed.resultsForModel(nil)["ran"],.bool(false)) }
    // TSCASE fixed-tools.test.ts:171
    func testFixedL171GuardsGoodBuildAndNextInPlainWords() async throws { let value = try F.value(await F.call(fixed(.init()),"fixed.status",#"{"project":"/work/api"}"#)); XCTAssertEqual(value["setUp"],.bool(true)); XCTAssertEqual(value["guards"],try F.json(#"[{"name":"the total keeps its pennies","because":"It printed 10.0 once."}]"#)); XCTAssertEqual(value["markedGood"]["build"],.string("1.0.0")); XCTAssertEqual(value["next"],.string("fixed.check")) }
    // TSCASE fixed-tools.test.ts:181
    func testFixedL181BooleanAgentsSwitchOnly() async throws { let fake = BackendDeckCoreTestPortToolsFixedFake(),defs = try fixed(fake); F.error(try await F.call(defs,"fixed.agents",#"{"project":"/work/api","on":"yes"}"#),contains:"true or false"); _ = try await F.call(defs,"fixed.agents",#"{"project":"/work/api","on":false}"#); let calls = await fake.trace(); XCTAssertEqual(calls,["agents /work/api false"]) }
    // TSCASE fixed-tools.test.ts:189
    func testFixedL189AskedByNamesHootAndKeyApp() { XCTAssertEqual(BackendDeckToolsAppFixed.askedBy(.init(kind:.local)),"Hoot"); XCTAssertEqual(BackendDeckToolsAppFixed.askedBy(.init(kind:.key,keyName:"ChatGPT")),"ChatGPT") }
    // TSCASE community-tools.test.ts:70
    func testCommunityL70ProgramAndTextTierWords() async throws { let fake = BackendDeckCoreTestPortToolsCommunityFake(),value = try F.value(await F.call(community(fake),"store.community")),items = value["items"].elements ?? []; XCTAssertEqual(items.first { $0["item"].string == "acme/search-mcp" }?["whatItRuns"],.string("Runs a program on this machine")); XCTAssertEqual(items.first { $0["item"].string == "bob/notes" }?["whatItRuns"],.string("Text only — nothing runs")) }
    // TSCASE community-tools.test.ts:77
    func testCommunityL77DescriptionAndConfirmationSayOtherPersonsProgramRuns() async throws { let fake = BackendDeckCoreTestPortToolsCommunityFake(),audit = BackendDeckCoreTestPortToolsAudit(),defs = try community(fake,audit:audit); XCTAssertTrue(defs[0].spec.description.contains("Installing runs someone else’s work on this Mac")); _ = try await F.call(defs,"store.community"); _ = try await F.call(defs,"store.community",#"{"action":"install","item":"acme/search-mcp"}"#); let rows = await audit.consent(); XCTAssertTrue(rows[1]["sentence"].string?.contains("runs someone else's work on this Mac") == true); XCTAssertTrue(rows[1]["sentence"].string?.contains("Runs a program on this machine") == true) }
    // TSCASE community-tools.test.ts:86
    func testCommunityL86InstallRemoveAlterAndListRead() async throws { let fake = BackendDeckCoreTestPortToolsCommunityFake(),audit = BackendDeckCoreTestPortToolsAudit(),defs = try community(fake,audit:audit); _ = try await F.call(defs,"store.community",#"{"action":"install","item":"x"}"#); _ = try await F.call(defs,"store.community",#"{"action":"remove","item":"x"}"#); _ = try await F.call(defs,"store.community"); let rows = await audit.consent(); XCTAssertEqual(rows.map { $0["tier"] },[.string("alter"),.string("alter"),.string("read")]) }
    // TSCASE community-tools.test.ts:93
    func testCommunityL93ExactInstallValueRedaction() throws { let value = BackendDeckToolsAppKit.redacted("store.community",try F.json(#"{"action":"install","item":"x","values":{"ACME_KEY":"sk-live-1234567890"}}"#)); XCTAssertFalse(value.compact.contains("sk-live")); XCTAssertEqual(value["values"],try F.json(#"{"ACME_KEY":"[18 characters]"}"#)) }
    // TSCASE community-tools.test.ts:99
    func testCommunityL99ExactInstallerChoiceForwarded() async throws { let fake = BackendDeckCoreTestPortToolsCommunityFake(); _ = try await F.call(community(fake),"store.community",#"{"action":"install","item":"acme/search-mcp","agents":["claude"],"values":{"ACME_KEY":"k"}}"#); let calls = await fake.trace(); XCTAssertEqual(calls[0],try F.json(#"{"id":"acme/search-mcp","choice":{"agents":["claude"],"values":{"ACME_KEY":"k"}}}"#)) }
    // TSCASE community-tools.test.ts:106
    func testCommunityL106KindAndQueryFilters() async throws { let fake = BackendDeckCoreTestPortToolsCommunityFake(),defs = try community(fake),skills = try F.value(await F.call(defs,"store.community",#"{"kind":"skill"}"#)),web = try F.value(await F.call(defs,"store.community",#"{"query":"web"}"#)); XCTAssertEqual(skills["items"].elements?.count,1); XCTAssertEqual(web["items"].elements?.map { $0["item"] },[.string("acme/search-mcp")]) }
    // TSCASE community-tools.test.ts:114
    func testCommunityL114OrdinarySessionRefusedBeforeStoreRead() async throws { let fake = BackendDeckCoreTestPortToolsCommunityFake(); F.error(try await F.call(community(fake,identity:.init(kind:.session,sessionID:"s1")),"store.community"),contains:"reaches only the windows attached to it") }
    // TSCASE community-tools.test.ts:155
    func testCommunityL155BrowserStoreWhereItRunsAndPinnedDigest() async throws { let fake = BackendDeckCoreTestPortToolsCommunityFake(),value = try F.value(await F.call(store(fake),"browser.store")); XCTAssertEqual(value["tools"].elements?.first?["tool"],.string("listings")); XCTAssertEqual(value["tools"].elements?.first?["runsOn"],.array([.string("example.com")])); XCTAssertEqual(value["tools"].elements?.first?["sha256"],.string(String(repeating:"a",count:64))) }
    // TSCASE community-tools.test.ts:161
    func testCommunityL161BrowserStoreAlterAndUnknownToolBeforeConsent() async throws { let fake = BackendDeckCoreTestPortToolsCommunityFake(),audit = BackendDeckCoreTestPortToolsAudit(),defs = try store(fake,audit:audit); _ = try await F.call(defs,"browser.store",#"{"action":"install","tool":"listings"}"#); F.error(try await F.call(defs,"browser.store",#"{"action":"install","tool":"nope"}"#),contains:"has no tool nope"); let rows = await audit.consent(); XCTAssertEqual(rows.count,1); XCTAssertEqual(rows[0]["tier"],.string("alter")) }
    // TSCASE community-tools.test.ts:167
    func testCommunityL167BrowserStoreExactInstallerAndNextExtract() async throws { let fake = BackendDeckCoreTestPortToolsCommunityFake(),value = try F.value(await F.call(store(fake),"browser.store",#"{"action":"install","tool":"listings"}"#)); let calls = await fake.trace(); XCTAssertEqual(calls[0]["id"],.string("listings")); XCTAssertTrue(value["next"].string?.contains("browser.extract") == true) }
}
