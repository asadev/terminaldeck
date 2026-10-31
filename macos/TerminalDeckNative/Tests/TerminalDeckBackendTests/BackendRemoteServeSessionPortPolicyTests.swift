import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeSessionPortPolicyTests: XCTestCase {
    func testCurrentChoicesTakeAwayASameFolderSessionIncludingOwner() throws {
        let shared = Choice(), row = try BackendRemoteServeAccountPortFixture.meta(id: "sess-shared", cwd: "/tmp/shared")
        let check: (String) -> Bool = { device in
            BackendRemoteServeSessionPolicy.visible(deviceID: device, session: row, hidden: nil,
                reach: { id in (id == "owner", ["/tmp/shared"]) }, shared: { _, id in shared.contains(id) })
        }
        XCTAssertTrue(check("guest")); XCTAssertTrue(check("owner"))
        shared.select(["sess-other"])
        XCTAssertFalse(check("guest")); XCTAssertFalse(check("owner"))
        shared.select(["sess-shared"]); XCTAssertTrue(check("guest"))
    }
    func testMissingChoiceRuleStillEnforcesFolderAndMissingHiddenRuleHidesNothing() throws {
        let shared = try BackendRemoteServeAccountPortFixture.meta(id: "sess-shared", cwd: "/tmp/shared")
        let privateRow = try BackendRemoteServeAccountPortFixture.meta(id: "sess-private", cwd: "/tmp/private")
        XCTAssertTrue(BackendRemoteServeSessionPolicy.visible(deviceID: "guest", session: shared, hidden: nil, reach: { _ in (false, ["/tmp/shared"]) }, shared: nil))
        XCTAssertFalse(BackendRemoteServeSessionPolicy.visible(deviceID: "guest", session: privateRow, hidden: nil, reach: { _ in (false, ["/tmp/shared"]) }, shared: nil))
        XCTAssertFalse(BackendRemoteServeSessionPolicy.isHidden("s1", ask: nil))
    }
    func testCreatorTicksOnlyTheSelectedDeviceThatActuallyRequestedSpawn() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            try await trust.remoteServeSetSessionGrants("guest", mode: .string("selected"), sessions: [])
            try await trust.remoteServeSetSessionGrants("other", mode: .string("selected"), sessions: [])
            let meta = try BackendRemoteServeAccountPortFixture.meta(cwd: "/tmp/shared", provider: "shell")
            let creator = BackendRemoteServeSessionCreate(folders: { _ in ["/tmp/shared"] }, spawn: { _ in meta }, noteStarted: { device, session in
                _ = try await trust.remoteServeIncludeStartedSession(device, sessionID: session)
            })
            let result = await creator.create(.init(deviceID: "guest"))
            XCTAssertEqual(result.session?.id, "sess-new")
            let own = await trust.sessionShared("guest", session: "sess-new"), other = await trust.sessionShared("other", session: "sess-new"), old = await trust.sessionShared("guest", session: "sess-shared")
            XCTAssertTrue(own); XCTAssertFalse(other); XCTAssertFalse(old)
        }
    }
    private final class Choice: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String]?
        func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids?.contains(id) ?? true }
        func select(_ ids: [String]) { lock.lock(); defer { lock.unlock() }; self.ids = ids }
    }
}
