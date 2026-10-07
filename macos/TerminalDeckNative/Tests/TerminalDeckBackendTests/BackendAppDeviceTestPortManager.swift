import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private final class BackendAppDeviceTestPortSignal: @unchecked Sendable {
    private let lock = NSLock(); private var seen = 0; private var waits: [(Int, CheckedContinuation<Void, Never>)] = []
    func note() { lock.lock(); seen += 1; let ready = waits.filter { $0.0 <= seen }; waits.removeAll { $0.0 <= seen }; lock.unlock(); for row in ready { row.1.resume() } }
    func when(_ count: Int) async { await withCheckedContinuation { answer in lock.lock(); if seen >= count { lock.unlock(); answer.resume() } else { waits.append((count, answer)); lock.unlock() } } }
}
private final class BackendAppDeviceTestPortView: @unchecked Sendable {
    private let lock = NSLock(); private var recorded: [(String, [NativeRPCValue])] = []
    func send(_ channel: String, _ args: [NativeRPCValue]) { lock.lock(); recorded.append((channel, args)); lock.unlock() }
    func rows() -> [(String, [NativeRPCValue])] { lock.lock(); defer { lock.unlock() }; return recorded }
    func clear() { lock.lock(); recorded.removeAll(); lock.unlock() }
    func viewer(_ id: String = "1") -> BackendAppDeviceViewer { .init(id: id, send: { [self] in send($0, $1) }, isDestroyed: { false }) }
}
private final class BackendAppDeviceTestPortImages: @unchecked Sendable {
    private let lock = NSLock(); private var images: [String: Data] = [:]
    func write(_ file: URL, _ data: Data) { lock.lock(); images[file.path] = data; lock.unlock() }
    func read(_ path: String) -> Data? { lock.lock(); defer { lock.unlock() }; return images[path] }
}
private actor BackendAppDeviceTestPortSession: BackendAppDeviceSessionServing {
    nonisolated let events: AsyncStream<BackendAppDeviceSessionEvent>
    private nonisolated let output: AsyncStream<BackendAppDeviceSessionEvent>.Continuation
    private(set) var previews: [Bool] = [], requested: [Bool] = [], touches: [String] = []
    private(set) var preview = false, closed = false
    private(set) var opens = 0
    private var holdOff = false
    private var releaseOff: CheckedContinuation<Void, Never>?
    private var previewWaits: [(Int, CheckedContinuation<Void, Never>)] = []
    init() { var sink: AsyncStream<BackendAppDeviceSessionEvent>.Continuation!; events = AsyncStream { sink = $0 }; output = sink }
    private var details: NativeRPCValue { BackendAppSessionTestPortObject([("id", .string("ios:TEST")), ("name", .string("iPhone 17 Pro")), ("platform", .string("ios")), ("kind", .string("simulator")), ("pointWidth", .number(402)), ("pointHeight", .number(874)), ("buttons", .array([.string("home")])), ("keys", .array([])), ("text", .string("unicode")), ("canRotate", .bool(true)), ("rawTouch", .bool(true))]) }
    func info() -> NativeRPCValue? { details }
    func screenConfiguration() -> Data? { Data([0x10, 1, 0x64, 0, 0x33]) }
    func isOpen() -> Bool { !closed }
    func open() -> NativeRPCValue { opens += 1; return details }
    func setPreview(_ on: Bool) async throws {
        requested.append(on); let ready = previewWaits.filter { $0.0 <= requested.count }; previewWaits.removeAll { $0.0 <= requested.count }; for row in ready { row.1.resume() }
        if !on, holdOff { await withCheckedContinuation { releaseOff = $0 }; holdOff = false }
        preview = on; previews.append(on)
    }
    func holdNextOff() { holdOff = true }
    func whenPreviewRequested(_ count: Int) async { if requested.count >= count { return }; await withCheckedContinuation { previewWaits.append((count, $0)) } }
    func finishOff() { releaseOff?.resume(); releaseOff = nil }
    func tap(x: Double, y: Double, holdMilliseconds: Double?) async throws {}
    func touch(phase: String, x: Double, y: Double) { touches.append(phase) }
    func swipe(from: NativeRPCValue, to: NativeRPCValue, durationMilliseconds: Double) async throws {}
    func type(_ text: String) async throws {}
    func key(_ key: String, modifiers: [String]) async throws {}
    func button(_ button: String) async throws {}
    func rotate(to: String?) -> String { to ?? "portrait" }
    func screenshot() -> BackendAppDeviceScreenshot { .init(png: Data("png".utf8), width: 10, height: 20) }
    func foreground() -> NativeRPCValue { .object([]) }
    func elementAt(x: Double, y: Double) -> NativeRPCValue? { nil }
    func tree(scope: String) -> NativeRPCValue { .object([]) }
    func close() { closed = true }
    func emit(_ packet: Data) { output.yield(.screen(packet)) }
    func disconnect(_ reason: String) { output.yield(.closed(reason)) }
}
final class BackendAppDeviceTestPortManager: XCTestCase, @unchecked Sendable {
    private let id = "ios:TEST"
    private let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    private func make() -> (BackendAppDeviceManager, BackendAppDeviceTestPortSession, BackendAppSessionTestPortClock, BackendAppDeviceTestPortSignal, BackendAppDeviceTestPortImages) {
        let session = BackendAppDeviceTestPortSession(), clock = BackendAppSessionTestPortClock(), signal = BackendAppDeviceTestPortSignal(), images = BackendAppDeviceTestPortImages()
        let engine = BackendAppDeviceEngine(bin: "/x", core: "/x/simview-core", cli: "/x/simview", environment: [:])
        let manager = BackendAppDeviceManager(locate: { .available(engine) }, platform: .init(environment: [:], home: "/fixture"), picturesDirectory: { URL(fileURLWithPath: "/fixture/pictures") }, clock: clock, writeImage: { images.write($0, $1) }, eventObserved: { _, _ in signal.note() }, makeSession: { _, _ in session })
        return (manager, session, clock, signal, images)
    }
    func testWatchEndsOnLastRequestDespiteSlowOff() async throws {
        let (m, s, _, _, _) = make(), view = BackendAppDeviceTestPortView(); try await m.watch(view.viewer(), id: id, mode: .on); await s.holdNextOff()
        let off = Task { try await m.watch(view.viewer(), id: id, mode: .off) }; await s.whenPreviewRequested(2)
        let on = Task { try await m.watch(view.viewer(), id: id, mode: .on) }; await s.finishOff(); try await off.value; try await on.value
        let preview = await s.preview, previews = await s.previews; XCTAssertTrue(preview); XCTAssertEqual(previews.last, true); await m.closeAll()
    }
    func testConfigurationPrecedesEveryPicture() async throws {
        let (m, s, _, signal, _) = make(), view = BackendAppDeviceTestPortView(); try await m.watch(view.viewer(), id: id, mode: .on)
        await s.emit(Data([0x11, 1])); await s.emit(Data([0x11, 2])); await signal.when(2)
        let packets = view.rows().filter { $0.0 == "devices:frame" }.compactMap { row -> Data? in if case .bytes(let bytes) = row.1[1] { return bytes }; return nil }
        XCTAssertEqual(packets, [Data([0x10, 1, 0x64, 0, 0x33]), Data([0x11, 1]), Data([0x11, 2])]); await m.closeAll()
    }
    func testBurstIsPassedWholeInOrderWithNoThinning() async throws {
        let (m, s, _, signal, _) = make(), view = BackendAppDeviceTestPortView(); try await m.watch(view.viewer(), id: id, mode: .on); view.clear()
        for i in 0..<60 { await s.emit(Data([0x11, UInt8(i)])) }; await signal.when(60)
        let numbers = view.rows().compactMap { row -> UInt8? in if case .bytes(let bytes) = row.1[1] { return bytes[1] }; return nil }
        XCTAssertEqual(numbers, (0..<60).map(UInt8.init)); await m.closeAll()
    }
    func testTouchPhasesAreSentInArrivalOrderWithoutWaitingForOtherInput() async throws {
        let (m, s, _, _, _) = make(); try await m.watch(BackendAppDeviceTestPortView().viewer(), id: id, mode: .on)
        try await m.touch(id, phase: "down", x: 0.5, y: 0.5); try await m.touch(id, phase: "move", x: 0.5, y: 0.6); try await m.touch(id, phase: "up", x: 0.5, y: 0.7)
        let phases = await s.touches, opens = await s.opens; XCTAssertEqual(phases, ["down", "move", "up"]); XCTAssertEqual(opens, 1); await m.closeAll()
    }
    func testOnlyLastViewerOffStopsPictures() async throws {
        let (m, s, _, _, _) = make(), a = BackendAppDeviceTestPortView(), b = BackendAppDeviceTestPortView()
        try await m.watch(a.viewer("1"), id: id, mode: .on); try await m.watch(b.viewer("2"), id: id, mode: .on); try await m.watch(a.viewer("1"), id: id, mode: .off); let still = await s.preview; XCTAssertTrue(still)
        try await m.watch(b.viewer("2"), id: id, mode: .off); let stopped = await s.preview; XCTAssertFalse(stopped); await m.closeAll()
    }
    func testHiddenViewerGetsNothingAndKeepsEngineOpenForFiveMinutes() async throws {
        let (m, s, clock, signal, _) = make(), view = BackendAppDeviceTestPortView(); try await m.watch(view.viewer(), id: id, mode: .on); try await m.watch(view.viewer(), id: id, mode: .paused)
        let preview = await s.preview; XCTAssertFalse(preview); view.clear(); await s.emit(Data([0x11, 1])); await signal.when(1); XCTAssertTrue(view.rows().isEmpty)
        clock.advance(5 * 60_000); let closed = await s.closed; XCTAssertFalse(closed); await m.closeAll()
    }
    func testReturningViewerGetsConfigurationThenFreshStream() async throws {
        let (m, s, _, signal, _) = make(), view = BackendAppDeviceTestPortView(); try await m.watch(view.viewer(), id: id, mode: .paused); let before = await s.preview; XCTAssertFalse(before)
        try await m.watch(view.viewer(), id: id, mode: .on); let after = await s.preview; XCTAssertTrue(after); await s.emit(Data([0x11, 9])); await signal.when(1)
        let packets = view.rows().compactMap { row -> Data? in if case .bytes(let data) = row.1[1] { return data }; return nil }; XCTAssertEqual(packets, [Data([0x10, 1, 0x64, 0, 0x33]), Data([0x11, 9])]); await m.closeAll()
    }
    func testAnyVisibleViewerKeepsPicturesComing() async throws {
        let (m, s, _, _, _) = make(), a = BackendAppDeviceTestPortView(), b = BackendAppDeviceTestPortView()
        try await m.watch(a.viewer("1"), id: id, mode: .on); try await m.watch(b.viewer("2"), id: id, mode: .on); try await m.watch(a.viewer("1"), id: id, mode: .paused); let one = await s.preview; XCTAssertTrue(one)
        try await m.watch(b.viewer("2"), id: id, mode: .paused); let none = await s.preview; XCTAssertFalse(none); try await m.watch(b.viewer("2"), id: id, mode: .on); let back = await s.preview; XCTAssertTrue(back)
        try await m.watch(b.viewer("2"), id: id, mode: .off); let pausedOnly = await s.preview; XCTAssertFalse(pausedOnly); await m.closeAll()
    }
    func testClosedViewerIsForgotten() async throws { let (m, s, _, _, _) = make(); try await m.watch(BackendAppDeviceTestPortView().viewer("7"), id: id, mode: .on); await m.forgetViewer("7"); let preview = await s.preview; XCTAssertFalse(preview); await m.closeAll() }
    func testDeviceGonePublishesOneCloseEventWithExactReason() async throws {
        let (m, s, _, signal, _) = make(); try await m.watch(BackendAppDeviceTestPortView().viewer(), id: id, mode: .on); var iterator = m.events.makeAsyncIterator(); await s.disconnect("The simulator engine stopped."); await signal.when(1)
        if case .some(.closed(let id, let reason)) = await iterator.next() { XCTAssertEqual(id + ": " + reason, "ios:TEST: The simulator engine stopped.") } else { XCTFail("Expected close notification") }; await m.closeAll()
    }
    func testScreenshotWritesExactBytesUnderDeviceName() async throws {
        let (m, _, _, _, images) = make(); let shot = try await m.screenshot(id)
        XCTAssertTrue(shot.path.hasPrefix("/fixture/pictures")); XCTAssertNotNil(shot.path.range(of: #"iPhone-17-Pro-\d{8}-\d{6}\.png$"#, options: .regularExpression)); XCTAssertEqual(String(decoding: try XCTUnwrap(images.read(shot.path)), as: UTF8.self), "png"); await m.closeAll()
    }
    private var round: NativeRPCValue { BackendAppSessionTestPortObject([("id", .string("round-1")), ("createdAt", .number(0)), ("where", BackendAppSessionTestPortObject([("kind", .string("device")), ("place", .string("iOS Simulator")), ("name", .string("iPhone 17 Pro"))])), ("frame", BackendAppSessionTestPortObject([("width", .number(1)), ("height", .number(1))])), ("annotations", .array([])), ("note", .string("Hi"))]) }
    func testMarkedPictureSavedAndRoundReadBackWithSentTo() async throws {
        let (m, _, _, _, _) = make(); let saved = try await m.saveRound(png: .string(png), round: round); XCTAssertTrue(saved["path"].string?.hasSuffix("-annotated.png") == true); XCTAssertEqual(saved["width"].number, 1)
        let before = await m.annotationRounds(); XCTAssertEqual(before.first?["picture"]["path"], saved["path"]); await m.markSent("round-1", sessionID: "s1", label: "shop · Session 1"); let after = await m.annotationRounds(); XCTAssertEqual(after[0]["sentTo"]["label"].string, "shop · Session 1"); XCTAssertEqual(after.count, 1); await m.closeAll()
    }
    func testInvalidPictureSavesNothing() async throws {
        let (m, _, _, _, _) = make(); do { _ = try await m.saveRound(png: .string("data:image/png;base64,bm90IGEgcG5n"), round: round); XCTFail("Expected PNG refusal") } catch { XCTAssertTrue(error.localizedDescription.contains("could not be read")) }; let rounds = await m.annotationRounds(); XCTAssertEqual(rounds.count, 0); await m.closeAll()
    }
    func testNewestTwentyRoundsRetained() async throws { let (m, _, _, _, _) = make(); for i in 0..<25 { _ = try await m.saveRound(png: .string(png), round: round.setting("id", .string("r\(i)"))) }; let rows = await m.annotationRounds(); XCTAssertEqual(rows.count, 20); XCTAssertEqual(rows[0]["id"].string, "r24"); await m.closeAll() }
    func testScreenWordsAndFilenameExact() {
        XCTAssertEqual(BackendAppDeviceManager.place(platform: "ios", kind: "simulator"), "iOS Simulator"); XCTAssertEqual(BackendAppDeviceManager.place(platform: "android", kind: "emulator"), "Android emulator"); XCTAssertEqual(BackendAppDeviceManager.place(platform: "android", kind: "physical"), "Android phone")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; let date = calendar.date(from: .init(year: 2026, month: 10, day: 3, hour: 1, minute: 2, second: 3))!
        XCTAssertEqual(BackendAppDeviceManager.pictureName("../../etc/passwd", now: date, calendar: calendar), "etc-passwd-20261003-010203")
    }
}
