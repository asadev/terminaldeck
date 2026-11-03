import AppKit
import WebKit
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
final class BrowserNativeCoverageTests: XCTestCase {
    func testClosedIsolatedTabReleasesItsPartition() throws {
        let tabs = NativeBrowserTabs.shared
        let first = tabs.create(isolated: true, show: false)
        let second = tabs.create(isolated: true, show: false)
        defer { tabs.close(first.id); tabs.close(second.id) }
        first.ensurePage(); second.ensurePage()
        let bridge = NativeBrowserDataBridge(tabs: tabs, authorizeFetch: { _, _, _ in })
        let partition = "terminaldeck-tab-" + UUID().uuidString
        try bridge.bindIsolatedPartition(partition, to: first.id)
        tabs.close(first.id)
        XCTAssertNoThrow(try bridge.bindIsolatedPartition(partition, to: second.id))
    }

    // Finding 8 (Asad, 24 Oct): the Annotate button stopped responding after a
    // round. A picked element opens the frozen surface, so the live picker is
    // done — `inspecting` must drop to false, or the toolbar button reads a
    // stale "on" and the next press silently toggles a picker that is gone.
    func testPickingAnElementEndsTheLivePickerSoAnnotateKeepsResponding() {
        let tabs = NativeBrowserTabs.shared, tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let pageImage = "data:image/png;base64," + rep.representation(using: .png, properties: [:])!.base64EncodedString()
        tab.inspectStateChanged(true)
        XCTAssertTrue(tab.inspecting)
        tab.inspected(BRInspectCapture(tabId: tab.id, element: nil,
                                       cssRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                       pageImage: pageImage, url: "https://example.invalid/"))
        guard case .annotate = tab.markup else { return XCTFail("A pick must open the Annotate surface") }
        XCTAssertFalse(tab.inspecting, "The live picker must end once the surface opens")
        // Leaving the surface returns to the page with the picker still off.
        tab.markup = nil
        XCTAssertFalse(tab.inspecting)
    }

    func testRepeatedContentCrashStopsUntilExplicitReload() {
        let tabs = NativeBrowserTabs.shared, tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        tab.contentProcessTerminated()
        XCTAssertNil(tab.failure)
        tab.contentProcessTerminated()
        XCTAssertNotNil(tab.failure)
        tab.ensurePage()
        tab.reload()
        tab.navigationStarted()
        tab.contentProcessTerminated()
        XCTAssertNil(tab.failure)
    }

    func testAgentPageSettingsStayInSyncWithToolbarSteps() {
        let tabs = NativeBrowserTabs.shared, tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        tab.ensurePage()
        let desktopUserAgent = tab.webView?.customUserAgent
        tab.setZoom(2)
        XCTAssertEqual(tab.zoom, 2)
        XCTAssertEqual(tab.webView?.pageZoom, 2)
        tab.zoom(by: -1)
        XCTAssertEqual(tab.zoom, 1.5)
        tab.setMobileUserAgent(true)
        XCTAssertTrue(tab.mobileUserAgent)
        XCTAssertEqual(tab.webView?.customUserAgent, BrowserDevicePreset.mobileUserAgent)
        tab.setUserAgent(nil)
        XCTAssertFalse(tab.mobileUserAgent)
        XCTAssertEqual(tab.webView?.customUserAgent, desktopUserAgent)
    }

    func testPageSchemesStayInsideTheTabAndDownloadsTakePriority() async {
        let tabs = NativeBrowserTabs.shared, tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        var opened: [URL] = []
        let delegate = NativeBrowserPageDelegate(tab: tab, openExternal: { opened.append($0) })
        let view = makeView(), preferences = WKWebpagePreferences()
        for address in ["http://example.invalid/", "https://example.invalid/", "about:blank", "data:text/plain,test", "blob:https://example.invalid/id"] {
            let result = await delegate.webView(view, decidePolicyFor: Action(address), preferences: preferences)
            XCTAssertEqual(result.0, .allow, address)
            XCTAssertTrue(result.1 === preferences)
        }
        let download = await delegate.webView(view, decidePolicyFor: Action("https://example.invalid/file", kind: .linkActivated, download: true, modifiers: .command), preferences: preferences)
        XCTAssertEqual(download.0, .download)
        XCTAssertTrue(opened.isEmpty)
    }

