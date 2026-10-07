import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Real remote controller, Safari provider, browser service and binding store.
/// Only the WebKit runtime and its session/authorization suppliers are fakes.
@MainActor
final class BackendRemoteServeMachinesTestsDesktopSafari: XCTestCase {
    private let context = NativeRPCContext(caller: .pairedDevice, ownerID: "phone")
    private func answer(_ rig: DesktopRig, _ tag: String, _ fields: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
        let request = try BackendRemoteServeMachinesTestsFixture.message(tag, fields)
        return await rig.control.answer(request, deviceID: "phone", kind: .mine, context: context).value
    }
    func testListedWindowIDIsStablePaneKeyNeverInnerViewID() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        rig.add(id: "browser:1:1", viewID: "view:1", title: "Example", url: "https://example.com/")
        let value = try await answer(rig, "browser.windows")
        XCTAssertEqual(value["windows"].elements?.first?["id"].string, "browser:1:1")
        XCTAssertEqual(value["windows"].elements?.first?["title"].string, "Example")
    }
    func testIsolatedWindowHasNoNamedSharedProfileOnWire() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        rig.add(id: "one", title: "Shared", url: "https://example.com/")
        rig.add(id: "two", title: "Isolated", url: "https://bank.example/", isolated: true)
        let value = try await answer(rig, "browser.windows"), rows = try XCTUnwrap(value["windows"].elements)
        XCTAssertFalse(rows[0].has("isolated")); XCTAssertEqual(rows[0]["profile"].string, "Default")
        XCTAssertEqual(rows[1]["isolated"].bool, true); XCTAssertFalse(rows[1].has("profile"))
    }
    func testWindowWithBlankPageURLKeepsLastKnownAddress() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        rig.add(id: "browser:1:1", url: "https://example.com/")
        rig.runtime.pages["browser:1:1"] = rig.runtime.pages["browser:1:1"]?.setting("url", .string(""))
        let value = try await answer(rig, "browser.windows")
        XCTAssertEqual(value["windows"].elements?.count, 1)
        XCTAssertEqual(value["windows"].elements?.first?["url"].string, "https://example.com/")
    }
    func testOpeningUsesNativePaneCreationAndReturnsCurrentRows() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        let value = try await answer(rig, "browser.window.open", [.init("url", .string("https://example.com/"))])
        XCTAssertEqual(rig.runtime.creations, ["https://example.com/"])
        XCTAssertEqual(value["windows"].elements?.count, 1); XCTAssertEqual(value["notice"].string, "Opened a window.")
    }
    func testEmptyOpenUsesMachineStartPagePreference() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        _ = try await answer(rig, "browser.window.open")
        XCTAssertEqual(rig.startPageReads, 1); XCTAssertEqual(rig.runtime.creations, ["https://start.example/"])
        // Native resolves the same empty-address intent before creating its own
        // WK tab; there is no Electron renderer link-request body to forward.
    }
    func testHistoryRoutesToPageOfRequestedStableWindow() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        rig.add(id: "browser:1:1", viewID: "view:1", url: "https://example.com/")
        for move in ["back", "forward", "reload"] {
            _ = try await answer(rig, "browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string(move))])
        }
        XCTAssertEqual(rig.runtime.commands, ["back browser:1:1", "forward browser:1:1", "reload browser:1:1"])
        // WKWebView is addressed by the stable tab key; its inner view is not
        // the independently reminted Electron WebContents UUID.
    }
    func testCloseUsesOwningPaneAndHumanNotice() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        rig.add(id: "browser:1:1", viewID: "view:1", title: "Example", url: "https://example.com/")
        let value = try await answer(rig, "browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string("close"))])
        XCTAssertEqual(rig.runtime.commands, ["close browser:1:1"])
        XCTAssertEqual(value["windows"].elements?.count, 0); XCTAssertEqual(value["notice"].string, "Closed Example.")
    }
    func testRefusedCloseLeavesCurrentWindowRowAndExplainsIt() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        rig.add(id: "browser:1:1", title: "Example", url: "https://example.com/"); rig.runtime.closeRefused = true
        let value = try await answer(rig, "browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string("close"))])
        XCTAssertTrue(value["notice"].string?.contains("did not answer") == true); XCTAssertEqual(value["windows"].elements?.count, 1)
    }
    func testCloseReleasesSessionBindingThroughActualSafariProvider() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        rig.add(id: "browser:1:1", title: "Example", url: "https://example.com/")
        _ = try await answer(rig, "browser.window.bind", [.init("id", .string("browser:1:1")), .init("session", .string("pty-1"))])
        XCTAssertEqual(rig.map.owner(of: "browser:1:1")?.sessionId, "pty-1")
        _ = try await answer(rig, "browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string("close"))])
        XCTAssertNil(rig.map.owner(of: "browser:1:1"))
    }
    func testBindUsesAuthoritativeStoreAndStablePaneKey() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        rig.add(id: "browser:1:1", viewID: "view:1", title: "Example", url: "https://example.com/")
        let value = try await answer(rig, "browser.window.bind", [.init("id", .string("browser:1:1")), .init("session", .string("pty-1"))])
        XCTAssertEqual(value["notice"].string, "Example is B1 in build.")
        XCTAssertEqual(rig.map.owner(of: "browser:1:1")?.sessionId, "pty-1"); XCTAssertNil(rig.map.owner(of: "view:1"))
        XCTAssertEqual(value["windows"].elements?.first?["slot"].string, "B1")
        XCTAssertEqual(value["windows"].elements?.first?["sessionTitle"].string, "build")
    }
    func testBindRefusesSessionNotInHostList() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        rig.add(id: "browser:1:1", url: "https://example.com/")
        let value = try await answer(rig, "browser.window.bind", [.init("id", .string("browser:1:1")), .init("session", .string("pty-elsewhere"))])
        XCTAssertTrue(value["notice"].string?.contains("No session by that name") == true); XCTAssertNil(rig.map.owner(of: "browser:1:1"))
    }
    func testOpenAttachesExactlyThePaneItCreated() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        let value = try await answer(rig, "browser.window.open", [.init("url", .string("https://example.com/")), .init("session", .string("pty-1"))])
        XCTAssertEqual(rig.map.owner(of: "browser:9:1")?.sessionId, "pty-1")
        XCTAssertEqual(value["windows"].elements?.first?["slot"].string, "B1")
        XCTAssertEqual(value["notice"].string, "https://example.com/ is B1 in build.")
    }
    func testUnknownOpenSessionCreatesNothing() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }
        let value = try await answer(rig, "browser.window.open", [.init("url", .string("https://example.com/")), .init("session", .string("pty-elsewhere"))])
        XCTAssertTrue(value["notice"].string?.contains("No session by that name") == true)
        XCTAssertTrue(rig.runtime.creations.isEmpty); XCTAssertEqual(value["windows"].elements?.count, 0)
    }
    func testMissingDocumentPickerProducesOneHonestNotice() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }; rig.add(id: "browser:1:1", url: "https://example.com/")
        let value = try await answer(rig, "browser.window.pick", [.init("id", .string("browser:1:1")), .init("x", .number(1)), .init("y", .number(1))])
        XCTAssertEqual(value["notice"].string, "This machine's browser cannot point at one thing on a page.")
    }
    func testScreenshotTargetsPageOfRequestedWindow() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }; rig.add(id: "browser:1:1", url: "https://example.com/")
        let value = try await answer(rig, "browser.window.shot", [.init("id", .string("browser:1:1"))])
        XCTAssertEqual(rig.runtime.commands, ["user-screenshot browser:1:1"]); XCTAssertEqual(value["t"].string, "browser.shot")
    }
    func testRecordingStartsAndStopsOnRequestedPage() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }; rig.add(id: "browser:1:1", title: "Example", url: "https://example.com/")
        _ = try await answer(rig, "browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string("record.on"))])
        XCTAssertEqual(rig.runtime.pages["browser:1:1"]?["recording"].bool, true)
        let value = try await answer(rig, "browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string("record.off"))])
        XCTAssertEqual(rig.runtime.pages["browser:1:1"]?["recording"].bool, false)
        XCTAssertEqual(value["notice"].string, "Stopped recording Example.")
    }
    func testRecordingListsNativeCollectedSteps() async throws {
        let rig = DesktopRig(); defer { rig.service.shutdown() }; rig.add(id: "browser:1:1", url: "https://example.com/")
        rig.runtime.steps = [.object([.init("kind", .string("navigate")), .init("url", .string("https://example.com/")), .init("at", .number(1))]),
            .object([.init("kind", .string("click")), .init("selector", .string("#submit")), .init("label", .string("Sign in")), .init("at", .number(2))])]
        let value = try await answer(rig, "browser.window.steps", [.init("id", .string("browser:1:1"))])
        XCTAssertEqual(value["steps"].elements?.map { $0["kind"].string }, ["navigate", "click"])
        XCTAssertEqual(value["steps"].elements?.last?["selector"].string, "#submit")
    }
}

