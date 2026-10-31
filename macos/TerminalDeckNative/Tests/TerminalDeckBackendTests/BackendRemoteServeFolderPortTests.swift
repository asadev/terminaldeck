import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendRemoteServeFolderPortTests: XCTestCase {
    func testUnchosenIsNilAndAbsentFromList() async {
        let trust = BackendRemoteTrustStore(directory: BackendRemoteServeAccountPortFixture.root())
        let folders = await trust.grantedFolders("device-a"), rows = await trust.remoteServeFolderGrants()
        XCTAssertNil(folders); XCTAssertEqual(rows, .array([]))
    }
    func testChosenOrderCopiesAndDevicesAreIndependent() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            let beta = "/Users/apple/Projects/beta", alpha = "/Users/apple/Projects/alpha"
            try await trust.remoteServeSetFolderGrants("device-a", folders: [.string(beta), .string(alpha)])
            try await trust.remoteServeSetFolderGrants("device-b", folders: [.string(alpha)])
            var copy = await trust.grantedFolders("device-a"); copy?.append("/etc")
            let a = await trust.grantedFolders("device-a"), b = await trust.grantedFolders("device-b")
            XCTAssertEqual(a, [beta, alpha]); XCTAssertEqual(b, [alpha])
        }
    }
    func testForgetRemovesDeviceRowAndIsIdempotent() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, _ in
            try await trust.remoteServeSetFolderGrants("device-a", folders: [.string("/Users/apple/Projects/alpha")])
            let first = try await trust.remoteServeForgetFolderGrants("device-a"), row = await trust.grantedFolders("device-a"), second = try await trust.remoteServeForgetFolderGrants("device-a")
            XCTAssertTrue(first); XCTAssertNil(row); XCTAssertFalse(second)
        }
    }
    func testReloadPersistsChosenAndEmptyListsWithExactSchemaAndPermissions() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, root in
            try await trust.remoteServeSetFolderGrants("device-a", folders: [.string("/Users/apple/Projects/alpha")])
            let file = root.appendingPathComponent("remote-folders.json"), raw = try NativeRPCValue.parseJSON(Data(contentsOf: file))
            XCTAssertEqual(raw, .object([.init("version", .number(1)), .init("devices", .object([.init("device-a", .array([.string("/Users/apple/Projects/alpha")]))]))]))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try await trust.remoteServeReloadDomainGrants()
            let chosen = await trust.grantedFolders("device-a"); XCTAssertEqual(chosen, ["/Users/apple/Projects/alpha"])
            try await trust.remoteServeSetFolderGrants("device-a", folders: []); try await trust.remoteServeReloadDomainGrants()
            let empty = await trust.grantedFolders("device-a"); XCTAssertEqual(empty, [])
        }
    }
    func testMacCleaningAbsolutePathsDedupeAndCase() {
        XCTAssertEqual(BackendRemoteServeSessionPolicy.cleanFolders([.string("Projects/alpha"), .string(""), .string("   "), .number(42), .null, .string("/Users/apple/Projects/alpha")]), ["/Users/apple/Projects/alpha"])
        XCTAssertEqual(BackendRemoteServeSessionPolicy.cleanFolders([.string("/Users/apple/Projects/alpha"), .string("/Users/apple/Projects/alpha/")]), ["/Users/apple/Projects/alpha"])
        XCTAssertEqual(BackendRemoteServeSessionPolicy.cleanFolders([.string("/Users/apple/Projects/Alpha"), .string("/Users/apple/Projects/alpha")]).count, 2)
    }
    func testCorruptFileBecomesAbsenceAndNextWriteRepairsIt() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, root in
            let file = root.appendingPathComponent("remote-folders.json")
            try Data("{ this is not json".utf8).write(to: file); try await trust.remoteServeReloadDomainGrants()
            let missing = await trust.grantedFolders("device-a"); XCTAssertNil(missing)
            try await trust.remoteServeSetFolderGrants("device-a", folders: [.string("/Users/apple/Projects/alpha")]); try await trust.remoteServeReloadDomainGrants()
            let repaired = await trust.grantedFolders("device-a"); XCTAssertEqual(repaired, ["/Users/apple/Projects/alpha"])
        }
    }
    func testEditedFileIsRecleaned() async throws {
        try await BackendRemoteServeAccountPortFixture.withTrust { trust, root in
            try Data(#"{"version":1,"devices":{"device-a":["nope","/Users/apple/Projects/alpha"]}}"#.utf8).write(to: root.appendingPathComponent("remote-folders.json"))
            try await trust.remoteServeReloadDomainGrants(); let chosen = await trust.grantedFolders("device-a")
            XCTAssertEqual(chosen, ["/Users/apple/Projects/alpha"])
        }
    }
}
