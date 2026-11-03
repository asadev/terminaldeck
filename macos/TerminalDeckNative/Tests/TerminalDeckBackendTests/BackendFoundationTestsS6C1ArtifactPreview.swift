import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// artifact-preview.test.ts over a real loopback socket and a real folder.
final class BackendFoundationTestsS6C1ArtifactPreview: XCTestCase {
    private final class S6C1NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private struct S6C1Answer { let status: Int; let headers: [String: String]; let data: Data; let url: URL?
        func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
        var text: String { String(decoding: data, as: UTF8.self) } }
    private let context = NativeRPCContext(caller: .nativeApp, ownerID: "s6c1-preview")
    private let png: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3]

    private func s6c1Fixture() throws -> BackendFoundationTestsBFixture {
        let f = try BackendFoundationTestsBFixture("s6c1-preview")
        try f.write("demo/index.html", "<h1>hi</h1><script src=\"app.js\"></script>")
        try f.write("demo/app.js", "console.log(1)")
        try Data(png).write(to: f.file("demo/shot.png"))
        try f.write("secrets.txt", "top")
        try f.write("demo/data.sqlite", "x")
        return f
    }
    private func s6c1Previews() -> BackendArtifactsPreview {
        BackendArtifactsPreview(authority: .init(scope: { _ in .local }), ownPorts: BackendDevOwnPorts(), announce: { _ in })
    }
    private func s6c1Fetch(_ port: Int, _ path: String, method: String = "GET", range: String? = nil, follow: Bool = true) async throws -> S6C1Answer {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let session = follow ? URLSession(configuration: .ephemeral) : URLSession(configuration: .ephemeral, delegate: S6C1NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers["\(k)"] = "\(v)" }
        return S6C1Answer(status: http.statusCode, headers: headers, data: data, url: http.url)
    }

    // MARK: pure parsing
    func testRefusesAWalkOutOfTheRootRatherThanTidyingItAway() {
        for bad in ["/a/../b", "/a/%2e%2e/b", "/a%00b", "/a/%2fetc/passwd", "relative", "/a/%zz"] {
            XCTAssertNil(BackendArtifactsPreview.segments(bad), bad)
        }
    }
    func testDecodesASegmentAndKeepsTheEmptyOnesOut() {
        XCTAssertEqual(BackendArtifactsPreview.segments("/s/demo//index.html"), ["s", "demo", "index.html"])
        XCTAssertEqual(BackendArtifactsPreview.segments("/s/design%20notes/read%20me.md"), ["s", "design notes", "read me.md"])
        XCTAssertEqual(BackendArtifactsPreview.segments("/"), [])
    }
    func testReadsTheOneRangeShapeAMediaElementSends() {
        func eq(_ r: BackendArtifactsPreview.Range, _ s: Int64, _ e: Int64, line: UInt = #line) {
            if case .bytes(let a, let b) = r { XCTAssertEqual(a, s, line: line); XCTAssertEqual(b, e, line: line) } else { XCTFail("not bytes", line: line) }
        }
        if case .whole = BackendArtifactsPreview.range(nil, size: 100) {} else { XCTFail("whole") }
        eq(BackendArtifactsPreview.range("bytes=0-", size: 100), 0, 99)
        eq(BackendArtifactsPreview.range("bytes=10-19", size: 100), 10, 19)
        eq(BackendArtifactsPreview.range("bytes=90-200", size: 100), 90, 99)
        eq(BackendArtifactsPreview.range("bytes=-20", size: 100), 80, 99)
    }
    func testRefusesARangeItCannotSatisfyInsteadOfSendingTheWholeFile() {
        for bad in ["bytes=200-", "bytes=20-10", "bytes="] {
            if case .unsatisfiable = BackendArtifactsPreview.range(bad, size: 100) {} else { XCTFail(bad) }
        }
        if case .whole = BackendArtifactsPreview.range("bytes=0-1,4-5", size: 100) {} else { XCTFail("multipart is answered whole") }
    }

    // MARK: over the socket (content types observed from responses; the helper is private)
    func testNamesTheTypesABrowserRendersAndRefusesToGuessAtTheRest() async throws {
        let f = try s6c1Fixture(), previews = s6c1Previews()
        try f.write("clip.mp4", "v"); try f.write("paper.pdf", "p"); try f.write("Makefile", "m"); try f.write("logo.PNG", "l")
        let h = try await previews.serve(root: f.root.path, context: context)
        let expected = [("demo/index.html", "text/html; charset=utf-8"), ("logo.PNG", "image/png"), ("clip.mp4", "video/mp4"), ("paper.pdf", "application/pdf"), ("demo/data.sqlite", "application/octet-stream"), ("Makefile", "application/octet-stream")]
        for (file, type) in expected {
            let a = try await s6c1Fetch(h.port, "/\(h.secret)/\(file)")
            XCTAssertEqual(a.header("content-type"), type, file)
        }
        await previews.stopAll()
    }
    func testServesAPageAndItsSiblingsFromOneOrigin() async throws {
        let f = try s6c1Fixture(), previews = s6c1Previews()
        let h = try await previews.serve(root: f.root.path, context: context)
        let page = try await s6c1Fetch(h.port, "/\(h.secret)/demo/index.html")
        XCTAssertEqual(page.status, 200); XCTAssertEqual(page.header("content-type"), "text/html; charset=utf-8"); XCTAssertTrue(page.text.contains("<h1>hi</h1>"))
        let script = try await s6c1Fetch(h.port, "/\(h.secret)/demo/app.js")
        XCTAssertEqual(script.status, 200); XCTAssertEqual(script.header("content-type"), "text/javascript; charset=utf-8")
        await previews.stopAll()
    }
    func testHandsOverRealBytesForAnImage() async throws {
        let f = try s6c1Fixture(), previews = s6c1Previews()
        let h = try await previews.serve(root: f.root.path, context: context)
        let a = try await s6c1Fetch(h.port, "/\(h.secret)/demo/shot.png")
        XCTAssertEqual(a.status, 200); XCTAssertEqual(a.header("content-type"), "image/png"); XCTAssertEqual([UInt8](a.data), png)
        await previews.stopAll()
    }
    func testAnswersARangeWith206AndTheRangeItSent() async throws {
        let f = try s6c1Fixture(), previews = s6c1Previews()
        let h = try await previews.serve(root: f.root.path, context: context)
        let a = try await s6c1Fetch(h.port, "/\(h.secret)/demo/shot.png", range: "bytes=2-4")
        XCTAssertEqual(a.status, 206); XCTAssertEqual(a.header("content-range"), "bytes 2-4/8"); XCTAssertEqual(a.header("content-length"), "3")
        XCTAssertEqual([UInt8](a.data), [0x4e, 0x47, 0])
        await previews.stopAll()
    }
    func testSendsATokenToTheFileItNamesSoRelativeURLsResolveFromThere() async throws {
        let f = try s6c1Fixture(), previews = s6c1Previews()
        let h = try await previews.serve(root: f.root.path, context: context)
        try await previews.link(root: f.root.path, token: "demo/index.html", relative: "demo/index.html")
        let hop = try await s6c1Fetch(h.port, "/\(h.secret)/~/demo%2Findex.html", follow: false)
        XCTAssertEqual(hop.status, 302); XCTAssertEqual(hop.header("location"), "/\(h.secret)/demo/index.html")
        let followed = try await s6c1Fetch(h.port, "/\(h.secret)/~/demo%2Findex.html")
        XCTAssertEqual(followed.url?.path, "/\(h.secret)/demo/index.html"); XCTAssertTrue(followed.text.contains("app.js"))
        await previews.stopAll()
    }
    func testServesAFolderAsItsIndexAndNeverAsAListing() async throws {
        let f = try s6c1Fixture(), previews = s6c1Previews()
        let h = try await previews.serve(root: f.root.path, context: context)
        let demo = try await s6c1Fetch(h.port, "/\(h.secret)/demo/")
        XCTAssertEqual(demo.status, 200)
        let bare = try await s6c1Fetch(h.port, "/\(h.secret)/")
        XCTAssertEqual(bare.status, 404); XCTAssertFalse(bare.text.contains("secrets.txt"))
        await previews.stopAll()
    }
    func testDropsTheQueryWhichBelongsToThePage() async throws {
        let f = try s6c1Fixture(), previews = s6c1Previews()
        let h = try await previews.serve(root: f.root.path, context: context)
        let a = try await s6c1Fetch(h.port, "/\(h.secret)/demo/index.html?tab=two")
        XCTAssertEqual(a.status, 200)
        await previews.stopAll()
    }
    func testAnswersTheSame404ForAWrongSecretAsForAMissingFile() async throws {
        let f = try s6c1Fixture(), previews = s6c1Previews()
        let h = try await previews.serve(root: f.root.path, context: context)
        let wrong = try await s6c1Fetch(h.port, "/not-the-secret/demo/index.html")
        let missing = try await s6c1Fetch(h.port, "/\(h.secret)/demo/nothing.html")
        XCTAssertEqual(wrong.status, 404); XCTAssertEqual(missing.status, 404); XCTAssertEqual(wrong.text, missing.text)
        await previews.stopAll()
    }
    func testRefusesAWalkOutOfTheRootAndALinkThatPointsOutOfIt() async throws {
        let f = try s6c1Fixture(), previews = s6c1Previews()
        try FileManager.default.createSymbolicLink(atPath: f.file("demo/escape").path, withDestinationPath: "/etc/passwd")
        let h = try await previews.serve(root: f.root.path, context: context)
        let up = try await s6c1Fetch(h.port, "/\(h.secret)/../secrets.txt")
        XCTAssertEqual(up.status, 404)
        let link = try await s6c1Fetch(h.port, "/\(h.secret)/demo/escape")
        XCTAssertEqual(link.status, 404)
        await previews.stopAll()
    }
    func testAnswersOnlyGetAndHead() async throws {
        let f = try s6c1Fixture(), previews = s6c1Previews()
        let h = try await previews.serve(root: f.root.path, context: context)
        let head = try await s6c1Fetch(h.port, "/\(h.secret)/demo/app.js", method: "HEAD")
        XCTAssertEqual(head.status, 200); XCTAssertEqual(head.header("content-length"), "14")
        let post = try await s6c1Fetch(h.port, "/\(h.secret)/demo/app.js", method: "POST")
        XCTAssertEqual(post.status, 405); XCTAssertEqual(post.header("allow"), "GET, HEAD")
        await previews.stopAll()
    }
    func testServesOneRootOnceHoweverManyTimesItIsAsked() async throws {
        let f = try s6c1Fixture(), previews = s6c1Previews()
        let first = try await previews.serve(root: f.root.path, context: context)
        let again = try await previews.serve(root: f.root.path, context: context)
        XCTAssertEqual(again.port, first.port); XCTAssertEqual(again.secret, first.secret)
        let current = await previews.current(root: f.root.path)
        XCTAssertEqual(current?.port, first.port); XCTAssertEqual(current?.secret, first.secret)
        await previews.stopAll()
    }
    func testClosesTheLeastRecentlyUsedRootRatherThanRefusingAFifth() async throws {
        let previews = s6c1Previews()
        var fixtures: [BackendFoundationTestsBFixture] = []
        for i in 0..<5 {
            let f = try BackendFoundationTestsBFixture("s6c1-preview-many-\(i)"); fixtures.append(f)
            _ = try await previews.serve(root: f.root.path, context: context)
        }
        let first = await previews.current(root: fixtures[0].root.path)
        XCTAssertNil(first)
        for f in fixtures.dropFirst() { let h = await previews.current(root: f.root.path); XCTAssertNotNil(h) }
        await previews.stopAll()
    }
    func testStopsAnsweringOnceStopped() async throws {
        let f = try s6c1Fixture(), previews = s6c1Previews()
        let h = try await previews.serve(root: f.root.path, context: context)
        let ok = try await s6c1Fetch(h.port, "/\(h.secret)/demo/app.js")
        XCTAssertEqual(ok.status, 200)
        await previews.stop(root: f.root.path)
        let current = await previews.current(root: f.root.path)
        XCTAssertNil(current)
        do { _ = try await s6c1Fetch(h.port, "/\(h.secret)/demo/app.js"); XCTFail("still answering") } catch {}
    }
}
