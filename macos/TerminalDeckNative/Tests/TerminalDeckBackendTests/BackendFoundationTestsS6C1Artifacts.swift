import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// artifacts.test.ts: parser, relativeToRoot, list, history and cancellation slots.
final class BackendFoundationTestsS6C1Artifacts: XCTestCase {
    private let context = NativeRPCContext(caller: .nativeApp, ownerID: "s6c1-artifacts")
    private struct S6C1Env {
        let fixture: BackendFoundationTestsBFixture
        var base: URL { URL(fileURLWithPath: fixture.root.path).resolvingSymlinksInPath() }
        var configDir: URL { base.appendingPathComponent("config") }
        var project: String { base.appendingPathComponent("project").path }
    }
    private func env(_ name: String) throws -> S6C1Env {
        let e = S6C1Env(fixture: try BackendFoundationTestsBFixture("s6c1-art-" + name))
        try FileManager.default.createDirectory(at: e.configDir.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: e.project, withIntermediateDirectories: true)
        return e
    }
    private func line(_ at: String, _ blocks: [[String: Any]]) -> [String: Any] {
        ["type": "assistant", "isSidechain": false, "timestamp": at, "message": ["role": "assistant", "model": "claude-opus-5", "content": blocks]]
    }
    private func write(_ path: String, _ content: String) -> [String: Any] { ["type": "tool_use", "id": "toolu_1", "name": "Write", "input": ["file_path": path, "content": content]] }
    private func edit(_ path: String, _ before: String, _ after: String, all: Bool = false) -> [String: Any] {
        ["type": "tool_use", "id": "toolu_2", "name": "Edit", "input": ["file_path": path, "old_string": before, "new_string": after, "replace_all": all]]
    }
    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }
    @discardableResult
    private func transcript(_ config: URL, cwd: String, _ session: String, _ lines: [[String: Any]]) throws -> String {
        let dir = config.appendingPathComponent("projects").appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(session + ".jsonl")
        try (try lines.map(json).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }
    private func index(_ e: S6C1Env, homes: String? = nil, homeScopes: [NativeTranscriptHomeScope] = []) -> BackendArtifactsIndex {
        let config = e.configDir.path
        let source = BackendArtifactsNativeTranscriptSource { _, _, _ in [NativeTranscriptScope(configDirectory: config, deviceHomesRoot: homes, homeScopes: homeScopes)] }
        return BackendArtifactsIndex(source: source, authority: .init(scope: { _ in .local }))
    }
    private func ms(_ iso: String) -> Double {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!.timeIntervalSince1970 * 1_000
    }
    private func paths(_ value: NativeRPCValue) -> [String] { (value["artifacts"].elements ?? []).compactMap { $0["relPath"].string } }

    // MARK: parser
    func testGateRejectsTheBulkOfATranscriptAndNeverYieldsTouchesForThem() throws {
        // mayCarryFileWrite is folded into touches(); its observable half is that these yield nothing.
        XCTAssertEqual(BackendArtifactsIndex.touches("{\"type\":\"user\",\"message\":{\"content\":\"hello\"}}").count, 0)
        XCTAssertEqual(BackendArtifactsIndex.touches("{\"type\":\"tool_use\",\"input\":{\"command\":\"ls\"}}").count, 0)
    }
    func testReadsAWriteAsAWriteWithTheContentItPutIn() throws {
        let touches = BackendArtifactsIndex.touches(try json(line("2026-08-16T10:00:00.000Z", [write("/p/a.ts", "hello")])))
        let t = try XCTUnwrap(touches.first)
        XCTAssertEqual(t.path, "/p/a.ts"); XCTAssertEqual(t.action, "write"); XCTAssertEqual(t.before, ""); XCTAssertEqual(t.after, "hello"); XCTAssertEqual(t.tool, "Write")
        XCTAssertEqual(t.at, ms("2026-08-16T10:00:00.000Z"))
    }
    func testReadsAnEditAsBothHalvesOfTheChange() throws {
        let t = try XCTUnwrap(BackendArtifactsIndex.touches(try json(line("2026-08-16T10:00:00.000Z", [edit("/p/a.ts", "old", "new", all: true)]))).first)
        XCTAssertEqual(t.action, "edit"); XCTAssertEqual(t.before, "old"); XCTAssertEqual(t.after, "new"); XCTAssertTrue(t.replaceAll); XCTAssertEqual(t.tool, "Edit")
    }
    func testReadsANotebookEditThroughItsOwnFieldNames() throws {
        let block: [String: Any] = ["type": "tool_use", "name": "NotebookEdit", "input": ["notebook_path": "/p/n.ipynb", "new_source": "print(1)", "edit_mode": "replace"]]
        let t = try XCTUnwrap(BackendArtifactsIndex.touches(try json(line("2026-08-16T10:00:00.000Z", [block]))).first)
        XCTAssertEqual(t.path, "/p/n.ipynb"); XCTAssertEqual(t.action, "edit"); XCTAssertEqual(t.after, "print(1)")
    }
    func testReadsEveryToolUseOnOneLineNotJustTheFirst() throws {
        let touches = BackendArtifactsIndex.touches(try json(line("2026-08-16T10:00:00.000Z", [["type": "text", "text": "editing both"], edit("/p/a.ts", "x", "y"), edit("/p/b.ts", "q", "r")])))
        XCTAssertEqual(touches.map(\.path), ["/p/a.ts", "/p/b.ts"])
    }
    func testIgnoresToolsThatDoNotWriteFiles() throws {
        let blocks: [[String: Any]] = [["type": "tool_use", "name": "Read", "input": ["file_path": "/p/a.ts"]], ["type": "tool_use", "name": "Bash", "input": ["command": "echo hi > /p/b.ts"]]]
        XCTAssertEqual(BackendArtifactsIndex.touches(try json(line("2026-08-16T10:00:00.000Z", blocks))).count, 0)
    }
    func testDropsARelativePathRatherThanResolvingItAgainstAGuess() throws {
        XCTAssertEqual(BackendArtifactsIndex.touches(try json(line("2026-08-16T10:00:00.000Z", [write("src/a.ts", "x")]))).count, 0)
    }
    func testSurvivesATornLastLine() {
        XCTAssertEqual(BackendArtifactsIndex.touches("{\"type\":\"assistant\",\"message\":{\"cont").count, 0)
    }
    func testRecordedAbsoluteAcceptsBothSpellingsATranscriptCanCarry() throws {
        func kept(_ p: String) throws -> Bool { !BackendArtifactsIndex.touches(try json(line("2026-08-16T10:00:00.000Z", [write(p, "x")]))).isEmpty }
        XCTAssertTrue(try kept("/Users/a/x.ts")); XCTAssertTrue(try kept("C:\\src\\x.ts"))
        XCTAssertFalse(try kept("src/x.ts")); XCTAssertFalse(try kept(""))
    }

    // MARK: relativeToRoot
    func testRelativeKeepsAFileInsideTheProject() { XCTAssertEqual(BackendArtifactsIndex.relative(root: "/Users/a/proj", recorded: "/Users/a/proj/src/main.ts"), "src/main.ts") }
    func testRelativeRefusesTheRootItself() { XCTAssertNil(BackendArtifactsIndex.relative(root: "/Users/a/proj", recorded: "/Users/a/proj")) }
    func testRelativeRefusesASiblingWhoseNameMerelyStartsWithTheRoot() { XCTAssertNil(BackendArtifactsIndex.relative(root: "/Users/a/proj", recorded: "/Users/a/proj2/src/main.ts")) }
    func testRelativeRefusesAnythingOutside() { XCTAssertNil(BackendArtifactsIndex.relative(root: "/Users/a/proj", recorded: "/Users/a/.claude/settings.json")) }

    // MARK: list
    func testGathersFilesWrittenAndEditedNewestFirst() async throws {
        let e = try env("list1"); try "const a = 1\n".write(toFile: e.project + "/a.ts", atomically: true, encoding: .utf8)
        try transcript(e.configDir, cwd: e.project, "sess-1", [
            line("2026-08-16T10:00:00.000Z", [write(e.project + "/a.ts", "const a = 0\n")]),
            line("2026-08-16T10:05:00.000Z", [edit(e.project + "/a.ts", "0", "1")]),
            line("2026-08-16T10:10:00.000Z", [write(e.project + "/docs/plan.md", "# Plan\n")])])
        let r = try await index(e).list(project: e.project, context: context)
        XCTAssertEqual(paths(r), ["docs/plan.md", "a.ts"])
        let items = try XCTUnwrap(r["artifacts"].elements), plan = items[0], a = items[1]
        XCTAssertEqual(plan["name"].string, "plan.md"); XCTAssertEqual(plan["writes"].number, 1); XCTAssertEqual(plan["edits"].number, 0); XCTAssertEqual(plan["lastTool"].string, "Write")
        XCTAssertEqual(a["name"].string, "a.ts"); XCTAssertEqual(a["writes"].number, 1); XCTAssertEqual(a["edits"].number, 1); XCTAssertEqual(a["lastTool"].string, "Edit")
        XCTAssertEqual(a["firstAt"].number, ms("2026-08-16T10:00:00.000Z")); XCTAssertEqual(a["lastAt"].number, ms("2026-08-16T10:05:00.000Z"))
    }
    func testSaysWhichFilesAreStillOnDiskAndWhichAreGone() async throws {
        let e = try env("disk"); try "kept\n".write(toFile: e.project + "/kept.ts", atomically: true, encoding: .utf8)
        try transcript(e.configDir, cwd: e.project, "sess-1", [
            line("2026-08-16T10:00:00.000Z", [write(e.project + "/kept.ts", "kept\n")]),
            line("2026-08-16T10:01:00.000Z", [write(e.project + "/scratch.tmp", "gone\n")])])
        let r = try await index(e).list(project: e.project, context: context)
        let byPath = Dictionary(uniqueKeysWithValues: (r["artifacts"].elements ?? []).map { ($0["relPath"].string ?? "", $0) })
        XCTAssertEqual(byPath["kept.ts"]?["onDisk"]["bytes"].number, 5)
        if case .null = try XCTUnwrap(byPath["scratch.tmp"])["onDisk"] {} else { XCTFail("scratch should not be on disk") }
    }
    func testCountsEditsOutsideTheProjectInsteadOfListingThem() async throws {
        let e = try env("outside")
        try transcript(e.configDir, cwd: e.project, "sess-1", [
            line("2026-08-16T10:00:00.000Z", [edit("/Users/a/.claude/settings.json", "x", "y")]),
            line("2026-08-16T10:01:00.000Z", [write(e.project + "/in.ts", "in\n")])])
        let r = try await index(e).list(project: e.project, context: context)
        XCTAssertEqual(paths(r), ["in.ts"]); XCTAssertEqual(r["outsideProject"].number, 1)
    }
    func testMergesTheSameFileAcrossSessionsAndReportsBoth() async throws {
        let e = try env("merge")
        try transcript(e.configDir, cwd: e.project, "older", [line("2026-08-15T09:00:00.000Z", [write(e.project + "/a.ts", "v1\n")])])
        try transcript(e.configDir, cwd: e.project, "newer", [line("2026-08-16T09:00:00.000Z", [edit(e.project + "/a.ts", "v1", "v2")])])
        let r = try await index(e).list(project: e.project, context: context)
        let items = try XCTUnwrap(r["artifacts"].elements); XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["sessionIds"].elements?.compactMap(\.string), ["newer", "older"])
        let sessions = try XCTUnwrap(r["sessions"].elements)
        XCTAssertEqual(sessions.compactMap { $0["sessionId"].string }, ["newer", "older"]); XCTAssertEqual(sessions[0]["files"].number, 1)
    }
    func testFindsWorkDoneFromAParentWorkspaceUnderTheWiderScope() async throws {
        let e = try env("parent"), orchestrator = e.base.appendingPathComponent("workspace").path
        try transcript(e.configDir, cwd: orchestrator, "from-parent", [line("2026-08-16T10:00:00.000Z", [write(e.project + "/src/deep.ts", "reached in\n")])])
        let own = try await index(e).list(project: e.project, context: context)
        XCTAssertEqual(paths(own), []); XCTAssertEqual(own["scope"].string, "project")
        var wide = BackendArtifactScanOptions(); wide.scope = .all
        let all = try await index(e).list(project: e.project, options: wide, context: context)
        XCTAssertEqual(paths(all), ["src/deep.ts"]); XCTAssertEqual(all["scope"].string, "all")
    }
    func testDoesNotDragAnotherProjectsFilesInUnderTheWiderScope() async throws {
        let e = try env("other"), elsewhere = e.base.appendingPathComponent("other-repo").path
        try transcript(e.configDir, cwd: elsewhere, "other", [line("2026-08-16T10:00:00.000Z", [write(elsewhere + "/x.ts", "not ours\n")])])
        var wide = BackendArtifactScanOptions(); wide.scope = .all
        let all = try await index(e).list(project: e.project, options: wide, context: context)
        XCTAssertEqual(paths(all), []); XCTAssertEqual(all["outsideProject"].number, 1)
    }
    func testReadsOnlyItsOwnFolderOutOfAScopedStoreHoweverWideTheScope() async throws {
        let e = try env("scoped"), homes = e.base.appendingPathComponent("homes")
        let copilotFolder = homes.appendingPathComponent("user-data/copilot").path
        let copilotHome = homes.appendingPathComponent("device-home/copilot"), phoneHome = homes.appendingPathComponent("device-home/a1b2c3d4e5f60718")
        for home in [copilotHome, phoneHome] { try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true) }
        try transcript(copilotHome.appendingPathComponent(".claude"), cwd: e.project, "fabricated", [line("2026-08-16T11:00:00.000Z", [write(e.project + "/src/forged.ts", "never happened\n")])])
        try transcript(copilotHome.appendingPathComponent(".claude"), cwd: copilotFolder, "real", [line("2026-08-16T11:01:00.000Z", [write(copilotFolder + "/memory/a.md", "ok\n")])])
        try transcript(phoneHome.appendingPathComponent(".claude"), cwd: e.project, "phone", [line("2026-08-16T11:02:00.000Z", [write(e.project + "/src/real.ts", "from a phone\n")])])
        var wide = BackendArtifactScanOptions(); wide.scope = .all
        let idx = index(e, homes: homes.appendingPathComponent("device-home").path, homeScopes: [NativeTranscriptHomeScope(home: copilotHome.path, folder: copilotFolder)])
        let all = try await idx.list(project: e.project, options: wide, context: context)
        XCTAssertEqual(paths(all), ["src/real.ts"])
        XCTAssertEqual((all["sessions"].elements ?? []).compactMap { $0["sessionId"].string }, ["phone"])
    }
    func testIsEmptyAndSaysSoHonestlyForAProjectNoAgentHasWrittenIn() async throws {
        let e = try env("empty")
        let r = try await index(e).list(project: e.project, context: context)
        XCTAssertEqual(paths(r), []); XCTAssertEqual(r["sessionsScanned"].number, 0); XCTAssertEqual(r["truncated"].bool, false)
    }
    func testReportsTruncationRatherThanSilentlyShorteningTheList() async throws {
        let e = try env("trunc")
        try transcript(e.configDir, cwd: e.project, "sess-1", [
            line("2026-08-16T10:00:00.000Z", [write(e.project + "/a.ts", "a")]),
            line("2026-08-16T10:01:00.000Z", [write(e.project + "/b.ts", "b")]),
            line("2026-08-16T10:02:00.000Z", [write(e.project + "/c.ts", "c")])])
        var options = BackendArtifactScanOptions(); options.maxArtifacts = 2
        let r = try await index(e).list(project: e.project, options: options, context: context)
        XCTAssertEqual(r["artifacts"].elements?.count, 2); XCTAssertEqual(r["truncated"].bool, true)
    }
    func testStopsAtTheTimeBudgetInsteadOfReadingAWholeHistory() async throws {
        let e = try env("budget")
        try transcript(e.configDir, cwd: e.project, "sess-1", [line("2026-08-16T10:00:00.000Z", [write(e.project + "/a.ts", "a")])])
        try transcript(e.configDir, cwd: e.project, "sess-2", [line("2026-08-16T09:00:00.000Z", [write(e.project + "/b.ts", "b")])])
        // A clock that is already past the deadline on its second reading, so the budget is proven to bite
        // without the test depending on machine speed.
        final class Ticks: @unchecked Sendable { let lock = NSLock(); var count = 0
            func next() -> Date { lock.lock(); defer { lock.unlock() }; count += 1; return Date(timeIntervalSince1970: count == 1 ? 0 : 1_000_000) } }
        let ticks = Ticks()
        var options = BackendArtifactScanOptions(); options.timeBudgetMilliseconds = 1; options.clock = { ticks.next() }
        let r = try await index(e).list(project: e.project, options: options, context: context)
        XCTAssertEqual(r["truncated"].bool, true)
        XCTAssertLessThan(r["sessionsScanned"].number ?? 99, 2)
    }
    func testGatePassesALineWithAToolUseNamingAFile() {
        XCTAssertTrue(BackendArtifactsIndex.mayCarryFileWrite("{\"type\":\"tool_use\",\"input\":{\"file_path\":\"/a\"}}"))
        XCTAssertTrue(BackendArtifactsIndex.mayCarryFileWrite("{\"type\":\"tool_use\",\"input\":{\"notebook_path\":\"/a\"}}"))
    }
    func testGateRejectsTheLinesThatMakeUpTheBulkOfATranscript() {
        XCTAssertFalse(BackendArtifactsIndex.mayCarryFileWrite("{\"type\":\"user\",\"message\":{\"content\":\"hello\"}}"))
        XCTAssertFalse(BackendArtifactsIndex.mayCarryFileWrite("{\"type\":\"tool_use\",\"input\":{\"command\":\"ls\"}}"))
    }

    // MARK: history
    func testReturnsEveryRecordedChangeToOneFileNewestFirst() async throws {
        let e = try env("hist")
        try transcript(e.configDir, cwd: e.project, "sess-1", [
            line("2026-08-16T10:00:00.000Z", [write(e.project + "/a.ts", "const a = 0\n")]),
            line("2026-08-16T10:05:00.000Z", [edit(e.project + "/a.ts", "0", "1")]),
            line("2026-08-16T10:06:00.000Z", [edit(e.project + "/other.ts", "p", "q")])])
        let h = try await index(e).history(project: e.project, relative: "a.ts", context: context)
        let changes = try XCTUnwrap(h["changes"].elements); XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0]["action"].string, "edit"); XCTAssertEqual(changes[0]["before"].string, "0"); XCTAssertEqual(changes[0]["after"].string, "1"); XCTAssertEqual(changes[0]["sessionId"].string, "sess-1")
        XCTAssertEqual(changes[1]["action"].string, "write"); XCTAssertEqual(changes[1]["before"].string, ""); XCTAssertEqual(changes[1]["after"].string, "const a = 0\n")
    }
    func testClipsAHugeWriteAndAdmitsIt() async throws {
        let e = try env("clip")
        try transcript(e.configDir, cwd: e.project, "sess-1", [line("2026-08-16T10:00:00.000Z", [write(e.project + "/big.txt", String(repeating: "x", count: 24_000 + 500))])])
        let h = try await index(e).history(project: e.project, relative: "big.txt", context: context)
        let first = try XCTUnwrap(h["changes"].elements?.first)
        XCTAssertEqual(first["after"].string?.utf16.count, 24_000); XCTAssertEqual(first["clipped"].bool, true)
    }
    func testRefusesAPathThatClimbsOutOfTheProject() async throws {
        // artifacts.ts answered an empty changes list; the Swift port refuses outright (still no read outside the folder).
        let e = try env("climb")
        try transcript(e.configDir, cwd: e.project, "sess-1", [line("2026-08-16T10:00:00.000Z", [write(e.project + "/a.ts", "a")])])
        do { let h = try await index(e).history(project: e.project, relative: "../../etc/hosts", context: context); XCTAssertEqual(h["changes"].elements?.count ?? 0, 0) }
        catch {}
    }

    // MARK: cancellation slots (ScanSlots equivalents, observed through gated fake transcript sources)
    private actor S6C1Gate {
        private var open = false, started = 0
        private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
        private var cancelled: Set<UUID> = []
        func wait(_ id: UUID) async throws {
            if cancelled.contains(id) { throw CancellationError() }
            if open { return }
            started += 1
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in waiters[id] = c }
        }
        func cancel(_ id: UUID) { cancelled.insert(id); waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        func release() { open = true; let all = waiters.values; waiters = [:]; all.forEach { $0.resume() } }
        var count: Int { started }
    }
    private struct S6C1GatedSource: BackendArtifactsTranscriptSource {
        let gate: S6C1Gate
        func transcripts(project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> [NativeTranscriptFile] {
            let id = UUID()
            try await withTaskCancellationHandler { try await gate.wait(id) } onCancel: { Task { await gate.cancel(id) } }
            return []
        }
        func authorizedPath(_ file: NativeTranscriptFile, project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> String { file.path }
    }
    private func waitStarted(_ gate: S6C1Gate, _ n: Int) async {
        var spins = 0
        while await gate.count < n && spins < 200_000 { spins += 1; await Task.yield() }
        let c = await gate.count; XCTAssertGreaterThanOrEqual(c, n)
    }
    private func gated(_ gate: S6C1Gate) -> BackendArtifactsIndex { BackendArtifactsIndex(source: S6C1GatedSource(gate: gate), authority: .init(scope: { _ in .local })) }
    private func ctx(_ owner: String) -> NativeRPCContext { NativeRPCContext(caller: .nativeApp, ownerID: owner) }
    private func throwsCancel(_ task: Task<NativeRPCValue, any Error>, line: UInt = #line) async -> Bool {
        do { _ = try await task.value; return false } catch { return true }
    }

    func testListAndChangesScansRunAtTheSameTime() async throws {
        let gate = S6C1Gate(), idx = gated(gate), c = ctx("w7")
        let list = Task { try await idx.list(project: "/tmp", context: c) }
        let changes = Task { try await idx.history(project: "/tmp", relative: "a.ts", context: c) }
        await waitStarted(gate, 2); await gate.release()
        let l = try await list.value, h = try await changes.value
        XCTAssertEqual(l["cancelled"].bool, false); XCTAssertEqual(h["cancelled"].bool, false)
    }
    func testStillRetiresThePreviousScanOnTheSameChannel() async throws {
        let gate = S6C1Gate(), idx = gated(gate), c = ctx("w7")
        let first = Task { try await idx.list(project: "/tmp", context: c) }
        await waitStarted(gate, 1)
        let second = Task { try await idx.list(project: "/tmp", context: c) }
        let firstCancelled = await throwsCancel(first)
        XCTAssertTrue(firstCancelled)
        await waitStarted(gate, 2); await gate.release()
        let done = try await second.value
        XCTAssertEqual(done["cancelled"].bool, false)
    }
    func testKeepsOneWindowsScansClearOfAnothers() async throws {
        let gate = S6C1Gate(), idx = gated(gate), ownerContext = { @Sendable (o: String) -> NativeRPCContext in NativeRPCContext(caller: .nativeApp, ownerID: o) }
        let mine = Task { try await idx.list(project: "/tmp", context: ownerContext("w7")) }
        let theirs = Task { try await idx.list(project: "/tmp", context: ownerContext("w8")) }
        await waitStarted(gate, 2); await gate.release()
        let m = try await mine.value, t = try await theirs.value
        XCTAssertEqual(m["cancelled"].bool, false); XCTAssertEqual(t["cancelled"].bool, false)
    }
    func testStopsEverythingAWindowAskedForWhenTheWindowGoes() async throws {
        let gate = S6C1Gate(), idx = gated(gate), ownerContext = { @Sendable (o: String) -> NativeRPCContext in NativeRPCContext(caller: .nativeApp, ownerID: o) }
        let list = Task { try await idx.list(project: "/tmp", context: ownerContext("w7")) }
        let changes = Task { try await idx.history(project: "/tmp", relative: "a.ts", context: ownerContext("w7")) }
        let other = Task { try await idx.list(project: "/tmp", context: ownerContext("w8")) }
        await waitStarted(gate, 3)
        await idx.cancel(ownerID: "w7")
        let a = await throwsCancel(list), b = await throwsCancel(changes)
        XCTAssertTrue(a); XCTAssertTrue(b)
        await gate.release()
        let o = try await other.value
        XCTAssertEqual(o["cancelled"].bool, false)
    }
    func testDoesNotForgetASlotANewerScanHasAlreadyTaken() async throws {
        let gate = S6C1Gate(), idx = gated(gate), c = ctx("w7")
        let first = Task { try await idx.list(project: "/tmp", context: c) }
        await waitStarted(gate, 1)
        let second = Task { try await idx.list(project: "/tmp", context: c) }
        let firstCancelled = await throwsCancel(first)   // superseded scan finishes after its replacement began
        XCTAssertTrue(firstCancelled)
        await waitStarted(gate, 2)
        await idx.cancel(ownerID: "w7")                  // must still reach the newer scan
        let secondCancelled = await throwsCancel(second)
        XCTAssertTrue(secondCancelled)
    }
}
