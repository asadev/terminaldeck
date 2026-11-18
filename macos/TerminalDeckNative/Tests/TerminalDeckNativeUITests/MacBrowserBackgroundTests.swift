import AppKit
import Network
import SwiftUI
import WebKit
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// No app launch, profile files, installed app, global tabs, OS captures or live sites.
/// The only windows are non-key offscreen fixture windows owned by this test process.
@MainActor
final class MacBrowserBackgroundTests: XCTestCase {
    @MainActor
    private final class Rig {
        let tabs = NativeBrowserTabs(persist: false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-browser-bg-\(UUID().uuidString)")
        init() { _ = NSApplication.shared }
        lazy var runtime = NativeSafariRuntime(tabs: tabs, bindings: BackendBrowserBindings(), dataRoot: root,
            screenshotDirectory: root, browserData: { _, _ in NSNull() }, authorizePopup: { _, _, _ in }, publish: { _, _ in })
        func page(_ html: String) async throws -> NativeBrowserTab {
            let tab = tabs.create(isolated: true, show: false)
            tab.ensurePage()
            tab.webView?.loadHTMLString("<!doctype html><meta charset=utf-8>" + html + "<div id=td-fixture-ready hidden></div>", baseURL: URL(string: "https://fixture.invalid/"))
            try await MacBrowserBackgroundTests.wait { !tab.isLoading && tab.webView?.url != nil }
            return tab
        }
        func close() {
            for tab in tabs.tabs { tabs.close(tab.id) }
            runtime.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
    }
    private static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BrowserDriverRefusal("The local browser fixture did not reach the expected state.")
    }
    private func ready(_ view: WKWebView, marker: Bool = true) async throws {
        for _ in 0..<500 {
            let script = marker ? "document.readyState==='complete' && !!document.getElementById('td-fixture-ready')" : "document.readyState==='complete'"
            if (try? await view.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BrowserDriverRefusal("The fixture document did not finish loading.")
    }
    private func command(_ runtime: NativeSafariRuntime, _ verb: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let request = try XCTUnwrap(BrowserDriverCommand.decode([["id": UUID().uuidString, "verb": verb, "args": args]]))
        return await BrowserDriverEngine(host: runtime).answer(request)
    }

    func testHiddenReadClickTypeAndSnapshotUseActualPageWithoutSelectingOrFocus() async throws {
        _ = NSApplication.shared
        let rig = Rig(); defer { rig.close() }
        var selected: [String] = []
        rig.tabs.onSelect = { selected.append($0) }
        let tab = try await rig.page("""
        <body style='margin:0;background:rgb(20,120,210);height:100vh'><h1>Hidden fixture</h1>
        <button id=go onclick="document.querySelector('h1').textContent='Clicked in background'">Go</button><input id=word>
        """)
        let view = try XCTUnwrap(tab.webView)
        try await ready(view)
        let beforeKey = NSApp.keyWindow, beforeMain = NSApp.mainWindow
        rig.runtime.ownTabID = tab.id
        let read = try await command(rig.runtime, "browser_read")
        XCTAssertNil(read["error"], "\(read)")
        XCTAssertTrue(String(describing: read).contains("Hidden fixture"))
        let click = try await command(rig.runtime, "browser_step", ["verb": "click", "selector": "#go"])
        XCTAssertNil(click["error"], "\(click)")
        let type = try await command(rig.runtime, "browser_step", ["verb": "type", "selector": "#word", "value": "local fixture"])
        XCTAssertNil(type["error"], "\(type)")
        let value = try await view.evaluateJavaScript("document.querySelector('#word').value") as? String
        XCTAssertEqual(value, "local fixture")
        let shot = try await rig.runtime.privacySnapshotPNG(tab.id)
        let image = try XCTUnwrap(NSBitmapImageRep(data: shot.bytes))
        let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.blueComponent, 0.5)
        XCTAssertLessThan(color.redComponent, 0.25, "The picture contains the blue fixture, not an empty white surface")
        XCTAssertGreaterThanOrEqual(shot.width, 1280)
        XCTAssertEqual(Double(shot.width) / Double(shot.height), 1.6, accuracy: 0.01)
        XCTAssertTrue(view.window is NativeBrowserCaptureWindow)
        XCTAssertFalse(tab.pageInWindow)
        XCTAssertFalse(tab.shownToPerson)
        XCTAssertTrue(NSApp.keyWindow === beforeKey)
        XCTAssertTrue(NSApp.mainWindow === beforeMain)
        XCTAssertEqual(selected, [])
        XCTAssertFalse(try XCTUnwrap(view.window).canBecomeKey)
        XCTAssertFalse(try XCTUnwrap(view.window).canBecomeMain)
        XCTAssertFalse(NSApp.isActive)
    }

    func testSwitchingHostsAndMinimisingKeepsTheSameDocumentAndFullSize() async throws {
        let rig = Rig(); defer { rig.close() }
        let tab = try await rig.page("<body style='background:rgb(20,120,210)'><h1>Same document</h1><script>window.identity='kept'</script>")
        let page = try XCTUnwrap(tab.webView)
        try await ready(page)
        let parent = FixtureWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 650), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let viewport = DeckWebViewport(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        parent.contentView = viewport
        defer { viewport.dismantle(); parent.contentView = nil; parent.close() }
        viewport.show(page); viewport.layoutSubtreeIfNeeded()
        XCTAssertTrue(page.window === parent)
        XCTAssertNil(tab.automation.parkingWindow)
        parent.fixtureMiniaturized = true
        NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: parent)
        XCTAssertTrue(page.window is NativeBrowserCaptureWindow)
        XCTAssertEqual(page.bounds.size, CGSize(width: 900, height: 650))
        let shot = try await rig.runtime.privacySnapshotPNG(tab.id)
        XCTAssertGreaterThan(shot.bytes.count, 1000)
        parent.fixtureMiniaturized = false
        NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: parent)
        XCTAssertTrue(page.window === parent)
        viewport.detach()
        try await Self.wait { page.window is NativeBrowserCaptureWindow }
        let identity = try await page.evaluateJavaScript("window.identity") as? String
        XCTAssertEqual(identity, "kept")
        XCTAssertEqual(page.configuration.preferences.inactiveSchedulingPolicy, .none)
        XCTAssertTrue(page.backgroundRenderingAvailable)
        XCTAssertFalse(NSApp.isActive)
    }

