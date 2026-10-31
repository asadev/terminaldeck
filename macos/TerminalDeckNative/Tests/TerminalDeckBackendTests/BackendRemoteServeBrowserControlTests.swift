import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Rule tests only. Written for the final integration gate; never run by this lane.
@MainActor
final class BackendRemoteServeBrowserControlTests: XCTestCase {
    private let context = NativeRPCContext(caller: .pairedDevice, ownerID: "phone")
    private func message(_ tag: String, _ fields: [NativeRPCValue.Field] = []) throws -> BackendRemoteClientMessage {
        switch BackendRemoteProtocol.parseClientMessage(.object([.init("t", .string(tag))] + fields)) {
        case .message(let message): return message
        case .refused(let error): throw error
        }
    }
    private func answer(_ fake: FakeBrowser, _ tag: String, _ fields: [NativeRPCValue.Field] = [],
                        kind: BackendRemoteDeviceKind = .mine) async throws -> NativeRPCValue {
        await BackendRemoteServeBrowserControl(operations: fake).answer(try message(tag, fields), deviceID: "phone", kind: kind, context: context).value
    }
    private func notice(_ value: NativeRPCValue) -> String { value["notice"].string ?? "" }

    func testOwnerGateReadsKindForEveryRequestAndRefusesGuestWithoutListing() async throws {
        let fake = FakeBrowser()
        let guest = try await answer(fake, "browser.windows", kind: .guest)
        XCTAssertEqual(guest["t"].string, "error")
        XCTAssertEqual(guest["code"].string, "unavailable")
        XCTAssertEqual(guest["message"].string, "This machine does not let this phone drive its browser.")
        XCTAssertEqual(fake.listCalls, 0)
        let allowed = try await answer(fake, "browser.windows")
        XCTAssertEqual(allowed["t"].string, "browser.window.rows")
        fake.mine = false
        let revoked = try await answer(fake, "browser.window.open")
        XCTAssertEqual(revoked["t"].string, "error")
        XCTAssertEqual(fake.openCalls, 0)
    }

    func testRowsUseSharedBindingsAndKeepExitedSessions() async throws {
        let fake = FakeBrowser()
        fake.add(.init(id: "w1", title: "Stripe", url: "https://stripe.com/", loading: true))
        fake.hostSessions = [.init(id: "s1", title: "Session 1", ended: true)]
        _ = try fake.bindings.attach("w1", to: .init(sessionId: "s1"))
        let value = try await answer(fake, "browser.windows")
        let row = try XCTUnwrap(value["windows"].elements?.first)
        XCTAssertEqual(row["slot"].string, "B1")
        XCTAssertEqual(row["sessionTitle"].string, "Session 1")
        XCTAssertEqual(row["loading"].bool, true)
        XCTAssertEqual(value["sessions"].elements?.first?["windows"].number, 1)
        XCTAssertEqual(value["sessions"].elements?.first?["title"].string, "Session 1 (exited)")
        XCTAssertFalse(value.has("notice"))
    }

    func testRowsBoundBothListsAndSanitizePageText() async throws {
        let fake = FakeBrowser()
        for i in 0..<41 { fake.add(.init(id: "w\(i)", title: String(repeating: "T", count: 400), url: "https://example.com/" + String(repeating: "a", count: 400))) }
        fake.hostSessions = (0..<35).map { .init(id: "s\($0)", title: "Session \($0)") }
        let value = try await answer(fake, "browser.windows")
        XCTAssertEqual(value["windows"].elements?.count, 32)
        XCTAssertEqual(value["sessions"].elements?.count, 32)
        XCTAssertEqual(notice(value), "Listing 32 of 41 windows and 32 of 35 sessions.")
        XCTAssertEqual(value["windows"].elements?.first?["title"].string?.count, 161)
        XCTAssertGreaterThan(value["windows"].elements?.first?["url"].string?.count ?? 0, 160)
        XCTAssertEqual(BackendRemoteServeBrowserText.line("one\n\u{1b}[0m\u{202e} two", maximum: 160), "one [0m two")
        XCTAssertLessThanOrEqual(BackendRemoteServeBrowserText.line(String(repeating: "😀", count: 100), maximum: 160).utf16.count, 161)
    }

