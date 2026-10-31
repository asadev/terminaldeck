import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor BackendDeckCoreTestPortToolsRoutineFake: BackendDeckToolsAppRoutineService {
    nonisolated static let file = ["# Nightly sweep","","when: schedule 02:30","in: /work/api","enabled: yes","quiet-for: 2m","expect-every: 1d","","---","","Run the tests. If anything fails, open a session and start fixing it.",""].joined(separator:"\n")
    private var calls: [NativeRPCValue] = []
    private var createResult: NativeRPCValue?
    private var runResult: NativeRPCValue?
    func setCreate(_ result: NativeRPCValue) { createResult = result }
    func setRun(_ result: NativeRPCValue) { runResult = result }
    func recorded() -> [NativeRPCValue] { calls }
    private func view(_ id: String) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("id",.string(id)),("name",.string("Nightly sweep")),("folder",.string("/work/api")),("triggers",.array([.string("schedule 02:30")])),("prompt",.string("Run the tests."))]) }
    func list() -> [NativeRPCValue] { [view("nightly-sweep")] }
    func get(_ id: String) -> NativeRPCValue? { id == "nightly-sweep" ? view(id) : nil }
    func text(_ id: String) -> NativeRPCValue { id == "nightly-sweep" ? BackendDeckCoreTestPortToolsFixture.object([("ok",.bool(true)),("id",.string(id)),("text",.string(Self.file)),("file",.string("/state/routines/nightly-sweep.md"))]) : BackendDeckCoreTestPortToolsFixture.object([("ok",.bool(false)),("problems",.array([.string("missing")]))]) }
    func draftFromFile(id: String,text: String) -> NativeRPCValue? {
        guard let parsed = BackendRoutinesFormat.parseRoutine(id,text:text).routine else { return nil }
        var draft = BackendDeckCoreTestPortToolsFixture.object([("name",.string(parsed.name)),("when",.array(parsed.triggers.map { .string(BackendRoutinesFormat.serializeTrigger($0)) })),("in",.string(parsed.folder)),("prompt",.string(parsed.prompt)),("quietFor",.string(BackendRoutinesFormat.serializeDuration(parsed.quietForMs)))])
        if let expect = parsed.expectEveryMs { draft = draft.setting("expectEvery",.string(BackendRoutinesFormat.serializeDuration(expect))) }; return draft
    }
    func create(_ draft: NativeRPCValue) -> NativeRPCValue { calls.append(BackendDeckCoreTestPortToolsFixture.object([("operation",.string("create")),("draft",draft)])); return createResult ?? BackendDeckCoreTestPortToolsFixture.object([("ok",.bool(true)),("id",.string("mine")),("view",view("mine"))]) }
    func update(_ id: String,draft: NativeRPCValue) -> NativeRPCValue { calls.append(BackendDeckCoreTestPortToolsFixture.object([("operation",.string("update")),("id",.string(id)),("draft",draft)])); return BackendDeckCoreTestPortToolsFixture.object([("ok",.bool(true)),("id",.string(id)),("view",view(id))]) }
    func remove(_ id: String) -> NativeRPCValue { BackendDeckCoreTestPortToolsFixture.object([("ok",.bool(id == "nightly-sweep"))]) }
    func run(_ id: String,by: String) -> NativeRPCValue { calls.append(BackendDeckCoreTestPortToolsFixture.object([("operation",.string("run")),("id",.string(id)),("by",.string(by))])); return runResult ?? BackendDeckCoreTestPortToolsFixture.object([("started",.bool(true)),("runId",.string("run-9"))]) }
    func pause(_ id: String,reason: String) -> Bool { true }
    func resume(_ id: String) -> Bool { true }
}

