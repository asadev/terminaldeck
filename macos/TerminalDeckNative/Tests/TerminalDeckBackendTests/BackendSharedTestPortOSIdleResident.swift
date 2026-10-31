import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Supplemental tests of the resident presence only. This is not a complete
/// resident app-composition claim and never creates a real status item.
final class BackendSharedTestPortOSIdleResident: XCTestCase {
    @MainActor func testRepresentedOwlPublicVisibilityPartial() {
        // A represented owl needs no second status item.
        let factory = BackendGapsS3ResidentTests.Factory()
        var callbacks: [String] = []
        let presence = BackendS3FillResidentPresence(sessions: { callbacks.append("sessions"); return [.init(id: "a", provider: "claude", cwd: "/work/a"), .init(id: "b", provider: "claude", cwd: "/work/b")] },
            open: { callbacks.append("open") }, stop: { callbacks.append("stop " + $0) }, quitAll: { callbacks.append("quit") }, represented: { true }, factory: factory)
        XCTAssertFalse(presence.visible)
        presence.show(); XCTAssertTrue(presence.visible)
        presence.refresh(); XCTAssertTrue(presence.visible)
        presence.hide(); XCTAssertFalse(presence.visible)
        XCTAssertEqual(callbacks, []); XCTAssertEqual(factory.live, 0)
    }
    @MainActor func testUnshownPresencePublicVisibilityPartial() {
        // An unshown presence never asks the app-supplied factory for an icon.
        let factory = BackendGapsS3ResidentTests.Factory()
        var callbacks: [String] = []
        let presence = BackendS3FillResidentPresence(sessions: { callbacks.append("sessions"); return [.init(id: "a", provider: "claude", cwd: "/work/a"), .init(id: "b", provider: "claude", cwd: "/work/b")] },
            open: { callbacks.append("open") }, stop: { callbacks.append("stop " + $0) }, quitAll: { callbacks.append("quit") }, represented: { false }, factory: factory)
        presence.refresh(); XCTAssertFalse(presence.visible)
        presence.hide(); XCTAssertFalse(presence.visible)
        XCTAssertEqual(callbacks, []); XCTAssertEqual(factory.live, 0)
    }
}
