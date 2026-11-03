import Foundation
import CryptoKit
import XCTest
@testable import TerminalDeckNativeCore

/// Release 27: the signed GitHub release manifest, the pinned signer and the side panel's update card.
/// The fixture below was written by tools/release/make-release-manifest.mjs with the REAL release key; the
/// Windows suite (GitHubReleaseChannelTests) checks the very same bytes, so both apps agree on one file.
final class Release27UpdateManifestTests: XCTestCase {
    static let fixture = Data(base64Encoded: "ewogICJzY2hlbWEiOiAxLAogICJwcm9kdWN0IjogInRlcm1pbmFsZGVjayIsCiAgInZlcnNpb24iOiAiOS45LjkiLAogICJ0YWciOiAidjkuOS45IiwKICAiY29tbWl0IjogIjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1NjciLAogICJyZWxlYXNlRGF0ZSI6ICIyMDI2LTExLTAzVDIyOjAwOjAwLjAwMFoiLAogICJub3Rlc1VybCI6ICJodHRwczovL2dpdGh1Yi5jb20vYXNhZGV2L3Rlcm1pbmFsZGVjay9yZWxlYXNlcy90YWcvdjkuOS45IiwKICAibm90ZXMiOiAiRml4dHVyZSBub3Rlcy4iLAogICJtYWMiOiB7CiAgICAiZmlsZSI6ICJ0ZXJtaW5hbGRlY2stbmF0aXZlLTkuOS45LWFybTY0LnppcCIsCiAgICAidXJsIjogImh0dHBzOi8vZ2l0aHViLmNvbS9hc2FkZXYvdGVybWluYWxkZWNrL3JlbGVhc2VzL2Rvd25sb2FkL3Y5LjkuOS90ZXJtaW5hbGRlY2stbmF0aXZlLTkuOS45LWFybTY0LnppcCIsCiAgICAic2l6ZSI6IDIyLAogICAgInNoYTI1NiI6ICJlYWM3NzFkMjJiNzdhOWM1M2IzOTgyMmZkM2ZkMjMyYzZmNTk5OGJhYTlkMzAyNTMyN2E0ZGUzNzI2ODNlYWFhIiwKICAgICJzaGE1MTIiOiAibzFtcjZLL2ZlQU82T1ZJQlFkZnZLYWg1clQvUlp4anUwbDlYZjBaZjVmZU1WQmdUWCt3bjdVMExHMXJjMi9wS2dCTGtuUmZ1d1FrQWxzWmpVNHZqNGc9PSIsCiAgICAiYnVuZGxlSWRlbnRpZmllciI6ICJkZXYudGVybWluYWxkZWNrLmFwcCIsCiAgICAiYXJjaGl0ZWN0dXJlIjogImFybTY0IiwKICAgICJ0ZWFtSWRlbnRpZmllciI6ICI2VTRWTlg1Vzg3IiwKICAgICJub3Rhcml6ZWQiOiBmYWxzZQogIH0sCiAgIndpbmRvd3MiOiB7CiAgICAiZmlsZSI6ICJUZXJtaW5hbERlY2stOS45LjkuMC14NjQubXNpeCIsCiAgICAidXJsIjogImh0dHBzOi8vZ2l0aHViLmNvbS9hc2FkZXYvdGVybWluYWxkZWNrL3JlbGVhc2VzL2Rvd25sb2FkL3Y5LjkuOS9UZXJtaW5hbERlY2stOS45LjkuMC14NjQubXNpeCIsCiAgICAic2l6ZSI6IDE5LAogICAgInNoYTI1NiI6ICJmNzExYmU4NGY4OWJkZDgwYWRiZWY0M2Q3OTljMmVhYTUwZTFmMzYxOWUyMDZmNzdlNjFmY2UwZTcwMGZlMTQ2IiwKICAgICJwYWNrYWdlTmFtZSI6ICJUZXJtaW5hbERlY2siLAogICAgInB1Ymxpc2hlciI6ICJDTj1UZXJtaW5hbCBEZWNrIFN0YWJsZSIsCiAgICAidmVyc2lvbiI6ICI5LjkuOS4wIiwKICAgICJhcmNoaXRlY3R1cmUiOiAieDY0IgogIH0KfQo=")!
    static let fixtureSignature = Data("SKMHPTRUEd2qsCbYQBM2X/ru/f1fsuhmpwZFVczXeqwT/2YDDLXWJETESafmRpW666MoIGlxGEP4oDMuAQM9AA==\n".utf8)
    let manifestURL = NativeReleaseManifest.defaultURL

