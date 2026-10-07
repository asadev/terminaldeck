import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// All thirty machine-browser-desktop.test.ts cases, through the actual remote
/// controller. Every callback is fake; no app, network or real wait is used.
final class BackendAppDesktopTestPortTests: XCTestCase {
    @MainActor func testListCarriesPaneIDNeverViewID() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/", title: "Example")
        let frame = try await r.answer("browser.windows"), listed = try r.rows(frame)
        XCTAssertEqual(listed.count, 1); XCTAssertEqual(listed[0]["id"].string, "browser:1:1"); XCTAssertEqual(listed[0]["title"].string, "Example")
    }
    @MainActor func testEmptyProfileMeansIsolatedWithNoProfileField() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/"); r.add(2, url: "https://bank.example/"); r.pages["view:2"] = .init(url: "https://bank.example/", profile: "")
        let frame = try await r.answer("browser.windows"), listed = try r.rows(frame)
        XCTAssertEqual(listed[0]["isolated"], .missing); XCTAssertEqual(listed[0]["profile"].string, "Default"); XCTAssertEqual(listed[1]["isolated"].bool, true); XCTAssertEqual(listed[1]["profile"], .missing)
    }
    @MainActor func testGonePageKeepsPaneRowAndLastAddress() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/"); r.pages["view:1"] = nil
        let frame = try await r.answer("browser.windows"), listed = try r.rows(frame)
        XCTAssertEqual(listed.count, 1); XCTAssertEqual(listed[0]["url"].string, "https://example.com/")
    }
    @MainActor func testUnclaimedRecorderFailureDoesNotBlankWholeList() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/"); r.add(2, url: "https://two.example/"); r.unclaimed.insert("view:1"); r.flows["view:2"] = .init(recording: true, steps: [])
        let frame = try await r.answer("browser.windows"), listed = try r.rows(frame)
        XCTAssertEqual(listed.count, 2); XCTAssertEqual(listed[0]["recording"], .missing); XCTAssertEqual(listed[1]["recording"].bool, true)
    }
    @MainActor func testIsolatedOpenRefusedWithoutCreatingSharedPane() async throws {
        let r = BackendAppDesktopTestPortRig(), frame = try await r.answer("browser.window.open", [.init("isolated", .bool(true))])
        XCTAssertTrue(r.notice(frame).contains("cannot mint an isolated partition")); XCTAssertEqual(try r.rows(frame).count, 0); XCTAssertEqual(r.did.count, 0)
    }
    @MainActor func testNamedProfileOpenRefusedWithoutUsingCurrentProfile() async throws {
        let r = BackendAppDesktopTestPortRig(), frame = try await r.answer("browser.window.open", [.init("profile", .string("Work"))])
        XCTAssertTrue(r.notice(frame).contains("the profile it is switched to")); XCTAssertEqual(r.did.count, 0)
    }
    @MainActor func testOpenUsesPaneRouteAndReturnsExactRowsNotice() async throws {
        let r = BackendAppDesktopTestPortRig(), frame = try await r.answer("browser.window.open", [.init("url", .string("https://example.com/"))])
        XCTAssertEqual(r.did, ["open https://example.com/"]); XCTAssertEqual(try r.rows(frame).count, 1); XCTAssertEqual(r.notice(frame), "Opened a window.")
    }
    @MainActor func testEmptyOpenAddressIsPassedUntouchedAsStartPage() async throws {
        let r = BackendAppDesktopTestPortRig(); _ = try await r.answer("browser.window.open"); XCTAssertEqual(r.did, ["open "])
    }
    @MainActor func testOpenFailureNamesMissingWindowAndClearsOldRefusal() async throws {
        let r = BackendAppDesktopTestPortRig(); r.opens = nil
        let first = try await r.answer("browser.window.open"); XCTAssertTrue(r.notice(first).contains("No window of this app answered"))
        r.opens = "browser:9:9"; let second = try await r.answer("browser.window.open"); XCTAssertEqual(r.notice(second), "Opened a window.")
    }
    @MainActor func testGoNormalizesBareHostBeforePageCallback() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/")
        _ = try await r.answer("browser.window.go", [.init("id", .string("browser:1:1")), .init("url", .string("example.com/next"))])
        XCTAssertEqual(r.did, ["go view:1 http://example.com/next"])
    }
    @MainActor func testBadAddressReturnsReasonAndDoesNotSteer() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/")
        let frame = try await r.answer("browser.window.go", [.init("id", .string("browser:1:1")), .init("url", .string("   "))])
        XCTAssertTrue(r.notice(frame).contains("Enter a URL to open")); XCTAssertEqual(r.did.count, 0)
    }
    @MainActor func testMintedPaneWithoutPageSaysNoPageYet() async throws {
        let r = BackendAppDesktopTestPortRig(); r.panes.append(.init(id: "browser:1:1", viewID: nil))
        let frame = try await r.answer("browser.window.go", [.init("id", .string("browser:1:1")), .init("url", .string("https://example.com/"))])
        XCTAssertTrue(r.notice(frame).contains("no page in it yet"))
    }
    @MainActor func testBackForwardAndReloadReachCurrentView() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/")
        for action in ["back", "forward", "reload"] { _ = try await r.answer("browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string(action))]) }
        XCTAssertEqual(r.did, ["back view:1", "forward view:1", "reload view:1"])
    }
    @MainActor func testIsolateRefusedWithoutClaimingIsolation() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/", title: "Example")
        let frame = try await r.answer("browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string("isolate"))])
        XCTAssertTrue(r.notice(frame).contains("cannot isolate a window")); XCTAssertEqual(try r.rows(frame)[0]["isolated"], .missing)
    }
    @MainActor func testCloseNamesPaneAndItsCurrentViewThroughOwningWindow() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/", title: "Example")
        let frame = try await r.answer("browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string("close"))])
        XCTAssertEqual(r.did, ["close browser:1:1 view:1 Example"]); XCTAssertEqual(try r.rows(frame).count, 0); XCTAssertEqual(r.notice(frame), "Closed Example.")
    }
    @MainActor func testUnansweredCloseLeavesRowAndReportsReason() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/", title: "Example"); r.stuck.insert("browser:1:1")
        let frame = try await r.answer("browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string("close"))])
        XCTAssertTrue(r.notice(frame).contains("did not answer")); XCTAssertEqual(try r.rows(frame).count, 1)
    }
    @MainActor func testClosedPaneRemovesSharedBindingRow() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/", title: "Example"); r.hostSessions = [.init(id: "pty-1", title: "build")]
        _ = try await r.answer("browser.window.bind", [.init("id", .string("browser:1:1")), .init("session", .string("pty-1"))]); XCTAssertEqual(r.held("pty-1").count, 1)
        _ = try await r.answer("browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string("close"))]); XCTAssertEqual(r.held("pty-1").count, 0)
    }
    @MainActor func testBindingUsesRealB1StoreKeyedOnPane() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/", title: "Example"); r.hostSessions = [.init(id: "pty-1", title: "build")]
        let frame = try await r.answer("browser.window.bind", [.init("id", .string("browser:1:1")), .init("session", .string("pty-1"))])
        XCTAssertEqual(r.notice(frame), "Example is B1 in build."); XCTAssertEqual(r.bindings.owner(of: "browser:1:1")?.sessionId, "pty-1"); XCTAssertNil(r.bindings.owner(of: "view:1")); XCTAssertEqual(try r.rows(frame)[0]["slot"].string, "B1"); XCTAssertEqual(try r.rows(frame)[0]["sessionTitle"].string, "build")
    }
    @MainActor func testUnlistedSessionBindingRefusedWithoutOwnership() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/")
        let frame = try await r.answer("browser.window.bind", [.init("id", .string("browser:1:1")), .init("session", .string("pty-elsewhere"))])
        XCTAssertTrue(r.notice(frame).contains("No session by that name")); XCTAssertNil(r.bindings.owner(of: "browser:1:1"))
    }
    @MainActor func testOpenedPaneAttachesExactPaneIDAndViewFromSameStore() async throws {
        let r = BackendAppDesktopTestPortRig(); r.hostSessions = [.init(id: "pty-1", title: "build")]
        let frame = try await r.answer("browser.window.open", [.init("url", .string("https://example.com/")), .init("session", .string("pty-1"))])
        XCTAssertEqual(r.did, ["open https://example.com/"]); XCTAssertEqual(r.bindings.owner(of: "browser:9:9")?.sessionId, "pty-1"); XCTAssertNil(r.bindings.owner(of: "view:browser:9:9"))
        let held = try XCTUnwrap(r.heldView("pty-1").first); XCTAssertEqual(held["browserTabId"].string, "browser:9:9"); XCTAssertEqual(held["viewId"].string, "view:browser:9:9")
        XCTAssertEqual(try r.rows(frame)[0]["slot"].string, "B1"); XCTAssertEqual(r.notice(frame), "https://example.com/ is B1 in build.")
    }
    @MainActor func testUnlistedOpenSessionDoesNotReachDesktop() async throws {
        let r = BackendAppDesktopTestPortRig()
        let frame = try await r.answer("browser.window.open", [.init("url", .string("https://example.com/")), .init("session", .string("pty-elsewhere"))])
        XCTAssertTrue(r.notice(frame).contains("No session by that name")); XCTAssertEqual(r.did, []); XCTAssertEqual(try r.rows(frame).count, 0)
    }
    @MainActor func testPickMapsPaneToViewNameAndDocumentPoint() async throws {
        let r = BackendAppDesktopTestPortRig(pick: true); r.add(1, url: "https://example.com/", title: "Example")
        let frame = try await r.answer("browser.window.pick", [.init("id", .string("browser:1:1")), .init("x", .number(40)), .init("y", .number(900)), .init("up", .number(2))])
        XCTAssertEqual(r.picks, [.init(id: "browser:1:1", viewID: "view:1", name: "Example", x: 40, y: 900, up: 2)]); XCTAssertEqual(frame["t"].string, "browser.window.picked"); XCTAssertEqual(frame["id"].string, "browser:1:1"); XCTAssertEqual(frame["selector"].string, "#save"); XCTAssertEqual(frame["depth"].number, 2); XCTAssertEqual(frame["maxUp"].number, 4); XCTAssertEqual(frame["url"].string, "https://example.com/")
    }
    @MainActor func testPickFallsBackToAddressAndDefaultAncestorDepth() async throws {
        let r = BackendAppDesktopTestPortRig(pick: true); r.add(1, url: "https://example.com/")
        _ = try await r.answer("browser.window.pick", [.init("id", .string("browser:1:1")), .init("x", .number(1)), .init("y", .number(1))])
        XCTAssertEqual(r.picks[0].name, "https://example.com/"); XCTAssertEqual(r.picks[0].up, 0)
    }
    @MainActor func testPickWithoutPageReturnsNoPageAndDoesNotCallDrive() async throws {
        let r = BackendAppDesktopTestPortRig(pick: true); r.panes.append(.init(id: "browser:1:1", viewID: nil))
        let frame = try await r.answer("browser.window.pick", [.init("id", .string("browser:1:1")), .init("x", .number(1)), .init("y", .number(1))])
        XCTAssertTrue(r.notice(frame).contains("no page in it yet")); XCTAssertEqual(r.picks, [])
    }
    @MainActor func testAbsentDriveHasExactNotice() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/")
        let frame = try await r.answer("browser.window.pick", [.init("id", .string("browser:1:1")), .init("x", .number(1)), .init("y", .number(1))])
        XCTAssertEqual(r.notice(frame), "This machine's browser cannot point at one thing on a page.")
    }
    @MainActor func testScreenshotCapturesCurrentViewAndReturnsShotFrame() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/")
        let frame = try await r.answer("browser.window.shot", [.init("id", .string("browser:1:1"))])
        XCTAssertEqual(r.did, ["capture view:1"]); XCTAssertEqual(frame["t"].string, "browser.shot")
    }
    @MainActor func testScreenshotWritesPathSizeAndNoteToSessionTwice() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/"); r.hostSessions = [.init(id: "pty-1", title: "build")]
        let frame = try await r.answer("browser.window.shot", [.init("id", .string("browser:1:1")), .init("session", .string("pty-1")), .init("note", .string("look at the header"))])
        XCTAssertEqual(r.typed.count, 2); XCTAssertEqual(r.typed[0].session, "pty-1"); XCTAssertTrue(r.typed[0].data.contains(r.shot.path)); XCTAssertTrue(r.typed[0].data.contains("2560 x 1440")); XCTAssertTrue(r.typed[0].data.contains("look at the header")); XCTAssertEqual(r.notice(frame), "Sent https://example.com/ to build.")
        XCTAssertEqual(r.waited, [50]); XCTAssertEqual(r.typed[1].data, "\r")
    }
    @MainActor func testRecorderStartsAndStopsOnViewBehindPane() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/", title: "Example")
        _ = try await r.answer("browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string("record.on"))]); XCTAssertEqual(r.flows["view:1"]?.recording, true)
        let frame = try await r.answer("browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string("record.off"))]); XCTAssertEqual(r.flows["view:1"]?.recording, false); XCTAssertEqual(r.notice(frame), "Stopped recording Example.")
    }
    @MainActor func testRecorderListsCollectedKindsAndSelector() async throws {
        let r = BackendAppDesktopTestPortRig(); r.add(1, url: "https://example.com/"); r.flows["view:1"] = .init(recording: true, steps: [.init(kind: .navigate, url: "https://example.com/", at: 1), .init(kind: .click, selector: "#submit", label: "Sign in", at: 2)])
        let frame = try await r.answer("browser.window.steps", [.init("id", .string("browser:1:1"))]); XCTAssertEqual(frame["t"].string, "browser.record.rows"); let steps = try XCTUnwrap(frame["steps"].elements)
        XCTAssertEqual(steps.map { $0["kind"].string }, ["navigate", "click"]); XCTAssertEqual(steps[1]["selector"].string, "#submit")
    }
    @MainActor func testAbsentRecorderRefusesBothStartAndRead() async throws {
        let r = BackendAppDesktopTestPortRig(recorder: false); r.add(1, url: "https://example.com/")
        let start = try await r.answer("browser.window.act", [.init("id", .string("browser:1:1")), .init("action", .string("record.on"))]), read = try await r.answer("browser.window.steps", [.init("id", .string("browser:1:1"))])
        XCTAssertTrue(r.notice(start).contains("cannot record a click flow")); XCTAssertTrue(r.notice(read).contains("cannot record a click flow"))
    }
    /// Supplemental regression: final rows would repair the URL and conceal a
    /// stale value seen by the actual shared-binding attach notification.
    @MainActor func testAttachNotificationUsesLivePageURLBeforeFinalRows() async throws {
        let r = BackendAppDesktopTestPortRig()
        r.add(1, url: "https://stale.example/", title: "Example")
        r.pages["view:1"] = .init(url: "https://current.example/", profile: "Default")
        r.hostSessions = [.init(id: "pty-1", title: "build")]
        var attachedURLs: [String] = []
        r.bindings.changed = {
            if r.bindings.owner(of: "browser:1:1")?.sessionId == "pty-1" {
                attachedURLs.append(r.bindings.window("browser:1:1")?.url ?? "")
            }
        }
        let frame = try await r.answer("browser.window.bind", [.init("id", .string("browser:1:1")), .init("session", .string("pty-1"))])
        XCTAssertFalse(attachedURLs.isEmpty)
        XCTAssertEqual(attachedURLs.first, "https://current.example/")
        XCTAssertEqual(try r.rows(frame)[0]["url"].string, "https://current.example/")
    }

}
