import Foundation
import XCTest
@testable import TerminalDeckBackend

/// String/path assertions on the actual launch fence. Kernel enforcement and
/// proof tests remain explicit gaps; strings do not establish those claims.
final class BackendFoundationTestsConfineRecords: XCTestCase {
    private func scratch() throws -> URL {
        // records.test.ts:114 `realpathSync(mkdtempSync(...))`: the kernel path the fence names.
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("foundation-records-fence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return URL(fileURLWithPath: BackendMacConfinement.kernelPath(made.path))
    }
    // records.test.ts:163
    func testUserDataParentSymlinkIsResolvedBeforeJoiningChildren() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("user-data"), link = root.appendingPathComponent("linked-user-data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: data)
        XCTAssertEqual(BackendMacConfinement.recordsFencePaths(link), BackendMacConfinement.recordsFencePaths(data))
        let fresh = root.appendingPathComponent("never-used")
        XCTAssertEqual(BackendMacConfinement.recordsFencePaths(fresh)[1], fresh.appendingPathComponent("routine-state.json").path)
    }
    // records.test.ts:183. Despite the historical title saying five, TS
    // actually expects seven paths and seven deny rules; preserve the code.
    func testFenceNamesExactlyTheSevenSourceRecords() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let expected = ["routines", "routine-state.json", "copilot-log", "remote/remote-device-kinds.json", "remote/remote-auth.json", "remote/access-keys.json", "plugin-grants.json"].map { root.appendingPathComponent($0).path }
        XCTAssertEqual(BackendMacConfinement.recordsFencePaths(root), expected)
        XCTAssertEqual(BackendMacConfinement.recordsFenceProfile(root).components(separatedBy: "(deny ").count - 1, 7)
    }
    // records.test.ts:217 plus the actual remote-parent symlink case.
    func testRemoteStoresResolveThroughParentEvenWhenFilesAreNew() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let fresh = root.appendingPathComponent("never-used"), paths = BackendMacConfinement.recordsFencePaths(fresh)
        XCTAssertEqual(paths[3], fresh.appendingPathComponent("remote/remote-device-kinds.json").path)
        XCTAssertEqual(paths[4], fresh.appendingPathComponent("remote/remote-auth.json").path)
        let data = root.appendingPathComponent("data"), actual = root.appendingPathComponent("real-remote")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: data.appendingPathComponent("remote"), withDestinationURL: actual)
        let linked = BackendMacConfinement.recordsFencePaths(data)
        XCTAssertEqual(linked[3], actual.appendingPathComponent("remote-device-kinds.json").path)
        XCTAssertEqual(linked[4], actual.appendingPathComponent("remote-auth.json").path)
    }
}
