import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeAccountPortReloadTests: XCTestCase {
    func testMalformedModeNarrowsToOnlyTheParsedSystemID() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, root in
            try Data(#"{"version":1,"devices":{"device-a":{"mode":"everything","accounts":["system",7]}}}"#.utf8).write(to: root.appendingPathComponent("remote-accounts.json"))
            try await trust.remoteServeReloadDomainGrants()
            let row = await trust.remoteServeAccountGrant("device-a"), system = await trust.accountAllowed("device-a", account: "system"), work = await trust.accountAllowed("device-a", account: "p-work")
            XCTAssertEqual(row?.wireValue, .object([.init("deviceId", .string("device-a")), .init("mode", .string("selected")), .init("accounts", .array([.string("system")]))]))
            XCTAssertTrue(system); XCTAssertFalse(work)
        }
    }
    func testUnreadableAccountFileMeansNoRowsAndSharesSystem() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, root in
            try Data("{ this is not json".utf8).write(to: root.appendingPathComponent("remote-accounts.json")); try await trust.remoteServeReloadDomainGrants()
            let rows = await trust.remoteServeAccountGrants(), shared = await trust.accountAllowed("device-a", account: "system")
            XCTAssertEqual(rows, []); XCTAssertTrue(shared)
        }
    }
    func testSourceCleaningFixtureKeepsOnlyWorkAndTrimmedSpacedIDs() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            let row = try await trust.remoteServeSetAccountGrants("device-a", mode: .string("selected"), accounts: [.string("p-work"), .string("p-work"), .string("   "), .number(42), .null, .string("  p-spaced  "), .string(String(repeating: "x", count: 500))])
            XCTAssertEqual(row.accounts, ["p-work", "p-spaced"])
        }
    }
}