    func testExternalSchemesNeedAClickAndFileAndScriptLinksNeverOpenApps() async {
        let tabs = NativeBrowserTabs.shared, tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        var opened: [URL] = []
        let delegate = NativeBrowserPageDelegate(tab: tab, openExternal: { opened.append($0) })
        let view = makeView()
        for address in ["mailto:test@example.invalid", "tel:123", "example-app:open"] {
            let automatic = await delegate.webView(view, decidePolicyFor: Action(address), preferences: WKWebpagePreferences())
            XCTAssertEqual(automatic.0, .cancel)
            XCTAssertTrue(opened.isEmpty)
        }
        for address in ["file:///not-a-file", "javascript:alert(1)"] {
            let clicked = await delegate.webView(view, decidePolicyFor: Action(address, kind: .linkActivated), preferences: WKWebpagePreferences())
            XCTAssertEqual(clicked.0, .cancel)
        }
        XCTAssertTrue(opened.isEmpty)
        let clicked = await delegate.webView(view, decidePolicyFor: Action("mailto:test@example.invalid", kind: .linkActivated), preferences: WKWebpagePreferences())
        XCTAssertEqual(clicked.0, .cancel)
        XCTAssertEqual(opened.map(\.absoluteString), ["mailto:test@example.invalid"])
        let missing = await delegate.webView(view, decidePolicyFor: Action(nil), preferences: WKWebpagePreferences())
        XCTAssertEqual(missing.0, .cancel)
    }

    func testLinkModifiersKeepProfileAndChooseBackgroundOrForegroundTab() async {
        let profile = UUID().uuidString.lowercased()
        let tabs = NativeBrowserTabs.shared, tab = tabs.create(isolated: true, profile: profile, show: false)
        let existing = Set(tabs.tabs.map(\.id))
        defer {
            for page in tabs.tabs where !existing.contains(page.id) { tabs.close(page.id) }
            tabs.close(tab.id)
        }
        let delegate = NativeBrowserPageDelegate(tab: tab, openExternal: { _ in XCTFail("A page link opened an external app") })
        let choices: [(NSEvent.ModifierFlags, Int, Bool)] = [(.command, 0, false), ([], 2, false), ([.command, .shift], 0, true)]
        for (modifiers, button, foreground) in choices {
            let before = Set(tabs.tabs.map(\.id)), selected = tabs.selectedID
            let result = await delegate.webView(makeView(), decidePolicyFor: Action("about:blank", kind: .linkActivated, modifiers: modifiers, button: button), preferences: WKWebpagePreferences())
            XCTAssertEqual(result.0, .cancel)
            let created = tabs.tabs.filter { !before.contains($0.id) }
            XCTAssertEqual(created.count, 1)
            XCTAssertEqual(created.first?.isolated, true)
            XCTAssertEqual(created.first?.profile, profile)
            XCTAssertEqual(tabs.selectedID, foreground ? created.first?.id : selected)
        }
    }

