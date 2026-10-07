import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// context-window.test.ts, through BackendUsageService.contextReading (the reader without a session/lifecycle fixture).
/// Directories are real and temporary: the thing under test is a file layout.
final class BackendFoundationTestsS6C1ContextReading: XCTestCase {
    private let at = "2026-08-19T13:48:22.481Z"
    private var atMs: Double {   // Date.parse(AT)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: at)!.timeIntervalSince1970 * 1000
    }
    private func turn(timestamp: String? = nil, model: String? = "claude-opus-5", usage: String? = nil, sidechain: Bool = false) -> String {
        let usageText = usage ?? "{\"input_tokens\":2,\"cache_read_input_tokens\":75511,\"cache_creation_input_tokens\":1703}"
        let modelPart = model.map { "\"model\":\"\($0)\"," } ?? ""
        return "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp ?? at)\",\(sidechain ? "\"isSidechain\":true," : "")\"message\":{\(modelPart)\"usage\":\(usageText)}}"
    }
    private func folder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("s6c1-ctxread-" + UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ dir: URL, _ name: String, _ text: String, age: TimeInterval = 0) throws {
        let file = dir.appendingPathComponent(name + ".jsonl")
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path)
    }
    private func read(_ dir: URL, named: String? = nil, provider: String = "claude") throws -> NativeRPCValue {
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.pathExtension == "jsonl" }
        let candidates = try files.map { (path: $0.path, id: $0.deletingPathExtension().lastPathComponent, modified: try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!.timeIntervalSince1970 * 1000) }
        return try BackendUsageService.contextReading(provider: provider, cwd: "/tmp/ctx", namedID: named, candidates: candidates.filter { named == nil || $0.id == named }, roots: [dir.path],
                                                      modelLabel: { $0 == "claude-opus-5" ? "Opus 5" : $0 }, now: 1_000)
    }

    func testAddsTheThreeFieldsThatMakeUpAResidentContext() throws {
        let dir = try folder(); try write(dir, "a", turn() + "\n")
        let reading = try read(dir)
        XCTAssertEqual(reading["state"].string, "ok"); XCTAssertEqual(reading["tokens"].number, 77_216)
        XCTAssertEqual(reading["model"].string, "claude-opus-5"); XCTAssertEqual(reading["reportedAt"].number, atMs)
    }
    func testIgnoresTheInterruptLinesWhoseUsageBlockIsAllZeros() throws {
        let dir = try folder()
        let zeros = turn(model: "<synthetic>", usage: "{\"input_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}")
        try write(dir, "a", turn() + "\n" + zeros + "\n")
        XCTAssertEqual(try read(dir)["tokens"].number, 77_216)
    }
    func testIgnoresASubAgentsOwnContextWhichSharesTheFile() throws {
        let dir = try folder()
        let side = turn(usage: "{\"input_tokens\":900000,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}", sidechain: true)
        try write(dir, "a", turn() + "\n" + side + "\n")
        XCTAssertEqual(try read(dir)["tokens"].number, 77_216)
    }
    func testWalksPastTheTitleStubsThatAreTheNewestFilesInARealFolder() throws {
        let dir = try folder(); try write(dir, "real", turn() + "\n", age: 60)
        for i in 0..<12 { try write(dir, "stub-\(i)", "{\"type\":\"ai-title\",\"title\":\"x\"}\n") }
        let reading = try read(dir)
        XCTAssertEqual(reading["state"].string, "ok"); XCTAssertEqual(reading["tokens"].number, 77_216)
        XCTAssertEqual(reading["source"]["sessionId"].string, "real")
    }
    func testSaysTheTranscriptWasInferredAndCountsTheSessionsItCouldBeConfusedWith() throws {
        let dir = try folder(); try write(dir, "one", turn() + "\n"); try write(dir, "two", turn() + "\n")
        let reading = try read(dir)
        XCTAssertEqual(reading["source"]["chosen"].string, "inferred"); XCTAssertEqual(reading["source"]["rivals"].number, 1)
        XCTAssertTrue(reading["detail"].string?.contains("may be the other one") == true)
    }
    func testPrefersTheNewestConversationOverTheNewestFile() throws {
        let dir = try folder()
        try write(dir, "live", turn() + "\n", age: 60)
        let weekOld = "2026-08-12T13:48:22.481Z"
        try write(dir, "touched", turn(timestamp: weekOld, usage: "{\"input_tokens\":1,\"cache_read_input_tokens\":106131,\"cache_creation_input_tokens\":0}") + "\n")
        let reading = try read(dir)
        XCTAssertEqual(reading["source"]["sessionId"].string, "live"); XCTAssertEqual(reading["tokens"].number, 77_216)
        XCTAssertEqual(reading["reportedAt"].number, atMs)
        XCTAssertEqual(reading["source"]["chosen"].string, "inferred"); XCTAssertEqual(reading["source"]["rivals"].number, 1)
    }
    func testStillFallsBackPastTheLiveWindowWhenNothingRecentHasAFigure() throws {
        let dir = try folder()
        try write(dir, "old", turn() + "\n", age: 3 * 3600); try write(dir, "stub", "{\"type\":\"ai-title\",\"title\":\"x\"}\n")
        let reading = try read(dir)
        XCTAssertEqual(reading["state"].string, "ok"); XCTAssertEqual(reading["source"]["sessionId"].string, "old")
    }
    func testLabelsTheModelUnderTheNameTheRestOfTheAppPrints() throws {
        let dir = try folder(); try write(dir, "a", turn() + "\n")
        let reading = try read(dir)
        XCTAssertEqual(reading["model"].string, "claude-opus-5"); XCTAssertEqual(reading["modelLabel"].string, "Opus 5")
    }
    func testNamesTheTranscriptWhenItIsGivenOne() throws {
        let dir = try folder(); try write(dir, "named", turn() + "\n")
        let reading = try read(dir, named: "named")
        XCTAssertEqual(reading["source"]["chosen"].string, "named"); XCTAssertEqual(reading["source"]["rivals"].number, 0)
    }
    func testAnswersNothingYetRatherThanZeroForAFolderWithNoTurnsInIt() throws {
        let dir = try folder()
        let reading = try read(dir)
        XCTAssertEqual(reading["state"].string, "nothing-yet"); XCTAssertTrue(reading["tokens"].isNullish); XCTAssertTrue(reading["percent"].isNullish)
    }
    func testTheDenominatorIsOneMillionForTheModelsThisMachineActuallyRuns() throws {
        let dir = try folder(); try write(dir, "a", turn() + "\n")
        let reading = try read(dir)
        XCTAssertEqual(reading["window"].number, 1_000_000); XCTAssertEqual(reading["percent"].number ?? 0, 7.72, accuracy: 0.01)
        XCTAssertEqual(reading["windowBasis"].string, "model")
    }
    func testGivesATokenCountWithNoPercentageWhenNothingOnDiskNamesAModel() throws {
        let dir = try folder()
        try write(dir, "a", turn(model: nil, usage: "{\"input_tokens\":100,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}") + "\n")
        let reading = try read(dir)
        XCTAssertTrue(reading["percent"].isNullish); XCTAssertTrue(reading["window"].isNullish)
    }
    func testFindsTheAnswerWhenItIsBehindAMegabyteOfToolOutput() throws {
        let dir = try folder()
        let filler = String(repeating: "{\"type\":\"user\",\"text\":\"" + String(repeating: "x", count: 4096) + "\"}\n", count: 300)
        try write(dir, "a", turn() + "\n" + filler)
        XCTAssertEqual(try read(dir)["tokens"].number, 77_216)
    }
    func testReadsCodexsResidentContextNotItsRunningTotal() {
        let line = "{\"timestamp\":\"\(at)\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":60285342},\"last_token_usage\":{\"input_tokens\":214679,\"cached_input_tokens\":12160,\"total_tokens\":215266},\"model_context_window\":258400}}}"
        let parsed = BackendUsageService.parseCodexContextLine(line, 0)
        XCTAssertEqual(parsed?.tokens, 214_679); XCTAssertEqual(parsed?.window, 258_400)
        XCTAssertNil(BackendUsageService.parseCodexContextLine("{\"payload\":{\"type\":\"token_count\",\"info\":null}}", 0))
    }
    func testNothingYetForACodexFolderWithNoRollout() throws {
        let dir = try folder()
        let reading = try BackendUsageService.contextReading(provider: "codex", cwd: "/tmp/ctx", namedID: nil, candidates: [], roots: [dir.path], modelLabel: { $0 }, now: 1)
        XCTAssertEqual(reading["state"].string, "nothing-yet")
    }
}
