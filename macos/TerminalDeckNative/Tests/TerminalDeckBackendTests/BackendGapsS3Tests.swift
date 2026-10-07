import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Night S3: the cases that were blocked on missing production seams, now supplied by the
/// BackendS3Fill* sources. user-data.test.ts, reachability.test.ts, resident-presence.test.ts,
/// native-mode.test.ts L214/L223 (free-standing consent), remote-native.test.ts L82/L91,
/// annotate.test.ts (browser address, selector, roundForTools), device-tree.test.ts (findNodes).
final class BackendGapsS3UserDataTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("td-s3-userdata-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try BackendFilesystemAuthority.canonical(url)
    }
    func testMovesUserDataToTheSlugNotTheDisplayName() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let named = root.appendingPathComponent("Terminal Deck"); try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        XCTAssertEqual(BackendS3FillUserData.pin(current: named, arguments: [])?.path, root.appendingPathComponent("terminaldeck").path)
    }
    func testCarriesStateOverOnTheFirstRunAfterARename() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Pawl"); try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(#"{"projects":["kept"]}"#.utf8).write(to: old.appendingPathComponent("state.json"))
        let pinned = try XCTUnwrap(BackendS3FillUserData.pin(current: old, arguments: []))
        XCTAssertEqual(try String(contentsOf: pinned.appendingPathComponent("state.json"), encoding: .utf8), #"{"projects":["kept"]}"#)
    }
    func testNeverOverwritesStateThePinnedFolderAlreadyHas() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Pawl"), pinned = root.appendingPathComponent("terminaldeck")
        for folder in [old, pinned] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data(#"{"projects":["stale"]}"#.utf8).write(to: old.appendingPathComponent("state.json"))
        try Data(#"{"projects":["current"]}"#.utf8).write(to: pinned.appendingPathComponent("state.json"))
        _ = BackendS3FillUserData.pin(current: old, arguments: [])
        XCTAssertEqual(try String(contentsOf: pinned.appendingPathComponent("state.json"), encoding: .utf8), #"{"projects":["current"]}"#)
    }
    func testLeavesThePathAloneWhenAlreadyPinnedAndCreatesNothing() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let pinned = root.appendingPathComponent("terminaldeck"); try FileManager.default.createDirectory(at: pinned, withIntermediateDirectories: true)
        XCTAssertNil(BackendS3FillUserData.pin(current: pinned, arguments: []))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["terminaldeck"])
    }
    func testExplicitUserDataDirIsNeverTouched() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let explicit = root.appendingPathComponent("td-explicit")
        XCTAssertNil(BackendS3FillUserData.pin(current: explicit, arguments: ["app", "--user-data-dir=" + explicit.path]))
        XCTAssertNil(BackendS3FillUserData.pin(current: explicit, arguments: ["app", "--user-data-dir", explicit.path]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])   // nothing created beside it either
    }
}

