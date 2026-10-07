import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendRoutinesIPCTests: XCTestCase {
    private var draft: NativeRPCValue { .object([.init("name", .string("Nightly sweep")), .init("when", .string("manual")), .init("in", .string(BackendRoutinesTestRig.project)), .init("prompt", .string("Run the tests."))]) }
    func testCreateWritesReadableFileAndDuplicateRetryCannotSpendTwice() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; let api = BackendRoutinesAPI(engine: rig.engine, store: rig.store)
        let created = try await api.create(draft), repeated = try await api.create(draft), differing = try await api.create(draft.setting("prompt", .string("Run the linter instead.")))
        XCTAssertTrue(created.ok); XCTAssertEqual(created.id, "nightly-sweep"); XCTAssertFalse(repeated.ok); XCTAssertTrue(repeated.problems.first?.contains("already does exactly this") == true); XCTAssertEqual(differing.id, "nightly-sweep-2")
        let text = try String(contentsOf: rig.directory.appendingPathComponent("routines/nightly-sweep.md"), encoding: .utf8); XCTAssertTrue(text.contains("# Nightly sweep")); XCTAssertTrue(text.contains("when: manual"))
    }
    func testRejectsPathsTakenNamesIncompleteAndNonObjectDrafts() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; let api = BackendRoutinesAPI(engine: rig.engine, store: rig.store)
        _ = try await api.create(draft.setting("id", .string("sweep")))
        let again = try await api.create(draft.setting("id", .string("sweep"))), path = try await api.create(draft.setting("id", .string("../../state"))), missing = try await api.create(draft.removing("when")), nothing = try await api.create(.null)
        XCTAssertFalse(again.ok); XCTAssertTrue(again.problems.first?.contains("already a routine") == true); XCTAssertFalse(path.ok); XCTAssertFalse(missing.ok); XCTAssertTrue(missing.problems.joined().contains("`when:`")); XCTAssertEqual(nothing.problems, ["A routine needs a name, a trigger, a folder and a prompt."])
        let removed = try await api.remove(.string("../../state")), view = await api.get(.string("../../state")); XCTAssertEqual(removed["ok"], .bool(false)); XCTAssertNil(view)
    }
    func testUpdateRemovePauseResumeAndManualBySource() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; let api = BackendRoutinesAPI(engine: rig.engine, store: rig.store)
        _ = try await api.create(draft); let id = NativeRPCValue.string("nightly-sweep")
        let update = try await api.update(id, draft: draft.setting("prompt", .string("Twice."))); XCTAssertEqual(update.view?.prompt, "Twice.")
        let before = rig.store.readText("nightly-sweep").text, paused = await api.pause(id, reason: .string("Not right now")), denied = await api.run(id, by: "copilot")
        XCTAssertTrue(paused); XCTAssertFalse(denied.started); XCTAssertEqual(denied.reason, "Not right now"); XCTAssertEqual(rig.store.readText("nightly-sweep").text, before)
        let resumed = await api.resume(id), started = await api.run(id, by: "copilot"); XCTAssertTrue(resumed); XCTAssertTrue(started.started); await BackendRoutinesTestRig.settle()
        let calls = await rig.runner.calls; XCTAssertEqual(calls.first?.cause, .manual(by: "copilot"))
        let removed = try await api.remove(id), absent = try await api.remove(id); XCTAssertEqual(removed["ok"], .bool(true)); XCTAssertEqual(absent["ok"], .bool(false))
    }
    func testRawTextIsVerbatimValidatedAndOnlyAnEditorForExistingRoutine() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; let api = BackendRoutinesAPI(engine: rig.engine, store: rig.store)
        _ = try await api.create(draft); let id = NativeRPCValue.string("nightly-sweep")
        let text = "# Nightly sweep\n\n# NOTE: leave the folder alone\nwhen: manual\nin: \(BackendRoutinesTestRig.project)\n---\n\nRun it twice.\n"
        let saved = try await api.saveText(id, text: .string(text)); XCTAssertTrue(saved.ok); XCTAssertEqual(rig.store.readText("nightly-sweep").text, text); XCTAssertEqual(saved.view?.prompt, "Run it twice.")
        let bad = try await api.saveText(id, text: .string("# Broken\nin: /tmp/x\n---\nGo.")); XCTAssertFalse(bad.ok); XCTAssertEqual(rig.store.readText("nightly-sweep").text, text)
        let missing = try await api.saveText(.string("never-existed"), text: .string(text)); XCTAssertFalse(missing.ok)
        for junk in [NativeRPCValue.missing, .null, .number(3), .object([]), .array([.string("a")])] { let answer = try await api.saveText(id, text: junk); XCTAssertEqual(answer.problems, ["Nothing was supplied to save."]) }
        let exact = await api.text(id); XCTAssertEqual(exact["text"], .string(text))
    }
    func testAllTenChannelsTierTableAndHumanRouteAreRegisteredExactlyOnce() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; let api = BackendRoutinesAPI(engine: rig.engine, store: rig.store), registry = NativeChannelRegistry()
        try await api.register(on: registry, ownerID: "test")
        let channels = await registry.channels(); XCTAssertEqual(channels.count, 10); XCTAssertEqual(Set(channels), BackendRoutinesAPI.channels)
        XCTAssertEqual(BackendRoutinesAPI.tiers["routines:create"], .alter); XCTAssertEqual(BackendRoutinesAPI.tiers["routines:run"], .act); XCTAssertEqual(BackendRoutinesAPI.tiers["routines:save-text"], .human); XCTAssertNil(BackendMCPTier(rawValue: "human"))
        let created = try await registry.invoke("routines:create", context: .init(caller: .nativeApp, ownerID: "person"), arguments: [draft]); XCTAssertEqual(created["ok"], .bool(true))
        let paired = NativeRPCContext(caller: .pairedDevice, ownerID: "device", capabilities: ["routines.write"])
        do { _ = try await registry.invoke("routines:save-text", context: paired, arguments: [.string("nightly-sweep"), .string("anything")]); XCTFail("raw-text route must be human-only") } catch let error as NativeRPCError { XCTAssertEqual(error.code, "not-permitted") }
        do { try await api.register(on: registry, ownerID: "again"); XCTFail("duplicate channels should fail") } catch let error as NativeRPCError { XCTAssertEqual(error.code, "duplicate-handler") }
    }
    func testConcurrentIdenticalCreatesKeepOneRoutine() async throws {
        let rig = try await BackendRoutinesTestRig.make(); addTeardownBlock { await rig.clean() }; let api = BackendRoutinesAPI(engine: rig.engine, store: rig.store), input = draft
        async let first = api.create(input); async let second = api.create(input)
        let results = try await [first, second]; XCTAssertEqual(results.filter(\.ok).count, 1); XCTAssertEqual(rig.store.list().count, 1)
    }
}
