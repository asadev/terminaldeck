import Foundation
import CryptoKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppStoreIndexTests: XCTestCase {
    private func document(serial: Double = 7) -> NativeRPCValue {
        .object([.init("v", .number(1)), .init("serial", .number(serial)), .init("issuedAt", .string("2026-08-27T00:00:00.000Z")),
            .init("expiresAt", .null), .init("generator", .string("terminaldeck-commons 0.1.0")), .init("truncated", .bool(false)), .init("items", .array([])), .init("revoked", .array([]))])
    }
    private func pair() throws -> Curve25519.Signing.PrivateKey {
        try .init(rawRepresentation: Data(SHA256.hash(data: Data(BackendSharedStoreKeys.developmentPhrase.utf8))))
    }
    private func envelope(_ raw: NativeRPCValue) throws -> String {
        let bytes = try raw.encodedJSON(), signature = try pair().signature(for: bytes)
        return NativeRPCValue.object([.init("v", .number(1)), .init("keyId", .string("td-store-dev-1")), .init("alg", .string("ed25519")),
            .init("sig", .string(signature.base64EncodedString())), .init("signed", .string(bytes.base64EncodedString()))]).compact
    }
    private var now: Double { 1_788_523_200_000 }
    func testSignatureTamperingReplayAndDevelopmentGate() throws {
        let text = try envelope(document())
        let accepted = BackendAppStoreIndex.check(text, keys: [BackendSharedStoreKeys.development], now: now)
        XCTAssertEqual(accepted.wire["ok"], .bool(true)); XCTAssertEqual(accepted.wire["keyId"], .string("td-store-dev-1"))
        var parsed = try NativeRPCValue.parseJSON(Data(text.utf8))
        var signed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(parsed["signed"].string))); signed[20] ^= 1
        parsed = parsed.setting("signed", .string(signed.base64EncodedString()))
        XCTAssertEqual(BackendAppStoreIndex.check(parsed.compact, keys: [BackendSharedStoreKeys.development], now: now).wire["why"], .string("this catalogue was not signed by Terminal Deck, so it was not used"))
        XCTAssertEqual(BackendAppStoreIndex.check(text, keys: [], now: now).wire["why"], .string("this build carries no key to check a catalogue with"))
        XCTAssertEqual(BackendAppStoreIndex.check(text, now: now).wire["ok"], .bool(false))
        XCTAssertTrue(BackendAppStoreIndex.check(text, keys: [BackendSharedStoreKeys.development], highWater: 8, now: now).wire["why"].string?.contains("withdrawn") == true)
        let packaged = BackendSharedStoreKeys.keys(environment: [BackendSharedStoreKeys.environmentKey: "1"], packaged: true)
        XCTAssertEqual(BackendAppStoreIndex.check(text, keys: packaged, now: now).wire["ok"], .bool(false))
    }
    func testClosedGrammarAndDigest() throws {
        let extra = document().setting("hydrate", .string("https://example.com/more.json"))
        XCTAssertEqual(BackendAppStoreIndex.check(try envelope(extra), keys: [BackendSharedStoreKeys.development], now: now).wire["why"], .string("the catalogue has a key this app does not know about: hydrate"))
        let bytes = Data("the archive".utf8), digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(BackendAppStoreIndex.artifactMatches(bytes, expectedHex: digest.uppercased()))
        XCTAssertFalse(BackendAppStoreIndex.artifactMatches(Data("the archivf".utf8), expectedHex: digest))
        XCTAssertFalse(BackendAppStoreIndex.artifactMatches(bytes, expectedHex: String(digest.prefix(32))))
        XCTAssertFalse(BackendAppStoreIndex.artifactMatches(bytes, expectedHex: digest + "\n"))
        XCTAssertFalse(BackendAppStoreIndex.artifactMatches(bytes, expectedHex: digest + "\r"))
        let fortyDays = document().setting("issuedAt", .string(BackendAppSettingsStore.iso(now - 40 * 86_400_000)))
        XCTAssertEqual(BackendAppStoreIndex.staleness(fortyDays, now: now), "This list is 40 days old.")
    }
    func testReverifiedCacheHighWaterAndOfflineReason() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendAppIndex-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = try envelope(document(serial: 9))
        let serving = BackendAppStoreIndexCache(userData: root, writable: true, keys: [BackendSharedStoreKeys.development], fetch: { _, _ in .init(ok: true, text: text) })
        let first = await serving.load(base: "http://127.0.0.1:8931", now: now)
        XCTAssertEqual(first["from"], .string("store"))
        let lower = try envelope(document(serial: 2)); try await serving.write(envelope: lower, serial: 2, at: now)
        let high = await serving.highWater(); XCTAssertEqual(high, 9)
        // Restore the valid current envelope before testing the offline fallback.
        try await serving.write(envelope: text, serial: 9, at: now)
        let offline = BackendAppStoreIndexCache(userData: root, keys: [BackendSharedStoreKeys.development], fetch: { _, _ in .init(ok: false, message: "the store could not be reached") })
        let kept = await offline.load(base: "http://127.0.0.1:8931", now: now)
        XCTAssertEqual(kept["from"], .string("kept")); XCTAssertEqual(kept["because"], .string("the store could not be reached"))
        let cacheFile = await serving.file
        let raw = try NativeRPCValue.parseJSON(Data(contentsOf: cacheFile)).setting("envelope", .string("tampered"))
        try raw.encodedJSON().write(to: cacheFile)
        let refused = await offline.read(now: now); XCTAssertNil(refused)
    }
}