final class BackendGapsS3HostFactsTests: XCTestCase {
    typealias R = BackendS3FillReachability
    private func facts(_ patch: (inout BackendS3FillHostFacts) -> Void = { _ in }) -> BackendS3FillHostFacts {
        var base = BackendS3FillHostFacts(platform: "linux", wsl: false, distro: nil, battery: false, systemd: true, user: "asad"); patch(&base); return base
    }
    func testSeparatesTheFourHostsAndCallsAWslBatteryHostWsl() {
        XCTAssertEqual(R.hostKind(facts { $0.wsl = true; $0.distro = "Ubuntu" }), .wsl)
        XCTAssertEqual(R.hostKind(facts { $0.battery = false }), .linuxServer)
        XCTAssertEqual(R.hostKind(facts { $0.battery = true }), .linuxLaptop)
        XCTAssertEqual(R.hostKind(facts { $0.platform = "darwin" }), .macos)
        XCTAssertEqual(R.hostKind(facts { $0.platform = "win32" }), .windows)
        XCTAssertEqual(R.hostKind(facts { $0.wsl = true; $0.battery = true }), .wsl)
    }
    func testDetectsWslFromTheLoginShellVariableAndPrefersItOverTheFallback() {
        let read = R.readHostFacts(platform: "linux", environment: ["WSL_DISTRO_NAME": "Ubuntu"], readText: { _ in nil }, exists: { _ in false }, rootWindowsPath: { "Wrong" })
        XCTAssertTrue(read.wsl); XCTAssertEqual(read.distro, "Ubuntu")
        let off = R.readHostFacts(platform: "darwin", environment: [:], rootWindowsPath: { "Ubuntu-24.04" })
        XCTAssertNil(off.distro)
    }
    func testFallbackNameComesFromTheRootPathOnlyOnLinuxUnderWsl() {
        let kernel = R.readHostFacts(platform: "linux", environment: [:], readText: { _ in "Linux version 5.15 microsoft-standard-WSL2" }, exists: { _ in false }, rootWindowsPath: { "Ubuntu-24.04" })
        XCTAssertTrue(kernel.wsl); XCTAssertEqual(kernel.distro, "Ubuntu-24.04")
    }
    func testAsksNothingOfLinuxWhenThePlatformIsNotLinux() {
        var asked = 0
        let read = R.readHostFacts(platform: "darwin", environment: ["USER": "asad"], readText: { _ in asked += 1; return nil }, exists: { _ in asked += 1; return true }, rootWindowsPath: { asked += 1; return "x" })
        XCTAssertEqual(read, BackendS3FillHostFacts(platform: "darwin", wsl: false, distro: nil, battery: false, systemd: false, user: "asad")); XCTAssertEqual(asked, 0)
    }
    func testReadsTheDistroOutOfTheRootPathInBothSpellingsAndRefusesOtherShapes() {
        XCTAssertEqual(R.distroFromRootPath("\\\\wsl.localhost\\Ubuntu-24.04\\"), "Ubuntu-24.04")
        XCTAssertEqual(R.distroFromRootPath("\\\\wsl$\\Ubuntu\\"), "Ubuntu")
        XCTAssertEqual(R.distroFromRootPath("\\\\wsl.localhost\\Debian\\\n"), "Debian")
        for other in ["/", "C:\\Users\\asad", "", "\\\\wsl.localhost\\Ubuntu\\home\\asad"] { XCTAssertNil(R.distroFromRootPath(other), other) }
    }
}

