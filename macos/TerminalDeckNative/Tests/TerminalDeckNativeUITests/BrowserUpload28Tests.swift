import Foundation
import Network
import WebKit
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Only dummy bytes, ephemeral profile tabs and loopback listeners. Never visits
/// a live site or reads the person's browser/profile files.
@MainActor
final class BrowserUpload28Tests: XCTestCase {
    private func runtime(_ scratch: URL) -> NativeSafariRuntime {
        NativeSafariRuntime(tabs: .shared, bindings: BackendBrowserBindings(), dataRoot: scratch.appendingPathComponent("app-data"),
                            screenshotDirectory: scratch, browserData: { _, _ in NSNull() },
                            authorizePopup: { _, _, _ in }, publish: { _, _ in })
    }

    private func waitFor(_ view: WKWebView, _ script: String) async throws {
        for _ in 0..<500 {
            if (try? await view.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The local upload fixture did not become ready")
        throw BrowserDriverRefusal("The local upload fixture did not become ready")
    }

    func testNavigationFromAuthorizedOriginAToBReceivesNoFiles() async throws {
        let b = try UploadOriginFixture(html: """
        <input id="upload" type="file"><script>
        window.received=0;document.addEventListener('drop',e=>{window.received+=e.dataTransfer.files.length});
        document.getElementById('upload').onchange=e=>{window.received+=e.target.files.length};
        </script>
        """)
        defer { b.stop() }
        let bURL = try await b.address()
        let a = try UploadOriginFixture(html: """
        <button id="upload" onclick="setTimeout(()=>location.href='\(bURL)',100)">Upload</button>
        """)
        defer { a.stop() }
        let aURL = try await a.address()
        XCTAssertNotEqual(BackendBrowserOrigin.exact(aURL), BackendBrowserOrigin.exact(bURL))
        let scratch = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("td-upload28-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("ordinary.txt")
        try Data("dummy document for authorized A".utf8).write(to: file)
        let runtime = runtime(scratch), id = runtime.createTab(url: try XCTUnwrap(URL(string: aURL)), isolated: true)
        defer { runtime.tabs.close(id) }
        let view = try runtime.requireView(id)
        try await waitFor(view, "!!document.getElementById('upload')")
        let authorizedDocument = runtime.uploadDocument(id)
        do {
            _ = try await runtime.upload(id, selector: "#upload", files: [file.path], probe: ["tag": "button"],
                                         authority: { runtime.uploadDocument(id) == authorizedDocument })
            XCTFail("Navigation during the chooser wait must refuse the upload")
        } catch {}
        try await waitFor(view, "typeof window.received === 'number'")
        XCTAssertEqual(BackendBrowserOrigin.exact(view.url?.absoluteString ?? ""), BackendBrowserOrigin.exact(bURL))
        let received = try await view.evaluateJavaScript("window.received") as? Int
        let count = try await view.evaluateJavaScript("document.getElementById('upload').files.length") as? Int
        XCTAssertEqual(received, 0)
        XCTAssertEqual(count, 0)
        XCTAssertFalse(try runtime.requireTab(id).automation.uploadArmed)
    }

    func testQueuedFallbackRefusesReplacementDocumentAndNestedFrame() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        defer { view.stopLoading() }
        let base = "http://127.0.0.1:42128/"
        view.loadHTMLString("<input id='upload' type='file'>", baseURL: URL(string: base))
        try await waitFor(view, "!!document.getElementById('upload')")
        let currentURL = try await view.evaluateJavaScript("String(location.href)") as? String
        let page = try XCTUnwrap(currentURL)
        _ = try await view.evaluateJavaScript("window.__tdUploadDocument='authorized'", in: nil, contentWorld: .defaultClient)
        let script = BrowserDriverScripts.with(BrowserDriverScripts.files, args: ["selector": "#upload", "mode": "input", "mainDocumentOnly": true,
            "files": [["name": "dummy.txt", "data": Data("dummy".utf8).base64EncodedString()]]])
        let bound = NativeSafariRuntime.boundUploadScript(script, token: "authorized", page: page)
        let allowed = try await view.evaluateJavaScript(bound, in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertEqual(allowed?["ok"] as? Bool, true, "The bound ordinary upload remains supported")
        // Same URL, new document: an origin-only guard would wrongly allow it.
        view.loadHTMLString("<input id='upload' type='file'>", baseURL: URL(string: base))
        try await waitFor(view, "!!document.getElementById('upload') && document.getElementById('upload').files.length===0")
        let refused = try await view.evaluateJavaScript(bound, in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertEqual(refused?["ok"] as? Bool, false)
        let replacementCount = try await view.evaluateJavaScript("document.getElementById('upload').files.length") as? Int
        XCTAssertEqual(replacementCount, 0)
        view.loadHTMLString("<iframe srcdoc=\"<input id='upload' type='file'>\"></iframe>", baseURL: URL(string: base))
        try await waitFor(view, "!!document.querySelector('iframe').contentDocument.getElementById('upload')")
        _ = try await view.evaluateJavaScript("window.__tdUploadDocument='authorized'", in: nil, contentWorld: .defaultClient)
        let nested = try await view.evaluateJavaScript(bound, in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertEqual(nested?["ok"] as? Bool, false)
        let nestedCount = try await view.evaluateJavaScript("document.querySelector('iframe').contentDocument.getElementById('upload').files.length") as? Int
        XCTAssertEqual(nestedCount, 0)
    }

    func testFallbackChecksRevokedAuthorityAndCancelledTaskBeforeDelivery() async throws {
        let server = try UploadOriginFixture(html: "<div id='upload'>Drop here</div><script>window.received=0;document.addEventListener('drop',e=>{window.received+=e.dataTransfer.files.length})</script>")
        defer { server.stop() }
        let address = try await server.address()
        let scratch = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("td-upload28-authority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("ordinary.txt")
        try Data("dummy document".utf8).write(to: file)
        let runtime = runtime(scratch), id = runtime.createTab(url: try XCTUnwrap(URL(string: address)), isolated: true)
        defer { runtime.tabs.close(id) }
        let view = try runtime.requireView(id), tab = try runtime.requireTab(id)
        try await waitFor(view, "!!document.getElementById('upload')")
        for cancel in [false, true] {
            var authorized = true
            let upload = Task { @MainActor in
                _ = try await runtime.upload(id, selector: "#upload", files: [file.path], probe: ["tag": "div"], authority: { authorized })
            }
            for _ in 0..<500 where !tab.automation.uploadArmed { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(tab.automation.uploadArmed)
            if cancel { upload.cancel() } else { authorized = false }
            do { _ = try await upload.value; XCTFail("Revocation/cancellation must stop the fallback") } catch {}
            let count = try await view.evaluateJavaScript("window.received") as? Int
            XCTAssertEqual(count, 0)
            XCTAssertFalse(tab.automation.uploadArmed)
        }
    }

    func testChooserChecksOriginFrameLiveAuthorityAndCancellation() {
        let automation = NativeBrowserAutomation(), file = URL(fileURLWithPath: "/tmp/dummy-upload28.txt")
        let a = "http://127.0.0.1:41001", b = "http://127.0.0.1:41002"
        var authorized = true
        func arm() { automation.armUpload([file], origin: a, authority: { authorized }) }
        arm()
        XCTAssertNil(automation.takeUpload(multiple: true, mainFrame: true, origin: b))
        arm()
        XCTAssertNil(automation.takeUpload(multiple: true, mainFrame: false, origin: a))
        arm(); authorized = false
        XCTAssertNil(automation.takeUpload(multiple: true, mainFrame: true, origin: a))
        authorized = true; arm()
        XCTAssertEqual(automation.takeUpload(multiple: true, mainFrame: true, origin: a), [file])
        let cancelled = NativeBrowserUploadCancellation()
        automation.armUpload([file], origin: a, authority: { !cancelled.isCancelled })
        cancelled.cancel()
        XCTAssertNil(automation.takeUpload(multiple: true, mainFrame: true, origin: a))
        XCTAssertFalse(automation.uploadArmed)
    }

    func testNavigationAndHandoverDisarmAndResumeCannotReviveUpload() {
        let tabs = NativeBrowserTabs.shared, tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        let file = URL(fileURLWithPath: "/tmp/dummy-upload28.txt"), a = "http://127.0.0.1:41001"
        tab.automation.armUpload([file], origin: a, authority: { true })
        tab.navigationStarted()
        XCTAssertFalse(tab.automation.uploadArmed)
        XCTAssertNil(tab.automation.takeUpload(multiple: true, mainFrame: true, origin: a))
        tab.automation.armUpload([file], origin: a, authority: { true })
        tab.beginHandover("Person takes the page")
        tab.endHandover("resumed")
        XCTAssertFalse(tab.automation.uploadArmed)
        XCTAssertNil(tab.automation.takeUpload(multiple: true, mainFrame: true, origin: a))
    }
}

@MainActor
private final class UploadOriginFixture {
    private let listener: NWListener
    init(html: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let body = Data(html.utf8)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let response = Data(header.utf8) + body
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .utility))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global(qos: .utility))
    }
    func address() async throws -> String {
        for _ in 0..<500 {
            if case .ready = listener.state, let port = listener.port, port.rawValue != 0 {
                return "http://127.0.0.1:\(port.rawValue)/"
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BrowserDriverRefusal("The local upload fixture listener did not start")
    }
    func stop() { listener.cancel() }
}
