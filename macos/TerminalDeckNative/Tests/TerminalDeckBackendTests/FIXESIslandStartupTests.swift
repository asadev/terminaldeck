import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor private final class FIXESIslandStubSurface: BackendHootIslandSurface {
    let ownerID = "island-stub"
    var destroyed = false, focused = false, bounds = CGRect.zero
    var snapshots: [NativeRPCValue] = []
    var snapshotReadyWhenShown = false
    func setBounds(_ bounds: CGRect) { self.bounds = bounds }
    func showInactive() { snapshotReadyWhenShown = !snapshots.isEmpty } // Stub only; no AppKit window can be shown.
    func focus() { focused = true }
    func blur() { focused = false }
    func destroy() { destroyed = true }
    func ignoreMouseEvents(_ ignore: Bool) { }
    func send(_ channel: String, arguments: [NativeRPCValue]) { if channel == "hoot-panel:snapshot", let first = arguments.first { snapshots.append(first) } }
    func menu(_ actions: [BackendHootMenuAction]) { }
    func on(_ event: String, action: @escaping @MainActor () -> Void) { }
}
@MainActor private final class FIXESIslandStubCatcher: BackendHootCatcherSurface {
    let ownerID = "catcher-stub"
    var destroyed = false
    var bounds = CGRect.zero, ignoring = false
    func setBounds(_ bounds: CGRect) { self.bounds = bounds }
    func showInactive() { }
    func ignoreMouseEvents(_ ignore: Bool) { ignoring = ignore }
    func destroy() { destroyed = true }
}
@MainActor private final class FIXESIslandStubCancel: BackendHootCancellation { func cancel() { } }