@MainActor final class BackendGapsS3ResidentTests: XCTestCase {
    final class Handle: BackendS3FillStatusItemHandle {
        var removed = false, rows: [BackendS3FillResidentMenu.Row] = []
        func update(toolTip: String, rows: [BackendS3FillResidentMenu.Row]) { self.rows = rows }
        func remove() { removed = true }
    }
    final class Factory: BackendS3FillStatusItemFactory {
        var made: [Handle] = []
        var live: Int { made.filter { !$0.removed }.count }
        func make(open: @escaping @MainActor () -> Void, stop: @escaping @MainActor (String) -> Void, quitAll: @escaping @MainActor () -> Void) -> any BackendS3FillStatusItemHandle {
            let handle = Handle(); made.append(handle); return handle
        }
    }
    final class Owl { var on: Bool; init(_ on: Bool) { self.on = on } }
    private func rig(_ owl: Owl) -> (BackendS3FillResidentPresence, Factory) {
        let factory = Factory()
        let presence = BackendS3FillResidentPresence(
            sessions: { [.init(id: "a", provider: "claude", cwd: "/work/a"), .init(id: "b", provider: "claude", cwd: "/work/b")] },
            open: {}, stop: { _ in }, quitAll: {}, represented: { owl.on }, factory: factory)
        return (presence, factory)
    }
    func testDrawsNoneOfItsOwnWhileTheOwlIsInTheMenuBarAndStillCountsAsVisible() {
        let (presence, factory) = rig(Owl(true)); presence.show()
        XCTAssertEqual(factory.live, 0); XCTAssertTrue(presence.visible)
    }
    func testDrawsItsOwnWhenTheOwlIsOffAndDropsItWhenTheOwlIsBack() {
        let owl = Owl(true), (presence, factory) = rig(owl); presence.show()
        owl.on = false; presence.refresh(); XCTAssertEqual(factory.live, 1); XCTAssertTrue(presence.visible)
        presence.refresh(); XCTAssertEqual(factory.made.count, 1)      // never two icons
        owl.on = true; presence.refresh(); XCTAssertEqual(factory.live, 0)
    }
    func testDrawsNothingWhileTheAppHasAWindowWhateverTheOwlIsDoing() {
        let (presence, factory) = rig(Owl(false)); presence.refresh()
        XCTAssertEqual(factory.live, 0); XCTAssertFalse(presence.visible)
        presence.show(); presence.hide(); XCTAssertEqual(factory.live, 0)
    }
    func testTheBackgroundMenuListsTheSessionsOpenAndQuit() {
        let rows = BackendS3FillResidentMenu.rows(sessions: [.init(id: "a", provider: "claude", cwd: "/work/api")])
        XCTAssertEqual(rows.map(\.label), ["Terminal Deck — 1 session running", "(separator)", "Open Terminal Deck", "(separator)", "Claude Code — api", "(separator)", "Quit and Stop All Sessions"])
        let none = BackendS3FillResidentMenu.rows(sessions: [.init(id: "x", provider: "codex", cwd: "/w", exitCode: 0)])
        XCTAssertEqual(none.map(\.label), ["Terminal Deck — 0 sessions running", "(separator)", "Open Terminal Deck", "(separator)", "Quit and Stop All Sessions"])
    }
}

@MainActor final class BackendGapsS3ConsentRemoteTests: XCTestCase {
    private let request = BackendPluginsConsentRequest(id: "p", name: "p", version: "1.0.0", hash: "h", capabilities: [], projects: [], tools: [], message: "Let the plugin read files?", detail: "It asked to.")
    func testFreeStandingBoxAnswerCountsAndIsAskedOnce() async {
        let shown = Counts()
        let consent = BackendS3FillFreeStandingConsent(present: { question in await shown.failed(question.message); return true })
        let outcome = await consent.ask(request); let asked = await shown.failures
        XCTAssertTrue(outcome.granted); XCTAssertEqual(asked, ["Let the plugin read files?"])
    }
    func testFreeStandingBoxDeclineAndShutdownRefuse() async {
        let declined = BackendS3FillFreeStandingConsent(present: { _ in false })
        let no = await declined.ask(request); XCTAssertFalse(no.granted)
        await declined.shutdown(); let after = await declined.ask(request)
        XCTAssertFalse(after.granted); XCTAssertEqual(after.reason, "shutting-down")
    }
    actor Counts { var tailnet = 0, serve = 0, failures: [String] = []
        func tailnetAsked() -> Bool { tailnet += 1; return true }
        func serveAsked() { serve += 1 }
        func failed(_ reason: String) { failures.append(reason) } }
    final class Reported: @unchecked Sendable { private let lock = NSLock(); private var items: [String] = []
        func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return items } }
    func testPreviewLaunchDialReportsTheDirectRefusalAndNeverTouchesTailscale() async {
        let counts = Counts(), reported = Reported()
        let remote = BackendS3FillPreviewRemote(preview: true, relayAvailable: false, readTailnet: { await counts.tailnetAsked() }, serveOn: { await counts.serveAsked() },
                                                onStartFailure: { reason in reported.append(reason) })   // remote/server.ts:9418-9423 reports synchronously after start()
        await remote.launch()
        let failures = reported.values, tailnet = await counts.tailnet, serve = await counts.serve
        XCTAssertEqual(failures, [BackendOSNativeMode.directRefusal]); XCTAssertEqual(tailnet, 0); XCTAssertEqual(serve, 0)
    }
    func testPreviewStartButtonReportsTheSameReasonRatherThanRefusingSilently() async {
        let counts = Counts()
        let remote = BackendS3FillPreviewRemote(preview: true, relayAvailable: false, readTailnet: { await counts.tailnetAsked() }, serveOn: { await counts.serveAsked() })
        let status = await remote.start(); let serve = await counts.serve
        XCTAssertEqual(status, .init(running: false, reason: BackendOSNativeMode.directRefusal)); XCTAssertEqual(serve, 0)
        let launch = BackendS3FillPreviewRemote(preview: true, relayAvailable: false, readTailnet: { true }, serveOn: {})
        await launch.launch(autoStart: false)   // autoStart false: nothing dials
    }
}