@MainActor
private final class DesktopRig {
    let map = BackendBrowserBindings()
    let runtime = DesktopRuntime()
    lazy var service: BackendBrowserService = {
        BackendBrowserService(runtime: runtime, bindings: map,
            resolve: { context in .init(ownerID: context.ownerID, managesWindows: true) },
            resolveSession: { id in
                guard id == "pty-1" else { throw NativeRPCError(code: "unknown-session", message: "No session by that name is running here.") }
                return .init(sessionId: id)
            }, resolveProfile: { _, id in .init(id: id ?? "Default", name: id ?? "Default", partition: "persist:terminaldeck-browser") },
            resolveCreationProfile: { _, id in .init(id: id ?? "Default", name: id ?? "Default", partition: "persist:terminaldeck-browser") },
            authorize: { _ in }, publish: { _, _, _ in }, reportEventFailure: { _ in })
    }()
    var startPageReads = 0
    lazy var provider = BackendRemoteServeBrowserSafari(service: service, isMine: { $0 == "phone" },
        sessions: { _ in [.init(id: "pty-1", title: "build")] }, write: { _, _, _ in XCTFail("This fixture must never send terminal input") },
        startPage: { [self] _ in startPageReads += 1; return "https://start.example/" }, authorize: { _ in })
    lazy var control = BackendRemoteServeBrowserControl(operations: provider)
    func add(id: String, viewID: String? = nil, title: String = "", url: String, isolated: Bool = false) {
        runtime.pages[id] = .object([.init("id", .string(id)), .init("title", .string(title)), .init("url", .string(url)),
            .init("profileId", .string("Default")), .init("isolated", .bool(isolated)), .init("recording", .bool(false)), .init("loading", .bool(false))])
        map.observe(.init(tabID: id, viewID: viewID ?? id, url: url, title: title))
    }
}

