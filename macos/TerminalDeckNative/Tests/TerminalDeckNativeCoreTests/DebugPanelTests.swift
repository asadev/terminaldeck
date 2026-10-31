import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Lane T — the Debug panel's rules (mirrors DebugPanel.test.tsx).

@Suite("Debug panel")
struct DebugPanelTests {
    private func call(_ seq: Int, _ channel: String, _ ms: Double, ok: Bool = true) -> IpcCallRecord {
        IpcCallRecord(seq: seq, channel: channel, kind: "invoke", at: 0, ms: ms, ok: ok, error: ok ? nil : "boom")
    }

    @Test func durationsAndTimes() {
        #expect(DebugPanelRules.ms(1500) == "1.50 s")
        #expect(DebugPanelRules.ms(42.4) == "42 ms")
        #expect(DebugPanelRules.ms(3.25) == "3.2 ms" || DebugPanelRules.ms(3.25) == "3.3 ms")
        #expect(DebugPanelRules.duration(-5) == "0s")
        #expect(DebugPanelRules.duration(59_000) == "59s")
        #expect(DebugPanelRules.duration(61_000) == "1m 1s")
        #expect(DebugPanelRules.duration(3_720_000) == "1h 2m")
        #expect(DebugPanelRules.clock(1_234, timeZone: TimeZone(identifier: "UTC")!) == "00:00:01.234")
    }

    @Test func channelsSummariseSlowestFirst() {
        let rows = DebugPanelRules.summarize([call(1, "a", 10), call(2, "b", 100, ok: false), call(3, "a", 30)])
        #expect(rows.map(\.channel) == ["b", "a"])
        #expect(rows[1].calls == 2 && rows[1].avgMs == 20 && rows[1].maxMs == 30)
        #expect(rows[0].errors == 1)
    }

    @Test func callsAreFilteredNewestFirstAndCapped() {
        let calls = [call(1, "session:list", 1), call(2, "mcp:list", 1), call(3, "session:write", 1)]
        #expect(DebugPanelRules.order(calls, filter: " SESSION ").map(\.seq) == [3, 1])
        #expect(DebugPanelRules.order(calls, filter: "").map(\.seq) == [3, 2, 1])
        let full = (1...500).map { call($0, "x", 1) }
        let next = DebugPanelRules.appending(call(501, "x", 1), to: full)
        #expect(next.count == 500 && next.first?.seq == 2 && next.last?.seq == 501)
    }

    @Test func recordsDecodeForgivingly() {
        let raw: [Any] = [["seq": 4, "channel": "a", "kind": "send", "at": 5, "ms": 1.5, "ok": false, "error": "no"], ["seq": 5]]
        let list = IpcCallRecord.list(raw)
        #expect(list.count == 1 && list[0].kind == "send" && !list[0].ok && list[0].error == "no")
        #expect(LogTail.decode(["file": "/x.log", "lines": ["a", 3, "b"]]) == LogTail(file: "/x.log", lines: ["a", "b"]))
    }
}