final class BackendGapsS3AnnotateTests: XCTestCase {
    func testNamesABrowserPageByItsAddress() {
        let place = AnnotateWhere(kind: "browser", place: "browser page", name: "Shop")
        XCTAssertEqual(Handoff.describeWhere(place, url: "http://localhost:3000/"), "the page http://localhost:3000/ titled \"Shop\"")
        XCTAssertEqual(Handoff.describeWhere(place, url: nil), "a browser page titled \"Shop\"")
        let device = AnnotateWhere(place: "iOS Simulator", name: "iPhone 17 Pro", app: "com.example.Shop", screen: "Checkout")
        XCTAssertEqual(Handoff.describeWhere(device, url: "ignored"), "the iOS Simulator \"iPhone 17 Pro\", app com.example.Shop, screen Checkout")
    }
    func testNamesAPageElementWithItsSelector() {
        let button = AnnotatedElement(role: "<button>", name: "Order now", identifier: "order")
        XCTAssertEqual(Handoff.describeElement(button, selector: "#order"), "<button> \"Order now\" (id order, selector #order)")
        XCTAssertEqual(Handoff.describeElement(nil, selector: "#order"), "blank space")
        XCTAssertEqual(Handoff.describeElement(button, selector: nil), Handoff.describeElement(button))
    }
    func testTheRoundForAToolIsFieldsNotASentence() {
        var list = Annotation.adding([], id: "a", rect: NormRect(x: 0.04, y: 0.444, width: 0.92, height: 0.062), element: .init(role: "button", name: "General", identifier: "com.apple.settings.general"))
        list = Annotation.adding(list, id: "b", rect: NormRect(x: 0.5, y: 0.9, width: 0.04, height: 0.04), element: nil)
        let round = AnnotationRound(id: "r1", createdAt: 1_790_000_000_000, where_: .init(place: "iOS Simulator", name: "iPhone 17 Pro"), frameWidth: 1206, frameHeight: 2622,
                                    annotations: list, note: "Make #1 bold and put #2 below it.\u{1b}[2J")
        let value = Handoff.roundForTools(round, sentTo: (sessionId: "s1", label: "shop · Session 1", at: 1_790_000_060_000))
        XCTAssertEqual((value["sentTo"] as? [String: Any])?["session"] as? String, "shop · Session 1")
        XCTAssertEqual((value["sentTo"] as? [String: Any])?["at"] as? String, "2026-09-21T14:14:20.000Z")
        XCTAssertEqual(value["createdAt"] as? String, "2026-09-21T14:13:20.000Z")
        XCTAssertEqual(value["note"] as? String, "Make #1 bold and put #2 below it. [2J")
        XCTAssertTrue(value["picture"] is NSNull)
        let markers = try? XCTUnwrap(value["markers"] as? [[String: Any]])
        XCTAssertEqual(markers?.compactMap { $0["n"] as? Int }, [1, 2]); XCTAssertEqual(markers?[1]["described"] as? String, "blank space")
        for marker in markers ?? [] { XCTAssertNil(marker["note"]) }
    }
}

