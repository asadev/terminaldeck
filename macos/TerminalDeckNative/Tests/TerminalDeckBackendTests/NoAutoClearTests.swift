import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 28 Oct 2026 (Asad): "This slash clear command should not happen. This is not a good feature. For now, remove this
/// feature completely." Terminal Deck never types `/clear` or `/new` (or a "read start.md" line) into any session, for
/// every session and every user: no planned refresh, no Refresh now, no memory.refresh.now, no refresh point. Hoot is
/// never restarted on a fresh conversation to empty his desk. Records written before still read.
final class NoAutoClearTests: XCTestCase {
    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources")

    /// The guard: no code anywhere in the app writes a command that starts a fresh conversation into a session.
    func testNoCodePathWritesClearOrNewIntoASession() throws {
        let files = (FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 500, "the whole Sources tree was read: " + Self.sources.path)
        // A quoted "/clear" or "/new" (alone, or followed by a key or text) is what was typed into a session.
        let pattern = try NSRegularExpression(pattern: "\"/(clear|new)\\b")
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let line = text[..<(Range(match.range, in: text)?.lowerBound ?? text.startIndex)].filter { $0 == "\n" }.count + 1
                found.append(file.lastPathComponent + ":" + String(line))
            }
        }
        XCTAssertEqual(found, [], "nothing may type /clear or /new into a session")
        // Memory reads sessions; it holds no way to type into one. Hoot's desk holds no way to swap his conversation.
        let center = try String(contentsOf: Self.sources.appendingPathComponent("TerminalDeckBackend/DeckMemorySessionCenter.swift"), encoding: .utf8)
        XCTAssertFalse(center.contains("try await write("), "the session centre has no session writer")
        let desk = try String(contentsOf: Self.sources.appendingPathComponent("TerminalDeckBackend/BackendHootDesk.swift"), encoding: .utf8)
        XCTAssertFalse(desk.contains("swap"), "Hoot's desk cannot restart Hoot on a fresh conversation")
    }

    func testTheRefreshToolAndPartAreGone() {
        XCTAssertFalse(DeckMemoryTools.toolIDs.contains("memory.refresh.now"))
        XCTAssertFalse(DeckMemoryTools.sessionToolNames.contains("memory_refresh_now"))
        XCTAssertFalse(DeckMemoryToolNames.ids.contains("memory.refresh.now"))
        XCTAssertNil(DeckMemoryPart(rawValue: "refresh"))
    }

    /// A seat record written before (with the old refresh point and the "adopted" mark) still reads, and is
    /// written back without them.
    func testRecordsWrittenBeforeStillRead() throws {
        let old = #"{"kind":"lead","id":"crm","name":"Alex","project":"crm","memoryOn":true,"refreshAt":0.5,"adopted":true,"hand":1,"job":"Brokers"}"#
        let owner = try JSONDecoder().decode(DeckMemorySessionOwner.self, from: Data(old.utf8))
        XCTAssertEqual(owner, DeckMemorySessionOwner(kind: .lead, id: "crm", name: "Alex", project: "crm", memoryOn: true, hand: 1, job: "Brokers"))
        XCTAssertTrue(owner.hasDesk, "it keeps the lead's memory")
        let written = String(decoding: try JSONEncoder().encode(owner), as: UTF8.self)
        XCTAssertFalse(written.contains("refreshAt")); XCTAssertFalse(written.contains("adopted"))
    }

    /// A category settings file that still names the refresh is written once more without it, every other value kept,
    /// and the earlier text is kept in archive/versions/.
    func testAnOlderSettingsFileLosesTheRefreshLineAndKeepsTheRest() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("NoAutoClear-" + UUID().uuidString + ".noindex")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("memory"), settings = root.appendingPathComponent("templates/agent/settings.md")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("- parts: card, notes, refresh, helper\n- refresh at: 0.7\n- helper ai: codex\n- hands per seat: 2\n- hands per project: 4\n".utf8).write(to: settings)
        let store = try await DeckMemoryStore.open(root: root, dataRoot: base.appendingPathComponent("data"), embedder: nil, watch: false)
        let text = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertFalse(text.lowercased().contains("refresh"), text)
        let template = try await store.template(.agent)
        XCTAssertEqual(template.parts, [.card, .notes, .helper]); XCTAssertEqual(template.helperAI, "codex")
        XCTAssertEqual(template.handsPerSeat, 2); XCTAssertEqual(template.handsPerProject, 4)
        XCTAssertFalse(DeckMemoryFiles.markdown(under: root.appendingPathComponent("archive/versions/templates/agent")).isEmpty, "the old text is kept")
        let lead = try String(contentsOf: root.appendingPathComponent("templates/lead/settings.md"), encoding: .utf8)
        XCTAssertFalse(lead.lowercased().contains("refresh"), "a new settings file never names it")
        await store.close()
    }

    private func transcript(_ lines: [String]) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("desk-fill-" + UUID().uuidString + ".jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file.path
    }
    private func claudeTurn(model: String?, tokens: Int) -> String {
        let named = model.map { #""model":"\#($0)","# } ?? ""
        return #"{"type":"assistant","isSidechain":false,"message":{\#(named)"role":"assistant","usage":{"input_tokens":\#(tokens),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
    }

    func testEachDeskIsMeasuredAgainstItsRealModelWindow() throws {
        // A 1M model is 1M: 150k held is 15%, not the 75% a 200k guess gave (which would have cleared it).
        let opus = try transcript([claudeTurn(model: "claude-opus-5-5", tokens: 150_000)])
        XCTAssertEqual(try XCTUnwrap(DeckMemorySessionCenter.deskFill(provider: "claude", transcriptPath: opus, largeWindow: false)), 0.15, accuracy: 0.0001)
        // A 200k model stays 200k.
        let small = try transcript([claudeTurn(model: "claude-haiku-4-5", tokens: 150_000)])
        XCTAssertEqual(try XCTUnwrap(DeckMemorySessionCenter.deskFill(provider: "claude", transcriptPath: small, largeWindow: false)), 0.75, accuracy: 0.0001)
        // Launched on a [1m] model: 1M whatever the table says.
        XCTAssertEqual(try XCTUnwrap(DeckMemorySessionCenter.deskFill(provider: "claude", transcriptPath: small, largeWindow: true)), 0.15, accuracy: 0.0001)
        // A turn already holding more than the table's window proves the larger one.
        let over = try transcript([claudeTurn(model: "claude-haiku-4-5", tokens: 300_000)])
        XCTAssertEqual(try XCTUnwrap(DeckMemorySessionCenter.deskFill(provider: "claude", transcriptPath: over, largeWindow: false)), 0.3, accuracy: 0.0001)
        // The newest turn's model decides (a /model switch mid-session).
        let switched = try transcript([claudeTurn(model: "claude-haiku-4-5", tokens: 100_000), claudeTurn(model: "claude-opus-5-5", tokens: 120_000)])
        XCTAssertEqual(try XCTUnwrap(DeckMemorySessionCenter.deskFill(provider: "claude", transcriptPath: switched, largeWindow: false)), 0.12, accuracy: 0.0001)
        // No model named and nothing else known: no reading, never a guess.
        let unnamed = try transcript([claudeTurn(model: nil, tokens: 150_000)])
        XCTAssertNil(DeckMemorySessionCenter.deskFill(provider: "claude", transcriptPath: unnamed, largeWindow: false))
        // Codex: the window its own record reports (unchanged).
        let codex = try transcript([#"{"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":400000,"last_token_usage":{"total_tokens":100000}}}}"#])
        XCTAssertEqual(try XCTUnwrap(DeckMemorySessionCenter.deskFill(provider: "codex", transcriptPath: codex, largeWindow: false)), 0.25, accuracy: 0.0001)
        XCTAssertEqual(DeckMemorySessionCenter.claudeWindow(model: "claude-opus-5-5", launchedLarge: false, used: 10), 1_000_000)
        XCTAssertEqual(DeckMemorySessionCenter.claudeWindow(model: "claude-haiku-4-5", launchedLarge: false, used: 10), 200_000)
    }
}