@MainActor
final class BackendDeckCoreTestPortToolsRoutinesTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private func tools(_ fake: BackendDeckCoreTestPortToolsRoutineFake,_ audit: BackendDeckCoreTestPortToolsAudit = .init()) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppRoutines.definitions(service:fake,access:F.access(audit)) }
    // TSCASE routine-tools.test.ts:42
    func testRoutineL42DraftUsesRealLoaderParser() async throws { let fake = BackendDeckCoreTestPortToolsRoutineFake(),raw = try await BackendDeckToolsAppRoutines.currentDraft(fake,"nightly-sweep"),draft = try XCTUnwrap(raw); XCTAssertEqual(draft["name"],.string("Nightly sweep")); XCTAssertEqual(draft["when"],.array([.string("schedule 02:30")])); XCTAssertEqual(draft["in"],.string("/work/api")); XCTAssertEqual(draft["quietFor"],.string("2m")); XCTAssertEqual(draft["expectEvery"],.string("1d")) }
    // TSCASE routine-tools.test.ts:54
    func testRoutineL54OnlySentFieldsOverlay() async throws { let fake = BackendDeckCoreTestPortToolsRoutineFake(); _ = try await F.call(tools(fake),"routines.save",#"{"routineId":"nightly-sweep","when":["schedule 03:00"]}"#); let calls = await fake.recorded(),draft = calls[0]["draft"]; XCTAssertEqual(calls[0]["id"],.string("nightly-sweep")); XCTAssertEqual(draft["when"],.array([.string("schedule 03:00")])); XCTAssertEqual(draft["in"],.string("/work/api")); XCTAssertEqual(draft["quietFor"],.string("2m")); XCTAssertEqual(draft["expectEvery"],.string("1d")); XCTAssertTrue(draft["prompt"].string?.contains("Run the tests.") == true) }
    // TSCASE routine-tools.test.ts:64
    // Same five fields and values as the source's toHaveBeenCalledWith (which ignores key order);
    // NativeRPCValue equality is ordered, so the order is the source's own: create({ ...patch, id })
    // with patchOf's name, when, in, prompt (routine-tools.ts:110-118, :240).
    func testRoutineL64NewIDPassesThroughWithExactDraft() async throws { let fake = BackendDeckCoreTestPortToolsRoutineFake(); _ = try await F.call(tools(fake),"routines.save",#"{"routineId":"mine","name":"Mine","when":"manual","folder":"/work/web","prompt":"Say hi."}"#); let calls = await fake.recorded(); XCTAssertEqual(calls[0]["operation"],.string("create")); XCTAssertEqual(calls[0]["draft"],try F.json(#"{"name":"Mine","when":["manual"],"in":"/work/web","prompt":"Say hi.","id":"mine"}"#)) }
    // TSCASE routine-tools.test.ts:74
    func testRoutineL74UnknownFolderBeforeConsent() async throws { let fake = BackendDeckCoreTestPortToolsRoutineFake(),audit = BackendDeckCoreTestPortToolsAudit(); F.error(try await F.call(tools(fake,audit),"routines.save",#"{"name":"x","folder":"/","prompt":"x"}"#),contains:"not a folder this app has open"); let consent = await audit.consent(); XCTAssertTrue(consent.isEmpty) }
    // TSCASE routine-tools.test.ts:81
    func testRoutineL81SaveRefusalKeepsParserProblem() async throws { let fake = BackendDeckCoreTestPortToolsRoutineFake(); await fake.setCreate(try F.json(#"{"ok":false,"problems":["This routine has no `when:` line."]}"#)); F.error(try await F.call(tools(fake),"routines.save",#"{"name":"x","folder":"/work/api","prompt":"x"}"#),contains:"no `when:` line") }
    // TSCASE routine-tools.test.ts:89
    func testRoutineL89RunCarriesCopilotProvenanceAndExactReply() async throws { let fake = BackendDeckCoreTestPortToolsRoutineFake(),value = try F.value(await F.call(tools(fake),"routines.run",#"{"routineId":"nightly-sweep"}"#)); let calls = await fake.recorded(); XCTAssertEqual(calls[0]["id"],.string("nightly-sweep")); XCTAssertEqual(calls[0]["by"],.string("copilot")); XCTAssertEqual(value,try F.json(#"{"routineId":"nightly-sweep","runId":"run-9"}"#)) }
    // TSCASE routine-tools.test.ts:97
    func testRoutineL97EngineRefusalKeepsReason() async throws { let fake = BackendDeckCoreTestPortToolsRoutineFake(); await fake.setRun(try F.json(#"{"started":false,"reason":"It has run 6 times this hour."}"#)); F.error(try await F.call(tools(fake),"routines.run",#"{"routineId":"nightly-sweep"}"#),contains:"6 times this hour") }
    // TSCASE routine-tools.test.ts:103
    func testRoutineL103GetReturnsVerbatimFile() async throws { let fake = BackendDeckCoreTestPortToolsRoutineFake(),value = try F.value(await F.call(tools(fake),"routines.get",#"{"routineId":"nightly-sweep"}"#)); XCTAssertEqual(value["file"]["text"],.string(BackendDeckCoreTestPortToolsRoutineFake.file)) }
}
