import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Reviewer MUST-FIX (28 Oct) on the board settle: a board change waiting for the 2 s write when a message is sent
/// must still reach that session. "Since your last message" counts from the prompt lines that message was shown.
@Suite("Board settle: no change lost before a message", .serialized)
struct BoardSettlePromptTests {
    /// The changes the board has, by time (ms), as the prompt lines list them.
    final class Board: @unchecked Sendable {
        private let lock = NSLock(); private var rows: [(at: Double, text: String)] = []
        func add(_ text: String) { lock.withLock { rows.append((Date().timeIntervalSince1970 * 1000, text)) } }
        func lines(since: Date?) -> String {
            let floor = since.map { $0.timeIntervalSince1970 * 1000 } ?? 0
            return lock.withLock { rows.filter { $0.at > floor }.map(\.text).joined(separator: "\n") }
        }
    }
    final class CenterBox: @unchecked Sendable { var center: DeckMemorySessionCenter? }

    @Test func aChangeHalfASecondBeforeAMessageIsInTheNextPromptLines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-board-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = BackendPTYManager(inheritedEnvironment: ["HOME": root.path, "PATH": "/usr/bin:/bin"], onEvent: { _ in })
        let session = try manager.create(.init(cwd: root.path, provider: "claude"),
            spawn: .init(provider: "claude", command: "/bin/cat", args: [], path: "/usr/bin:/bin"))
        defer { manager.kill(session.id) }
        let board = Board(), box = CenterBox()
        var services = DeckMemorySessionServices.files(memoryRoot: { root })
        services.owner = { _, _ in DeckMemorySessionOwner(kind: .lead, id: "p", name: "Lead", project: "p", memoryOn: true) }
        services.startContext = { _, _, _, _ in "" }
        services.promptLines = { _, meta in board.lines(since: box.center?.lastPromptDate(sessionID: meta.id)) }
        services.turnEnded = { _ in }; services.activity = { _ in }
        let center = DeckMemorySessionCenter(dataRoot: root, manager: manager, services: services)
        box.center = center
        try center.start(); defer { center.stop() }
        await center.started(session, input: .init(cwd: root.path, provider: "claude"))   // prompt.md made now (empty board)
        let prompt = DeckMemorySessionHook.session(center.root, session.id).appendingPathComponent("prompt.md")

        try await Task.sleep(for: .milliseconds(50))
        board.add("iLoop finished its task")
        await center.memoryChanged(DeckMemoryChange(area: .board))       // its write waits for the 2 s settle
        try await Task.sleep(for: .milliseconds(500))
        // The message, half a second later: the hook printed the prompt.md made BEFORE the change.
        let event = "{\"event\":\"prompt\",\"session\":\"\(session.id)\",\"name\":\"prompt\",\"at\":\(Date().timeIntervalSince1970),\"input\":{\"prompt\":\"ok do 1\"}}"
        let events = DeckMemorySessionHook.events(center.root)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        try Data(event.utf8).write(to: events.appendingPathComponent("0001-prompt.json"))

        var shown = ""
        for _ in 0..<80 {   // up to 4 s: past the settle write too
            shown = (try? String(contentsOf: prompt, encoding: .utf8)) ?? ""
            if shown.contains("iLoop finished its task") { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(shown.contains("iLoop finished its task"), "the change the message was not shown is in the next prompt lines")
    }

    @Test func sinceCountsFromWhatTheMessageWasShown() {
        #expect(DeckMemorySessionCenter.shownSince(prompt: 2_000, built: 1_000) == 1_000)
        #expect(DeckMemorySessionCenter.shownSince(prompt: 2_000, built: 3_000) == 2_000, "never later than the message")
        #expect(DeckMemorySessionCenter.shownSince(prompt: 2_000, built: nil) == 2_000)
    }
}