final class FIXESIslandStartupTests: XCTestCase {
    @MainActor func testFirstSnapshotArrivesWithoutSessionEventOrStartingHoot() throws {
        let surface = FIXESIslandStubSurface(), catcher = FIXESIslandStubCatcher()
        var starts = 0, theme = "light"
        let bar = BackendHootMenuBar(.init(makeIsland: { surface }, makeCatcher: { catcher },
            place: { .init(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), barHeight: 24) },
            read: { _ in .missing }, write: { _ in }, hoot: { .init(status: "stopped", cwd: "/stub") },
            startHoot: { starts += 1; return nil }, say: { _, _ in XCTFail("A startup snapshot sent an AI message") },
            watchChat: { _, _, _ in XCTFail("Stopped Hoot started a transcript reader"); return FIXESIslandStubCancel() },
            sessions: { [] }, isHoot: { _ in false }, showSession: { _ in }, openApp: { _ in }, appearance: { theme },
            schedule: { _, _ in FIXESIslandStubCancel() }))
        try bar.apply()
        let initial = try XCTUnwrap(surface.snapshots.first)
        XCTAssertEqual(initial["hoot"]["status"].string, "stopped")
        XCTAssertEqual(initial["appearance"].string, "light")
        XCTAssertEqual(initial["expanded"].bool, false)
        XCTAssertEqual(starts, 0); XCTAssertFalse(surface.focused)
        XCTAssertTrue(surface.snapshotReadyWhenShown)
        theme = "dark"; bar.themeChanged()
        XCTAssertEqual(surface.snapshots.last?["appearance"].string, "dark")
        bar.dispose()
    }
    @MainActor func testQuietHideDisablesTheCatcherAndWidthChangeUsesSamePillGeometry() throws {
        let surface = FIXESIslandStubSurface(), catcher = FIXESIslandStubCatcher()
        var options = FIXESIslandOptions(whenQuiet: .hide), sessions: [IslandSessionRow] = []
        var settings: [String: NativeRPCValue] = [BackendHootMenuBar.widthKey: .number(900), BackendHootMenuBar.heightKey: .number(400)]
        let bar = BackendHootMenuBar(.init(makeIsland: { surface }, makeCatcher: { catcher },
            place: { .init(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), barHeight: 24) },
            read: { settings[$0] ?? .missing }, write: { patch in for field in patch.fields ?? [] { settings[field.key] = field.value } },
            hoot: { .init(status: "stopped", cwd: "/stub") }, startHoot: { XCTFail("No AI starts"); return nil }, say: { _, _ in XCTFail("No AI sends") },
            watchChat: { _, _, _ in XCTFail("No reader starts"); return FIXESIslandStubCancel() }, sessions: { sessions }, isHoot: { _ in false },
            showSession: { _ in }, openApp: { _ in }, appearance: { "light" }, presentation: { options }, schedule: { _, _ in FIXESIslandStubCancel() }))
        try bar.apply()
        XCTAssertTrue(catcher.ignoring); XCTAssertEqual(catcher.bounds.width, 352) // the chosen width applies at rest too (Asad, 10 Oct); XCTAssertEqual(catcher.bounds.height, 26)
        bar.event("hoot-panel:catch", owner: catcher.ownerID, argument: .string("press"))
        XCTAssertEqual(bar.snapshot()["expanded"].bool, false)
        sessions = [.init(id: "stub-session", label: "Commander", status: "working")]
        options.width = .wide; try bar.useWidthPreset(); bar.displaysChanged()
        XCTAssertFalse(catcher.ignoring); XCTAssertEqual(catcher.bounds.width, 432)
        XCTAssertEqual(bar.rememberedSize(), CGSize(width: 520, height: 400)); XCTAssertEqual(bar.snapshot()["quiet"].bool, false)
        bar.dispose()
    }
    @MainActor func testHeadlessHootBusyIsActiveWithoutAnyOtherSessions() throws {
        let surface = FIXESIslandStubSurface(), catcher = FIXESIslandStubCatcher()
        var busy = true
        let bar = BackendHootMenuBar(.init(makeIsland: { surface }, makeCatcher: { catcher },
            place: { .init(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), barHeight: 24) },
            read: { _ in .missing }, write: { _ in }, hoot: { .init(status: "running", sessionID: "stub-hoot", cwd: "/stub") },
            startHoot: { XCTFail("No AI starts"); return nil }, say: { _, _ in XCTFail("No AI sends") },
            watchChat: { _, _, _ in XCTFail("No reader starts"); return FIXESIslandStubCancel() }, sessions: { [] }, isHoot: { _ in false },
            showSession: { _ in }, openApp: { _ in }, appearance: { "light" }, presentation: { .init(whenQuiet: .hide) },
            hootBusy: { busy }, schedule: { _, _ in FIXESIslandStubCancel() }))
        try bar.apply()
        XCTAssertEqual(surface.snapshots.first?["hoot"]["busy"].bool, true)
        XCTAssertEqual(surface.snapshots.first?["quiet"].bool, false)
        XCTAssertEqual(surface.snapshots.first?["label"]["text"].string, "Hoot is working")
        XCTAssertFalse(catcher.ignoring); XCTAssertEqual(catcher.bounds.width, 352)
        busy = false; bar.forward(BackendHootChatChannels.event, arguments: [.object([])])
        XCTAssertEqual(surface.snapshots.last?["quiet"].bool, true); XCTAssertTrue(catcher.ignoring)
        bar.dispose()
    }
    @MainActor func testReenableRefreshesHootAfterEventsWhileHidden() throws {
        var surfaces: [FIXESIslandStubSurface] = []
        var settings: [String: NativeRPCValue] = [:]
        var state = BackendHootMenuSessionState(status: "running", sessionID: "stub-hoot", cwd: "/stub")
        let bar = BackendHootMenuBar(.init(makeIsland: {
            let surface = FIXESIslandStubSurface(); surfaces.append(surface); return surface
        }, makeCatcher: { FIXESIslandStubCatcher() },
            place: { .init(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), barHeight: 24) },
            read: { settings[$0] ?? .missing }, write: { patch in for field in patch.fields ?? [] { settings[field.key] = field.value } },
            hoot: { state }, startHoot: { XCTFail("No AI starts"); return nil }, say: { _, _ in XCTFail("No AI sends") },
            watchChat: { _, _, _ in XCTFail("No reader starts"); return FIXESIslandStubCancel() }, sessions: { [] }, isHoot: { _ in false },
            showSession: { _ in }, openApp: { _ in }, appearance: { "light" }, schedule: { _, _ in FIXESIslandStubCancel() }))
        try bar.apply(); XCTAssertEqual(surfaces[0].snapshots.first?["hoot"]["status"].string, "running")
        _ = try bar.configure(.object([.init("enabled", .bool(false))]))
        state = .init(status: "stopped", cwd: "/stub")
        bar.forward("session:exit", arguments: [])
        _ = try bar.configure(.object([.init("enabled", .bool(true))]))
        XCTAssertEqual(surfaces.count, 2); XCTAssertEqual(surfaces[1].snapshots.first?["hoot"]["status"].string, "stopped")
        XCTAssertTrue(surfaces[1].snapshotReadyWhenShown)
        bar.dispose()
    }
}
