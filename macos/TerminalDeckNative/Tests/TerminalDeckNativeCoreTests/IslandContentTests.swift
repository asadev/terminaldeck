import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors native-island.test.tsx (hootRunsIn, mergeIslandMessages), AllSessions.test.tsx
// and hoot-panel-model's allSessionsInOrder.

private func line(_ id: String, _ text: String, _ role: IntentChatLine.Role = .agent) -> IntentChatLine {
    IntentChatLine(id: id, role: role, text: text)
}

@Test func islandSnapshotIsReadLikeThePage() {
    let body: [String: Any] = ["type": "island-snapshot", "snapshot": [
        "assistant": "", "stage": "running", "line": "2 working",
        "sessions": [["id": "a", "label": "", "status": "bogus"], ["label": "no id"], ["id": "b", "label": "api", "status": "input"]],
    ]]
    let snapshot = IslandContent.snapshot(body)
    #expect(snapshot?.assistant == "Hoot")
    #expect(snapshot?.sessions == [IslandSessionRow(id: "a", label: "Session", status: "idle"),
                                   IslandSessionRow(id: "b", label: "api", status: "input")])
    #expect(snapshot?.line == "2 working")
    #expect(IslandContent.snapshot(["type": "island", "state": [:]]) == nil)
    #expect(!IslandContent.isSnapshotMessage(["type": "island"]))
}

@Test func allSessionsOrderAndWords() {
    let rows = ["exited", "idle", "working", "input", "completed", "working"].enumerated().map {
        IslandSessionRow(id: "\($0.offset)", label: "s\($0.offset)", status: $0.element)
    }
    #expect(IslandContent.inOrder(rows).map(\.id) == ["3", "2", "5", "1", "4", "0"])
    #expect(["input", "working", "completed", "exited", "waiting"].map(IslandContent.what) == ["needs you", "working", "finished", "ended", "idle"])
    #expect(IslandContentWords.rowTitle(rows[3]) == "s3: needs you")
    #expect(IslandContentWords.quiet("Hoot", stopped: true) == "Hoot is not running.")
    #expect(IslandContentWords.quiet("Nova", stopped: false) == "Ask Nova anything.")
}

@Test func islandMessagesMergeAndCap() {
    let held = (1...7).map { line("m\($0)", "t\($0)") }
    let merged = IslandContent.merge(held, [line("m7", "edited"), line("m8", "t8"), line("m9", "t9")], reset: false)
    #expect(merged.count == 8)
    #expect(merged.first?.id == "m2")
    #expect(merged.first(where: { $0.id == "m7" })?.text == "edited")
    #expect(IslandContent.merge(held, [line("x", "y")], reset: true).map(\.id) == ["x"])

    let read = IslandContent.lines(["reset": true, "messages": [
        ["id": "1", "role": "you", "text": "hi"], ["id": "2", "role": "agent", "text": "  "],
        ["id": "3", "role": "system", "text": "no"], ["id": "4", "role": "agent", "text": "hello"],
    ]])
    #expect(read.reset)
    #expect(read.lines.map(\.id) == ["1", "4"])
}

@Test func hootRunsWhereItStarted() {
    let list: [Any] = [["id": "h", "cwd": "/started/here"], ["id": "o", "cwd": "/other"]]
    #expect(IslandContent.hootRunsIn(list, hootId: "h", configured: "/configured") == "/started/here")
    #expect(IslandContent.hootRunsIn(list, hootId: "gone", configured: "/configured") == "/configured")
    #expect(IslandContent.hootRunsIn([["id": "h", "cwd": ""]], hootId: "h", configured: "/configured") == "/configured")
    #expect(IslandContent.hootRunsIn(list, hootId: nil, configured: nil) == nil)
}