    func testTimersAnimationNetworkAndSnapshotSurviveOldSixtySecondExpiry() async throws {
        let server = try BackgroundHTTPFixture(); defer { server.stop() }
        let socket = try BackgroundWebSocketFixture(); defer { socket.stop() }
        let socketURL = try await socket.address()
        let url = try await server.address()
        let rig = Rig(); defer { rig.close() }
        let id = rig.runtime.createTab(url: url, isolated: true)
        let tab = try rig.runtime.requireTab(id), page = try XCTUnwrap(tab.webView)
        try await ready(page)
        _ = try await page.evaluateJavaScript("window.socketState='waiting';window.fixtureSocket=new WebSocket('\(socketURL)');window.fixtureSocket.onmessage=e=>window.socketState=e.data;true")
        _ = try await rig.runtime.privacySnapshotPNG(id)
        let host = page.window
        // Longer than the deleted idle expiry, with no tool touching or renewing the page in between.
        try await Task.sleep(for: .seconds(65))
        XCTAssertTrue(page.window === host)
        let state = try await page.evaluateJavaScript("({ticks:window.ticks,frames:window.framesSeen,net:window.net,socket:window.socketState})") as? [String: Any]
        XCTAssertGreaterThan((state?["ticks"] as? Int) ?? 0, 500)
        XCTAssertGreaterThan((state?["frames"] as? Int) ?? 0, 100)
        XCTAssertEqual(state?["net"] as? String, "loopback response")
        XCTAssertEqual(state?["socket"] as? String, "socket alive after expiry")
        rig.runtime.ownTabID = id
        let read = try await command(rig.runtime, "browser_read")
        XCTAssertNil(read["error"], "\(read)")
        XCTAssertTrue(String(describing: read).contains("Still running"), "The actual browser_read result must contain the rendered fixture text")
        let shot = try await rig.runtime.privacySnapshotPNG(id)
        let image = try XCTUnwrap(NSBitmapImageRep(data: shot.bytes))
        let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(color.redComponent, 0.25)
        XCTAssertGreaterThan(color.blueComponent, 0.5)
        XCTAssertFalse(NSApp.isActive)
    }