    func testTheRealKeySignedFixtureVerifiesAndReadsAsTheMacRelease() throws {
        XCTAssertNoThrow(try NativeReleaseManifest.verify(Self.fixture, signatureFile: Self.fixtureSignature))
        let release = try NativeReleaseManifest.macRelease(from: Self.fixture, manifestURL: manifestURL,
                                                           bundleIdentifier: "dev.terminaldeck.app", architecture: "arm64")
        XCTAssertEqual(release.version, "9.9.9")
        XCTAssertEqual(release.channel, "native-mac")
        XCTAssertEqual(release.sha256, "eac771d22b77a9c53b39822fd3fd232c6f5998baa9d3025327a4de372683eaaa")
        XCTAssertEqual(release.size, 22)
        XCTAssertEqual(release.notarized, false)
        XCTAssertEqual(release.notesURL?.absoluteString, "https://github.com/asadev/terminaldeck/releases/tag/v9.9.9")
        XCTAssertEqual(release.releaseNotes, "Fixture notes.")
    }

    func testOneChangedByteOrAnotherKeyIsRefusedBeforeAnyDownload() throws {
        var changed = Self.fixture; changed[changed.count / 2] ^= 0x01
        XCTAssertThrowsError(try NativeReleaseManifest.verify(changed, signatureFile: Self.fixtureSignature)) {
            XCTAssertTrue($0.localizedDescription.contains("not signed by"))
        }
        let other = Curve25519.Signing.PrivateKey()
        let forged = Data(try other.signature(for: Self.fixture).base64EncodedString().utf8)
        XCTAssertThrowsError(try NativeReleaseManifest.verify(Self.fixture, signatureFile: forged))
        XCTAssertThrowsError(try NativeReleaseManifest.verify(Self.fixture, signatureFile: Data("not base64".utf8)))
        XCTAssertThrowsError(try NativeReleaseManifest.verify(Self.fixture, signatureFile: Data()))
    }

