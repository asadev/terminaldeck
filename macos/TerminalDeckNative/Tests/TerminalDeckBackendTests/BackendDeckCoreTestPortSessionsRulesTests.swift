import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreTestPortSessionsRulesTests: XCTestCase {
    private typealias V = NativeRPCValue
    private typealias Match = BackendDeckToolsSessionsTranscriptMatch
    private typealias Typing = BackendDeckToolsSessionsTyping
    private let t0 = 1_787_043_600_000.0
    private func o(_ fields: [(String, V)]) -> V { .object(fields.map { .init($0.0, $0.1) }) }
    private func session(_ id: String = "deck-1", at: Double? = nil, provider: String? = nil, resumed: Bool = false) -> V {
        var result = o([("id", .string(id)), ("createdAt", .number(at ?? t0))])
        if let provider { result = result.setting("provider", .string(provider)) }
        if resumed { result = result.setting("resumed", .bool(true)) }
        return result
    }
    private func file(_ path: String = "/store/a.jsonl", born: Double? = nil, modified: Double? = nil, bytes: Double = 4096) -> V {
        o([("path", .string(path)), ("sessionId", .string("cli-a")), ("createdAt", .number(born ?? t0)),
            ("modifiedAt", .number(modified ?? t0 + 60_000)), ("bytes", .number(bytes))])
    }
    private func match(_ one: V, _ files: [V], _ sessions: [V]) -> V { Match.match(session: one, files: files, sessionsInFolder: sessions) }
    func testShellNeverReceivesConversationAndExplainsAbsence() {
        let out = match(session(provider: "shell"), [file()], [session()])
        XCTAssertEqual(out["path"], .null); XCTAssertEqual(out["basis"], .string("none"))
        XCTAssertTrue(out["note"].string?.contains("writes no transcript") == true)
    }
    func testShellsNeverCompeteForClaudeConversation() {
        let out = match(session(provider: "claude"), [file()], [session(), session("shell-1", provider: "shell"), session("shell-2", provider: "shell")])
        XCTAssertEqual(out["path"], .string("/store/a.jsonl")); XCTAssertEqual(out["basis"], .string("only-one"))
        XCTAssertEqual(out["ambiguous"], .bool(false)); XCTAssertEqual(out["otherSessions"], .array([]))
    }
    func testClaudeStillCompetesAndUnspecifiedProviderStaysEligible() {
        let out = match(session(provider: "claude"), [file(), file("/store/b.jsonl", born: t0 + 1000)], [session(), session("deck-2", at: t0 + 1000, provider: "claude")])
        XCTAssertEqual(out["otherSessions"], .array([.string("deck-2")]))
        XCTAssertEqual(match(session(), [file()], [session()])["path"], .string("/store/a.jsonl"))
    }
    func testOnlyConversationAnswerMatchesEntireSourceShape() {
        XCTAssertEqual(match(session(), [file()], [session()]), o([("path", .string("/store/a.jsonl")), ("basis", .string("only-one")),
            ("ambiguous", .bool(false)), ("otherSessions", .array([])), ("note", .null)]))
    }
    func testOneOldConversationIsNeverSharedAmongFreshSessions() {
        let out = match(session(), [file(born: t0 - 1_800_000, modified: t0 + 600_000)], [session(), session("deck-2", at: t0 + 600_000), session("deck-3", at: t0 + 1_200_000)])
        XCTAssertEqual(out["path"], .null); XCTAssertEqual(out["basis"], .string("none"))
    }
    func testEmptyTranscriptIsNotConversation() {
        let out = match(session(), [file(bytes: 0)], [session()])
        XCTAssertEqual(out["path"], .null); XCTAssertEqual(out["basis"], .string("none"))
    }
    func testBirthRatherThanLatestWriteDecidesOwnership() {
        let out = match(session(), [file("/store/theirs.jsonl", born: t0 - 1_800_000, modified: t0 + 600_000), file("/store/mine.jsonl", modified: t0 + 1000)], [session(), session("deck-2", at: t0 + 600_000)])
        XCTAssertEqual(out["path"], .string("/store/mine.jsonl")); XCTAssertEqual(out["basis"], .string("started-together"))
        XCTAssertEqual(out["ambiguous"], .bool(true)); XCTAssertEqual(out["otherSessions"], .array([.string("deck-2")]))
    }
    func testOlderConversationsCannotBeAssignedToFreshSharedSession() {
        let out = match(session(), [file(born: t0 - 3_600_000, modified: t0 + 5000), file("/store/b.jsonl", born: t0 - 5_400_000, modified: t0 + 9000)], [session(), session("deck-2", at: t0 + 600_000)])
        XCTAssertEqual(out["path"], .null); XCTAssertEqual(out["basis"], .string("none"))
        XCTAssertTrue(out["note"].string?.contains("began before this session started") == true)
    }
    func testNearestBirthAmongTwoCandidatesReportsGuess() {
        let out = match(session(), [file(modified: t0 + 1000), file("/store/b.jsonl", born: t0 + 2000, modified: t0 + 9000)], [session(), session("deck-2", at: t0 + 600_000)])
        XCTAssertEqual(out["path"], .string("/store/a.jsonl")); XCTAssertEqual(out["basis"], .string("nearest-start"))
        XCTAssertEqual(out["ambiguous"], .bool(true)); XCTAssertTrue(out["note"].string?.contains("possibly another session's") == true)
    }
    func testTwoSessions104SecondsApartReceiveDifferentTranscripts() {
        let old = session("older", at: 1_787_049_603_000), new = session("newer", at: 1_787_049_707_000)
        let small = file("/store/small.jsonl", born: 1_787_049_603_500, modified: 1_787_049_630_000, bytes: 966)
        let big = file("/store/big.jsonl", born: 1_787_049_707_500, modified: 1_787_049_732_000, bytes: 88_000)
        let a = match(old, [small, big], [old, new]), b = match(new, [small, big], [old, new])
        XCTAssertEqual(a["path"], .string("/store/small.jsonl")); XCTAssertEqual(b["path"], .string("/store/big.jsonl"))
        XCTAssertNotEqual(a["path"], b["path"])
    }
    func testResumedSessionCannotClaimFreshSessionFile() {
        let fresh = session("fresh"), resumed = session("resumed", at: t0 + 1000, resumed: true)
        XCTAssertEqual(match(fresh, [file("/store/fresh.jsonl", born: t0 + 200, modified: t0 + 5000)], [fresh, resumed])["path"], .string("/store/fresh.jsonl"))
    }
    func testResumedSharedSessionUsesNewestAndStatesUncertainty() {
        let out = match(session(resumed: true), [file(born: t0 - 86_400_000, modified: t0 + 1000), file("/store/b.jsonl", born: t0 - 172_800_000, modified: t0 + 5000)], [session(), session("deck-2", at: t0 + 600_000)])
        XCTAssertEqual(out["path"], .string("/store/b.jsonl")); XCTAssertEqual(out["basis"], .string("newest"))
        XCTAssertTrue(out["note"].string?.contains("it was resumed") == true)
    }
    func testToleranceIncludesExactEdgeAndExcludesOneMillisecondBeyond() {
        let edge = Match.startToleranceMilliseconds
        XCTAssertEqual(match(session(), [file("/store/in.jsonl", born: t0 + edge), file("/store/out.jsonl", born: t0 + edge + 1, modified: t0 + 999_999)], [session(), session("deck-2", at: t0 + 600_000)])["path"], .string("/store/in.jsonl"))
    }
    func testGoneSessionsDoNotMakeFolderAmbiguous() {
        let out = match(session(), [file()], [session()])
        XCTAssertEqual(out["otherSessions"], .array([])); XCTAssertEqual(out["ambiguous"], .bool(false))
    }
    func testOnlySessionCanReadAnOlderConversation() {
        let older = file(born: t0 - 86_400_000, modified: t0 + 1000)
        XCTAssertEqual(match(session(), [older], [session()])["path"], older["path"])
    }
    func testLongLineAndReturnHaveSourceGapAndSeparateWrites() async throws {
        let trace = BackendDeckCoreTestPortSessionsTrace()
        let long = "please read the failing test in src/app.test.ts and fix the cause rather than the assertion, then run it"
        try await Typing.typeLine(write: { trace.append("write " + V.string($0).compact) }, text: long, submit: true, sleep: { trace.append("wait \($0)") })
        XCTAssertEqual(trace.values, ["write " + V.string(long).compact, "wait \(Typing.keyGapMilliseconds)", "write \"\\r\""])
    }
    func testPermissionMenuNamedKeysUseExactTerminalBytes() throws {
        for (name, bytes) in [("enter", "\r"), ("escape", "\u{1b}"), ("down", "\u{1b}[B"), ("ctrl-c", "\u{03}"), ("shift-tab", "\u{1b}[Z")] {
            XCTAssertEqual(try Typing.resolveKey(.string(name)).bytes, bytes, name)
        }
    }
    func testAllSourceKeyAliasesAndMenuCharacters() throws {
        for (raw, name) in [("Ctrl+C", "ctrl-c"), ("ctrl_c", "ctrl-c"), ("Return", "enter"), ("esc", "escape"), ("arrow-up", "up")] {
            XCTAssertEqual(try Typing.resolveKey(.string(raw)).name, name, raw)
        }
        for raw in ["2", "y", "é"] {
            let key = try Typing.resolveKey(.string(raw)); XCTAssertEqual(key.name, "char:" + raw); XCTAssertEqual(key.bytes, raw)
        }
    }
    func testRawControlBytesAndUnknownNameNeverBecomeInput() {
        for raw in ["\u{1b}", "\u{03}", "ctrl-z"] { XCTAssertThrowsError(try Typing.resolveKey(.string(raw))) }
        XCTAssertThrowsError(try Typing.resolveKey(.string("hyper"))) { XCTAssertTrue($0.localizedDescription.contains("enter, escape")) }
    }
    func testEscapeThenOneThenEnterAreThreeSeparatedWrites() async throws {
        let trace = BackendDeckCoreTestPortSessionsTrace()
        try await Typing.pressKeys(write: { trace.append("write " + V.string($0).compact) }, keys: Typing.resolveKeys(.array([.string("escape"), .string("1"), .string("enter")])), sleep: { trace.append("wait \($0)") })
        XCTAssertEqual(trace.values, ["write \"\\u001b\"", "wait \(Typing.escapeGapMilliseconds)", "write \"1\"", "wait \(Typing.keyGapMilliseconds)", "write \"\\r\""])
    }
}

final class BackendDeckCoreTestPortSessionsTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}
