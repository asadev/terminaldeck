import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeAccountPortStoreTests: XCTestCase {
    func testUnnarrowedSharesEveryLoginAndHasNoRow() async {
        let trust = BackendRemoteTrustStore(directory: BackendRemoteServeAccountPortFixture.root())
        let grant = await trust.remoteServeAccountGrant("device-a"), rows = await trust.remoteServeAccountGrants()
        let shares = await trust.accountAllowed("device-a", account: "system"), any = await trust.hasAnyAccount("device-a")
        XCTAssertNil(grant); XCTAssertEqual(rows, []); XCTAssertTrue(shares); XCTAssertTrue(any)
    }
    func testSelectedRetainsTickOrderAndComparesOpaqueIDsExactly() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            try await trust.remoteServeSetAccountGrants("device-a", mode: .string("selected"), accounts: [.string("p-work"), .string("system")])
            let row = await trust.remoteServeAccountGrant("device-a")
            XCTAssertEqual(row?.wireValue, .object([.init("deviceId", .string("device-a")), .init("mode", .string("selected")), .init("accounts", .array([.string("p-work"), .string("system")]))]))
            let given = await trust.accountAllowed("device-a", account: "p-work"), other = await trust.accountAllowed("device-a", account: "system:codex")
            XCTAssertTrue(given); XCTAssertFalse(other)
        }
    }
    func testForgetRestoresAbsenceAndSecondForgetDoesNothing() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            try await trust.remoteServeSetAccountGrants("device-a", mode: .string("selected"), accounts: [.string("system")])
            let first = try await trust.remoteServeForgetAccountGrants("device-a"), row = await trust.remoteServeAccountGrant("device-a"), second = try await trust.remoteServeForgetAccountGrants("device-a")
            XCTAssertTrue(first); XCTAssertNil(row); XCTAssertFalse(second)
        }
    }
    func testDropDeletedAccountAcrossDevicesNeverWidensSelectedOrAll() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            try await trust.remoteServeSetAccountGrants("device-a", mode: .string("selected"), accounts: [.string("system"), .string("p-gone")])
            try await trust.remoteServeSetAccountGrants("device-b", mode: .string("selected"), accounts: [.string("p-gone")])
            try await trust.remoteServeSetAccountGrants("device-c", mode: .string("all"), accounts: [])
            let changed = try await trust.remoteServeDropAccount("p-gone")
            let a = await trust.remoteServeAccountGrant("device-a"), b = await trust.remoteServeAccountGrant("device-b"), c = await trust.remoteServeAccountGrant("device-c"), any = await trust.hasAnyAccount("device-b")
            XCTAssertTrue(changed); XCTAssertEqual(a?.accounts, ["system"]); XCTAssertEqual(b?.accounts, []); XCTAssertFalse(any)
            XCTAssertEqual(c?.wireValue["mode"], .string("all")); XCTAssertEqual(c?.accounts, [])
            let again = try await trust.remoteServeDropAccount("p-gone"); XCTAssertFalse(again)
        }
    }
}
