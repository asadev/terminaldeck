import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeFolderPortCreateTests: XCTestCase {
    func testRealGrantReachAllowsOnlyTheRequestingPhonesChosenFolder() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            let spawn = Spawn(), creator = Self.creator(trust, spawn)
            try await trust.remoteServeSetFolderGrants("phone", folders: [.string("/Users/apple/Projects/alpha")])
            try await trust.remoteServeSetFolderGrants("tablet", folders: [.string("/Users/apple/Projects/beta")])
            let allowed = await creator.create(.init(deviceID: "phone", cwd: "/Users/apple/Projects/alpha"))
            let other = await creator.create(.init(deviceID: "phone", cwd: "/Users/apple/Projects/beta"))
            XCTAssertNotNil(allowed.session); XCTAssertNil(other.session); XCTAssertEqual(try other.message().value["code"], .string("unauthorized"))
            let inputs = await spawn.inputs(); XCTAssertEqual(inputs.map(\.cwd), ["/Users/apple/Projects/alpha"])
        }
    }
    func testTakingFolderAwayChangesTheVeryNextTapWithoutReconnect() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            let spawn = Spawn(), creator = Self.creator(trust, spawn)
            try await trust.remoteServeSetFolderGrants("phone", folders: [.string("/Users/apple/Projects/alpha"), .string("/Users/apple/Projects/beta")])
            let before = await creator.create(.init(deviceID: "phone", cwd: "/Users/apple/Projects/beta")); XCTAssertNotNil(before.session)
            try await trust.remoteServeSetFolderGrants("phone", folders: [.string("/Users/apple/Projects/alpha")])
            let after = await creator.create(.init(deviceID: "phone", cwd: "/Users/apple/Projects/beta")); XCTAssertNil(after.session)
            let inputs = await spawn.inputs(); XCTAssertEqual(inputs.count, 1)
        }
    }
    func testUnchosenAndExplicitlyEmptyPhoneStartNothing() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            let spawn = Spawn(), creator = Self.creator(trust, spawn)
            let unchosen = await creator.create(.init(deviceID: "phone-that-predates-grants", cwd: "/Users/apple/Projects/whatever-is-open")); XCTAssertNil(unchosen.session)
            try await trust.remoteServeSetFolderGrants("phone", folders: [])
            let named = await creator.create(.init(deviceID: "phone", cwd: "/Users/apple/Projects/alpha")), absent = await creator.create(.init(deviceID: "phone"))
            XCTAssertNil(named.session); XCTAssertNil(absent.session)
            let inputs = await spawn.inputs(); XCTAssertEqual(inputs.count, 0)
        }
    }
    private static func creator(_ trust: BackendRemoteTrustStore, _ spawn: Spawn) -> BackendRemoteServeSessionCreate {
        .init(folders: { device in await trust.reach(device, offered: ["/Users/apple/Projects/whatever-is-open"], home: "/Users/apple").folders }, spawn: { try await spawn.create($0) })
    }
    private actor Spawn {
        var requested: [BackendRemoteCreateRequest] = []
        func create(_ input: BackendRemoteCreateRequest) throws -> BackendSessionMeta { requested.append(input); return try BackendRemoteServeAccountPortFixture.meta(cwd: input.cwd) }
        func inputs() -> [BackendRemoteCreateRequest] { requested }
    }
}
