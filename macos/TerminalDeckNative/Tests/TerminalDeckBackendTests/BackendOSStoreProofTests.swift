import Foundation
import CryptoKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// store-install.proof's signed catalogue -> cache -> digest -> archive ->
/// grammar -> real scratch install chain. No agent CLI or real home is used.
final class BackendOSStoreProofTests: XCTestCase {
    func testSignedDevelopmentCatalogueInstallKeptFallbackAndUntrustedKeyRefusal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSStoreProof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try BackendOSStoreInstallFixture.item()
        let rawRow = fixture.row.setting("install", fixture.row["install"].removing("kind"))
        let document = BackendOSStoreInstallFixture.loaded([rawRow])["index"], signed = try document.encodedJSON()
        let seed = Data(SHA256.hash(data: Data(BackendSharedStoreKeys.developmentPhrase.utf8)))
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed), signature = try privateKey.signature(for: signed)
        let envelope: NativeRPCValue = .object([.init("v", .number(1)), .init("keyId", .string(BackendSharedStoreKeys.development.id)), .init("alg", .string("ed25519")), .init("sig", .string(signature.base64EncodedString())), .init("signed", .string(signed.base64EncodedString()))])
        let keys = BackendSharedStoreKeys.keys(environment: ["TERMINALDECK_STORE_DEV_KEY": "1"], packaged: false)
        let cache = BackendAppStoreIndexCache(userData: root, writable: true, keys: keys, fetch: { _, _ in .init(ok: true, text: envelope.compact) })
        let now = 1_788_048_000_000.0
        let installer = try BackendOSStoreInstaller(userData: root, environment: [:], home: root.appendingPathComponent("home").path, writable: true,
            loadIndex: { await cache.load(base: "http://127.0.0.1:8933", now: now) }, fetchArtifact: { _, _ in .init(ok: true, bytes: fixture.archive) })
        let view = try await installer.view(); XCTAssertEqual(view["ok"].bool, true)
        let installed = try await installer.install(id: "pub/thing", choice: .object([.init("agents", .array([.string("claude")]))])); XCTAssertEqual(installed["ok"].bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("home/.claude/skills/pub.thing/SKILL.md").path))
        let offline = BackendAppStoreIndexCache(userData: root, keys: keys, fetch: { _, _ in .init(ok: false, message: "offline") })
        let kept = await offline.load(base: "http://127.0.0.1:1", now: now); XCTAssertEqual(kept["from"].string, "kept")
        for trusted in [BackendSharedStoreKeys.live, BackendSharedStoreKeys.keys(environment: ["TERMINALDECK_STORE_DEV_KEY": "1"], packaged: true)] {
            let stranger = BackendAppStoreIndexCache(userData: root, keys: trusted, fetch: { _, _ in .init(ok: true, text: envelope.compact) })
            let refused = await stranger.load(base: "http://127.0.0.1:8933", now: now); XCTAssertEqual(refused["ok"].bool, false)
        }
        let removed = try await installer.remove(id: "pub/thing"); XCTAssertEqual(removed["ok"].bool, true)
        XCTAssertEqual(BackendOSStoreInstaller.readLedger(root), [])
    }
}