    func testOnlyHardGoogleSignInRefusalGetsNotice() async throws {
        let fake = FakeBrowser()
        fake.add(.init(id: "w1", url: "https://accounts.google.com/v3/signin/identifier?flowName=GeneralOAuthLite"))
        let quiet = try await answer(fake, "browser.windows")
        XCTAssertEqual(notice(quiet), "")
        fake.openWindows[0].url = "https://accounts.google.com/v3/signin/rejected?dsh=1"
        let refused = try await answer(fake, "browser.windows")
        XCTAssertTrue(notice(refused).contains("Google will not sign in in this machine's browser"))
    }

    func testOpenNeverSelectsSessionByDefaultAndChecksNamedSessionBeforeOpening() async throws {
        let fake = FakeBrowser()
        fake.hostSessions = [.init(id: "s1", title: "Session 1")]
        let invalid = try await answer(fake, "browser.window.open", [.init("session", .string("ghost"))])
        XCTAssertEqual(notice(invalid), "No session by that name is running here.")
        XCTAssertEqual(fake.openCalls, 0)
        let plain = try await answer(fake, "browser.window.open", [.init("url", .string("https://example.com/")), .init("isolated", .bool(true))])
        XCTAssertEqual(notice(plain), "Opened an isolated window.")
        XCTAssertFalse(plain["windows"].elements?.first?.has("slot") ?? true)
        XCTAssertNil(fake.bindings.owner(of: "w1"))
    }

    func testOpenAndAttachUsesExactNewWindowAndSameSlotStore() async throws {
        let fake = FakeBrowser()
        fake.hostSessions = [.init(id: "s1", title: "Session 1")]
        _ = try await answer(fake, "browser.window.open", [.init("url", .string("https://one.example/")), .init("session", .string("s1"))])
        let second = try await answer(fake, "browser.window.open", [.init("url", .string("https://two.example/")), .init("session", .string("s1"))])
        XCTAssertEqual(second["windows"].elements?.map { $0["slot"].string }, ["B1", "B2"])
        XCTAssertEqual(notice(second), "https://two.example/ is B2 in Session 1.")
        let held = fake.bindings.bindings(for: .init(ownerID: "test", managesWindows: true)).of(.init(sessionId: "s1"))
        XCTAssertEqual(held.map(\.tabID), ["w1", "w2"])
    }

    func testOpenThatCreatesNothingUsesHostReasonOrFixedRefusal() async throws {
        let fake = FakeBrowser(); fake.openReturnsNil = true
        fake.openReason = ""
        let fallback = try await answer(fake, "browser.window.open")
        XCTAssertEqual(notice(fallback), "This machine's browser did not open a window.")
        fake.openReason = "Safari is unavailable in this process."
        let explained = try await answer(fake, "browser.window.open")
        XCTAssertEqual(notice(explained), "Safari is unavailable in this process.")
        XCTAssertEqual(explained["windows"].elements?.count, 0)
    }

    func testIsolationKeepsWindowIDSlotAndUpdatesSharedView() async throws {
        let fake = FakeBrowser()
        fake.add(.init(id: "w1", title: "Stripe", viewID: "view1"))
        fake.hostSessions = [.init(id: "s1", title: "Session 1")]
        _ = try await answer(fake, "browser.window.bind", [.init("id", .string("w1")), .init("session", .string("s1"))])
        let isolated = try await answer(fake, "browser.window.act", [.init("id", .string("w1")), .init("action", .string("isolate"))])
        XCTAssertEqual(isolated["windows"].elements?.first?["slot"].string, "B1")
        XCTAssertEqual(fake.bindings.window("w1")?.viewID, "view-w1-true")
        XCTAssertEqual(notice(isolated), "Stripe is isolated.")
        let already = try await answer(fake, "browser.window.act", [.init("id", .string("w1")), .init("action", .string("isolate"))])
        XCTAssertEqual(notice(already), "Stripe is already isolated.")
        XCTAssertEqual(fake.repartitions, 1)
    }

