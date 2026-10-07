import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendRemoteServeMachinesTestsGuest: XCTestCase {
    func testCloseIsRefusedBeforeWelcomeWithoutStartingDial() async {
        let guest = BackendRemoteServeMachinesTestsFixture.guest()
        do { try await guest.send(type: "close", fields: [.init("id", .string("s1"))], capability: "close"); XCTFail("An offline close was sent") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "machine-offline") }
        let state = await guest.state(); XCTAssertEqual(state.phase, .offline); XCTAssertEqual(state.sessions, [])
    }
    func testWindowAskRefusedOfflineInsteadOfQueued() async {
        let guest = BackendRemoteServeMachinesTestsFixture.guest()
        do { try await guest.askWindow(id: "w-9", sessionID: "s1", tool: "browser.read", arguments: "{}"); XCTFail("An offline browser ask was queued") }
        catch { XCTAssertEqual((error as? NativeRPCError)?.code, "machine-offline") }
        let state = await guest.state(); XCTAssertFalse(state.capabilities.contains("hostwindows")); XCTAssertEqual(state.phase, .offline)
    }
    func testSupplementalGuestConstructionIsInertAndNeverSaidFoldersRemainNull() async {
        let guest = BackendRemoteServeMachinesTestsFixture.guest(), state = await guest.state()
        XCTAssertEqual(state.phase, .offline); XCTAssertNil(state.reason); XCTAssertNil(state.folders)
        XCTAssertTrue(state.sessions.isEmpty); XCTAssertTrue(state.ports.isEmpty); XCTAssertEqual(state.copilot, .null)
    }
}
