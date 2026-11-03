import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// 18 Oct (#54, #434): a session switched to another account keeps its natural place in the side list (never a
/// pinned row number), and the conversation's records go when its last session closes.
@MainActor
final class SessionRailSwitchPlaceTests: XCTestCase {
    private func state(_ ids: [String]) -> SidebarState {
        .init(groups: [.init(id: "sessions", title: nil, items: ids.map { .init(id: $0, title: $0, kind: .session, status: "working") })],
              projects: [], selectedId: nil)
    }
    private func order(_ rail: NativeSessionRailContinuity, _ ids: [String], started: [String: Double]) -> [String] {
        rail.project(SIDEBARLayout.running(state(ids), started: rail.started(started))).map { rail.identity($0.id) }
    }

    func testASwitchedSessionKeepsItsPlaceAsOthersComeAndGo() {
        let rail = NativeSessionRailContinuity()
        rail.keepPlace("s", startedAt: 20)
        rail.carry("s", to: "s2")
        // Newest first: the replacement started last (90) but sorts at its conversation's first start (20).
        XCTAssertEqual(order(rail, ["a", "s2", "b"], started: ["a": 10, "s2": 90, "b": 30]), ["b", "s", "a"])
        // Two sessions start and b closes: it stays between the newer and the older ones, not at row 1.
        XCTAssertEqual(order(rail, ["a", "s2", "n1", "n2"], started: ["a": 10, "s2": 90, "n1": 40, "n2": 50]), ["n2", "n1", "s", "a"])
        // A second switch keeps the first start.
        rail.keepPlace("s2", startedAt: 90); rail.carry("s2", to: "s3"); rail.removed("s2")
        XCTAssertEqual(rail.started(["s3": 120])["s3"], 20)
    }

    func testTheConversationsRecordsGoWithItsLastSession() {
        let rail = NativeSessionRailContinuity()
        rail.keepPlace("s", startedAt: 20); rail.renamed("s", title: "Mine")
        rail.carry("s", to: "s2")
        rail.removed("s")
        XCTAssertEqual(rail.title("s2"), "Mine"); XCTAssertEqual(rail.since["s"], 20)
        rail.removed("s2")
        XCTAssertTrue(rail.aliases.isEmpty); XCTAssertTrue(rail.titles.isEmpty); XCTAssertTrue(rail.since.isEmpty)
        XCTAssertEqual(rail.identity("s2"), "s2")
    }
}