    func testDetachLeavesPageAndCloseReleasesBinding() async throws {
        let fake = FakeBrowser()
        fake.add(.init(id: "w1", title: "Stripe")); fake.hostSessions = [.init(id: "s1", title: "Session 1")]
        _ = try await answer(fake, "browser.window.bind", [.init("id", .string("w1")), .init("session", .string("s1"))])
        let detached = try await answer(fake, "browser.window.bind", [.init("id", .string("w1"))])
        XCTAssertEqual(notice(detached), "Stripe is no longer attached to a session.")
        XCTAssertEqual(detached["windows"].elements?.count, 1)
        _ = try await answer(fake, "browser.window.bind", [.init("id", .string("w1")), .init("session", .string("s1"))])
        let closed = try await answer(fake, "browser.window.act", [.init("id", .string("w1")), .init("action", .string("close"))])
        XCTAssertEqual(notice(closed), "Closed Stripe.")
        XCTAssertNil(fake.bindings.owner(of: "w1"))
        XCTAssertEqual(closed["windows"].elements?.count, 0)
    }

    func testScreenshotSessionResolvedBeforeCaptureAndRequiresLiveSession() async throws {
        let fake = FakeBrowser(); fake.add(.init(id: "w1", title: "Stripe"))
        let unknown = try await answer(fake, "browser.window.shot", [.init("id", .string("w1")), .init("session", .string("ghost"))])
        XCTAssertEqual(notice(unknown), "No session by that name is running here.")
        fake.hostSessions = [.init(id: "s1", title: "Session 1", ended: true)]
        let ended = try await answer(fake, "browser.window.shot", [.init("id", .string("w1")), .init("session", .string("s1"))])
        XCTAssertEqual(notice(ended), "Session 1 has exited.")
        XCTAssertEqual(fake.captureCalls, 0)
    }

    func testScreenshotSendsExactCaptionThenReturnAfter50Milliseconds() async throws {
        let fake = FakeBrowser(); fake.add(.init(id: "w1", title: "Stripe", url: "https://stripe.com/"))
        fake.hostSessions = [.init(id: "s1", title: "Session 1")]
        let value = try await answer(fake, "browser.window.shot", [.init("id", .string("w1")), .init("session", .string("s1")), .init("note", .string("look\nat this"))])
        XCTAssertEqual(value["t"].string, "browser.window.rows")
        XCTAssertEqual(notice(value), "Sent Stripe to Session 1.")
        XCTAssertEqual(fake.writes, ["look at this [browser screenshot of https://stripe.com/: /p/shot.png (1280 x 800)]", "\r"])
        XCTAssertEqual(fake.waits, [50])
        let (typed, submit) = BackendRemoteServeBrowserText.replayWrites("file @photo.png")
        XCTAssertEqual(typed, "file @photo.png "); XCTAssertEqual(submit, "\r")
    }

    func testScreenshotPreviewIsWholeBoundedOrRefusedAndSessionPathHasNoPreviewCeiling() async throws {
        let fake = FakeBrowser(); fake.add(.init(id: "w1", title: "Stripe"))
        let shot = try await answer(fake, "browser.window.shot", [.init("id", .string("w1"))])
        XCTAssertEqual(shot["t"].string, "browser.shot")
        XCTAssertEqual(Data(base64Encoded: shot["png"].string ?? ""), fake.shot.preview)
        XCTAssertEqual(shot["at"].number, 1_700_000_000_000)
        fake.shot = .init(path: "/p/shot.png", width: 1280, height: 800, preview: Data(repeating: 0, count: 48 * 1024))
        let large = try await answer(fake, "browser.window.shot", [.init("id", .string("w1"))])
        XCTAssertTrue(notice(large).contains("48 KB, over the 47 KB this link carries"))
        XCTAssertTrue(notice(large).contains("/p/shot.png"))
        fake.hostSessions = [.init(id: "s1", title: "Session 1")]
        let sent = try await answer(fake, "browser.window.shot", [.init("id", .string("w1")), .init("session", .string("s1"))])
        XCTAssertEqual(notice(sent), "Sent Stripe to Session 1.")
    }

    func testMissingSavedScreenshotAndMissingPreviewAreExplicit() async throws {
        let fake = FakeBrowser(); fake.add(.init(id: "w1", title: "Stripe")); fake.hostSessions = [.init(id: "s1", title: "Session 1")]
        fake.shot = .init(path: "", width: 10, height: 10, preview: Data())
        let noPath = try await answer(fake, "browser.window.shot", [.init("id", .string("w1")), .init("session", .string("s1"))])
        XCTAssertEqual(notice(noPath), "Stripe was photographed, but this machine saved no file to send.")
        XCTAssertTrue(fake.writes.isEmpty)
        let noPreview = try await answer(fake, "browser.window.shot", [.init("id", .string("w1"))])
        XCTAssertEqual(notice(noPreview), "Stripe was photographed, but no picture small enough to send could be made.")
    }