    private func signed(_ edit: (inout [String: Any]) -> Void) throws -> (Data, Data, String) {
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Self.fixture) as? [String: Any])
        edit(&object)
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let key = Curve25519.Signing.PrivateKey()
        return (bytes, Data(try key.signature(for: bytes).base64EncodedString().utf8), key.publicKey.rawRepresentation.base64EncodedString())
    }

    func testAnotherTeamProductOrRepositoryIsRefusedEvenWhenSigned() throws {
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("team", { var mac = $0["mac"] as! [String: Any]; mac["teamIdentifier"] = "AAAAAAAAAA"; $0["mac"] = mac }),
            ("product", { $0["product"] = "something-else" }),
            ("schema", { $0["schema"] = 2 }),
            ("repository", { var mac = $0["mac"] as! [String: Any]; mac["url"] = "https://github.com/someone/else/releases/download/v9.9.9/terminaldeck-native-9.9.9-arm64.zip"; $0["mac"] = mac }),
            ("sha256", { var mac = $0["mac"] as! [String: Any]; mac["sha256"] = "ABC"; $0["mac"] = mac }),
            ("notes page", { $0["notesUrl"] = "https://example.com/releases/tag/v9.9.9" }),
            ("bundle", { var mac = $0["mac"] as! [String: Any]; mac["bundleIdentifier"] = "other.app"; $0["mac"] = mac }),
        ]
        for (name, edit) in cases {
            let (bytes, signature, key) = try signed(edit)
            XCTAssertNoThrow(try NativeReleaseManifest.verify(bytes, signatureFile: signature, keys: [key]), name)
            XCTAssertThrowsError(try NativeReleaseManifest.macRelease(from: bytes, manifestURL: manifestURL,
                bundleIdentifier: "dev.terminaldeck.app", architecture: "arm64"), name)
        }
    }

    func testOnlyThisRepositorysReleaseManifestIsASource() {
        XCTAssertNoThrow(try NativeUpdateFeed.validateSourceURL(manifestURL))
        XCTAssertNoThrow(try NativeUpdateFeed.validateSourceURL(URL(string: "https://github.com/asadev/terminaldeck/releases/latest/download/latest-native-mac.yml")!))
        for raw in ["http://github.com/asadev/terminaldeck/releases/latest/download/release-manifest.json",
                    "https://example.com/asadev/terminaldeck/releases/latest/download/release-manifest.json",
                    "https://github.com/asadev/terminaldeck/raw/main/release-manifest.json",
                    "https://github.com/asadev/terminaldeck/releases/latest/download/release-manifest.json?x=1"] {
            XCTAssertThrowsError(try NativeUpdateFeed.validateSourceURL(URL(string: raw)!), raw)
        }
        XCTAssertEqual(NativeReleaseManifest.signatureURL(for: manifestURL).lastPathComponent, "release-manifest.json.sig")
    }

    func testArchiveMustMatchTheManifestsSHA256AsWellAsSHA512() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("r27-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("update.zip")
        try Data("fixture mac zip bytes\n".utf8).write(to: archive)
        let release = try NativeReleaseManifest.macRelease(from: Self.fixture, manifestURL: manifestURL, bundleIdentifier: "dev.terminaldeck.app", architecture: "arm64")
        XCTAssertNoThrow(try NativeUpdatePackage.verifyArchive(archive, release: release))
        let wrong = NativeUpdateRelease(schemaVersion: 1, channel: "native-mac", version: release.version, bundleIdentifier: release.bundleIdentifier,
            architecture: "arm64", url: release.url, sha512: release.sha512, size: release.size, releaseDate: "", releaseNotes: nil,
            sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try NativeUpdatePackage.verifyArchive(archive, release: wrong)) { XCTAssertTrue($0.localizedDescription.contains("SHA-256")) }
    }

    func testTheSignerIsPinnedToTheDeveloperIDOfTeam6U4VNX5W87() throws {
        XCTAssertEqual(NativeUpdateTrust.teamIdentifier, "6U4VNX5W87")
        XCTAssertTrue(NativeUpdateTrust.developerIDRequirement.contains("1.2.840.113635.100.6.1.13"))
        XCTAssertTrue(NativeUpdateTrust.developerIDRequirement.contains("certificate leaf[subject.OU] = \"6U4VNX5W87\""))
        // An ad-hoc signed copy (what any fork or local build is) never passes.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("r27-adhoc-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app"), binary = app.appendingPathComponent("Contents/MacOS/Fixture")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.terminaldeck.fixture", "CFBundleExecutable": "Fixture"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        _ = try NativeUpdatePackage.command("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        XCTAssertThrowsError(try NativeUpdateTrust.verifyDeveloperID(app)) { XCTAssertTrue($0.localizedDescription.contains("Developer ID")) }
        XCTAssertFalse(NativeUpdateTrust.assess(app).notarized)
        XCTAssertThrowsError(try NativeUpdateTrust.verify(app, requireNotarized: true))
    }

    // MARK: The side panel card (just above Settings)

    func testTheCardWalksAvailableDownloadReadyAndOnlyShowsRealState() {
        let notes = URL(string: "https://github.com/asadev/terminaldeck/releases/tag/v0.21.0")!
        func card(_ state: UpdateState, waiting: String? = nil, restarting: Bool = false, dismissed: String? = nil, offered: String? = nil, inApp: Int = 0) -> UpdateCard? {
            UpdateCard.make(state, waitingFor: waiting, restarting: restarting, dismissedVersion: dismissed, offered: offered, hiddenError: nil, notesURL: notes, inAppSessions: inApp)
        }
        XCTAssertNil(card(.none)); XCTAssertNil(card(.checking)); XCTAssertNil(card(.unsupported(reason: "dev run")))
        let offer = card(.available(version: "0.21.0", notes: nil, sizeBytes: 90 * 1024 * 1024))
        XCTAssertEqual(offer?.title, "Update available · 0.21.0")
        XCTAssertEqual(offer?.primary, .init(label: "Download", action: .download))
        XCTAssertEqual(offer?.detail, "90 MB download")
        XCTAssertEqual(offer?.notesURL, notes)
        XCTAssertEqual(offer?.dismissKey, "0.21.0")
        XCTAssertNil(card(.available(version: "0.21.0", notes: nil, sizeBytes: nil), dismissed: "0.21.0"))
        XCTAssertNotNil(card(.available(version: "0.21.1", notes: nil, sizeBytes: nil), dismissed: "0.21.0"))
        let downloading = card(.downloading(version: "0.21.0", percent: 42.7, bytesPerSecond: 3 * 1024 * 1024))
        XCTAssertEqual(downloading?.title, "Downloading 0.21.0"); XCTAssertEqual(downloading?.progress ?? 0, 0.427, accuracy: 0.0001)
        XCTAssertEqual(downloading?.detail, "42% · 3.0 MB/s"); XCTAssertNil(downloading?.primary); XCTAssertNil(downloading?.dismissKey)
        let ready = card(.ready(version: "0.21.0"))
        XCTAssertEqual(ready?.primary, .init(label: "Restart to update", action: .restart))
        XCTAssertEqual(ready?.detail, "Your sessions keep running through the restart.")
        XCTAssertEqual(card(.ready(version: "0.21.0"), inApp: 2)?.detail, "2 sessions that run inside the app close; kept sessions keep running.")
        let waiting = card(.ready(version: "0.21.0"), waiting: "Hoot is answering", dismissed: "0.21.0")
        XCTAssertEqual(waiting?.primary, .init(label: "Cancel", action: .cancelWait))
        XCTAssertEqual(waiting?.detail, "Waiting: Hoot is answering. It restarts right after.")
        XCTAssertNil(waiting?.dismissKey)
        XCTAssertEqual(card(.ready(version: "0.21.0"), restarting: true)?.busy, true)
        // An error shows only after the card's own offer (an automatic check never errors on screen).
        XCTAssertNil(card(.error(message: "GitHub could not be reached")))
        XCTAssertEqual(card(.error(message: "SHA-256 failed"), offered: "0.21.0")?.primary, .init(label: "Try again", action: .retry))
    }
}