@MainActor
private final class DesktopRuntime: BackendBrowserRuntime {
    var ownTabID: String?
    var pages: [String: NativeRPCValue] = [:]
    var commands: [String] = [], creations: [String] = [], steps: [NativeRPCValue] = []
    var closeRefused = false
    func bindings() async -> BrowserBindings { .init() }
    func tabExists(_ id: String) -> Bool { pages[id] != nil }
    func createTab(url: URL, isolated: Bool) -> String { createProfileTab(url: url, isolated: isolated, profileID: "Default") }
    func createProfileTab(url: URL, isolated: Bool, profileID: String) -> String {
        creations.append(url.absoluteString); let id = "browser:9:\(creations.count)"
        pages[id] = .object([.init("id", .string(id)), .init("url", .string(url.absoluteString)), .init("title", .string("")),
            .init("profileId", .string(profileID)), .init("isolated", .bool(isolated)), .init("recording", .bool(false)), .init("loading", .bool(false))])
        return id
    }
    func pageState(_ id: String) throws -> NativeRPCValue {
        guard let page = pages[id] else { throw NativeRPCError(code: "unavailable", message: "that window has no page in it yet") }; return page
    }
    func pageCommand(_ id: String, operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        _ = try pageState(id); commands.append("\(operation) \(id)")
        switch operation {
        case "close":
            if closeRefused { throw NativeRPCError(code: "unavailable", message: "the window that holds it did not answer") }
            pages[id] = nil; return .null
        case "record": pages[id] = pages[id]?.setting("recording", .bool(arguments["on"].bool == true))
        case "recording": return .object([.init("recording", pages[id]?["recording"] ?? .bool(false)), .init("steps", .array(steps))])
        case "user-screenshot": return .object([.init("path", .string("/scratch/shot.png")), .init("width", .number(2560)), .init("height", .number(1440)),
            .init("preview", .string("data:image/png;base64," + Data([137,80,78,71,13,10,26,10]).base64EncodedString()))])
        case "back", "forward", "reload", "state": break
        default: throw NativeRPCError(code: "unavailable", message: "The test runtime does not implement \(operation).")
        }
        return try pageState(id)
    }
    func attach(_ id: String, to session: BrowserDriverSession) async -> String? { nil }
    func load(_ id: String, url: URL) { XCTFail("Unrelated agent navigation was called") }
    func isIsolated(_ id: String) -> Bool { pages[id]?["isolated"].bool ?? false }
    func setIsolated(_ id: String, _ isolated: Bool) { pages[id] = pages[id]?.setting("isolated", .bool(isolated)) }
    func settle(_ id: String, timeoutMs: Int) async -> Bool { tabExists(id) }
    func pageURL(_ id: String) -> String { pages[id]?["url"].string ?? "" }
    func title(_ id: String) -> String { pages[id]?["title"].string ?? "" }
    func displayTitle(_ id: String) -> String { title(id) }
    func evaluate(_ id: String, _ script: String) async throws -> Any? { throw NativeRPCError(code: "unavailable", message: "No script evaluation in this fixture") }
    func reveal(_ id: String) async -> Bool { tabExists(id) }
    func click(_ id: String, cssRect: CGRect) -> Bool { false }
    func focusForTyping(_ id: String) -> Bool { false }
    func type(_ id: String, plan: BrowserTypingPlan) -> Bool { false }
    func press(_ id: String, key: BrowserKeySpec) -> Bool { false }
    func screenshot(_ id: String) async throws -> (path: String, width: Int, height: Int, masked: Int) { throw NativeRPCError(code: "unavailable", message: "Use the user-screenshot command fixture") }
    func handoverPrompt(_ id: String) -> String? { nil }
    func otherHandover(than id: String) -> String? { nil }
    func handOver(_ id: String, prompt: String, windowMs: Int) async -> String { "stopped" }
    func closeTab(_ id: String) { pages[id] = nil }
    func unbind(_ id: String) {}
    func now() -> Double { 1000 }
    func pause(ms: Int) async { XCTFail("A real or virtual sleep must not be requested by this fixture") }
    func frameCommand(_ tabID: String, operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue { throw NativeRPCError(code: "unavailable", message: "No frame operations in this fixture") }
    func dataCommand(_ operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue { throw NativeRPCError(code: "unavailable", message: "No profile data operations in this fixture") }
    func revealScreenshot(_ path: String) throws { XCTFail("A fixture must not reveal an image") }
}
