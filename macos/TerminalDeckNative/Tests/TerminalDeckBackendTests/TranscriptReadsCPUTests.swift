import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 28 Oct (Asad: the app stayed near a whole core with sessions only lightly working). The usage bar's context read,
/// about once a second per shown session, re-read the transcript's tail every time; the board's prompt lines were
/// rewritten for every desk at every status change. A transcript is now read only from where the last read stopped,
/// and the prompt lines once the board has settled.
@Suite("Transcript reads: only what is new")
struct TranscriptReadsCPUTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func line(_ tokens: Int, filler: Int = 0) -> String {
        "{\"tokens\":\(tokens),\"pad\":\"" + String(repeating: "x", count: filler) + "\"}\n"
    }
    private func parse(_ line: String) -> BackendContextTailCache.Prompt? {
        guard let value = try? NativeRPCValue.parseJSON(Data(line.utf8)), let tokens = value["tokens"].number else { return nil }
        return .init(tokens: tokens, model: "m", at: tokens)
    }
    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func anUnchangedTranscriptIsNotReadAgain() throws {
        let root = try folder(), file = root.appendingPathComponent("a.jsonl")
        try Data((line(100) + line(300) + line(200)).utf8).write(to: file)
        let tails = BackendContextTailCache(), steps = [256 * 1024, 1024 * 1024]
        let first = try tails.read(path: file.path, roots: [root.path], steps: steps, parse: parse)
        #expect(first.latest?.tokens == 200 && first.high == 300 && first.bytes > 0)
        let again = try tails.read(path: file.path, roots: [root.path], steps: steps, parse: parse)
        #expect(again.bytes == 0, "nothing new: nothing read")
        #expect(again.latest == first.latest && again.high == first.high)
    }

    @Test func aGrownTranscriptIsReadOnlyFromWhereItStopped() throws {
        let root = try folder(), file = root.appendingPathComponent("a.jsonl")
        try Data((0..<2000).map { line($0, filler: 100) }.joined().utf8).write(to: file)   // ~230 KB of history
        let tails = BackendContextTailCache(), steps = [256 * 1024, 1024 * 1024]
        _ = try tails.read(path: file.path, roots: [root.path], steps: steps, parse: parse)
        let added = line(5000)
        try append(added, to: file)
        let next = try tails.read(path: file.path, roots: [root.path], steps: steps, parse: parse)
        #expect(next.bytes == added.utf8.count, "only the new line, not the 230 KB before it")
        #expect(next.latest?.tokens == 5000 && next.high == 5000)
    }

    @Test func aLineStillBeingWrittenWaitsForItsEnd() throws {
        let root = try folder(), file = root.appendingPathComponent("a.jsonl")
        try Data(line(10).utf8).write(to: file)
        let tails = BackendContextTailCache(), steps = [256 * 1024]
        _ = try tails.read(path: file.path, roots: [root.path], steps: steps, parse: parse)
        try append("{\"tokens\":77", to: file)
        #expect(try tails.read(path: file.path, roots: [root.path], steps: steps, parse: parse).latest?.tokens == 10)
        try append(",\"pad\":\"\"}\n", to: file)
        #expect(try tails.read(path: file.path, roots: [root.path], steps: steps, parse: parse).latest?.tokens == 77,
                "the half line is read whole once it ends")
    }

    @Test func aReplacedOrShrunkTranscriptIsReadAfresh() throws {
        let root = try folder(), file = root.appendingPathComponent("a.jsonl")
        try Data((line(100) + line(900)).utf8).write(to: file)
        let tails = BackendContextTailCache(), steps = [256 * 1024]
        #expect(try tails.read(path: file.path, roots: [root.path], steps: steps, parse: parse).high == 900)
        try FileManager.default.removeItem(at: file)
        try Data(line(40).utf8).write(to: file)   // a rewind or a new file: another inode, shorter
        let fresh = try tails.read(path: file.path, roots: [root.path], steps: steps, parse: parse)
        #expect(fresh.latest?.tokens == 40 && fresh.high == 40, "nothing carried over from the file it replaced")
    }

    @Test func aTranscriptOutsideTheApprovedFolderIsRefused() throws {
        let root = try folder(), other = try folder(), file = other.appendingPathComponent("a.jsonl")
        try Data(line(1).utf8).write(to: file)
        #expect(throws: (any Error).self) { try BackendContextTailCache().read(path: file.path, roots: [root.path], steps: [1024], parse: parse) }
    }

    /// Reviewer (28 Oct): a /model switch starts the new model's own peak, so an old model's high figure never
    /// stretches the new model's window.
    @Test func anotherModelStartsItsOwnPeak() throws {
        let root = try folder(), file = root.appendingPathComponent("a.jsonl")
        func modelLine(_ model: String, _ tokens: Int) -> String { "{\"model\":\"\(model)\",\"tokens\":\(tokens)}\n" }
        func parseModel(_ line: String) -> BackendContextTailCache.Prompt? {
            guard let value = try? NativeRPCValue.parseJSON(Data(line.utf8)), let tokens = value["tokens"].number, let model = value["model"].string else { return nil }
            return .init(tokens: tokens, model: model, at: tokens)
        }
        try Data((modelLine("big", 900) + modelLine("big", 300)).utf8).write(to: file)
        let tails = BackendContextTailCache(), steps = [256 * 1024]
        #expect(try tails.read(path: file.path, roots: [root.path], steps: steps, parse: parseModel).high == 900)
        try append(modelLine("small", 100), to: file)
        let after = try tails.read(path: file.path, roots: [root.path], steps: steps, parse: parseModel)
        #expect(after.latest?.model == "small" && after.high == 100)
        try append(modelLine("small", 150), to: file)
        #expect(try tails.read(path: file.path, roots: [root.path], steps: steps, parse: parseModel).high == 150)
    }

    /// Fifty board changes across three desks book one write of their prompt lines, not fifty.
    @Test func boardChangesSettleIntoOneWrite() {
        var settle = DeckMemoryBoardSettle(), booked = 0
        for index in 0..<50 { if settle.note(["deck-dev", "commander", "iloop"][index % 3]) { booked += 1 } }
        #expect(booked == 1)
        let taken = settle.take()
        #expect(taken == ["deck-dev", "commander", "iloop"])
        let next = settle.note("deck-dev")
        #expect(next, "after the write, the next change books the next one")
        #expect(DeckMemorySessionCenter.boardSettle > 0)
    }
}
