import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fixture-only files, never app/home/config directories. Nothing is created
/// until a test explicitly calls this initializer at the combined gate.
final class BackendFoundationTestsBFixture {
    let root: URL
    let context = NativeRPCContext(caller: .nativeApp, ownerID: "foundation-B-fixture")
    init(_ name: String = "fixture") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendFoundationTestsB-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func file(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    func mkdir(_ relative: String) throws { try FileManager.default.createDirectory(at: file(relative), withIntermediateDirectories: true) }
    func write(_ relative: String, _ text: String) throws {
        let file = file(relative); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: file)
    }
    var authority: BackendFilesystemAuthority {
        let root = root
        return BackendFilesystemAuthority { _ in BackendFilesystemScope(readRoots: [root], writeRoots: [root]) }
    }
}