    func testResponsePoliciesDownloadUnsupportedContentAndMainFrameAttachments() async {
        let attachment = HTTPURLResponse(url: URL(string: "https://example.invalid/file")!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Disposition": "AtTaChMeNt; filename=test.txt"])!
        for (main, show, expected) in [(true, true, WKNavigationResponsePolicy.download),
                                       (false, true, .allow), (false, false, .download)] {
            let policy = NativeBrowserPageDelegate.responsePolicy(response: attachment, isForMainFrame: main, canShowMIMEType: show)
            XCTAssertEqual(policy, expected)
        }
        let page = URLResponse(url: URL(string: "https://example.invalid/page")!, mimeType: "text/html", expectedContentLength: 0, textEncodingName: "utf-8")
        let allowed = NativeBrowserPageDelegate.responsePolicy(response: page, isForMainFrame: true, canShowMIMEType: true)
        XCTAssertEqual(allowed, .allow)
    }

    func testIsolatedDataPartitionsCannotBeStolenOrReusedAfterCancellation() async throws {
        let tabs = NativeBrowserTabs.shared
        let first = tabs.create(isolated: true, show: false), second = tabs.create(isolated: true, show: false)
        defer { tabs.close(first.id); tabs.close(second.id) }
        first.ensurePage(); second.ensurePage()
        let bridge = NativeBrowserDataBridge(tabs: tabs, authorizeFetch: { _, _, _ in XCTFail("No fetch was requested") })
        let partition = "terminaldeck-tab-" + UUID().uuidString
        try bridge.bindIsolatedPartition(partition, to: first.id)
        XCTAssertThrowsError(try bridge.bindIsolatedPartition(partition, to: second.id))
        XCTAssertThrowsError(try bridge.bindIsolatedPartition("persist:other-browser", to: first.id))
        let size = try await bridge.handle("browser-data:cache-size", ["partition": partition])
        XCTAssertTrue(size is NSNull, "Unknown cache size must not be a fabricated zero")
        await bridge.cancel(partition: partition)
        do {
            _ = try await bridge.handle("browser-data:cache-size", ["partition": partition])
            XCTFail("A retired partition remained usable")
        } catch {}
        await bridge.shutdown()
    }

    func testDataFetchAsksForTheExactProfileAndURLBeforeSendingAnything() async throws {
        let tabs = NativeBrowserTabs.shared, tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        tab.ensurePage()
        var calls: [(String, URL, String)] = []
        let bridge = NativeBrowserDataBridge(tabs: tabs, authorizeFetch: { partition, url, operation in
            calls.append((partition, url, operation))
            throw NativeRPCError(code: "test-denied", message: "Not granted")
        })
        let partition = "terminaldeck-tab-" + UUID().uuidString
        try bridge.bindIsolatedPartition(partition, to: tab.id)
        do {
            _ = try await bridge.handle("browser-data:fetch", ["partition": partition, "fetchID": "denied-fetch", "url": "https://example.invalid/private"])
            XCTFail("A denied fetch completed")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "test-denied") }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, partition)
        XCTAssertEqual(calls.first?.1.absoluteString, "https://example.invalid/private")
        XCTAssertEqual(calls.first?.2, "browser-data:fetch-hop")
        await bridge.shutdown()
    }

    func testPasswordsFollowCommittedDocumentsAndLoseAccessWhenOwnershipIsRevoked() async throws {
        let profile = UUID().uuidString.lowercased()
        var ownership: NativeSafariPasswordsOwnership? = .init(profileID: profile, isolated: true, agentHolding: true)
        let adapter = NativeSafariPasswords(ownership: { _ in ownership }, signInOffer: { _, _ in }, passwordOffer: { _, _ in }, reportFailure: { _ in })
        defer { adapter.shutdown() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        adapter.install(into: configuration)
        adapter.install(into: configuration)
        XCTAssertEqual(configuration.userContentController.userScripts.count, 1)
        XCTAssertTrue(configuration.userContentController.userScripts.allSatisfy(\.isForMainFrameOnly))
        XCTAssertEqual(configuration.userContentController.userScripts.first?.injectionTime, .atDocumentStart)
        let view = PageView(frame: .zero, configuration: configuration)
        view.pageURL = URL(string: "https://example.invalid/first")
        let host = adapter.makeHost()
        adapter.bind(view, tabID: "page")
        let uncommitted = try await host.tab("page")
        XCTAssertNil(uncommitted)
        adapter.didCommit(view, tabID: "page")
        let firstValue = try await host.tab("page")
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.profileID, profile)
        XCTAssertEqual(first.committedURL, "https://example.invalid/first")
        XCTAssertTrue(first.isolated && first.agentHolding && first.documentFromAgent)
        view.pageURL = URL(string: "https://example.invalid/second")
        adapter.didCommit(view, tabID: "page")
        let secondValue = try await host.tab("page")
        let second = try XCTUnwrap(secondValue)
        XCTAssertNotEqual(first.documentID, second.documentID)
        ownership = nil
        let revoked = try await host.tab("page")
        XCTAssertNil(revoked)
        adapter.unbind(tabID: "page")
        let unbound = try await host.tab("page")
        XCTAssertNil(unbound)
    }

    private func makeView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private final class Action: WKNavigationAction {
        let value: URLRequest
        let kind: WKNavigationType
        let download: Bool
        let modifiers: NSEvent.ModifierFlags
        let button: Int
        init(_ address: String?, kind: WKNavigationType = .other, download: Bool = false, modifiers: NSEvent.ModifierFlags = [], button: Int = 0) {
            var request = URLRequest(url: URL(string: "about:blank")!)
            request.url = address.flatMap(URL.init(string:))
            value = request; self.kind = kind; self.download = download; self.modifiers = modifiers; self.button = button
            super.init()
        }
        override var request: URLRequest { value }
        override var navigationType: WKNavigationType { kind }
        override var shouldPerformDownload: Bool { download }
        override var modifierFlags: NSEvent.ModifierFlags { modifiers }
        override var buttonNumber: Int { button }
        override var targetFrame: WKFrameInfo? { nil }
    }
    private final class PageView: WKWebView {
        var pageURL: URL?
        override var url: URL? { pageURL }
    }
}
