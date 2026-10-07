import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor BackendMacAppHandoffFrameSink {
    var frames: [NativeRPCValue] = []
    func emit(_ frame: NativeRPCValue) { frames.append(frame) }
    func value() -> [NativeRPCValue] { frames }
}
actor BackendMacAppHandoffCastFixtureState {
    var scrollY: Double = 0
    var inputValues: [NativeRPCValue] = []
    var captures: [(Int, Int)] = []
    var prompt = ""
    var taker: String?
    var outcome: String?
    var detachments = 0
    func move(_ y: Double) { scrollY = y }
    func ask(_ value: String) { prompt = value }
    func grant() -> BackendWebKitProfileArmingWatchGrant {
        .init(ownDevice: true, canInput: true, baton: prompt.isEmpty ? .unclaimed : .human, humanHolder: taker.map { "local:" + $0 })
    }
    func frame(_ width: Int, _ quality: Int) throws -> BackendWebKitProfileArmingWatchFrame {
        captures.append((width, quality))
        return try .init(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), width: 800, height: 600, viewportWidth: 800, viewportHeight: 600, pageScale: 1, scrollX: 0, scrollY: scrollY, privacy: .owner)
    }
    func input(_ value: NativeRPCValue) -> NativeRPCValue { inputValues.append(value); return BackendMacAppHandoffObject(["ok": .bool(true)]) }
    func take(_ caller: BackendBrowserScrapingCaller) { taker = caller.ownerID }
    func untake() { taker = nil; detachments += 1 }
    func back(_ carryOn: Bool) -> BackendMacAppHandoffCastResult { outcome = carryOn ? "resumed" : "stopped"; taker = nil; prompt = ""; return .init(ok: true) }
    func holding() -> BackendMacAppHandoffHandoverState { .init(asking: !prompt.isEmpty, prompt: prompt, taker: taker) }
    func result() -> (input: [NativeRPCValue], captures: [(Int, Int)], outcome: String?, detachments: Int) { (inputValues, captures, outcome, detachments) }
}
struct BackendMacAppHandoffCastRig: Sendable {
    let state: BackendMacAppHandoffCastFixtureState
    let watch: BackendWebKitProfileArmingWatch
    let drive: BackendMacAppHandoffWebKitCastDrive
    let router: BackendMacAppHandoffScreencast
    let window: String
    static func make(window: String = "browser:1755:3", own: Bool = false, windows: (@Sendable () async throws -> [BackendMacAppHandoffCastWindow])? = nil) -> Self {
        let target = BackendBrowserCaptureTarget(tabID: "tab", profileID: "default", pageURL: URL(string: "https://example.com/")!, title: "Example"), state = BackendMacAppHandoffCastFixtureState()
        let hooks = BackendWebKitProfileArmingWatchHooks(grant: { _, _ in await state.grant() }, snapshot: { _, _, _, width, quality in try await state.frame(width, quality) }, input: { _, _, value, _ in await state.input(value) }, take: { caller, _ in await state.take(caller) }, untake: { _, _ in await state.untake() })
        let watch = BackendWebKitProfileArmingWatch(target: target, hooks: hooks)
        let drive = BackendMacAppHandoffWebKitCastDrive(hooks: .init(watch: { _ in watch }, caller: { id in .init(ownerID: id, attended: true, remote: true) }, holding: { _ in await state.holding() }, handBack: { _, _, carryOn in await state.back(carryOn) }))
        let router = BackendMacAppHandoffScreencast(drive: drive, windows: windows ?? { [.init(window: window, target: own ? nil : target, url: "https://example.com/", title: "Example")] })
        return .init(state: state, watch: watch, drive: drive, router: router, window: window)
    }
    func start(_ id: String, _ sink: BackendMacAppHandoffFrameSink, width: Int = 800, quality: Int = 50) async throws -> BackendMacAppHandoffCastResult { try await router.watch(watcherID: id, window: window, maxWidth: width, quality: quality) { await sink.emit($0) } }
    func close() async { await watch.dispose() }
}
final class BackendMacAppHandoffScreencastTests: XCTestCase {
    func testStripListsOpenWindowAndLiveCast() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), sink = BackendMacAppHandoffFrameSink(), before = await rig.router.surfaces()
        BackendMacAppHandoffEqual(before, [BackendMacAppHandoffObject(["window": .string(rig.window), "url": .string("https://example.com/"), "title": .string("Example"), "live": .bool(false)])])
        _ = try await rig.start("conn-1", sink); let after = await rig.router.surfaces(); BackendMacAppHandoffEqual(after[0]["live"], .bool(true)); await rig.close()
    }
    func testUnavailableWindowListAnswersEmptyStrip() async { let rig = BackendMacAppHandoffCastRig.make(windows: { throw BackendMacAppHandoffTestError(message: "no browser") }), result = await rig.router.surfaces(); BackendMacAppHandoffEqual(result, []); await rig.close() }
    func testClosedWindowIsRefusedWithoutCapture() async throws {
        let rig = BackendMacAppHandoffCastRig.make(windows: { [] }), answer = try await rig.start("conn-1", .init()), effects = await rig.state.result()
        XCTAssertFalse(answer.ok); BackendMacAppHandoffEqual(answer.reason, "that window is not open on this machine any more"); XCTAssertTrue(effects.captures.isEmpty); await rig.close()
    }
    func testFrameKeepsWindowTagGeometryAndJPEG() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), sink = BackendMacAppHandoffFrameSink(), result = try await rig.start("conn-1", sink, width: 640, quality: 40), frames = await sink.value(), effects = await rig.state.result()
        XCTAssertTrue(result.ok); BackendMacAppHandoffEqual(effects.captures.first?.0, 640); BackendMacAppHandoffEqual(effects.captures.first?.1, 40)
        let frame = try XCTUnwrap(frames.first); BackendMacAppHandoffEqual(frame["t"], .string("browser.frame")); BackendMacAppHandoffEqual(frame["window"], .string(rig.window)); BackendMacAppHandoffEqual(frame["seq"], .number(1)); BackendMacAppHandoffEqual(frame["w"], .number(800)); BackendMacAppHandoffEqual(frame["dw"], .number(800)); BackendMacAppHandoffEqual(frame["masked"], .missing); XCTAssertFalse((frame["data"].string ?? "").isEmpty); await rig.close()
    }
    func testACKReleasesOnlyLatestHeldFrameAndDuplicateCannotAdvance() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), sink = BackendMacAppHandoffFrameSink(); _ = try await rig.start("conn-1", sink)
        await rig.state.move(120); await rig.watch.invalidate(); var frames = await sink.value(); BackendMacAppHandoffEqual(frames.count, 1)
        try await rig.router.ack(watcherID: "conn-1", window: rig.window, sequence: 1); frames = await sink.value(); BackendMacAppHandoffEqual(frames.count, 2); BackendMacAppHandoffEqual(frames[1]["scrollY"], .number(120))
        await rig.state.move(240); await rig.watch.invalidate(); try await rig.router.ack(watcherID: "conn-1", window: rig.window, sequence: 1); frames = await sink.value(); BackendMacAppHandoffEqual(frames.count, 2)
        try await rig.router.ack(watcherID: "conn-1", window: rig.window, sequence: 2); frames = await sink.value(); BackendMacAppHandoffEqual(frames.count, 3); await rig.close()
    }
    func testTwoConnectionsKeepIndependentACKChains() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), fast = BackendMacAppHandoffFrameSink(), slow = BackendMacAppHandoffFrameSink(); _ = try await rig.start("conn-1", fast); _ = try await rig.start("conn-2", slow)
        try await rig.router.ack(watcherID: "conn-1", window: rig.window, sequence: 1); await rig.state.move(60); await rig.watch.invalidate()
        let a = await fast.value(), b = await slow.value(); BackendMacAppHandoffEqual(a.count, 2); BackendMacAppHandoffEqual(b.count, 1); await rig.close()
    }
    func testInputGoesToHostRecordedFrameGeometry() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), sink = BackendMacAppHandoffFrameSink(); _ = try await rig.start("conn-1", sink, width: 400)
        let result = try await rig.router.input(watcherID: "conn-1", window: rig.window, frame: BackendMacAppHandoffObject(["t": .string("browser.input"), "window": .string(rig.window), "seq": .number(1), "mouse": BackendMacAppHandoffObject(["type": .string("down"), "x": .number(80), "y": .number(40), "clicks": .number(1)])])), effects = await rig.state.result()
        XCTAssertTrue(result.ok); BackendMacAppHandoffEqual(effects.input.count, 1); BackendMacAppHandoffEqual(effects.input[0]["mouse"]["type"], .string("down")); BackendMacAppHandoffEqual(effects.input[0]["mouse"]["clicks"], .number(1)); BackendMacAppHandoffEqual(effects.input[0]["mouse"]["x"], .number(80)); await rig.close()
    }
    func testUnwatchedConnectionInputCannotReachPage() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), result = try await rig.router.input(watcherID: "conn-1", window: rig.window, frame: .object([])), effects = await rig.state.result()
        XCTAssertFalse(result.ok); BackendMacAppHandoffEqual(result.reason, "that window is not being watched on this connection"); XCTAssertTrue(effects.input.isEmpty); await rig.close()
    }
    func testLastUnwatchClearsLiveAndStopsDelivery() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), sink = BackendMacAppHandoffFrameSink(); _ = try await rig.start("conn-1", sink); try await rig.router.unwatch(watcherID: "conn-1", window: rig.window)
        await rig.watch.invalidate(); let rows = await rig.router.surfaces(), frames = await sink.value(), effects = await rig.state.result(); BackendMacAppHandoffEqual(rows[0]["live"], .bool(false)); BackendMacAppHandoffEqual(frames.count, 1); XCTAssertGreaterThan(effects.detachments, 0); await rig.close()
    }
    func testSocketDropClearsCastsAndLateInputACKDoNothing() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), sink = BackendMacAppHandoffFrameSink(); _ = try await rig.start("conn-1", sink); try await rig.router.dropWatcher("conn-1")
        try await rig.router.ack(watcherID: "conn-1", window: rig.window, sequence: 1); let late = try await rig.router.input(watcherID: "conn-1", window: rig.window, frame: .object([])); await rig.watch.invalidate()
        let rows = await rig.router.surfaces(), frames = await sink.value(), effects = await rig.state.result(); BackendMacAppHandoffEqual(rows[0]["live"], .bool(false)); XCTAssertFalse(late.ok); BackendMacAppHandoffEqual(frames.count, 1); XCTAssertTrue(effects.input.isEmpty); await rig.close()
    }
    func testDroppingOneSocketKeepsOtherViewerLive() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), leaving = BackendMacAppHandoffFrameSink(), staying = BackendMacAppHandoffFrameSink(); _ = try await rig.start("conn-1", leaving); _ = try await rig.start("conn-2", staying); try await rig.router.dropWatcher("conn-1")
        let rows = await rig.router.surfaces(), frames = await staying.value(); BackendMacAppHandoffEqual(rows[0]["live"], .bool(true)); BackendMacAppHandoffEqual(frames.count, 1); await rig.close()
    }
    func testNoBrowserRefusesAndNeverRemembersCast() async throws {
        let router = BackendMacAppHandoffScreencast(drive: BackendMacAppHandoffNoBrowser(), windows: { [.init(window: "pane", target: nil, url: "", title: "")] })
        let result = try await router.watch(watcherID: "conn-1", window: "pane", maxWidth: 800, quality: 50, emit: { _ in }), rows = await router.surfaces(), late = try await router.input(watcherID: "conn-1", window: "pane", frame: .object([]))
        XCTAssertFalse(result.ok); BackendMacAppHandoffEqual(result.reason, "this app has no browser running"); BackendMacAppHandoffEqual(rows[0]["live"], .bool(false)); XCTAssertFalse(late.ok)
    }
    func testDroppingNeverWatchedConnectionIsHarmless() async throws { let router = BackendMacAppHandoffScreencast(drive: BackendMacAppHandoffNoBrowser(), windows: { [] }); try await router.dropWatcher("conn-9"); try await router.unwatch(watcherID: "conn-9", window: "pane") }
    func testFrontTabAbsentHasNoRow() { XCTAssertNil(BackendMacAppHandoffScreencast.frontTab(url: nil, title: "")) }
    func testFrontTabLabelsLivePageAndOwnSlot() { let row = BackendMacAppHandoffScreencast.frontTab(url: "https://www.google.com/", title: "Google"); BackendMacAppHandoffEqual(row?.window, ""); XCTAssertNil(row?.target); BackendMacAppHandoffEqual(row?.url, "https://www.google.com/"); BackendMacAppHandoffEqual(row?.title, "Google") }
    func testFrontTabFollowsSameSiteAndCrossSitePaths() { let same = BackendMacAppHandoffScreencast.frontTab(url: "https://www.google.com/search?q=deck", title: "deck - Google Search"), cross = BackendMacAppHandoffScreencast.frontTab(url: "https://news.example.com/story/1", title: "A story"); BackendMacAppHandoffEqual(same?.url, "https://www.google.com/search?q=deck"); BackendMacAppHandoffEqual(same?.title, "deck - Google Search"); BackendMacAppHandoffEqual(cross?.url, "https://news.example.com/story/1"); BackendMacAppHandoffEqual(cross?.title, "A story") }
    func testBlankFrontTabDoesNotPrintOpaqueOrigin() { let row = BackendMacAppHandoffScreencast.frontTab(url: "about:blank", title: ""); BackendMacAppHandoffEqual(row?.window, ""); XCTAssertNil(row?.target); BackendMacAppHandoffEqual(row?.url, ""); BackendMacAppHandoffEqual(row?.title, "") }
    func testNamedWindowOnOwnSlotStillStreamsACKsAndInputs() async throws {
        let rig = BackendMacAppHandoffCastRig.make(window: "browser:1755:9", own: true), sink = BackendMacAppHandoffFrameSink(); _ = try await rig.start("conn-1", sink); try await rig.router.ack(watcherID: "conn-1", window: rig.window, sequence: 1); await rig.state.move(120); await rig.watch.invalidate()
        let frames = await sink.value(), rows = await rig.router.surfaces(); BackendMacAppHandoffEqual(frames.count, 2); BackendMacAppHandoffEqual(frames[0]["window"], .string("browser:1755:9")); BackendMacAppHandoffEqual(rows[0]["window"], .string("browser:1755:9"))
        let answer = try await rig.router.input(watcherID: "conn-1", window: rig.window, frame: BackendMacAppHandoffObject(["seq": .number(2), "mouse": BackendMacAppHandoffObject(["type": .string("down"), "x": .number(80), "y": .number(40)])])); XCTAssertTrue(answer.ok); await rig.close()
    }
    func testOwnSlotQuestionTakeAndHandBackUseSameRuntime() async throws { try await handoverRound(own: true) }
    func testUncastWindowHasNoQuestionAndCannotTakeOrHandBack() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), state = try await rig.router.handover(rig.window), take = try await rig.router.take(watcherID: "conn-1", window: rig.window), back = try await rig.router.handBack(watcherID: "conn-1", window: rig.window, carryOn: true)
        BackendMacAppHandoffEqual(state, .none); XCTAssertFalse(take.ok); XCTAssertFalse(back.ok); await rig.close()
    }
    func testBoundSlotTakeAndHandBackReachSamePage() async throws { try await handoverRound(own: false) }
    private func handoverRound(own: Bool) async throws {
        let rig = BackendMacAppHandoffCastRig.make(own: own), sink = BackendMacAppHandoffFrameSink(); _ = try await rig.start("conn-1", sink); await rig.watch.curtain("Sign in and then press Done."); await rig.state.ask("Sign in and then press Done.")
        let question = try await rig.router.handover(rig.window); XCTAssertTrue(question.asking); XCTAssertTrue(question.prompt.contains("Sign in")); XCTAssertNil(question.taker)
        let take = try await rig.router.take(watcherID: "conn-1", window: rig.window), held = try await rig.router.handover(rig.window); XCTAssertTrue(take.ok); BackendMacAppHandoffEqual(held.taker, "conn-1")
        let frames = await sink.value(), latest = try XCTUnwrap(frames.last?["seq"].number)
        let typed = try await rig.router.input(watcherID: "conn-1", window: rig.window, frame: BackendMacAppHandoffObject(["seq": .number(latest), "paste": .string("hunter2")]))
        XCTAssertTrue(typed.ok); let effects = await rig.state.result(); BackendMacAppHandoffEqual(effects.input.last?["paste"], .string("hunter2"))
        let back = try await rig.router.handBack(watcherID: "conn-1", window: rig.window, carryOn: true), final = try await rig.router.handover(rig.window), result = await rig.state.result()
        XCTAssertTrue(back.ok); BackendMacAppHandoffEqual(result.outcome, "resumed"); BackendMacAppHandoffEqual(final, .none); await rig.close()
    }
    func testStrangerCannotTakeQuestionAndStopReachesRuntime() async throws {
        let rig = BackendMacAppHandoffCastRig.make(), sink = BackendMacAppHandoffFrameSink(); _ = try await rig.start("conn-1", sink); await rig.watch.curtain("Sign in and then press Done."); await rig.state.ask("Sign in and then press Done.")
        let answer = try await rig.router.take(watcherID: "conn-2", window: rig.window), before = try await rig.router.handover(rig.window); XCTAssertFalse(answer.ok); BackendMacAppHandoffEqual(answer.reason, "that window is not being watched on this connection"); XCTAssertNil(before.taker)
        _ = try await rig.router.take(watcherID: "conn-1", window: rig.window); _ = try await rig.router.handBack(watcherID: "conn-1", window: rig.window, carryOn: false); let after = await rig.state.result(); BackendMacAppHandoffEqual(after.outcome, "stopped"); await rig.close()
    }
    func testUnsupportedWebKitEveryNthIsExplicitRefusal() async throws { let rig = BackendMacAppHandoffCastRig.make(), result = try await rig.router.watch(watcherID: "conn-1", window: rig.window, maxWidth: 800, quality: 50, everyNth: 2, emit: { _ in }); XCTAssertFalse(result.ok); XCTAssertTrue(result.reason?.contains("unavailable") == true); await rig.close() }
}