    func testEachJavaScriptDialogWaitsAndThenUsesThePersonsAnswer() async throws {
        for kind in ["alert", "confirm", "prompt"] {
            let rig = Rig(); defer { rig.close() }
            let tab = try await rig.page("<body>Dialog fixture</body>")
            let page = try XCTUnwrap(tab.webView)
            try await ready(page)
            var personReady = false, shown: [String] = []
            tab.pageRequests = NativeBrowserPageRequests(tab: tab, ready: { personReady })
            let delegate = NativeBrowserPageDelegate(tab: tab, present: { _, alert in
                shown.append(kind)
                if let field = alert.accessoryView as? NSTextField { field.stringValue = "dummy answer" }
                return .alertFirstButtonReturn
            })
            page.uiDelegate = delegate
            tab.automation.toolTouched()
            let script = kind == "prompt" ? "window.answer=prompt('Fixture prompt','default')" : "window.answer=\(kind)('Fixture \(kind)')"
            let started = ProcessInfo.processInfo.systemUptime
            do { _ = try await rig.runtime.js(page, script, world: .page); XCTFail("The tool must hear that the page is waiting") }
            catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("waiting for the person"), "\(error)") }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
            XCTAssertEqual(tab.pageRequests.questions.first?.kind, kind)
            XCTAssertTrue(tab.pageRequests.needsAttention)
            XCTAssertEqual(shown, [])
            XCTAssertNil(page.window?.attachedSheet)
            let notes = rig.runtime.takePageNotes(tab.id)
            XCTAssertEqual(notes.last?["answer"] as? String, "waiting for the person")
            personReady = true
            tab.pageRequests.review()
            try await Self.wait { tab.pageRequests.questions.isEmpty }
            XCTAssertEqual(shown, [kind])
            if kind != "alert" {
                let answer = try await page.evaluateJavaScript("window.answer")
                if kind == "confirm" { XCTAssertEqual(answer as? Bool, true) }
                else { XCTAssertEqual(answer as? String, "dummy answer") }
            }
            XCTAssertFalse(tab.automation.dialogs.contains { $0.answer.contains("dummy answer") })
        }
    }

    func testStandingDialogAnswersRemainExplicitAndOnceOnly() async throws {
        let rig = Rig(); defer { rig.close() }
        let tab = try await rig.page("<body>Dialog policy fixture</body>")
        let view = try XCTUnwrap(tab.webView); try await ready(view)
        tab.automation.dialogPolicy = .accept; tab.automation.dialogOnce = true
        let result = try await rig.runtime.js(view, "confirm('A pre-authorized fixture question')", world: .page) as? Bool
        XCTAssertEqual(result, true)
        XCTAssertEqual(tab.automation.dialogPolicy, .ask)
        XCTAssertTrue(tab.pageRequests.questions.isEmpty)
    }

    func testFileChooserMediaAndLocationDelegatesWaitInsteadOfDenyingForTools() async throws {
        let rig = Rig(); defer { rig.close() }
        let tab = try await rig.page("<body>Delegate fixture<input id=files type=file></body>")
        let view = try XCTUnwrap(tab.webView); try await ready(view)
        let delegate = NativeBrowserPageDelegate(tab: tab)
        let frame = try await fixtureFrame(view)
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")))
        if #available(macOS 27.0, *) {
            XCTAssertTrue(delegate.responds(to: NSSelectorFromString("webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:")))
        }
        tab.automation.toolTouched()
        rig.runtime.ownTabID = tab.id
        let chooser = try await command(rig.runtime, "browser_step", ["verb": "click", "selector": "#files"])
        XCTAssertTrue(String(describing: chooser).lowercased().contains("waiting for the person"))
        try await Self.wait { tab.pageRequests.questions.first?.kind == "file-chooser" }
        XCTAssertNil(view.window?.attachedSheet)
        tab.pageRequests.reset()
        for type in [WKMediaCaptureType.camera, .microphone, .cameraAndMicrophone] {
            let media = Task { await delegate.webView(view, decideMediaCapturePermissionsFor: frame.securityOrigin, initiatedBy: frame, type: type) }
            try await Self.wait { tab.pageRequests.questions.first?.kind == "media-permission" }
            XCTAssertTrue(tab.pageRequests.line?.contains("Waiting for the person") == true)
            tab.pageRequests.reset()
            let answer = await media.value
            XCTAssertEqual(answer, .deny, "Closing the question cancels it; it was not silently denied on arrival")
        }
        if #available(macOS 27.0, *) {
            let location = Task { await delegate.webView(view, requestGeolocationPermissionFor: frame.securityOrigin, initiatedBy: frame) }
            try await Self.wait { tab.pageRequests.questions.first?.kind == "location" }
            tab.pageRequests.reset()
            let answer = await location.value
            XCTAssertEqual(answer, .deny)
        }
    }

    func testCompletedHumanFileChoiceDoesNotRefuseTheNextToolStep() async throws {
        let rig = Rig(); defer { rig.close() }
        let tab = try await rig.page(#"<button id=next onclick="this.textContent='Continued'">Continue</button>"#)
        let page = try XCTUnwrap(tab.webView); try await ready(page)
        tab.automation.noteForTool(.init(kind: "file-chooser", message: "The person answered the chooser.", site: "fixture.invalid",
            answer: "files chosen", by: "person", at: Date()))
        rig.runtime.ownTabID = tab.id
        let answer = try await command(rig.runtime, "browser_step", ["verb": "click", "selector": "#next"])
        XCTAssertNil(answer["error"], "A completed human choice must not become the legacy upload refusal: \(answer)")
        let text = try await page.evaluateJavaScript("document.getElementById('next').textContent") as? String
        XCTAssertEqual(text, "Continued")
    }

    func testHTTPAuthenticationWaitsAndCredentialDoesNotEnterToolNotes() async throws {
        let rig = Rig(); defer { rig.close() }
        let tab = try await rig.page("<body>HTTP fixture</body>")
        let page = try XCTUnwrap(tab.webView); try await ready(page)
        var personReady = false
        tab.pageRequests = NativeBrowserPageRequests(tab: tab, ready: { personReady })
        let delegate = NativeBrowserPageDelegate(tab: tab, present: { _, alert in
            let fields = alert.accessoryView?.subviews.compactMap { $0 as? NSTextField } ?? []
            fields.first?.stringValue = "dummy-user"; fields.last?.stringValue = "dummy-http-password"
            return .alertFirstButtonReturn
        })
        let space = URLProtectionSpace(host: "fixture.invalid", port: 443, protocol: "https", realm: "Fixture", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: FixtureChallengeSender())
        let result = Task { await delegate.webView(page, respondTo: challenge) }
        try await Self.wait { tab.pageRequests.questions.first?.kind == "http-sign-in" }
        XCTAssertNil(page.window?.attachedSheet)
        XCTAssertFalse(String(describing: rig.runtime.takePageNotes(tab.id)).contains("dummy-http-password"))
        personReady = true; tab.pageRequests.review()
        let answer = await result.value
        XCTAssertEqual(answer.0, .useCredential)
        XCTAssertEqual(answer.1?.user, "dummy-user")
        XCTAssertEqual(answer.1?.persistence, URLCredential.Persistence.none)
    }

    func testBrowserOpenReturnsWaitingForHTTPQuestionInsteadOfAnUnexplainedUnsettledPage() async throws {
        let server = try BackgroundHTTPFixture(); defer { server.stop() }
        let url = try await server.address().appendingPathComponent("auth")
        let rig = Rig(); defer { rig.close() }
        let answer = try await command(rig.runtime, "browser_open", ["url": url.absoluteString, "isolate": true])
        XCTAssertNil(answer["error"], "\(answer)")
        let value = try XCTUnwrap(answer["value"] as? [String: Any])
        XCTAssertEqual(value["status"] as? String, "waiting for the person")
        XCTAssertEqual(value["settled"] as? Bool, false)
        let id = try XCTUnwrap(rig.runtime.ownTabID)
        do { _ = try await rig.runtime.privacySnapshotPNG(id); XCTFail("A waiting question must be reported before capture") }
        catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("waiting for the person")) }
    }

    func testPasskeyCapabilitiesExplainMissingManagedEntitlementAndAssociatedDomains() async throws {
        let missing = NativeBrowserPageCapabilities(browserPasskeys: false, associatedDomains: ["webcredentials:terminaldeck.dev"], locationDelegate: false)
        XCTAssertNil(missing.passkeyRefusal(relyingParty: "terminaldeck.dev"))
        XCTAssertTrue(missing.passkeyRefusal(relyingParty: "accounts.google.com")?.contains("managed browser passkey entitlement") == true)
        XCTAssertNil(NativeBrowserPageCapabilities(browserPasskeys: true, associatedDomains: [], locationDelegate: true).passkeyRefusal(relyingParty: "any.invalid"))
        let rig = Rig(); defer { rig.close() }
        let tab = try await rig.page("<body>Passkey fixture</body>")
        let bridge = NativeBrowserRequestBridge(tabs: rig.tabs, capabilities: { missing })
        for kind in ["webauthn", "notification", "location", "error-media", "error-webauthn", "popup-blocked"] {
            let answer = await bridge.answer(kind: kind, tab: tab, site: "fixture.invalid", errorName: "NotAllowedError")
            XCTAssertEqual(answer["allow"] as? Bool, false)
            XCTAssertNotNil(answer["reason"] as? String)
            XCTAssertNotNil(tab.pageRequests.problem)
            XCTAssertFalse(rig.runtime.takePageNotes(tab.id).isEmpty)
            tab.pageRequests.reset()
        }
    }

    func testAllowedWebAuthnIsHeldUntilReviewedAndStaysWaitingUntilNativeCompletion() async throws {
        let rig = Rig(); defer { rig.close() }
        let tab = try await rig.page("<body>Passkey gate fixture</body>")
        var personReady = false
        tab.pageRequests = NativeBrowserPageRequests(tab: tab, ready: { personReady })
        let bridge = NativeBrowserRequestBridge(tabs: rig.tabs, capabilities: { .init(browserPasskeys: true, associatedDomains: [], locationDelegate: true) })
        let request = Task { NativeBrowserUnchecked(await bridge.answer(kind: "webauthn", tab: tab, site: "fixture.invalid")) }
        try await Self.wait { tab.pageRequests.questions.first?.kind == "webauthn" }
        personReady = true; tab.pageRequests.review()
        let carried = await request.value
        let result = try XCTUnwrap(carried.value as? [String: Any])
        XCTAssertEqual(result["allow"] as? Bool, true)
        XCTAssertNotNil(tab.pageRequests.waitingReason)
        _ = await bridge.answer(kind: "request-finished", tab: tab, site: "fixture.invalid", relyingParty: result["ticket"] as? String)
        XCTAssertNil(tab.pageRequests.waitingReason)
    }

    func testVisibleWebAuthnPreservesPageGestureBeforeAnyBridgeAwait() async throws {
        let rig = Rig(); defer { rig.close() }
        rig.tabs.requestBridge = NativeBrowserRequestBridge(tabs: rig.tabs, capabilities: {
            .init(browserPasskeys: true, associatedDomains: [], locationDelegate: true)
        })
        let configuration = rig.tabs.makeConfiguration(profile: "", isolated: true)
        configuration.userContentController.addUserScript(WKUserScript(source: """
        navigator.credentials.get=function(){window.calledDuring=window.phase;return Promise.resolve({fixture:true})};
        Object.defineProperty(document,'hasFocus',{value:()=>true});
        Object.defineProperty(navigator,'userActivation',{value:{isActive:true}});
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let tab = rig.tabs.create(isolated: true, show: false, configuration: configuration)
        let view = try XCTUnwrap(tab.webView)
        view.loadHTMLString("<body>Gesture fixture<div id=td-fixture-ready hidden></div></body>", baseURL: URL(string: "https://fixture.invalid/"))
        try await ready(view)
        _ = try await view.evaluateJavaScript("window.phase='before';navigator.credentials.get({publicKey:{challenge:new Uint8Array([1]),rpId:'fixture.invalid'}}).then(r=>window.fixtureDone=r.fixture);window.phase='after';true")
        for _ in 0..<500 {
            if (try? await view.evaluateJavaScript("window.fixtureDone===true")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let during = try await view.evaluateJavaScript("String(window.calledDuring || 'not called')") as? String
        XCTAssertEqual(during, "before", "The native call must run in the original page click, before awaiting the bridge")
        try await Self.wait { tab.pageRequests.questions.isEmpty }
        XCTAssertFalse(NSApp.isActive)
    }

    func testActualPageBridgeReportsUnsupportedPasskeysWithoutLeakingChallengeBytes() async throws {
        let rig = Rig(); defer { rig.close() }
        let tab = try await rig.page("<body>Page request bridge fixture</body>")
        let page = try XCTUnwrap(tab.webView); try await ready(page)
        // The test binary has no managed browser entitlement. No authenticator or keychain access is attempted.
        let script = "navigator.credentials.get({publicKey:{challenge:new Uint8Array([9,8,7]),rpId:'fixture.invalid'}}).catch(e=>{window.fixtureReason=e.message});true"
        _ = try await page.evaluateJavaScript(script)
        try await Self.wait { tab.pageRequests.problem != nil }
        XCTAssertTrue(tab.pageRequests.problem?.contains("managed browser passkey entitlement") == true)
        XCTAssertFalse(String(describing: rig.runtime.takePageNotes(tab.id)).contains("challenge"))
        let state = try rig.runtime.pageState(tab.id)
        XCTAssertEqual(state["personRequest"].string, tab.pageRequests.problem)
    }

    func testPopupUsesOriginalConfigurationOpenerAndQuietAttention() async throws {
        let rig = Rig(); defer { rig.close() }
        let opener = try await rig.page("<body>Opener fixture</body>")
        let view = try XCTUnwrap(opener.webView); try await ready(view)
        opener.automation.toolTouched()
        let configuration = rig.tabs.makeConfiguration(profile: opener.profile, isolated: true)
        // Real WKUIDelegate configurations carry this exact store and share the opener's controller.
        configuration.websiteDataStore = view.configuration.websiteDataStore
        configuration.userContentController = view.configuration.userContentController
        let childView = try rig.runtime.adoptPopup(configuration: configuration, openerID: opener.id, requestedURL: URL(string: "https://fixture.invalid/sign-in"), transientSignIn: true)
        let child = try XCTUnwrap(rig.tabs.tabs.first { $0.webView === childView })
        XCTAssertTrue(childView.configuration.websiteDataStore === view.configuration.websiteDataStore)
        XCTAssertTrue(childView.configuration.userContentController === view.configuration.userContentController)
        XCTAssertNotNil(child.pageRequests.reviewNotice)
        XCTAssertTrue(rig.tabs.browserTabs.first { $0.id == child.id }?.needsAttention == true)
        XCTAssertNotEqual(rig.tabs.selectedID, child.id)
        XCTAssertTrue(childView.window is NativeBrowserCaptureWindow)
        XCTAssertFalse(NSApp.isActive)
    }

    func testRealWindowOpenKeepsOpenerMessagingWhileBothTabsStayHidden() async throws {
        let rig = Rig(); defer { rig.close() }
        let opener = try await rig.page("""
        <button id=open onclick="window.child=window.open('about:blank')">Open fixture</button>
        <script>addEventListener('message',event=>window.fixtureMessage=event.data)</script>
        """)
        let parent = try XCTUnwrap(opener.webView); try await ready(parent)
        rig.runtime.ownTabID = opener.id
        let selectedBefore = rig.tabs.selectedID
        let answer = try await command(rig.runtime, "browser_step", ["verb": "click", "selector": "#open"])
        XCTAssertNil(answer["error"], "\(answer)")
        try await Self.wait { rig.tabs.tabs.count == 2 }
        let child = try XCTUnwrap(rig.tabs.tabs.first { $0.id != opener.id })
        let page = try XCTUnwrap(child.webView); try await ready(page, marker: false)
        let hasOpener = try await page.evaluateJavaScript("if(window.opener)window.opener.postMessage('fixture message','*');Boolean(window.opener)") as? Bool
        XCTAssertEqual(hasOpener, true)
        var delivered = false
        for _ in 0..<500 {
            delivered = (try? await parent.evaluateJavaScript("window.fixtureMessage==='fixture message'")) as? Bool == true
            if delivered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(delivered)
        XCTAssertTrue(child.pageRequests.needsAttention)
        XCTAssertEqual(rig.tabs.selectedID, selectedBefore)
        XCTAssertTrue(parent.window is NativeBrowserCaptureWindow)
        XCTAssertTrue(page.window is NativeBrowserCaptureWindow)
        XCTAssertFalse(NSApp.isActive)
    }

    func testExternalAppTransitionWaitsForThePersonAndNeverOpensFromAToolClick() async throws {
        let rig = Rig(); defer { rig.close() }
        let tab = try await rig.page("<body>External app fixture</body>")
        let page = try XCTUnwrap(tab.webView); try await ready(page)
        var personReady = false, opened: [URL] = []
        tab.pageRequests = NativeBrowserPageRequests(tab: tab, ready: { personReady })
        let delegate = NativeBrowserPageDelegate(tab: tab, openExternal: { opened.append($0) }, present: { _, _ in .alertFirstButtonReturn })
        let action = FixtureAction("fixture-app:sign-in")
        let request = Task { await delegate.webView(page, decidePolicyFor: action, preferences: WKWebpagePreferences()) }
        try await Self.wait { tab.pageRequests.questions.first?.kind == "external-app" }
        XCTAssertEqual(opened, [])
        personReady = true; tab.pageRequests.review()
        let result = await request.value
        XCTAssertEqual(result.0, .cancel)
        XCTAssertEqual(opened.map(\.absoluteString), ["fixture-app:sign-in"])
    }

    func testDownloadResponseStillUsesExistingDelegateAndDoesNotOpenAnything() async throws {
        _ = NSApplication.shared
        let server = try BackgroundHTTPFixture(); defer { server.stop() }
        let url = try await server.address().appendingPathComponent("download")
        let downloads = FixtureDownloads()
        let tabs = NativeBrowserTabs(persist: false, downloads: downloads)
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        tab.load(url)
        try await Self.wait { downloads.adoptions == 1 }
        XCTAssertTrue(downloads.view === tab.webView)
        XCTAssertEqual(tab.automation.toolNotes.last?.kind, "download")
        XCTAssertTrue(tab.webView?.window is NativeBrowserCaptureWindow)
        XCTAssertFalse(NSApp.isActive)
    }

    func testClosingOrReplacingPageCancelsQuestionsAndReleasesBackgroundWindow() async throws {
        let rig = Rig(); defer { rig.close() }
        let tab = try await rig.page("<body>Lifecycle fixture</body>")
        weak var window = tab.automation.parkingWindow
        let request = Task { await tab.pageRequests.wait(kind: "confirm", message: "Fixture question", site: "fixture.invalid") }
        try await Self.wait { !tab.pageRequests.questions.isEmpty }
        tab.navigationStarted()
        let ticket = await request.value
        XCTAssertNil(ticket)
        XCTAssertFalse(tab.pageRequests.needsAttention)
        rig.tabs.close(tab.id)
        await Task.yield()
        XCTAssertNil(window)
        XCTAssertNil(tab.webView)
    }

    func testRequestBarRendersLocallyAtWideAndNarrowWidths() async throws {
        let rig = Rig(); defer { rig.close() }
        let tab = try await rig.page("<body>Notice fixture</body>")
        tab.pageRequests.unavailable(kind: "webauthn", reason: NativeBrowserPageCapabilities(browserPasskeys: false, associatedDomains: [], locationDelegate: true).passkeyRefusal(relyingParty: "fixture.invalid")!)
        let themes: [(String, NSAppearance.Name, ColorScheme)] = [("light", .aqua, .light), ("dark", .darkAqua, .dark)]
        for (theme, appearance, scheme) in themes {
            for width: CGFloat in [900, 380] {
                let view = NSHostingView(rootView: NativeBrowserPageRequestBar(tab: tab)
                    .frame(width: width, height: 110, alignment: .top).background(DeckTokens.page).environment(\.colorScheme, scheme))
                let window = FixtureWindow(contentRect: NSRect(x: -25_000, y: -25_000, width: width, height: 110), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                window.orderBack(nil)
                defer { window.contentView = nil; window.close() }
                settleRender(view)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("browser-bg-\(theme)-\(Int(width)).png")
                try png.write(to: path)
                XCTAssertGreaterThan(png.count, 2000)
            }
        }
        XCTAssertFalse(NSApp.isActive)
    }

    private func settleRender(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        view.layoutSubtreeIfNeeded()
    }

    private final class FixtureDownloads: NativeCompositionBrowserDownloadsPresentation {
        var adoptions = 0
        weak var view: WKWebView?
        var items: [NativeBrowserDownloads.Item] { [] }
        var badge: (label: String, tone: String)? { nil }
        var runningCount: Int { 0 }
        var overallFraction: Double? { nil }
        var message: String { "" }
        func backendRow(_ id: UUID) -> BackendBrowserDownloadRow? { nil }
        func adopt(_ download: WKDownload, webView: WKWebView) { adoptions += 1; view = webView; download.cancel { _ in } }
        func cancel(_ id: UUID) {}
        func clearFinished() {}
        func open(_ id: UUID) { XCTFail("A download opened an app") }
        func reveal(_ id: UUID) { XCTFail("A download opened Finder") }
        func openDownloadsFolder() { XCTFail("A download opened Finder") }
    }
    private final class FixtureWindow: NSWindow {
        var fixtureMiniaturized = false
        override var isMiniaturized: Bool { fixtureMiniaturized }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private func fixtureFrame(_ view: WKWebView) async throws -> WKFrameInfo {
        let capture = FrameCapture()
        let controller = view.configuration.userContentController
        controller.add(capture, name: "fixtureFrame")
        defer { controller.removeScriptMessageHandler(forName: "fixtureFrame") }
        _ = try await view.evaluateJavaScript("window.webkit.messageHandlers.fixtureFrame.postMessage(true);true")
        try await Self.wait { capture.frame != nil }
        return try XCTUnwrap(capture.frame)
    }
    private final class FrameCapture: NSObject, WKScriptMessageHandler {
        var frame: WKFrameInfo?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { frame = message.frameInfo }
    }
    private final class FixtureAction: WKNavigationAction {
        private let address: URL
        init(_ url: String) { address = URL(string: url)!; super.init() }
        override var request: URLRequest { URLRequest(url: address) }
        override var navigationType: WKNavigationType { .linkActivated }
        override var shouldPerformDownload: Bool { false }
    }
    private final class FixtureChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }
}

/// A loopback-only document, delayed fetch and continuous DOM animation. No app backend is started.
@MainActor
private final class BackgroundHTTPFixture {
    private let listener: NWListener
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let html = """
        <!doctype html><body style='margin:0;background:rgb(20,120,210);height:100vh'><h1>Still running</h1><div id=td-fixture-ready hidden></div><script>
        window.ticks=0;window.framesSeen=0;window.net='waiting';setInterval(()=>window.ticks++,30);
        function frame(){window.framesSeen++;requestAnimationFrame(frame)}requestAnimationFrame(frame);
        setTimeout(()=>fetch('/ping').then(r=>r.text()).then(s=>window.net=s),61000);
        </script>
        """
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .utility))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { bytes, _, _, _ in
                let request = bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let body = Data((request.hasPrefix("GET /ping ") ? "loopback response" : html).utf8)
                let attachment = request.hasPrefix("GET /download ") ? "Content-Disposition: attachment; filename=fixture.txt\r\n" : ""
                let status = request.hasPrefix("GET /auth ") ? "401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"Fixture\"" : "200 OK"
                let response = Data("HTTP/1.1 \(status)\r\n\(attachment)Content-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global(qos: .utility))
    }
    func address() async throws -> URL {
        for _ in 0..<500 {
            if case .ready = listener.state, let port = listener.port { return URL(string: "http://127.0.0.1:\(port.rawValue)/")! }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BrowserDriverRefusal("The background fixture listener did not start")
    }
    func stop() { listener.cancel() }
}

@MainActor
private final class BackgroundWebSocketFixture {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.connections.append(connection) }
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 62) {
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                    let context = NWConnection.ContentContext(identifier: "fixture", metadata: [metadata])
                    connection.send(content: Data("socket alive after expiry".utf8), contentContext: context,
                        isComplete: true, completion: .contentProcessed { _ in })
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
        listener.start(queue: .global(qos: .utility))
    }
    func address() async throws -> String {
        for _ in 0..<500 {
            if case .ready = listener.state, let port = listener.port { return "ws://127.0.0.1:\(port.rawValue)/" }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BrowserDriverRefusal("The fixture WebSocket did not start")
    }
    func stop() { connections.forEach { $0.cancel() }; connections = []; listener.cancel() }
}