    func testRecordingUsesFirst60StepsReportsRestAndDropsSecretValue() async throws {
        let fake = FakeBrowser(); fake.add(.init(id: "w1"))
        fake.steps = (0..<67).map { .init(kind: .click, selector: "#submit", label: "Sign in", at: Double($0)) }
        fake.steps[2] = .init(kind: .type, selector: "#password", label: "Password", value: "hunter2", redacted: true, at: 2)
        let value = try await answer(fake, "browser.window.steps", [.init("id", .string("w1"))])
        XCTAssertEqual(value["steps"].elements?.count, 61)
        XCTAssertEqual(value["steps"].elements?.last?["kind"].string, "truncated")
        XCTAssertEqual(value["steps"].elements?.last?["at"].number, 60)
        XCTAssertEqual(value["steps"].elements?.last?["detail"].string, "7 more steps recorded — the whole flow is on this machine.")
        XCTAssertEqual(value["steps"].elements?.first?["detail"].string, "Click \"Sign in\" (`#submit`)")
        XCTAssertFalse(value.compact.contains("hunter2"))
    }

    func testPickedElementUsesHostURLFiniteGeometryAndDocumentAncestors() async throws {
        let fake = FakeBrowser(); fake.add(.init(id: "w1", url: "https://bank.example/"))
        fake.picked = .init(found: true, tag: "input", selector: "#" + String(repeating: "a", count: 600), label: "Password", labelSource: "label",
                            x: .nan, y: 12, width: .infinity, height: 40, depth: -3, maxUp: 2.7)
        let value = try await answer(fake, "browser.window.pick", [.init("id", .string("w1")), .init("x", .number(20)), .init("y", .number(1200)), .init("up", .number(3))])
        XCTAssertEqual(fake.pickedPoints.map { $0.2 }, [3])
        XCTAssertEqual(fake.pickedPoints.first?.1, 1200)
        XCTAssertEqual(value["url"].string, "https://bank.example/")
        XCTAssertEqual(value["rect"]["x"].number, 0); XCTAssertEqual(value["rect"]["w"].number, 0)
        XCTAssertEqual(value["depth"].number, 0); XCTAssertEqual(value["maxUp"].number, 2)
        XCTAssertEqual(value["selector"].string?.count, 401)
        XCTAssertFalse(value.has("value"))
    }

    func testMissingPickerRecorderAndDesktopResizeReturnNotice() async throws {
        let fake = FakeBrowser(); fake.add(.init(id: "w1")); fake.canPick = false; fake.canRecord = false
        let pick = try await answer(fake, "browser.window.pick", [.init("id", .string("w1")), .init("x", .number(1)), .init("y", .number(1))])
        XCTAssertEqual(notice(pick), "This machine's browser cannot point at one thing on a page.")
        let record = try await answer(fake, "browser.window.steps", [.init("id", .string("w1"))])
        XCTAssertEqual(notice(record), "This machine's browser cannot record a click flow.")
        let size = try await answer(fake, "browser.window.size", [.init("id", .string("w1")), .init("width", .number(393)), .init("height", .number(440))])
        XCTAssertEqual(notice(size), "This machine's browser lays its own windows out, so this one cannot be resized from here.")
    }

    func testEveryBrokenDependencyReturnsWireReplyRatherThanThrowing() async throws {
        for broken in ["list", "sessions", "open", "go", "history", "close", "capture", "write", "record", "pick", "repartition"] {
            let fake = FakeBrowser(); fake.add(.init(id: "w1", title: "Stripe")); fake.hostSessions = [.init(id: "s1", title: "Session 1")]
            fake.broken = broken
            let requests: [(String, [NativeRPCValue.Field])] = [
                ("browser.windows", []), ("browser.window.open", []),
                ("browser.window.go", [.init("id", .string("w1")), .init("url", .string("https://example.com/"))]),
                ("browser.window.act", [.init("id", .string("w1")), .init("action", .string("reload"))]),
                ("browser.window.act", [.init("id", .string("w1")), .init("action", .string("record.on"))]),
                ("browser.window.act", [.init("id", .string("w1")), .init("action", .string("isolate"))]),
                ("browser.window.shot", [.init("id", .string("w1")), .init("session", .string("s1"))]),
                ("browser.window.steps", [.init("id", .string("w1"))]),
                ("browser.window.pick", [.init("id", .string("w1")), .init("x", .number(1)), .init("y", .number(1))]),
                ("browser.window.act", [.init("id", .string("w1")), .init("action", .string("close"))])]
            for (tag, fields) in requests {
                let value = try await answer(fake, tag, fields)
                XCTAssertTrue(["browser.window.rows", "browser.shot", "browser.record.rows", "browser.window.picked"].contains(value["t"].string ?? ""), broken)
            }
        }
    }
}

