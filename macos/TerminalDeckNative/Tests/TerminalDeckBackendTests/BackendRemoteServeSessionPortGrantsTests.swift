import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeSessionPortGrantsTests: XCTestCase {
    func testAbsentSelectedAndAllHaveExactDistinctRowsAndSharing() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            let absent = await trust.remoteServeSessionGrant("device-a"), rows = await trust.remoteServeSessionGrants(), open = await trust.sessionShared("device-a", session: "sess-1")
            XCTAssertNil(absent); XCTAssertEqual(rows, []); XCTAssertTrue(open)
            try await trust.remoteServeSetSessionGrants("device-a", mode: .string("selected"), sessions: [.string("sess-2"), .string("sess-1")])
            let chosen = await trust.remoteServeSessionGrant("device-a"), first = await trust.sessionShared("device-a", session: "sess-1"), other = await trust.sessionShared("device-a", session: "sess-3")
            XCTAssertEqual(chosen?.sessions, ["sess-2", "sess-1"]); XCTAssertTrue(first); XCTAssertFalse(other)
            try await trust.remoteServeSetSessionGrants("device-a", mode: .string("selected"), sessions: [])
            let none = await trust.sessionShared("device-a", session: "sess-1"), empty = await trust.remoteServeSessionGrant("device-a")
            XCTAssertFalse(none); XCTAssertEqual(empty?.sessions, []); XCTAssertFalse(empty?.all == true)
            try await trust.remoteServeSetSessionGrants("device-a", mode: .string("all"), sessions: [.string("sess-1")])
            let all = await trust.remoteServeSessionGrant("device-a"), future = await trust.sessionShared("device-a", session: "sess-9")
            XCTAssertTrue(all?.all == true); XCTAssertEqual(all?.sessions, []); XCTAssertTrue(future)
        }
    }
    func testOneDevicesChoiceDoesNotNarrowAnother() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            try await trust.remoteServeSetSessionGrants("device-a", mode: .string("selected"), sessions: [.string("sess-1")])
            let bOpen = await trust.sessionShared("device-b", session: "sess-1"); XCTAssertTrue(bOpen)
            try await trust.remoteServeSetSessionGrants("device-b", mode: .string("selected"), sessions: [])
            let b = await trust.sessionShared("device-b", session: "sess-1"), a = await trust.sessionShared("device-a", session: "sess-1")
            XCTAssertFalse(b); XCTAssertTrue(a)
        }
    }
    func testRestartForgetAndSecretFileSchema() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, root in
            try await trust.remoteServeSetSessionGrants("device-a", mode: .string("selected"), sessions: [.string("sess-1")])
            let file = root.appendingPathComponent("remote-sessions.json"), raw = try NativeRPCValue.parseJSON(Data(contentsOf: file))
            XCTAssertEqual(raw, .object([.init("version", .number(1)), .init("devices", .object([.init("device-a", .object([.init("mode", .string("selected")), .init("sessions", .array([.string("sess-1")]))]))]))]))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try await trust.remoteServeReloadDomainGrants()
            let one = await trust.sessionShared("device-a", session: "sess-1"), two = await trust.sessionShared("device-a", session: "sess-2")
            XCTAssertTrue(one); XCTAssertFalse(two)
            let forgotten = try await trust.remoteServeForgetSessionGrants("device-a"), row = await trust.remoteServeSessionGrant("device-a")
            XCTAssertTrue(forgotten); XCTAssertNil(row); try await trust.remoteServeReloadDomainGrants()
            let remaining = await trust.remoteServeSessionGrants(); XCTAssertEqual(remaining, [])
        }
    }
    func testDropEndedTickAndCleanInvalidIDsWithoutWidening() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            try await trust.remoteServeSetSessionGrants("device-a", mode: .string("selected"), sessions: [.string("sess-1"), .string("sess-2"), .string(""), .string("  "), .number(7), .null, .string("sess-1"), .string(String(repeating: "x", count: 200))])
            let clean = await trust.remoteServeSessionGrant("device-a"); XCTAssertEqual(clean?.sessions, ["sess-1", "sess-2"])
            let dropped = try await trust.remoteServeDropSession("sess-1"), row = await trust.remoteServeSessionGrant("device-a"), allowed = await trust.sessionShared("device-a", session: "sess-1")
            XCTAssertTrue(dropped); XCTAssertEqual(row?.sessions, ["sess-2"]); XCTAssertFalse(allowed)
        }
    }
    func testUnknownModeNarrowsToSelectedOnReload() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, root in
            try Data(#"{"version":1,"devices":{"device-a":{"mode":"everything","sessions":["sess-1"]}}}"#.utf8).write(to: root.appendingPathComponent("remote-sessions.json"))
            try await trust.remoteServeReloadDomainGrants()
            let one = await trust.sessionShared("device-a", session: "sess-1"), two = await trust.sessionShared("device-a", session: "sess-2")
            XCTAssertTrue(one); XCTAssertFalse(two)
        }
    }
    func testIncludeOnlyTicksRequestingSelectedDeviceAndIsIdempotent() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            let absent = try await trust.remoteServeIncludeStartedSession("guest", sessionID: "sess-new"); XCTAssertFalse(absent)
            try await trust.remoteServeSetSessionGrants("guest", mode: .string("all"), sessions: [])
            let all = try await trust.remoteServeIncludeStartedSession("guest", sessionID: "sess-new"); XCTAssertFalse(all)
            try await trust.remoteServeSetSessionGrants("guest", mode: .string("selected"), sessions: [])
            try await trust.remoteServeSetSessionGrants("other", mode: .string("selected"), sessions: [])
            let included = try await trust.remoteServeIncludeStartedSession("guest", sessionID: "sess-new"), repeated = try await trust.remoteServeIncludeStartedSession("guest", sessionID: "sess-new")
            let own = await trust.sessionShared("guest", session: "sess-new"), other = await trust.sessionShared("other", session: "sess-new"), third = await trust.sessionShared("guest", session: "sess-2")
            XCTAssertTrue(included); XCTAssertFalse(repeated); XCTAssertTrue(own); XCTAssertFalse(other); XCTAssertFalse(third)
        }
    }
    func testFolderAndSessionAxesNarrowCurrentViewsIncludingOwner() throws {
        let row = try BackendRemoteServeAccountPortFixture.meta(id: "sess-private", cwd: "/tmp/private")
        XCTAssertFalse(BackendRemoteServeSessionPolicy.visible(deviceID: "guest", session: row, hidden: nil, reach: { _ in (false, ["/tmp/shared"]) }, shared: { _, _ in true }))
        XCTAssertFalse(BackendRemoteServeSessionPolicy.visible(deviceID: "owner", session: row, hidden: nil, reach: { _ in (true, []) }, shared: { _, _ in false }))
        XCTAssertFalse(BackendRemoteServeSessionPolicy.visible(deviceID: "guest", session: row, hidden: nil, reach: { _ in throw Failure.rule }, shared: nil))
        XCTAssertFalse(BackendRemoteServeSessionPolicy.visible(deviceID: "guest", session: row, hidden: nil, reach: nil, shared: { _, _ in throw Failure.rule }))
        XCTAssertTrue(BackendRemoteServeSessionPolicy.visible(deviceID: "guest", session: row, hidden: nil, reach: { _ in (false, ["/tmp/private"]) }, shared: nil))
    }
    private enum Failure: Error { case rule }
}
