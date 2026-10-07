import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendMacAppHandoffAttachmentsTests: XCTestCase {
    typealias R = BackendMacAppHandoffAttachRules
    private let now: Double = 1_786_939_506_000
    private func plist(_ paths: [String]) -> String { "<plist><array>" + paths.map { "<string>\($0)</string>" }.joined() + "</array></plist>" }
    private func service(files: BackendMacAppHandoffFakeFiles = .init(), clipboard: BackendMacAppHandoffFakeClipboard = .init(), panels: BackendMacAppHandoffFakePanels = .init(), boundaries: [String: BackendDeviceBoundary] = [:], nativeShell: Bool = true, bring: BackendMacAppHandoffFakeBringIn = .init()) -> BackendMacAppHandoffAttachments {
        .init(files: files, clipboard: clipboard, panels: panels, boundaries: BackendMacAppHandoffFakeBoundaries(values: boundaries), bringIn: bring, pasteDirectory: "/fixture/pasted", home: "/Users/apple", nativeShell: nativeShell, now: { 1_786_939_506_000 }, random: { "a1b2c3" })
    }
    func testClipboardPrefersMultiFilePlist() { BackendMacAppHandoffEqual(R.clipboardPaths(plist: plist(["/Users/apple/Desktop/one.png", "/Users/apple/Desktop/two.png"]), fileURL: "file:///Users/apple/Desktop/one.png"), ["/Users/apple/Desktop/one.png", "/Users/apple/Desktop/two.png"]) }
    func testBinaryPlistFallsBackToSingleURL() { BackendMacAppHandoffEqual(R.clipboardPaths(plist: "bplist00\0\0", fileURL: "file:///tmp/only.txt"), ["/tmp/only.txt"]) }
    func testPlistWinsOverSingleFormats() { BackendMacAppHandoffEqual(R.clipboardPaths(plist: plist(["/tmp/a.txt", "/tmp/b.txt"]), fileURL: "file:///tmp/one.txt"), ["/tmp/a.txt", "/tmp/b.txt"]) }
    func testClipboardTextIsNotAFile() { BackendMacAppHandoffEqual(R.clipboardPaths(plist: "", fileURL: ""), []); BackendMacAppHandoffEqual(R.clipboardPaths(plist: "", fileURL: "just some words"), []) }
    func testXMLAndPercentEscapesDecode() { BackendMacAppHandoffEqual(R.clipboardPaths(plist: plist(["/tmp/a &amp; b.txt"]), fileURL: ""), ["/tmp/a & b.txt"]); BackendMacAppHandoffEqual(R.pathFromFileURL("file:///tmp/a%20file%20with%20spaces.png"), "/tmp/a file with spaces.png") }
    func testMalformedAndNonlocalFileURLMeansNothing() { for url in ["https://example.com/x.png", "file://server/share/x.png", "", "file:///%E0%A4%A"] { XCTAssertNil(R.pathFromFileURL(url)) } }
    func testPOSIXFileURLKeepsCorrectSeparators() { BackendMacAppHandoffEqual(R.pathFromFileURL("file:///tmp/x.png"), "/tmp/x.png"); BackendMacAppHandoffEqual(R.pathFromFileURL("file:///tmp/dir/"), "/tmp/dir") }
    func testPastedImageNameIsLegibleAndUnique() {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let firstDate = formatter.date(from: "2026-08-17T04:05:06.789Z")!, secondDate = formatter.date(from: "2026-08-17T04:05:06.999Z")!
        let first = R.pastedImageName(nowMS: firstDate.timeIntervalSince1970 * 1_000, random: "a1b2c3"), second = R.pastedImageName(nowMS: secondDate.timeIntervalSince1970 * 1_000, random: "d4e5f6")
        BackendMacAppHandoffEqual(first, "pasted-2026-08-17_04-05-06-a1b2c3.png"); XCTAssertNotEqual(first, second)
    }
    func testPruningDeletesOldAndKeepsFresh() async {
        let files = BackendMacAppHandoffFakeFiles(); await files.rows("/fixture/pasted", ["old.png", "fresh.png"]); await files.seed("/fixture/pasted/old.png", modified: now - 30 * 24 * 60 * 60 * 1_000); await files.seed("/fixture/pasted/fresh.png", modified: now)
        await service(files: files).prune(nowMS: now); let result = await files.snapshot(); BackendMacAppHandoffEqual(result.removed, ["/fixture/pasted/old.png"]); XCTAssertNotNil(result.data["/fixture/pasted/fresh.png"])
    }
    func testPruningAbsentDirectoryDoesNotThrow() async { await service().prune(nowMS: now) }
    func testFilePasteNeverWritesPreviewCopy() async throws {
        let files = BackendMacAppHandoffFakeFiles(), board = BackendMacAppHandoffFakeClipboard(["NSFilenamesPboardType": plist(["/Users/apple/Desktop/shot.png"])], png: Data("preview".utf8))
        let result = try await service(files: files, clipboard: board).paste(), written = await files.snapshot(), imageReads = await board.imageReadCount()
        BackendMacAppHandoffEqual(result["ok"], .bool(true)); BackendMacAppHandoffEqual(result["source"], .string("files")); BackendMacAppHandoffEqual(result["picks"].elements?.first?["path"], .string("/Users/apple/Desktop/shot.png")); XCTAssertTrue(written.made.isEmpty); XCTAssertTrue(written.data.isEmpty); BackendMacAppHandoffEqual(imageReads, 0)
    }
    func testBitmapPasteWritesOnePrivatePNG() async throws {
        let files = BackendMacAppHandoffFakeFiles(), board = BackendMacAppHandoffFakeClipboard(png: Data("not-really-a-png".utf8))
        let result = try await service(files: files, clipboard: board).paste(), written = await files.snapshot()
        BackendMacAppHandoffEqual(result["ok"], .bool(true)); BackendMacAppHandoffEqual(result["source"], .string("image")); BackendMacAppHandoffEqual(result["picks"].elements?.count, 1)
        let path = try XCTUnwrap(result["picks"].elements?.first?["path"].string)
        BackendMacAppHandoffEqual(result["picks"].elements?.first?["isDirectory"], .bool(false)); BackendMacAppHandoffEqual(written.data.count, 1); BackendMacAppHandoffEqual(written.data[path], Data("not-really-a-png".utf8)); BackendMacAppHandoffEqual(written.modes[path], 0o600); BackendMacAppHandoffEqual(written.modes["/fixture/pasted"], 0o700)
        XCTAssertNotNil(path.range(of: #"/pasted-2026-08-17_04-05-06-[0-9a-f]{6}\.png$"#, options: .regularExpression))
    }
    func testEmptyClipboardReportsExactNothingSentence() async throws { let result = try await service().paste(); BackendMacAppHandoffEqual(result["ok"], .bool(false)); BackendMacAppHandoffEqual(result["reason"], .string("nothing")); BackendMacAppHandoffEqual(result["detail"], .string("There is no file or image on the clipboard.")) }
    func testUnknownClipboardFormatFallsThroughToFileURL() async throws {
        let board = BackendMacAppHandoffFakeClipboard(["public.file-url": "file:///tmp/from-the-url.txt"], failing: ["NSFilenamesPboardType"])
        let result = try await service(clipboard: board).paste(); BackendMacAppHandoffEqual(result["ok"], .bool(true)); BackendMacAppHandoffEqual(result["picks"].elements?.first?["path"], .string("/tmp/from-the-url.txt"))
    }
    func testInspectStatsDirectoryAndEmptyFile() async {
        let files = BackendMacAppHandoffFakeFiles(); await files.seed("/fixture/inner", directory: true); await files.seed("/fixture/note.txt")
        let result = await service(files: files).inspect(.array([.string("/fixture/inner"), .string("/fixture/note.txt")]))
        BackendMacAppHandoffEqual(result, .array([BackendMacAppHandoffObject(["path": .string("/fixture/inner"), "isDirectory": .bool(true)]), BackendMacAppHandoffObject(["path": .string("/fixture/note.txt"), "isDirectory": .bool(false)])]))
    }
    func testInspectDropsNonStringsAndNonArray() async {
        let source = service(), mixed = await source.inspect(.array([.number(1), .string(""), .null])), nonArray = await source.inspect(.string("not an array")); BackendMacAppHandoffEqual(mixed, .array([])); BackendMacAppHandoffEqual(nonArray, .array([]))
    }
    func testUnknownSessionIsUnconfined() async throws { let answer = try await service().boundary(.string("a-session"), context: BackendMacAppHandoffContext()); BackendMacAppHandoffEqual(answer, BackendMacAppHandoffObject(["confined": .bool(false), "folder": .string(""), "projects": .array([])])) }
    func testConfinedBoundaryNamesFolder() async throws { let source = service(boundaries: ["phone-session": .init(deviceKey: "phone", folder: "/Users/apple/granted")]), answer = try await source.boundary(.string("phone-session"), context: BackendMacAppHandoffContext()); BackendMacAppHandoffEqual(answer, BackendMacAppHandoffObject(["confined": .bool(true), "folder": .string("/Users/apple/granted"), "projects": .array([])])) }
    func testBoundaryCarriesCopilotReadableProjects() async throws { let source = service(boundaries: ["copilot": .init(deviceKey: "copilot", folder: "/Users/apple/copilot", readOnlyProjects: ["/Users/apple/Projects/thing"])]), answer = try await source.boundary(.string("copilot"), context: BackendMacAppHandoffContext()); BackendMacAppHandoffEqual(answer["projects"], .array([.string("/Users/apple/Projects/thing")])); BackendMacAppHandoffEqual(answer["confined"], .bool(true)) }
    func testMissingSessionIDIsUnconfined() async throws { let answer = try await service().boundary(.missing, context: BackendMacAppHandoffContext()); BackendMacAppHandoffEqual(answer["confined"], .bool(false)); BackendMacAppHandoffEqual(answer["folder"], .string("")); BackendMacAppHandoffEqual(answer["projects"], .array([])) }
    func testNonNativeBrowseReportsNoWindow() async throws { let answer = try await service(nativeShell: false).browse(BackendMacAppHandoffObject(["mode": .string("file")]), context: BackendMacAppHandoffContext()); BackendMacAppHandoffEqual(answer, BackendMacAppHandoffObject(["ok": .bool(false), "reason": .string("no-window")])) }
    func testNativeBrowseUsesFreestandingPanelAndHome() async throws {
        let panels = BackendMacAppHandoffFakePanels(); await panels.set(paths: ["/fixture/a.txt", "/fixture/b.txt"])
        let answer = try await service(panels: panels).browse(BackendMacAppHandoffObject(["mode": .string("file")]), context: BackendMacAppHandoffContext()), options = await panels.seen()
        BackendMacAppHandoffEqual(answer["ok"], .bool(true)); BackendMacAppHandoffEqual(options["defaultPath"], .string("/Users/apple")); BackendMacAppHandoffEqual(options["properties"], .array([.string("openFile"), .string("multiSelections")]))
    }
    func testPasteWriteFailureIsVisible() async throws { let files = BackendMacAppHandoffFakeFiles(); await files.fail(true); let answer = try await service(files: files, clipboard: .init(png: Data([1]))).paste(); BackendMacAppHandoffEqual(answer["reason"], .string("write-failed")); BackendMacAppHandoffEqual(answer["detail"], .string("disk full")) }
}
