import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Link policy")
struct PageLinksTests {
    private let engine = EngineOrigin(url: URL(string: "http://127.0.0.1:5123/?t=x")!)

    private func decide(_ url: String, _ disposition: String? = "tab") -> LinkAction {
        var body: [String: Any] = ["type": "open-link", "url": url]
        if let disposition { body["disposition"] = disposition }
        guard let request = LinkRequest.parse(body) else { return .refuse("unparsed") }
        return LinkPolicy.decide(request, engineOrigin: engine)
    }

    @Test func webLinksGoWhereThePageAsked() {
        #expect(decide("https://example.com/a?b=1") == .tab(URL(string: "https://example.com/a?b=1")!))
        #expect(decide("http://example.com", "external") == .external(URL(string: "http://example.com")!))
        // Missing or unknown: the default browser, never a tab nobody asked for.
        #expect(decide("https://example.com", nil) == .external(URL(string: "https://example.com")!))
        #expect(decide("https://example.com", "window") == .external(URL(string: "https://example.com")!))
        // A local dev server is fine; only the engine's own address is not.
        #expect(decide("http://127.0.0.1:3000/") == .tab(URL(string: "http://127.0.0.1:3000/")!))
    }

    @Test func theEnginesOwnPagesNeverLeaveTheApp() {
        guard case .refuse = decide("http://127.0.0.1:5123/?island=1") else { Issue.record("tab"); return }
        guard case .refuse = decide("http://127.0.0.1:5123/x", "external") else { Issue.record("external"); return }
    }

    @Test func mailGoesToTheMailApp() {
        #expect(decide("mailto:someone@example.com") == .external(URL(string: "mailto:someone@example.com")!))
    }

    @Test func filesAndOtherAppsOnlyAfterAsking() {
        #expect(decide("file:///Users/me/notes.txt") == .askFile(URL(string: "file:///Users/me/notes.txt")!))
        #expect(decide("vscode://file/Users/me/a.ts:3") == .askApp(URL(string: "vscode://file/Users/me/a.ts:3")!))
        #expect(decide("slack://open", "external") == .askApp(URL(string: "slack://open")!))
    }

    @Test func scriptDataAndNonsenseAreRefused() {
        for bad in ["javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,<b>x</b>", "blob:http://127.0.0.1:5123/abc",
                    "about:blank", "not a url", "https:///nohost", "/relative/path", "1abc:thing"] {
            guard case .refuse = decide(bad) else { Issue.record("\(bad) should be refused"); continue }
        }
    }

    @Test func malformedRequestsAreNotLinks() {
        #expect(LinkRequest.parse(["type": "open-link"]) == nil)
        #expect(LinkRequest.parse(["type": "open-link", "url": "  "]) == nil)
        #expect(LinkRequest.parse(["type": "open-link", "url": 5]) == nil)
        #expect(LinkRequest.parse(["type": "open-link", "url": String(repeating: "a", count: 9000)]) == nil)
        #expect(LinkRequest.parse(["type": "context-menu", "url": "https://example.com"]) == nil)
        #expect(LinkRequest.isLinkMessage(["type": "open-link"]))
        #expect(PageMessage.parse(["type": "open-link", "url": "https://example.com"]) == nil)
    }
}

@Suite("Microphone permission")
struct MediaCapturePolicyTests {
    private let engine = EngineOrigin(url: URL(string: "http://127.0.0.1:5123/?t=x")!)

    @Test func microphoneForTheEngineOnly() {
        #expect(MediaCapturePolicy.decide(kind: .microphone, scheme: "http", host: "127.0.0.1", port: 5123, engineOrigin: engine) == .grant)
        #expect(MediaCapturePolicy.decide(kind: .microphone, scheme: "http", host: "127.0.0.1", port: 3000, engineOrigin: engine) == .deny)
        #expect(MediaCapturePolicy.decide(kind: .microphone, scheme: "https", host: "example.com", port: 443, engineOrigin: engine) == .deny)
        #expect(MediaCapturePolicy.decide(kind: .microphone, scheme: "http", host: "127.0.0.1", port: 5123, engineOrigin: nil) == .deny)
    }

    @Test func neverTheCamera() {
        #expect(MediaCapturePolicy.decide(kind: .camera, scheme: "http", host: "127.0.0.1", port: 5123, engineOrigin: engine) == .deny)
        #expect(MediaCapturePolicy.decide(kind: .cameraAndMicrophone, scheme: "http", host: "127.0.0.1", port: 5123, engineOrigin: engine) == .deny)
    }
}
