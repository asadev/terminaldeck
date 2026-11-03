import XCTest
import Foundation
@testable import TerminalDeckBackend

final class BackendRemoteServeHostPortSecretTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("td-secret-port-" + UUID().uuidString) }
    func testExactBytes0600File0700FolderAndNoLeftoverTemporaryFile() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("nested"), file = directory.appendingPathComponent("machines.json")
        try BackendRemoteServeSecretFile.write(directory: directory, file: file, contents: Data(#"{"version":1}"#.utf8))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), #"{"version":1}"#)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["machines.json"])
    }
    func testMacWriteNeedsNoProcessAndProtectExistingIsAlwaysANoop() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("auth.json"), missing = root.appendingPathComponent("missing.json")
        try BackendRemoteServeSecretFile.write(directory: root, file: file, contents: Data("{}".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        BackendRemoteServeSecretFile.protectExisting(directory: root, file: missing)
        BackendRemoteServeSecretFile.protectExisting(directory: root, file: file)
        BackendRemoteServeSecretFile.protectExisting(directory: root, file: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "{}")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }
    func testSecondWriteReplacesRatherThanAppending() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("host.json")
        try BackendRemoteServeSecretFile.write(directory: root, file: file, contents: Data("first".utf8))
        try BackendRemoteServeSecretFile.write(directory: root, file: file, contents: Data("second".utf8))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "second")
    }
    func testFailureLeavesNoTemporarySecretAndCannotReplaceDirectory() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BackendRemoteServeSecretFile.write(directory: root, file: destination, contents: Data("secret".utf8)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["auth.json"])
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)); XCTAssertTrue(isDirectory.boolValue)
    }
    func testDestinationSymlinkDoesNotWriteThroughToAnotherFile() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let victim = root.appendingPathComponent("victim"), destination = root.appendingPathComponent("auth.json")
        try Data("keep this".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: victim)
        try BackendRemoteServeSecretFile.write(directory: root, file: destination, contents: Data("new secret".utf8))
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "keep this")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new secret")
    }
    /// Positive controls for the original source sweep. Native writer routing
    /// requires the separate authoritative native writer manifest in the map.
    func testSourceWriterSweepPatternNoticesRawWritesAndIgnoresSharedWriter() throws {
        let pattern = try NSRegularExpression(pattern: #"\b(writeFileSync|appendFileSync|createWriteStream|openSync|writeFile)\s*\("#)
        func notices(_ text: String) -> Bool { pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        XCTAssertTrue(notices("    writeFileSync(this.file, JSON.stringify(state))"))
        XCTAssertTrue(notices(#"const fd = openSync(tmp, "wx", 0o600)"#))
        XCTAssertFalse(notices("writeSecretFile(this.dir, this.file, body)"))
    }
}
