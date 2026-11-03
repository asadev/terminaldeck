import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Agents seat (2 Nov, for install #25): what the Agents page's "At work" refresh costs under a scripted 60 s stream of
/// change events. Opt-in, never part of a normal run: TD_AGENTS_REFRESH_BENCH=1, and TD_AGENTS_REFRESH_BENCH_CHAT=<a Hoot
/// chat.json> to measure a real conversation (its last 500 events, as `agents-watch:list` reads Hoot) instead of the
/// built-in one. Prints one "BENCH" line per figure.
final class AGTAgentsRefreshBenchTests: XCTestCase {
    static let environment = ProcessInfo.processInfo.environment
    static var enabled: Bool { environment["TD_AGENTS_REFRESH_BENCH"] == "1" }
    /// The scripted stream: one change event every 100 ms (session status changes and Hoot chat updates) for 60 s.
    static let streamSeconds = Double(environment["TD_AGENTS_REFRESH_BENCH_SECONDS"] ?? "") ?? 60
    static let eventGap: Duration = .milliseconds(100)

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    /// Hoot's snapshot as `chat.snapshot(limit: 500)` hands it to the list.
    static func snapshot() throws -> NativeRPCValue {
        if let path = environment["TD_AGENTS_REFRESH_BENCH_CHAT"], !path.isEmpty {
            let chat = try NativeRPCValue.parseJSON(try Data(contentsOf: URL(fileURLWithPath: path)))
            let conversation = try chat["conversationId"].requireString("conversationId", nonempty: true)
            let events = (chat["events"].elements ?? []).filter { $0["conversationId"].string == conversation }.suffix(500)
            return .object([.init("conversationId", .string(conversation)), .init("provider", .string("claude")),
                            .init("alive", .bool(true)), .init("busy", .bool(false)), .init("pending", .array([])),
                            .init("events", .array(Array(events)))])
        }
        var events: [HootChatEvent] = [], sequence = 0
        func add(_ turn: Int, _ record: HootChatRecord) {
            sequence += 1
            events.append(HootChatEvent(conversationID: "bench", turnID: "turn-\(turn)", sequence: sequence, provider: .claude,
                                        record: record, at: Double(1_700_000_000 + sequence)))
        }
        let listing = (0..<40).map { "/Users/someone/Projects/app/Sources/File\($0).swift  token=abc\($0)def  \(UUID().uuidString)" }
            .joined(separator: "\n")
        for turn in 0..<33 {
            add(turn, .text(.user, id: "u\(turn)", "Please look at the sessions and tell me what is running."))
            for piece in 0..<6 { add(turn, .text(.textDelta, id: "m\(turn)", "Part \(piece) of the answer. ")) }
            add(turn, .text(.message, id: "m\(turn)", "Here is what is running."))
            for tool in 0..<3 {
                let id = "t\(turn)-\(tool)"
                add(turn, .init(.toolCall, id: id, value: .object([.init("name", .string("mcp__deck-control__sessions_list")),
                                                                   .init("input", .object([.init("project", .string("app"))]))])))
                add(turn, .init(.toolResult, id: id, value: .object([.init("output", .string(listing)), .init("isError", .bool(false))])))
            }
            add(turn, .init(.completed, id: "c\(turn)", value: .object([])))
        }
        return .object([.init("conversationId", .string("bench")), .init("provider", .string("claude")),
                        .init("alive", .bool(true)), .init("busy", .bool(false)), .init("pending", .array([])),
                        .init("events", .array(events.map(\.wireValue)))])
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func perCall(_ label: String, times: Int = 20, _ work: () throws -> Void) rethrows {
        try work()   // warm
        let cpu = cpuSeconds(), clock = ContinuousClock(), start = clock.now
        for _ in 0..<times { try work() }
        let wall = clock.now - start
        print(String(format: "BENCH %@: %.2f ms per call (cpu %.2f ms)", label,
                     seconds(wall) * 1000 / Double(times), (cpuSeconds() - cpu) * 1000 / Double(times)))
    }

    /// Since 2 Nov: the same stream goes through the list's pacing (at most one read per 1.5 s, one at a time), and the
    /// list reads Hoot's row only. The figures before the change came from this file's first version at 4d9ebc75, where
    /// every event started a full list that projected and cleaned Hoot's whole conversation (`AWAgentsWatchHoot.project`).
    @MainActor
    func testPacedListUnderTheScriptedStream() async throws {
        try XCTSkipUnless(Self.enabled, "Set TD_AGENTS_REFRESH_BENCH=1 to measure.")
        let snapshot = try Self.snapshot()
        print("BENCH snapshot: \(snapshot["events"].elements?.count ?? 0) Hoot events")
        try Self.perCall("list's Hoot part (row only)") { _ = try AWAgentsWatchHoot.agents(snapshot) }
        try Self.perCall("conversation read, results already cleaned") { _ = try AWAgentsWatchHoot.project(snapshot) }
        try Self.perCall("conversation read, nothing cleaned yet") {
            AWAgentsWatchHoot.Cleaned.shared.reset(); _ = try AWAgentsWatchHoot.project(snapshot)
        }
        let pacer = AGTRefreshPacer { await Task.detached { _ = try? AWAgentsWatchHoot.agents(snapshot) }.value }
        let cpu = Self.cpuSeconds(), clock = ContinuousClock(), start = clock.now
        let events = Int(Self.streamSeconds * 10)
        for _ in 0..<events {
            pacer.request()
            try await Task.sleep(for: Self.eventGap)
        }
        try await Task.sleep(for: .milliseconds(1_600))   // the trailing read after the last event
        let used = Self.cpuSeconds() - cpu, seconds = Self.seconds(clock.now - start)
        print(String(format: "BENCH after: %d events, %d list rebuilds in %.1f s = %.0f rebuilds/min; cpu %.1f s = %.1f%% of one core",
                     events, pacer.reads, seconds, Double(pacer.reads) * 60 / seconds, used, used / seconds * 100))
        XCTAssertLessThanOrEqual(pacer.reads, Int(seconds / 1.5) + 2)
    }
}