@MainActor
private final class FakeBrowser: BackendRemoteServeBrowserOperations {
    let bindings = BackendBrowserBindings()
    var mine = true
    var canRecord = true
    var canRepartition = true
    var canPick = true
    var openWindows: [BackendRemoteServeBrowserWindow] = []
    var hostSessions: [BackendRemoteServeBrowserSession] = []
    var writes: [String] = [], waits: [Int] = []
    var steps: [BrowserRecordedStep] = []
    var pickedPoints: [(Double, Double, Int)] = []
    var picked = BackendRemoteServeBrowserPicked(found: true, tag: "button", selector: "#save", label: "Save", labelSource: "text")
    var shot = BackendRemoteServeBrowserCapture(path: "/p/shot.png", width: 1280, height: 800, preview: Data([137, 80, 78, 71]))
    var broken = ""
    var openReturnsNil = false
    var openReason: String?
    var listCalls = 0, openCalls = 0, captureCalls = 0, repartitions = 0
    func add(_ window: BackendRemoteServeBrowserWindow) {
        openWindows.append(window)
        bindings.observe(.init(tabID: window.id, viewID: window.viewID ?? window.id, url: window.url, title: window.title))
    }
    func guardOperation(_ operation: String) throws {
        if broken == operation { throw NativeRPCError(code: "unavailable", message: "the \(operation) dep is unwell") }
    }
    func isMine(_ deviceID: String) async -> Bool { mine }
    func list(context: NativeRPCContext) async throws -> [BackendRemoteServeBrowserWindow] { listCalls += 1; try guardOperation("list"); return openWindows }
    func sessions(context: NativeRPCContext) async throws -> [BackendRemoteServeBrowserSession] { try guardOperation("sessions"); return hostSessions }
    func open(url: String, profile: String, isolated: Bool, context: NativeRPCContext) async throws -> String? {
        try guardOperation("open"); openCalls += 1
        if openReturnsNil { return nil }
        let id = "w\(openCalls)"
        add(.init(id: id, url: url.isEmpty ? "about:blank" : url, viewID: "view-\(id)", profile: profile, isolated: isolated)); return id
    }
    func whyNotOpen() -> String? { openReason }
    func go(id: String, url: String, context: NativeRPCContext) async throws { try guardOperation("go") }
    func history(id: String, move: String, context: NativeRPCContext) async throws { try guardOperation("history") }
    func close(id: String, context: NativeRPCContext) async throws { try guardOperation("close"); openWindows.removeAll { $0.id == id } }
    func attach(id: String, sessionID: String, context: NativeRPCContext) async throws -> BrowserBoundWindow { try bindings.attach(id, to: .init(sessionId: sessionID)) }
    func detach(id: String, context: NativeRPCContext) async throws { bindings.detach(id) }
    func repartition(id: String, isolated: Bool, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserMove? {
        try guardOperation("repartition"); repartitions += 1
        guard let index = openWindows.firstIndex(where: { $0.id == id }) else { return nil }
        openWindows[index].isolated = isolated; return .init(viewID: "view-\(id)-\(isolated)")
    }
    func setRecording(id: String, on: Bool, context: NativeRPCContext) async throws { try guardOperation("record") }
    func recordedSteps(id: String, context: NativeRPCContext) async throws -> [BrowserRecordedStep] { try guardOperation("record"); return steps }
    func capture(id: String, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserCapture { try guardOperation("capture"); captureCalls += 1; return shot }
    func pick(id: String, x: Double, y: Double, up: Int, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserPicked {
        try guardOperation("pick"); pickedPoints.append((x, y, up)); return picked
    }
    func write(sessionID: String, data: String, context: NativeRPCContext) async throws { try guardOperation("write"); writes.append(data) }
    func now() -> Double { 1_700_000_000_000 }
    func wait(milliseconds: Int) async throws { waits.append(milliseconds) }
}