final class BackendGapsS3FindNodesTests: XCTestCase {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormRect { NormRect(x: x, y: y, width: w, height: h) }
    private func settings() -> DeviceNode {
        let general = DeviceNode(ref: "ax:5", role: "AXButton", label: "General", identifier: "com.apple.settings.general", frame: rect(0.04, 0.444, 0.92, 0.062), children: [DeviceNode(ref: "ax:5a", role: "AXImage")])
        let access = DeviceNode(ref: "ax:6", role: "AXButton", label: "Accessibility", identifier: "com.apple.settings.accessibility", frame: rect(0.04, 0.506, 0.92, 0.062))
        let hidden = DeviceNode(ref: "ax:7", role: "AXButton", label: "Hidden one", hidden: true, frame: rect(0.04, 0.6, 0.92, 0.062))
        let group = DeviceNode(ref: "ax:2", role: "AXGroup", identifier: "com.apple.settings.sidebar.collectionView", frame: rect(0, 0, 1, 1), children: [general, access, hidden])
        return DeviceNode(ref: "ax:0", role: "AXApplication", label: "Settings", frame: rect(0, 0, 1, 1), children: [DeviceNode(ref: "ax:1", role: "AXHeading", label: "Settings"), group])
    }
    func testMatchesTheWholeNameCaseInsensitively() {
        XCTAssertEqual(DeviceTreeQuery.findNodes(settings(), .init(name: "general")).map(\.ref), ["ax:5"])
        XCTAssertEqual(DeviceTreeQuery.findNodes(settings(), .init(name: "Gen")).count, 0)
    }
    func testMatchesPartOfANameOnlyWhenAsked() { XCTAssertEqual(DeviceTreeQuery.findNodes(settings(), .init(name: "Gen", partial: true)).map(\.ref), ["ax:5"]) }
    func testTakesARoleInEitherSpelling() {
        XCTAssertEqual(DeviceTreeQuery.findNodes(settings(), .init(role: "button")).count, 3)
        XCTAssertEqual(DeviceTreeQuery.findNodes(settings(), .init(name: "Accessibility", role: "AXButton")).map(\.ref), ["ax:6"])
    }
    func testFindsByIdentifier() { XCTAssertEqual(DeviceTreeQuery.findNodes(settings(), .init(identifier: "com.apple.settings.general")).first?.label, "General") }
    func testFindsNothingForAnEmptyQueryRatherThanEverything() { XCTAssertEqual(DeviceTreeQuery.findNodes(settings(), .init()), []) }
}

final class BackendGapsS3ShortCodeTests: XCTestCase {
    private func word(_ draw: UInt64) -> [UInt8] { [UInt8((draw >> 24) & 0xff), UInt8((draw >> 16) & 0xff), UInt8((draw >> 8) & 0xff), UInt8(draw & 0xff)] }
    func testRejectionSamplingPaddingAndRefusals() throws {
        let limit = BackendShortCode.drawLimit
        XCTAssertEqual(try BackendShortCode.codeFromBytes([limit + 7, 123_456, 0, 0].flatMap(word)), "123456")
        XCTAssertEqual(try BackendShortCode.codeFromBytes([limit - 1, 0, 0, 0].flatMap(word)), "999999")
        XCTAssertEqual(try BackendShortCode.codeFromBytes([7, 0, 0, 0].flatMap(word)), "000007")
        XCTAssertThrowsError(try BackendShortCode.codeFromBytes([UInt8](repeating: 0, count: 15))) { XCTAssertEqual($0 as? BackendShortCodeError, .tooLittleRandomness) }
        XCTAssertThrowsError(try BackendShortCode.codeFromBytes((0..<4).flatMap { _ in word(limit) })) { XCTAssertEqual($0 as? BackendShortCodeError, .rejectionRegion) }
    }
}
