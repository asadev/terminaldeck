import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Supplemental tests of the provisional helpers only. This is not a complete
/// resident/idle app-composition claim and never creates a real status item.
final class BackendSharedTestPortOSIdleResident: XCTestCase {
    @MainActor private final class Part: BackendOSIdleable {
        let name: String
        let heldWhenIdle: Bool
        var log: [String] = []
        init(_ name: String, held: Bool = false) { self.name = name; heldWhenIdle = held }
        // Source sleep/wake are subsystem hooks; the fake merely records calls.
        func sleep() { log.append("sleep") }
        func wake() { log.append("wake") }
    }
    @MainActor func testIdleStartsIdle() {
        XCTAssertEqual(BackendOSIdleController().mode, "idle")
    }
    @MainActor func testIdleSleepsRegisteredPartImmediately() {
        let scanner = Part("localhost port scanning"), idle = BackendOSIdleController()
        idle.register(scanner)
        XCTAssertEqual(scanner.log, ["sleep"])
    }
    @MainActor func testIdleNeverSleepsAWayIn() {
        let relay = Part("relay connection", held: true), idle = BackendOSIdleController()
        idle.register(relay); idle.attached(1); idle.attached(0)
        XCTAssertEqual(relay.log, [])
        XCTAssertTrue(idle.report()["holding"].elements?.contains(.string("relay connection")) == true)
    }
    @MainActor func testIdleWakesFirstAttachAndSleepsLastDetach() {
        let status = Part("session status detection"), idle = BackendOSIdleController()
        idle.register(status)
        XCTAssertEqual(idle.attached(1), "awake"); XCTAssertEqual(idle.attached(0), "idle")
        XCTAssertEqual(status.log, ["sleep", "wake", "sleep"])
    }
    @MainActor func testIdleDoesNothingWhenCountsDoNotCrossZero() {
        let status = Part("session status detection"), idle = BackendOSIdleController()
        idle.register(status)
        for count in [1, 2, 3, 1] { idle.attached(count) }
        XCTAssertEqual(status.log, ["sleep", "wake"])
    }
    @MainActor func testIdleReportsExactOrderedPartsInBothModes() {
        let idle = BackendOSIdleController()
        idle.register(Part("relay connection", held: true)); idle.register(Part("session status detection")); idle.register(Part("localhost port scanning"))
        XCTAssertEqual(idle.report(), .object([
            .init("mode", .string("idle")), .init("attached", .number(0)), .init("holding", .array([.string("relay connection")])),
            .init("stopped", .array([.string("session status detection"), .string("localhost port scanning")])),
        ]))
        idle.attached(2)
        XCTAssertEqual(idle.report(), .object([
            .init("mode", .string("awake")), .init("attached", .number(2)),
            .init("holding", .array([.string("relay connection"), .string("session status detection"), .string("localhost port scanning")])), .init("stopped", .array([])),
        ]))
    }
    @MainActor func testIdleNegativeCountsAreClampedSupplement() {
        let idle = BackendOSIdleController(attached: -2)
        XCTAssertEqual(idle.report()["attached"], .number(0))
        XCTAssertEqual(idle.attached(-1), "idle")
    }
    func testQuitStopsOutrightWithNoLiveSessions() {
        for behavior in ["keep", "ask", "stop"] { XCTAssertEqual(BackendOSResidentRules.plannedQuit(liveSessions: 0, behavior: behavior), "stop") }
    }
    func testQuitAsksOnlyWhenThereIsSomethingToLose() {
        XCTAssertEqual(BackendOSResidentRules.plannedQuit(liveSessions: 1, behavior: "ask"), "ask")
        XCTAssertEqual(BackendOSResidentRules.plannedQuit(liveSessions: 4, behavior: "ask"), "ask")
    }
    func testQuitHonorsRememberedKeepAndStop() {
        XCTAssertEqual(BackendOSResidentRules.plannedQuit(liveSessions: 2, behavior: "keep"), "keep")
        XCTAssertEqual(BackendOSResidentRules.plannedQuit(liveSessions: 2, behavior: "stop"), "stop")
    }
    func testQuitEveryButtonMatchesItsLabel() {
        XCTAssertEqual(BackendOSResidentRules.quitButtons, ["Keep Them Running", "Stop Everything", "Cancel"])
        XCTAssertEqual(BackendOSResidentRules.quitAnswer(0), "keep")
        XCTAssertEqual(BackendOSResidentRules.quitAnswer(1), "stop")
        XCTAssertEqual(BackendOSResidentRules.quitAnswer(2), "cancel")
    }
    func testQuitDismissalCancelsRatherThanChoosing() {
        XCTAssertEqual(BackendOSResidentRules.quitAnswer(-1), "cancel")
        XCTAssertEqual(BackendOSResidentRules.quitAnswer(99), "cancel")
    }
    func testQuitQuestionCountsTheSessions() {
        XCTAssertEqual(BackendOSResidentRules.quitQuestion(count: 1).message, "One session is still running.")
        XCTAssertEqual(BackendOSResidentRules.quitQuestion(count: 2).message, "2 sessions are still running.")
    }
    func testQuitQuestionNamesMenuBarAndExactExplanation() {
        let detail = BackendOSResidentRules.quitQuestion(count: 1).detail
        XCTAssertTrue(detail.contains("menu bar"))
        XCTAssertEqual(detail, "Quitting has always ended them. It does not have to: Terminal Deck can keep them running on this machine with no window, and put them back — screens and all — the next time you open it.\n\nWhile they are running you will find Terminal Deck in the menu bar, which lists them and can stop any of them, or all of them, without opening a window.")
    }
    @MainActor func testRepresentedOwlPublicVisibilityPartial() {
        // represented=true keeps the current implementation on a path that
        // never accesses NSStatusBar.system. Icon allocation counts/private
        // menu shape remain unrepresentable and are not asserted here.
        var callbacks: [String] = []
        let presence = BackendOSResidentPresence(sessions: { callbacks.append("sessions"); return [.init(id: "a", provider: "claude", cwd: "/work/a"), .init(id: "b", provider: "claude", cwd: "/work/b")] },
            open: { callbacks.append("open") }, stop: { callbacks.append("stop " + $0) }, quitAll: { callbacks.append("quit") }, represented: { true })
        XCTAssertFalse(presence.visible)
        presence.show(); XCTAssertTrue(presence.visible)
        presence.refresh(); XCTAssertTrue(presence.visible)
        presence.hide(); XCTAssertFalse(presence.visible)
        XCTAssertEqual(callbacks, [])
    }
    @MainActor func testUnshownPresencePublicVisibilityPartial() {
        // Do not call show with represented=false: that would create a real
        // AppKit status item. Only the pre-show source branch is covered.
        var callbacks: [String] = []
        let presence = BackendOSResidentPresence(sessions: { callbacks.append("sessions"); return [.init(id: "a", provider: "claude", cwd: "/work/a"), .init(id: "b", provider: "claude", cwd: "/work/b")] },
            open: { callbacks.append("open") }, stop: { callbacks.append("stop " + $0) }, quitAll: { callbacks.append("quit") }, represented: { false })
        presence.refresh(); XCTAssertFalse(presence.visible)
        presence.hide(); XCTAssertFalse(presence.visible)
        XCTAssertEqual(callbacks, [])
    }
}
