import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud delete witness adapter")
struct DeleteWitnessTests {
    let home = "/Users/witness"
    let project = "/Users/witness/Cloud"
    let t0 = Date().addingTimeInterval(-300)
    let row = NativeRPCValue.object([.init("id", .string("session-routing-id")),
        .init("title", .string("Night work")), .init("agent", .string("Builder"))])

    struct AI {
        let session: String
        let agent: String?
        let command: Date
        let group: String
    }

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    /// The witness keeps command times as seconds since 1970 (a Double, also saved as JSON), so a Date comes back within
    /// a microsecond, not bit for bit. Matching uses a 2 s tolerance and file times are whole milliseconds.
    func sameTime(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.001 }
    func ai(_ answer: CloudDeleteWitnessAnswer) -> AI? {
        guard case let .ai(session, agent, command, group) = answer else { return nil }
        return AI(session: session, agent: agent, command: command, group: group)
    }
    func witness(_ directory: URL? = nil, since: Double = -60) -> BackendAIDeleteWitness {
        BackendAIDeleteWitness(dataRoot: directory, home: home, now: at(since))
    }
    func event(_ name: String, command: String, id: String = "call-1") throws -> BackendSessionHookEvent {
        let body: [String: Any] = ["session_id": "provider-routing-id", "cwd": project,
            "hook_event_name": name, "tool_name": "Bash", "tool_use_id": id, "tool_input": ["command": command]]
        return BackendSessionHookEvent.parse(provider: "claude", event: name, sessionID: "session-routing-id",
            body: try JSONSerialization.data(withJSONObject: body), environmentHeader: nil, peerPID: 1)
    }
    func who(_ adapter: BackendCloudDeleteWitness, _ file: String, from: Double = 0, to: Double = 2) async -> CloudDeleteWitnessAnswer {
        await adapter.who(removed: URL(fileURLWithPath: project + "/" + file), lastSeen: at(from), seenGoneAt: at(to))
    }

    @Test func mapsAIWithNamesAndCommandStart() async throws {
        let w = witness()
        w.accept(try event("PreToolUse", command: "rm notes/a.md"), session: row, at: at(0))
        let adapter = BackendCloudDeleteWitness(witness: w)
        let answer = await who(adapter, "notes/a.md")
        let mapped = try #require(ai(answer))
        #expect(mapped.session == "Night work")
        #expect(mapped.agent == "Builder")
        #expect(sameTime(mapped.command, at(0)))
        #expect(UUID(uuidString: mapped.group) != nil)
        #expect(mapped.session != "session-routing-id" && mapped.agent != "provider-routing-id")
    }

    @Test func mapsByHandAndCannotKnow() async throws {
        let w = witness()
        let adapter = BackendCloudDeleteWitness(witness: w)
        w.accept(try event("PreToolUse", command: "git checkout other"), session: row, at: at(0))
        let hand = await who(adapter, "CLAUDE.md")
        let unobserved = await who(adapter, "CLAUDE.md", from: -100, to: -80)
        #expect(hand == .notAI)
        #expect(unobserved == .cannotKnow)
        w.accept(try event("PreToolUse", command: "python3 cleanup.py", id: "script"), session: row, at: at(10))
        let script = await who(adapter, "CLAUDE.md", from: 10, to: 12)
        #expect(script == .cannotKnow)
    }

    @Test func oneCommandHasOneGroupAcrossPathsAndAdapters() async throws {
        let w = witness()
        w.accept(try event("PreToolUse", command: "rm notes/a.md boot/CLAUDE.md"), session: row, at: at(0))
        let first = await who(BackendCloudDeleteWitness(witness: w), "notes/a.md")
        let second = await who(BackendCloudDeleteWitness(witness: w), "boot/CLAUDE.md")
        let a = try #require(ai(first)), b = try #require(ai(second))
        #expect(a.group == b.group)
        #expect(UUID(uuidString: a.group) != nil)
    }

    @Test func nextCommandGetsAnotherGroupEvenForTheSameText() async throws {
        let w = witness()
        let adapter = BackendCloudDeleteWitness(witness: w)
        w.accept(try event("PreToolUse", command: "rm notes/a.md"), session: row, at: at(0))
        w.accept(try event("PostToolUse", command: "rm notes/a.md"), session: row, at: at(1))
        let first = await who(adapter, "notes/a.md")
        w.accept(try event("PreToolUse", command: "rm notes/a.md", id: "call-2"), session: row, at: at(10))
        let second = await who(adapter, "notes/a.md", from: 10, to: 12)
        let a = try #require(ai(first)), b = try #require(ai(second))
        #expect(a.group != b.group)
        #expect(sameTime(b.command, at(10)))
    }

    @Test func commandsAtTheSameTimeStillHaveSeparateGroups() async throws {
        let w = witness()
        let adapter = BackendCloudDeleteWitness(witness: w)
        w.accept(try event("PreToolUse", command: "rm a.md", id: "call-a"), session: row, at: at(0))
        w.accept(try event("PreToolUse", command: "rm b.md", id: "call-b"), session: row, at: at(0))
        let first = await who(adapter, "a.md"), second = await who(adapter, "b.md")
        let a = try #require(ai(first)), b = try #require(ai(second))
        #expect(a.command == b.command)
        #expect(a.group != b.group)
    }

