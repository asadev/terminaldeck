import Foundation
import CryptoKit
import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRemoteServeMachinesTestsUpdatesCore: XCTestCase {
    private let feed = URL(string: "https://github.com/asadev/terminaldeck/releases/latest/download/latest-native-mac.yml")!
    private let archiveURL = URL(string: "https://github.com/asadev/terminaldeck/releases/download/v9.9.9/terminaldeck-native-9.9.9-arm64.zip")!
    private let identifier = "dev.terminaldeck.native.fixture"
    private let realChecksum = "HyckKuCltIQ1t6OkRtigLH/TQu4FjnfjIKMh6TVE1t+bu3PY+4gBskBRgW958alTu/wMSwurn63PfSlYRVuqfQ=="
    private func release(version: String = "9.9.9", size: Int64 = 1, checksum: String? = nil, url: URL? = nil, notes: String? = nil) -> NativeUpdateRelease {
        .init(schemaVersion: 1, channel: "native-mac", version: version, bundleIdentifier: identifier, architecture: "arm64",
            url: url ?? archiveURL, sha512: checksum ?? realChecksum, size: size, releaseDate: "2026-08-13T09:26:05.671Z", releaseNotes: notes)
    }
    private func data(_ release: NativeUpdateRelease, dropping: String? = nil, crlf: Bool = false) throws -> Data {
        let bytes = try JSONEncoder().encode(release)
        let dictionary = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let fields = try dictionary.keys.sorted().filter { $0 != dropping }.map { key -> String in
            let value = try JSONSerialization.data(withJSONObject: dictionary[key]!, options: [.fragmentsAllowed, .sortedKeys])
            return key + ": " + String(decoding: value, as: UTF8.self)
        }
        return Data((fields.joined(separator: crlf ? "\r\n" : "\n") + (crlf ? "\r\n" : "\n")).utf8)
    }
    private func decode(_ bytes: Data) throws -> NativeUpdateRelease {
        try NativeUpdateFeed.decode(bytes, feedURL: feed, bundleIdentifier: identifier, architecture: "arm64")
    }
    private func validate(_ release: NativeUpdateRelease) throws {
        try NativeUpdateFeed.validate(release, feedURL: feed, bundleIdentifier: identifier, architecture: "arm64")
    }
    func testNativeFeedReadsCRLFAndQuotedScalarValues() throws {
        let expected = release()
        XCTAssertEqual(try decode(data(expected, crlf: true)), expected)
    }
    func testChecksumSlashesPlusAndPaddingPreserved() throws {
        let decoded = try decode(data(release()))
        XCTAssertEqual(decoded.sha512, realChecksum); XCTAssertTrue(decoded.sha512.contains("/")); XCTAssertTrue(decoded.sha512.contains("+"))
        XCTAssertTrue(decoded.sha512.hasSuffix("==")); XCTAssertEqual(Data(base64Encoded: decoded.sha512)?.count, 64)
    }
    func testMissingSizeCannotBecomeUsableRelease() throws {
        XCTAssertThrowsError(try decode(data(release(), dropping: "size")))
    }
    func testPathShapedVersionCannotEscapeStaging() {
        for version in ["../../etc", "..", ""] { XCTAssertThrowsError(try validate(release(version: version))) }
    }
    func testDMGIsRefusedWithoutFallback() {
        let dmg = URL(string: "https://github.com/asadev/terminaldeck/releases/download/v9.9.9/terminaldeck-native-9.9.9-arm64.dmg")!
        XCTAssertThrowsError(try validate(release(url: dmg)))
    }
    func testNonHTTPSAssetsRefused() {
        for raw in ["http://example.com/a.zip", "file:///tmp/a.zip"] { XCTAssertThrowsError(try validate(release(url: URL(string: raw)!))) }
    }
    func testUnsafeAssetFilenameNeverBecomesZipDestination() {
        for raw in ["https://github.com/asadev/terminaldeck/releases/download/v9.9.9/terminaldeck-native.dmg",
                    "https://github.com/asadev/terminaldeck/releases/download/v9.9.9/%2E%2E%2Fescape-native.zip"] {
            XCTAssertThrowsError(try validate(release(url: URL(string: raw)!)))
        }
    }
    func testChecksumEncodingRejectsEveryNearMiss() {
        let hex = SHA512.hash(data: Data("x".utf8)).map { String(format: "%02x", $0) }.joined()
        let sha256 = Data(SHA256.hash(data: Data("x".utf8))).base64EncodedString()
        XCTAssertNoThrow(try validate(release()))
        for digest in [hex, "", "not base64!", sha256] { XCTAssertThrowsError(try validate(release(checksum: digest))) }
    }
    func testArchiveVerificationSeparatesWrongSizeWrongDigestAndCorrectBytes() throws {
        let directory = try BackendRemoteServeMachinesTestsFixture.scratch(); defer { BackendRemoteServeMachinesTestsFixture.remove(directory) }
        let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) }), archive = directory.appendingPathComponent("update.zip")
        try bytes.write(to: archive)
        let hash = Data(SHA512.hash(data: bytes)).base64EncodedString()
        XCTAssertThrowsError(try NativeUpdatePackage.verifyArchive(archive, release: release(size: Int64(bytes.count + 10), checksum: hash))) {
            XCTAssertTrue($0.localizedDescription.lowercased().contains("size"))
        }
        XCTAssertThrowsError(try NativeUpdatePackage.verifyArchive(archive, release: release(size: Int64(bytes.count), checksum: Data(SHA512.hash(data: Data("different bytes".utf8))).base64EncodedString()))) {
            XCTAssertTrue($0.localizedDescription.lowercased().contains("sha512"))
        }
        XCTAssertNoThrow(try NativeUpdatePackage.verifyArchive(archive, release: release(size: Int64(bytes.count), checksum: hash)))
    }
    private func fakeBundle(_ root: URL, executableField: String = "Fake App", executableMode: Int = 0o755) throws -> URL {
        let app = root.appendingPathComponent("Fake App.app"), binary = app.appendingPathComponent("Contents/MacOS/Fake App")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture only, never executed".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: executableMode], ofItemAtPath: binary.path)
        let info: [String: String] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": "9.9.9", "CFBundleExecutable": executableField]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }
    func testNonExecutableBundleBinaryRefusedBeforeAnyProcess() throws {
        let root = try BackendRemoteServeMachinesTestsFixture.scratch(); defer { BackendRemoteServeMachinesTestsFixture.remove(root) }
        let app = try fakeBundle(root, executableMode: 0o644)
        XCTAssertThrowsError(try NativeUpdatePackage.validateBundle(app, release: release(), executableName: "Fake App", expectedTeam: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("not executable"))
        }
        // Identity/mode guard returns before bundled-engine discovery/codesign.
    }
    func testExecutablePlistCannotPointOutsideOwnBundle() throws {
        let root = try BackendRemoteServeMachinesTestsFixture.scratch(); defer { BackendRemoteServeMachinesTestsFixture.remove(root) }
        let app = try fakeBundle(root, executableField: "../../../../bin/sh")
        XCTAssertThrowsError(try NativeUpdatePackage.validateBundle(app, release: release(), executableName: "Fake App", expectedTeam: nil)) {
            XCTAssertTrue($0.localizedDescription.contains("outside its own bundle"))
        }
        // No source fixture binary, shell or signing process is run.
    }
    private func version(_ text: String) throws -> AppVersion { try XCTUnwrap(AppVersion(text)) }
    func testVersionsOrderNumericallyRatherThanLexically() throws {
        XCTAssertGreaterThan(try version("0.2.0"), try version("0.1.0")); XCTAssertGreaterThan(try version("0.10.0"), try version("0.9.0"))
        XCTAssertEqual(try version("1.0.0"), try version("1.0.0")); XCTAssertLessThan(try version("0.1.0"), try version("0.1.1"))
    }
    func testMissingVersionSegmentMeansZero() throws {
        XCTAssertEqual(try version("1.2"), try version("1.2.0")); XCTAssertLessThan(try version("1.2"), try version("1.2.1"))
    }
    func testPrereleaseIsBeforeItsReleaseWithNumericIdentifiers() throws {
        for (a, b) in [("0.2.0-beta.1", "0.2.0"), ("0.2.0-beta.1", "0.2.0-beta.2"), ("0.2.0-beta.2", "0.2.0-beta.10"), ("0.2.0-alpha", "0.2.0-beta")] {
            XCTAssertLessThan(try version(a), try version(b))
        }
        XCTAssertGreaterThan(try version("0.2.0-beta"), try version("0.1.9"))
    }
    func testVersionLeadingVAndBuildMetadataIgnored() throws {
        XCTAssertEqual(try version("v1.2.3"), try version("1.2.3")); XCTAssertEqual(try version("1.2.3+build.9"), try version("1.2.3"))
    }
    func testSupplementalNativeFeedPinsAppArchitectureAndRepository() {
        let foreign = URL(string: "https://github.com/somebody/another/releases/download/v9.9.9/other-native.zip")!
        XCTAssertThrowsError(try validate(release(url: foreign)))
        XCTAssertThrowsError(try NativeUpdateFeed.validate(release(), feedURL: feed, bundleIdentifier: "other.app", architecture: "arm64"))
        XCTAssertThrowsError(try NativeUpdateFeed.validate(release(), feedURL: feed, bundleIdentifier: identifier, architecture: "x64"))
    }
    func testSupplementalOriginalNotesNotificationBudgetPreserved() throws {
        let decoded = try decode(data(release(notes: String(repeating: "x", count: 8000))))
        XCTAssertLessThanOrEqual(decoded.releaseNotes?.utf16.count ?? 0, 4000)
        // This exposes the returned native feed reading; it does not claim the
        // blocked controller readNotes/notification integration is covered.
    }
}
