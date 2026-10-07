import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendMacAppHandoffLinksTests: XCTestCase {
    typealias R = BackendMacAppHandoffLinkRules
    func testAppWebInside() { BackendMacAppHandoffEqual(R.app(.string("https://github.com/cli/cli/pull/1")), .tab); BackendMacAppHandoffEqual(R.app(.string("http://localhost:3000/")), .tab) }
    func testAppPushesObjectWithoutSystemLaunch() async throws {
        let fake = BackendMacAppHandoffFakeDesktop(), links = BackendMacAppHandoffLinks(desktop: fake)
        let route = try await links.app(ownerID: "window", url: .string("https://github.com/cli/cli")), result = await fake.result()
        BackendMacAppHandoffEqual(route, .tab); BackendMacAppHandoffEqual(result.pushed.count, 1); BackendMacAppHandoffEqual(result.pushed[0].0, R.tabChannel); BackendMacAppHandoffEqual(result.pushed[0].1, BackendMacAppHandoffObject(["url": .string("https://github.com/cli/cli")])); BackendMacAppHandoffEqual(result.opened, [])
    }
    func testAppNonWebUsesSystem() async throws {
        for url in ["mailto:someone@example.com", "file:///Users/apple/Downloads", "x-github-client://openRepo/x"] { BackendMacAppHandoffEqual(R.app(.string(url)), .system) }
        let fake = BackendMacAppHandoffFakeDesktop(), links = BackendMacAppHandoffLinks(desktop: fake)
        let route = try await links.app(ownerID: "window", url: .string("mailto:someone@example.com")), result = await fake.result()
        BackendMacAppHandoffEqual(route, .system); BackendMacAppHandoffEqual(result.pushed.count, 0); BackendMacAppHandoffEqual(result.opened, ["mailto:someone@example.com"])
    }
    func testAppRefusesScriptsAndProcessSchemes() async throws {
        let fake = BackendMacAppHandoffFakeDesktop(), links = BackendMacAppHandoffLinks(desktop: fake)
        for url in ["javascript:alert(1)", "vbscript:msgbox(1)", "data:text/html,<script>1</script>", "blob:https://example.com/x", "chrome://settings", "devtools://devtools/bundled/x.html", "view-source:https://example.com", "relative/path", ""] { BackendMacAppHandoffEqual(R.app(.string(url)), .refused) }
        let result = try await links.openSystem(.string("javascript:alert(1)")), calls = await fake.result()
        XCTAssertFalse(result); BackendMacAppHandoffEqual(calls.opened, [])
    }
    func testGoneOwnerDoesNotReceivePush() async throws {
        let fake = BackendMacAppHandoffFakeDesktop(); await fake.set(alive: false)
        let route = try await BackendMacAppHandoffLinks(desktop: fake).app(ownerID: "gone", url: .string("https://example.com")), result = await fake.result()
        BackendMacAppHandoffEqual(route, .tab); XCTAssertTrue(result.pushed.isEmpty)
    }
    func testGuestWebBecomesAppTab() async throws {
        let fake = BackendMacAppHandoffFakeDesktop(), links = BackendMacAppHandoffLinks(desktop: fake)
        let route = try await links.guest(ownerID: "window", url: .string("https://example.com/x")), result = await fake.result()
        BackendMacAppHandoffEqual(route, .tab); BackendMacAppHandoffEqual(result.pushed[0].0, R.tabChannel); BackendMacAppHandoffEqual(result.pushed[0].1["url"], .string("https://example.com/x"))
    }
    func testGuestNeverOpensSystem() async throws {
        for url in ["file:///etc/passwd", "mailto:someone@example.com", "x-github-client://openRepo/x", "javascript:alert(1)"] { BackendMacAppHandoffEqual(R.guest(.string(url)), .refused) }
        let fake = BackendMacAppHandoffFakeDesktop(), links = BackendMacAppHandoffLinks(desktop: fake)
        let route = try await links.guest(ownerID: "window", url: .string("file:///etc/passwd")), result = await fake.result()
        BackendMacAppHandoffEqual(route, .refused); XCTAssertTrue(result.pushed.isEmpty); XCTAssertTrue(result.opened.isEmpty)
    }
    func testGuestMatchesNavigationGateIncludingBlank() { for url in ["https://a.example/", "http://b.example/", "about:blank"] { XCTAssertTrue(R.navigationAllowed(.string(url))); BackendMacAppHandoffEqual(R.guest(.string(url)), .tab) } }
    func testMenuSystemAndCopyItemsActuallyWork() async throws {
        let fake = BackendMacAppHandoffFakeDesktop(), links = BackendMacAppHandoffLinks(desktop: fake)
        let shown = try await links.menu(ownerID: "window", url: .string("https://example.com/page")); XCTAssertTrue(shown)
        let before = await fake.result(); BackendMacAppHandoffEqual(before.labels, ["Open in System Browser", "Copy Link"])
        try await fake.press("Open in System Browser"); try await fake.press("Copy Link")
        let after = await fake.result(); BackendMacAppHandoffEqual(after.opened, ["https://example.com/page"]); BackendMacAppHandoffEqual(after.copied, ["https://example.com/page"])
    }
    func testMenuOmitsMeaninglessSystemItem() async throws {
        let fake = BackendMacAppHandoffFakeDesktop(); _ = try await BackendMacAppHandoffLinks(desktop: fake).menu(ownerID: "window", url: .string("about:blank"))
        let value = await fake.result(); BackendMacAppHandoffEqual(value.labels, ["Copy Link"]); XCTAssertFalse(R.canOpenOutside(.string("about:blank"))); XCTAssertTrue(R.canOpenOutside(.string("https://example.com")))
    }
    func testMenuRequiresWindowAndAddress() async throws {
        let fake = BackendMacAppHandoffFakeDesktop(), links = BackendMacAppHandoffLinks(desktop: fake)
        let none = try await links.menu(ownerID: nil, url: .string("https://example.com")); await fake.set(alive: false)
        let gone = try await links.menu(ownerID: "gone", url: .string("https://example.com")); await fake.set()
        let blank = try await links.menu(ownerID: "window", url: .string("")), result = await fake.result()
        XCTAssertFalse(none); XCTAssertFalse(gone); XCTAssertFalse(blank); XCTAssertTrue(result.labels.isEmpty)
    }
    func testSystemIPCReachesNativeOpener() async throws {
        let fake = BackendMacAppHandoffFakeDesktop(), registry = NativeChannelRegistry(); try await BackendMacAppHandoffLinks(desktop: fake).register(registry: registry)
        let answer = try await registry.invoke("link:system", context: BackendMacAppHandoffContext(), arguments: [.string("https://example.com")]), result = await fake.result()
        BackendMacAppHandoffEqual(answer, .bool(true)); BackendMacAppHandoffEqual(result.opened, ["https://example.com"])
    }
    func testSystemIPCRefusesNonDocument() async throws {
        let fake = BackendMacAppHandoffFakeDesktop(), registry = NativeChannelRegistry(); try await BackendMacAppHandoffLinks(desktop: fake).register(registry: registry)
        let answer = try await registry.invoke("link:system", context: BackendMacAppHandoffContext(), arguments: [.string("javascript:alert(1)")]), result = await fake.result()
        BackendMacAppHandoffEqual(answer, .bool(false)); XCTAssertTrue(result.opened.isEmpty)
    }
    func testMenuIPCBelongsToCallerWindow() async throws {
        let fake = BackendMacAppHandoffFakeDesktop(), registry = NativeChannelRegistry(); try await BackendMacAppHandoffLinks(desktop: fake).register(registry: registry)
        let answer = try await registry.invoke("link:menu", context: BackendMacAppHandoffContext(), arguments: [.string("https://example.com")]), result = await fake.result()
        BackendMacAppHandoffEqual(answer, .bool(true)); BackendMacAppHandoffEqual(result.labels.count, 2)
    }
    func testMenuIPCHonestlyAnswersNoWindow() async throws {
        let fake = BackendMacAppHandoffFakeDesktop(), registry = NativeChannelRegistry(); await fake.set(window: false); try await BackendMacAppHandoffLinks(desktop: fake).register(registry: registry)
        let answer = try await registry.invoke("link:menu", context: BackendMacAppHandoffContext(), arguments: [.string("https://example.com")]); BackendMacAppHandoffEqual(answer, .bool(false))
    }
    func testPushConstantMatchesPreloadSubscription() throws {
        let source = try preload(), expression = try NSRegularExpression(pattern: #"ipcRenderer\.on\(\s*'([^']+)'"#)
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source))
        let names = matches.compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } }; XCTAssertTrue(names.contains(R.tabChannel))
    }
    func testSubscriptionGuardReadsActualSubscriptions() throws {
        let source = try preload(), expression = try NSRegularExpression(pattern: #"ipcRenderer\.on\(\s*'([^']+)'"#); XCTAssertGreaterThan(expression.numberOfMatches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)), 3)
    }
    func testBothTrustedAndGuestPushUseExportedChannel() async throws {
        let fake = BackendMacAppHandoffFakeDesktop(), links = BackendMacAppHandoffLinks(desktop: fake)
        _ = try await links.app(ownerID: "window", url: .string("https://a.example")); _ = try await links.guest(ownerID: "window", url: .string("https://b.example"))
        let value = await fake.result(); BackendMacAppHandoffEqual(Set(value.pushed.map(\.0)), [R.tabChannel])
    }
    private func preload() throws -> String { var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }; return try String(contentsOf: root.appendingPathComponent("src/preload/index.ts"), encoding: .utf8) }
}