    @Test func reloadKeepsGroupAndNamesAcrossTheEndEvent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("delete-witness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = witness(directory)
        before.accept(try event("PreToolUse", command: "rm -rf notes"), session: row, at: at(0))
        let first = await who(BackendCloudDeleteWitness(witness: before), "notes/a.md")
        let a = try #require(ai(first))
        let after = witness(directory, since: 30)
        let renamed = row.setting("title", .string("Renamed later")).setting("agent", .string("Another seat"))
        after.accept(try event("PostToolUse", command: "rm -rf notes"), session: renamed, at: at(40))
        let second = await who(BackendCloudDeleteWitness(witness: after), "notes/b.md", from: 5, to: 35)
        let b = try #require(ai(second))
        #expect(b.group == a.group && b.command == a.command)
        #expect(b.session == "Night work" && b.agent == "Builder")
        let saved = try Data(contentsOf: directory.appendingPathComponent(BackendAIDeleteWitness.fileName))
        let text = String(decoding: saved, as: UTF8.self)
        #expect(!text.contains("rm -rf") && !text.contains("Renamed later"))
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(BackendAIDeleteWitness.fileName).path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func reloadKeepsGroupForTheRetentionWindow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("delete-witness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = witness(directory)
        before.accept(try event("PreToolUse", command: "rm a.md"), session: row, at: at(0))
        before.accept(try event("PostToolUse", command: "rm a.md"), session: row, at: at(1))
        let first = await who(BackendCloudDeleteWitness(witness: before), "a.md")
        let a = try #require(ai(first))
        let after = witness(directory, since: BackendAIDeleteWitness.keep - 10)
        let retained = await who(BackendCloudDeleteWitness(witness: after), "a.md")
        let b = try #require(ai(retained))
        #expect(a.group == b.group)
        let expired = witness(directory, since: BackendAIDeleteWitness.keep + 10)
        let missing = await who(BackendCloudDeleteWitness(witness: expired), "a.md")
        #expect(missing == .cannotKnow)
    }

    @Test func appNameAloneDoesNotBecomeAnAgentName() async throws {
        for app in ["Claude Code", "Codex", "Gemini"] {
            let w = witness()
            let plain = row.setting("agent", .string(app))
            w.accept(try event("PreToolUse", command: "rm a.md"), session: plain, at: at(0))
            let answer = await who(BackendCloudDeleteWitness(witness: w), "a.md")
            let mapped = try #require(ai(answer))
            #expect(mapped.session == "Night work" && mapped.agent == nil)
        }
    }

    @Test func plainSessionAndSeatNameAreDistinct() async throws {
        let plain = row.setting("agent", .null).setting("seat", .object([.init("name", .string("Reviewer"))]))
        let w = witness()
        w.accept(try event("PreToolUse", command: "rm a.md"), session: plain, at: at(0))
        let answer = await who(BackendCloudDeleteWitness(witness: w), "a.md")
        let mapped = try #require(ai(answer))
        #expect(mapped.session == "Night work" && mapped.agent == "Reviewer")
    }

    @Test func missingNameNeverExposesTheSessionID() async throws {
        let w = witness()
        w.accept(try event("PreToolUse", command: "rm a.md"), session: .object([.init("id", .string("session-routing-id"))]), at: at(0))
        let answer = await who(BackendCloudDeleteWitness(witness: w), "a.md")
        #expect(answer == .cannotKnow)
    }

    @Test func forwardsBothObservationTimes() async throws {
        let w = witness()
        let adapter = BackendCloudDeleteWitness(witness: w)
        w.accept(try event("PreToolUse", command: "rm a.md"), session: row, at: at(0))
        w.accept(try event("PostToolUse", command: "rm a.md"), session: row, at: at(1))
        let overlapping = await who(adapter, "a.md")
        let stillPresentAfter = await who(adapter, "a.md", from: 10, to: 20)
        #expect(ai(overlapping) != nil)
        #expect(stillPresentAfter == .notAI)
    }

    @Test func aNonFileURLCannotBeAttributed() async {
        let answer = await BackendCloudDeleteWitness(witness: witness()).who(
            removed: URL(string: "https://example.com/a.md")!, lastSeen: at(0), seenGoneAt: at(2))
        #expect(answer == .cannotKnow)
    }

    @Test func oldBroadRecordsCannotBecomeTravellingDeletes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("delete-witness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The old format had no way to tell a git/build fallback from a plain shell removal.
        let old: [String: Any] = ["version": 1, "windows": [["session": "session-routing-id", "provider": "claude",
            "agentName": "Builder", "tool": "Bash", "key": "old-hash", "start": t0.timeIntervalSince1970,
            "background": false, "covers": [["kind": "folder", "value": project, "subtree": true]]]]]
        try JSONSerialization.data(withJSONObject: old).write(to: directory.appendingPathComponent(BackendAIDeleteWitness.fileName))
        let after = witness(directory, since: 30)
        let answer = await who(BackendCloudDeleteWitness(witness: after), "CLAUDE.md")
        #expect(answer == .cannotKnow)
    }
}
