import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private let backendRoutinesGood = """
# Nightly sweep

when: schedule 02:30
when: session-failed
in: /Users/asad/Projects/terminaldeck
enabled: yes
overlap: skip
max-runs-per-hour: 4
quiet-for: 2m
expect-every: 26h

---

Run the tests. If anything fails, say what.

"""
private let backendRoutinesSimple = "# Sweep\n\nwhen: manual\nin: /tmp/project\n\n---\n\nHave a look.\n"
private func backendRoutinesTemp() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-routines-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); return directory
}
private func backendRoutinesDraft(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }

@Suite("Routine format — format.ts")
struct BackendRoutinesFormatTests {
    @Test func parsesWholeRoutineAndRoundTrips() throws {
        let routine = try #require(BackendRoutinesFormat.parseRoutine("nightly-sweep", text: backendRoutinesGood).routine)
        #expect(routine.id == "nightly-sweep"); #expect(routine.name == "Nightly sweep")
        #expect(routine.triggers == [.schedule(.at(minutes: 150, days: nil)), .sessionFailed])
        #expect(routine.folder == "/Users/asad/Projects/terminaldeck"); #expect(routine.overlap == .skip)
        #expect(routine.maxRunsPerHour == 4); #expect(routine.quietForMs == 120_000)
        #expect(routine.expectEveryMs == 26 * 3_600_000.0)  // format.test.ts toBe(26 * 3600_000); a Double? needs a Double, not an Int, on the right
        #expect(routine.prompt == "Run the tests. If anything fails, say what.")
        #expect(BackendRoutinesFormat.parseRoutine("nightly-sweep", text: BackendRoutinesFormat.serializeRoutine(routine)).routine == routine)
    }
    @Test func defaultsKeepFileShort() throws {
        let routine = try #require(BackendRoutinesFormat.parseRoutine("quick", text: backendRoutinesSimple).routine)
        #expect(routine.maxRunsPerHour == 6); #expect(routine.maxRunsPerDay == 24); #expect(routine.quietForMs == 30_000)
        let text = BackendRoutinesFormat.serializeRoutine(routine)
        #expect(!text.contains("max-runs-per-hour")); #expect(!text.contains("quiet-for"))
        #expect(text.contains("when: manual")); #expect(text.contains("in: /tmp/project"))
    }
    @Test func handlesCRLFAndBareCR() {
        let plain = BackendRoutinesFormat.parseRoutine("crlf", text: backendRoutinesGood)
        #expect(BackendRoutinesFormat.parseRoutine("crlf", text: backendRoutinesGood.replacingOccurrences(of: "\n", with: "\r\n")) == plain)
        #expect(BackendRoutinesFormat.parseRoutine("crlf", text: backendRoutinesGood.replacingOccurrences(of: "\n", with: "\r")) == plain)
    }
    @Test func listsEveryMissingPartAndMalformedKey() {
        let parsed = BackendRoutinesFormat.parseRoutine("empty", text: "# Nothing\nnot a header\n")
        #expect(!parsed.ok)
        #expect(parsed.problems == ["`not a header` is not a `key: value` line.",
            "This routine has no `when:` line, so nothing can start it.",
            "This routine has no `in:` line, so there is nowhere for it to run.",
            "This routine has no `---` line, so there is no prompt beneath it."])
    }
    @Test func unknownKeysSurviveWithValuesAndOrder() throws {
        let text = backendRoutinesSimple.replacingOccurrences(of: "in: /tmp/project", with: "in: /tmp/project\nnotify: slack\nfuture: yes\nnotify: email")
        let parsed = BackendRoutinesFormat.parseRoutine("future", text: text), routine = try #require(parsed.routine)
        #expect(parsed.warnings.count == 3); #expect(routine.unknown["notify"] == ["slack", "email"])
        let serialized = BackendRoutinesFormat.serializeRoutine(routine)
        #expect(serialized.contains("notify: slack\nnotify: email\nfuture: yes"))
        #expect(BackendRoutinesFormat.parseRoutine("future", text: serialized).routine == routine)
    }
    @Test func clampsBothCeilingsAndMinimumWithWarnings() throws {
        let greedy = backendRoutinesSimple.replacingOccurrences(of: "in: /tmp/project", with: "in: /tmp/project\nmax-runs-per-hour: 100000\nmax-runs-per-day: 999999")
        let parsed = BackendRoutinesFormat.parseRoutine("greedy", text: greedy), routine = try #require(parsed.routine)
        #expect(routine.maxRunsPerHour == 60); #expect(routine.maxRunsPerDay == 500)
        #expect(parsed.warnings == ["`max-runs-per-hour: 100000` was lowered to 60, which is the most this app will run a routine unattended.",
            "`max-runs-per-day: 999999` was lowered to 500, which is the most this app will run a routine unattended."])
        let minimum = BackendRoutinesFormat.parseRoutine("minimum", text: backendRoutinesSimple.replacingOccurrences(of: "in: /tmp/project", with: "in: /tmp/project\nmax-runs-per-hour: 0"))
        #expect(minimum.routine?.maxRunsPerHour == 1)
        #expect(minimum.warnings == ["`max-runs-per-hour: 0` was raised to 1 — use `enabled: no` to stop a routine."])
    }
    @Test func refusesBadBooleansPoliciesCountsAndDurations() {
        for (field, refusal) in [("enabled: maybe", "`enabled: maybe` should be yes or no."),
            ("overlap: parallel", "`overlap: parallel` should be queue, skip or cancel."),
            ("max-runs-per-hour: 2.5", "`max-runs-per-hour: 2.5` should be a whole number."),
            ("quiet-for: 15", "`quiet-for: 15` should be a duration, like 30s."),
            ("expect-every: soon", "`expect-every: soon` should be a duration, like 26h.")] {
            let parsed = BackendRoutinesFormat.parseRoutine("bad", text: backendRoutinesSimple.replacingOccurrences(of: "in: /tmp/project", with: "in: /tmp/project\n" + field))
            #expect(parsed.problems == [refusal])
        }
        for text in ["yes", "true", "ON", "1"] {
            #expect(BackendRoutinesFormat.parseRoutine("yes", text: backendRoutinesSimple.replacingOccurrences(of: "in: /tmp/project", with: "in: /tmp/project\nenabled: " + text)).routine?.enabled == true)
        }
        for text in ["no", "false", "OFF", "0"] {
            #expect(BackendRoutinesFormat.parseRoutine("no", text: backendRoutinesSimple.replacingOccurrences(of: "in: /tmp/project", with: "in: /tmp/project\nenabled: " + text)).routine?.enabled == false)
        }
    }
    @Test func promptIsUTF8CappedAndCanContainAnotherSeparator() throws {
        let header = "# Huge\nwhen: manual\nin: /tmp/project\n---\n"
        #expect(BackendRoutinesFormat.parseRoutine("huge", text: header + String(repeating: "x", count: 8_193)).problems == ["The prompt is longer than 8192 bytes."])
        #expect(BackendRoutinesFormat.parseRoutine("huge", text: header + String(repeating: "🙂", count: 2_049)).problems == ["The prompt is longer than 8192 bytes."])
        #expect(BackendRoutinesFormat.parseRoutine("empty", text: header + "\n \t").problems == ["The prompt below `---` is empty."])
        #expect(BackendRoutinesFormat.parseRoutine("huge", text: String(repeating: "x", count: 65_537)).problems == ["This file is larger than 65536 bytes."])
        let ruled = try #require(BackendRoutinesFormat.parseRoutine("ruled", text: header + "\nOne\n\n---\n\nTwo\n").routine)
        #expect(ruled.prompt == "One\n\n---\n\nTwo")
    }
    @Test func splitsCommentsAndTruncatesNames() {
        let split = BackendRoutinesFormat.splitDocument("## Name\n# note\nwhen: manual\n---\nText")
        #expect(split.heading == "Name"); #expect(split.comments == ["note"]); #expect(split.header == ["when: manual"]); #expect(split.prompt == "Text")
        #expect(BackendRoutinesFormat.parseRoutine("long", text: backendRoutinesSimple.replacingOccurrences(of: "# Sweep", with: "# " + String(repeating: "a", count: 81))).routine?.name.utf16.count == 80)
    }
    @Test func readsEveryTriggerAndReportsUnknownGrammar() {
        let cases: [(String, BackendRoutinesTrigger)] = [("session-finished", .sessionFinished), ("session-failed", .sessionFailed),
            ("session-idle 15m", .sessionIdle(afterMs: 900_000)), ("alert critical", .alert(severity: "critical", alertKind: nil)),
            ("alert session-blocked", .alert(severity: nil, alertKind: "session-blocked")), ("alert", .alert(severity: nil, alertKind: nil)),
            ("file-change src/**", .fileChange(glob: "src/**")), ("file-change", .fileChange(glob: "**/*")), ("git-change", .gitChange), ("manual", .manual)]
        for (text, trigger) in cases { #expect(BackendRoutinesFormat.parseTrigger(text).trigger == trigger) }
        #expect(BackendRoutinesFormat.parseTrigger("session-idle 15").problem == "`when: session-idle` needs a duration, like `session-idle 15m`")
        #expect(BackendRoutinesFormat.parseTrigger("alert bad_thing").problem != nil)
        #expect(BackendRoutinesFormat.parseTrigger("file-change x\0y").problem != nil)
        #expect(BackendRoutinesFormat.parseTrigger("file-change " + String(repeating: "x", count: 201)).problem != nil)
        #expect(BackendRoutinesFormat.parseTrigger("when-the-moon-is-full").problem?.contains("schedule 09:00") == true)
    }
    @Test func durationNeedsUnitsAndSerializesWholeUnits() {
        for (text, value) in [("30s", 30_000.0), ("15m", 900_000.0), ("2h", 7_200_000.0), ("1d", 86_400_000.0)] {
            #expect(BackendRoutinesFormat.parseDuration(text) == value); #expect(BackendRoutinesFormat.serializeDuration(value) == text)
        }
        for text in ["15", "0m", "", "2H", "1000000s"] { #expect(BackendRoutinesFormat.parseDuration(text) == nil) }
        #expect(BackendRoutinesFormat.serializeDuration(1_501) == "2s")
        #expect(BackendRoutinesFormat.serializeDuration(0) == "1s")
        #expect(BackendRoutinesFormat.parseDuration("\u{FEFF}15m\u{FEFF}") == 900_000)
        #expect(BackendRoutinesFormat.parseDuration("\u{0085}15m") == nil)
    }
    @Test func idsAreSafeAndReservedNamesRemainRefused() {
        #expect(BackendRoutinesFormat.slugify("Nightly Sweep!") == "nightly-sweep")
        #expect(BackendRoutinesFormat.slugify("../../etc/passwd") == "etc-passwd")
        for id in ["../x", "CON", "", "con", "lpt1", "aux", "a-", "Nightly Sweep"] { #expect(!BackendRoutinesFormat.isValidId(id)) }
        #expect(BackendRoutinesFormat.suggestId("Nightly sweep", taken: ["nightly-sweep"]) == "nightly-sweep-2")
        #expect(BackendRoutinesFormat.suggestId("Con", taken: []) == "con-routine")
        #expect(BackendRoutinesFormat.suggestId("", taken: []) == "routine")
        #expect(!BackendRoutinesFormat.parseRoutine("../../state", text: backendRoutinesGood).ok)
    }
    @Test func draftsShareParserAndCannotInjectHeaders() throws {
        let draft = backendRoutinesDraft([("name", .string("Sweep\nin: /")), ("when", .array([.string("git-change"), .string("manual")])),
            ("in", .string("/tmp/project")), ("prompt", .string("when: schedule every 5m\nin: /\n")), ("overlap", .string("skip")), ("maxRunsPerHour", .number(999_999))])
        let parsed = BackendRoutinesFormat.routineFromDraft("sneaky", draft: draft), routine = try #require(parsed.routine)
        #expect(routine.folder == "/tmp/project"); #expect(!routine.name.contains("\n"))
        #expect(routine.triggers == [.gitChange, .manual]); #expect(routine.maxRunsPerHour == 60); #expect(routine.overlap == .skip)
        #expect(!BackendRoutinesFormat.routineFromDraft("nothing", draft: draft.removing("when")).ok)
        #expect(BackendRoutinesFormat.routineFromDraft("ten", draft: draft.setting("when", .array(Array(repeating: .string("manual"), count: 11)))).routine?.triggers.count == 10)
    }
    @Test func serializationKeepsMultilinePromptAndDisabledFlag() {
        let routine = BackendRoutinesRoutine(id: "x", name: "X", triggers: [.manual], folder: "/tmp/x", prompt: "Line one\n\nLine two", enabled: false)
        let text = BackendRoutinesFormat.serializeRoutine(routine)
        #expect(text.contains("enabled: no")); #expect(text.contains("---\n\nLine one\n\nLine two\n"))
    }
}

@Suite("Routine files — store.ts")
struct BackendRoutinesStoreTests {
    @Test func recordsLiveOutsideCopilotWritableBoundary() {
        #expect(BackendRoutinesPaths.routinesDirFor("/data") == "/data/routines")
        #expect(BackendRoutinesPaths.runtimeStateFileFor("/data") == "/data/routine-state.json")
        #expect(!BackendRoutinesPaths.routinesDirFor("/data").contains("copilot"))
        #expect(!BackendRoutinesPaths.runtimeStateFileFor("/data").contains("copilot"))
    }
    @Test func missingDirectoryIsEmptyAndHandwrittenBrokenFilesStayListed() throws {
        let dir = try backendRoutinesTemp(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BackendRoutinesStore(directory: dir.appendingPathComponent("missing")).list().isEmpty)
        try Data(backendRoutinesSimple.utf8).write(to: dir.appendingPathComponent("sweep.md"))
        try Data("# Broken\nwhen: nonsense\n".utf8).write(to: dir.appendingPathComponent("broken.md"))
        try Data(backendRoutinesSimple.utf8).write(to: dir.appendingPathComponent("Not Valid.md"))
        try Data("hello".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("archive"), withIntermediateDirectories: true)
        let listed = BackendRoutinesStore(directory: dir).list()
        #expect(listed.map(\.id) == ["Not Valid", "broken", "sweep"])
        #expect(listed.last?.routine?.name == "Sweep")
        #expect(listed[0].problems.first?.contains("not a usable") == true)
        #expect(listed[1].problems.joined().contains("nonsense"))
    }
    @Test func canonicalSaveRoundTripsAndRemovalTellsTruth() throws {
        let dir = try backendRoutinesTemp(); defer { try? FileManager.default.removeItem(at: dir) }
        let routine = try #require(BackendRoutinesFormat.parseRoutine("sweep", text: backendRoutinesSimple).routine), store = BackendRoutinesStore(directory: dir)
        #expect(try store.save(routine) == dir.appendingPathComponent("sweep.md").path)
        #expect(try store.read("sweep").routine == routine)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["sweep.md"])
        #expect(try store.remove("sweep")); #expect(try !store.remove("sweep")); #expect(store.list().isEmpty)
    }
    @Test func textEditorKeepsExactBytesAndComments() throws {
        let dir = try backendRoutinesTemp(); defer { try? FileManager.default.removeItem(at: dir) }
        let hand = "# Sweep\r\n\r\n# NOTE: kept\r\nwhen: manual\r\nin: /tmp/project\r\n\r\n---\r\n\r\nHave a look.\r\n", store = BackendRoutinesStore(directory: dir)
        _ = try store.saveText("sweep", text: hand)
        #expect(store.readText("sweep").text == hand)
        #expect(try Data(contentsOf: dir.appendingPathComponent("sweep.md")) == Data(hand.utf8))
        let routine = try #require(try store.read("sweep").routine)
        #expect(!BackendRoutinesFormat.serializeRoutine(routine).contains("NOTE:"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["sweep.md"])
    }
    @Test func validatesPathsInEveryDirectionAndChecksBytesBeforeRead() throws {
        let dir = try backendRoutinesTemp(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackendRoutinesStore(directory: dir)
        for id in ["../../state", "/etc/passwd", ".."] {
            #expect(throws: (any Error).self) { try BackendRoutinesStore.routineFilePath(dir.path, id: id) }
            #expect(throws: (any Error).self) { try store.remove(id) }
            #expect(throws: (any Error).self) { try store.saveText(id, text: "x") }
            #expect(!store.readText(id).ok)
        }
        try Data(repeating: 120, count: 65_537).write(to: dir.appendingPathComponent("huge.md"))
        #expect(store.readText("huge").error == "This file is larger than 65536 bytes.")
        #expect(try store.read("huge").problems == ["This file is larger than 65536 bytes."])
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("linked.md"), withDestinationURL: dir.appendingPathComponent("huge.md"))
        #expect(store.readText("linked").error == "This file is larger than 65536 bytes.")
        let nested = dir.appendingPathComponent("folder.md")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: nested.appendingPathComponent("keep.txt"))
        #expect(try !store.remove("folder"))
        #expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent("keep.txt").path))
    }
    @Test func capKeepsOverflowVisibleAndDisarmed() throws {
        let dir = try backendRoutinesTemp(); defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<103 { try Data(backendRoutinesSimple.utf8).write(to: dir.appendingPathComponent(String(format: "r%04d.md", index))) }
        let listed = BackendRoutinesStore(directory: dir).list()
        #expect(listed.filter(\.ok).count == 100); #expect(listed.filter { !$0.ok }.count == 3)
        #expect(listed.last?.problems == ["This folder holds more than 100 routines, so this one was not loaded."])
    }
    @Test func nativeWatcherNoticesHandEditAndStops() async throws {
        let dir = try backendRoutinesTemp(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackendRoutinesStore(directory: dir), changes = BackendRoutinesTestCounter()
        try store.startWatching(onChange: { changes.increment() }, debounceMs: 20)
        try await Task.sleep(for: .milliseconds(250))
        try Data(backendRoutinesSimple.utf8).write(to: dir.appendingPathComponent("sweep.md"))
        for _ in 0..<40 { if changes.count > 0 { break }; try await Task.sleep(for: .milliseconds(50)) }
        #expect(changes.count > 0); #expect(store.list().count == 1)
        store.stop(); let before = changes.count
        try Data("changed".utf8).write(to: dir.appendingPathComponent("sweep.md"))
        try await Task.sleep(for: .milliseconds(200)); #expect(changes.count == before)
    }
}

private final class BackendRoutinesTestCounter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("Routine bookkeeping — runtime-state.ts")
struct BackendRoutinesRuntimeStateTests {
    @Test func startsEmptyAndRunBudgetPauseAndRefusalSurviveRestart() throws {
        let dir = try backendRoutinesTemp(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("routine-state.json"), now = 100_000_000.0
        let state = BackendRoutinesRuntimeState(file: file, now: { now }, debounceMs: 0)
        #expect(state.get("x") == BackendRoutinesRuntime())
        state.update("x", change: { value in value.runs = [now - 1_000]; value.pausedReason = "failed five times"; value.consecutiveFailures = 5
            value.lastFiredAt = now; value.lastFinishedAt = now; value.lastOutcome = "failed"; value.lastError = "failed"
            value.noteRefusal(.init(at: now, tool: "settings.write", reason: "not-permitted-unattended", runId: "r1")) }, immediate: true)
        let restored = BackendRoutinesRuntimeState(file: file, now: { now }).get("x")
        #expect(restored == state.get("x")); #expect(restored.runs.count == 1); #expect(restored.pausedReason != nil)
        let json = try NativeRPCValue.parseJSON(Data(contentsOf: file))
        #expect(json["version"].number == 1)
        #expect(json["routines"]["x"]["refusals"].elements?.first?["runId"].string == "r1")
    }
    @Test func sanitizesDiskFieldsWithoutTrustingTypesOrPrototype() throws {
        let dir = try backendRoutinesTemp(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        let row = backendRoutinesDraft([("runs", .array([.string("wrong"), .number(1), .null, .number(2)])),
            ("lastFiredAt", .string("wrong")), ("lastFinishedAt", .number(3)), ("lastOutcome", .string("wrong")),
            ("lastError", .string(String(repeating: "x", count: 501))), ("consecutiveFailures", .number(2.9)),
            ("pausedReason", .string(String(repeating: "y", count: 301))), ("refusals", .array([
                backendRoutinesDraft([("at", .number(1)), ("tool", .string("wrong"))]),
                BackendRoutinesRefusal(at: 2, tool: String(repeating: "t", count: 101), reason: "declined", runId: "r").wire]))])
        try backendRoutinesDraft([("version", .number(999)), ("routines", backendRoutinesDraft([("__proto__", row), ("x", row)]))]).encodedJSON().write(to: file)
        let state = BackendRoutinesRuntimeState(file: file), value = state.get("x")
        #expect(value.runs == [1, 2]); #expect(value.lastFiredAt == nil); #expect(value.lastFinishedAt == 3)
        #expect(value.lastOutcome == nil); #expect(value.lastError?.count == 500); #expect(value.pausedReason?.count == 300)
        #expect(value.consecutiveFailures == 2); #expect(value.refusals.count == 1); #expect(value.refusals.first?.tool.count == 100)
        #expect(state.get("__proto__") == BackendRoutinesRuntime())
    }
    @Test func boundsLoadedStampsAndNewestRefusals() throws {
        let dir = try backendRoutinesTemp(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        let row = backendRoutinesDraft([("runs", .array((0..<605).map { .number(Double($0)) })),
            ("refusals", .array((0..<15).map { BackendRoutinesRefusal(at: Double($0), tool: "settings.write", reason: "declined", runId: "r\($0)").wire }))])
        try backendRoutinesDraft([("routines", backendRoutinesDraft([("x", row)]))]).encodedJSON().write(to: file)
        let value = BackendRoutinesRuntimeState(file: file).get("x")
        #expect(value.runs.count == 600); #expect(value.runs.first == 5); #expect(value.refusals.count == 10); #expect(value.refusals.first?.runId == "r5")
        var runtime = BackendRoutinesRuntime()
        for index in 0..<11 { BackendRoutinesRuntimeState.noteRefusal(&runtime, refusal: .init(at: Double(index), tool: "x", reason: "no", runId: "r\(index)")) }
        #expect(runtime.refusals.first?.runId == "r1")
    }
    @Test func prunesAgedStampsAndForgetsMissingRoutines() throws {
        let dir = try backendRoutinesTemp(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = 100_000_000.0, cutoff = now - 25 * 3_600_000
        let state = BackendRoutinesRuntimeState(file: dir.appendingPathComponent("state.json"), now: { now }, debounceMs: 0)
        state.update("kept", change: { $0.runs = [cutoff - 1, cutoff, now] })
        state.update("gone", change: { $0.pausedReason = "paused" })
        #expect(state.get("kept").runs == [cutoff, now])
        state.forgetMissing(["kept"])
        let json = try NativeRPCValue.parseJSON(Data(contentsOf: dir.appendingPathComponent("state.json")))
        #expect(json["routines"]["gone"] == .missing)
    }
    @Test func corruptStateIsEmptyAndPersistenceFailureIsObservable() throws {
        let dir = try backendRoutinesTemp(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        try Data("not json".utf8).write(to: file)
        #expect(BackendRoutinesRuntimeState(file: file).get("x") == BackendRoutinesRuntime())
        let failed = BackendRoutinesRuntimeState(file: dir, debounceMs: 0)
        failed.update("x", change: { $0.lastFiredAt = 1 }, immediate: true)
        #expect(failed.lastPersistenceError != nil); #expect(failed.get("x").lastFiredAt == 1)
    }
}
