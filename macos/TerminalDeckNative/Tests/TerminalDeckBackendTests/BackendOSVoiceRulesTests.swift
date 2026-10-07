import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendOSVoiceRulesTests: XCTestCase {
    func testJSONEmptyTranscriptIsSuccessButUnrecognisedJSONIsNotTranscript() {
        XCTAssertEqual(BackendOSVoiceRules.transcript("{\"text\":\"\"}"), "")
        XCTAssertEqual(BackendOSVoiceRules.transcript("{\"text\":\"hello\"}"), "hello")
        XCTAssertNil(BackendOSVoiceRules.transcript("{\"answer\":\"hello\"}"))
        XCTAssertEqual(BackendOSVoiceRules.transcript("  bare words \n"), "bare words")
        XCTAssertNil(BackendOSVoiceRules.transcript(" \n"))
    }
    func testFailureDistinguishesAuthenticationRateLimitAndProviderOutage() {
        XCTAssertTrue(BackendOSVoiceRules.failure(status: 401, body: "{\"error\":{\"message\":\"invalid\"}}").contains("rejected the key — invalid"))
        XCTAssertTrue(BackendOSVoiceRules.failure(status: 429, body: "slow down").contains("Wait a moment"))
        XCTAssertTrue(BackendOSVoiceRules.failure(status: 503, body: "unavailable").contains("Nothing is wrong with the key"))
        XCTAssertEqual(BackendOSVoiceRules.failure(status: 422, body: "{\"detail\":\"bad container\"}"), "bad container")
    }
    func testKeyFilePayloadRoundTripsOnlyProviderAndKey() throws {
        let text = try BackendOSVoiceRules.encodeKey(provider: "groq", key: "fixture-dummy-key")
        let value = try NativeRPCValue.parseJSON(Data(text.utf8)), decoded = try BackendOSVoiceRules.decodeKey(text)
        XCTAssertEqual(Set(value.fields!.map(\.key)), ["provider", "key"])
        XCTAssertEqual(decoded.provider, "groq"); XCTAssertEqual(decoded.key, "fixture-dummy-key")
        XCTAssertThrowsError(try BackendOSVoiceRules.decodeKey("{\"provider\":\"groq\",\"key\":\"\"}"))
    }
    func testKeyCheckWavAndMultipartDoNotPermitHeaderInjection() {
        let wave = BackendOSVoiceRules.silentWav(milliseconds: 200)
        XCTAssertEqual(wave.count, 6444); XCTAssertEqual(String(decoding: wave.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wave[36..<40], as: UTF8.self), "data")
        XCTAssertTrue(wave.dropFirst(44).allSatisfy { $0 == 0 })
        let provider = BackendOSVoiceRules.provider("elevenlabs")!
        let body = String(decoding: BackendOSVoiceRules.multipart(provider: provider, audio: Data([1, 2]), filename: "a\"\r\nInjected: x.wav", boundary: "fixture"), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model_id\"")); XCTAssertTrue(body.contains("scribe_v1"))
        XCTAssertFalse(body.contains("\r\nInjected: x")); XCTAssertTrue(body.contains("%22%0D%0A"))
    }
    func testCustomAPIKeyCannotFollowCrossOriginOrDowngradeRedirect() {
        let source = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        XCTAssertTrue(BackendOSVoiceRedirectGuard.allowed(original: source, target: URL(string: "https://api.elevenlabs.io/v2/speech")))
        XCTAssertFalse(BackendOSVoiceRedirectGuard.allowed(original: source, target: URL(string: "https://other.example/speech")))
        XCTAssertFalse(BackendOSVoiceRedirectGuard.allowed(original: source, target: URL(string: "http://api.elevenlabs.io/speech")))
    }
    func testAcceptedKeyPersistsOriginalBinaryV10FormatWithoutPlaintextFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSVoice-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NativeStateStore(file: root.appendingPathComponent("state.json"), ownership: .exclusive), cipher = BackendOSVoiceFixtureCipher()
        let http = BackendOSVoiceFixtureHTTP(status: 200, body: "{\"text\":\"\"}")
        let voice = try BackendOSVoiceService(userData: root, store: store, cipher: cipher, http: http, authorize: { _, _ in })
        let before = await http.count(); XCTAssertEqual(before, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: voice.file.path))
        try await voice.activate(oldVoiceOwnerDisabled: true)
        let result = try await voice.save(providerID: "groq", key: "fixture-only-secret")
        XCTAssertEqual(result["ok"].bool, true)
        let bytes = try Data(contentsOf: voice.file)
        XCTAssertTrue(bytes.starts(with: Data("v10".utf8)))
        XCTAssertNil(bytes.range(of: Data("fixture-only-secret".utf8)))
        let decoded = try BackendOSVoiceRules.decodeKey(cipher.decrypt(bytes))
        XCTAssertEqual(decoded.provider, "groq"); XCTAssertEqual(decoded.key, "fixture-only-secret")
        let status = await voice.status(); XCTAssertEqual(status["hasKey"].bool, true); XCTAssertFalse(status.compact.contains("fixture-only-secret"))
        await store.close()
    }
    func testRejectedKeyIsNotEncryptedOrSavedAndExistingCiphertextRemains() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSVoice-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NativeStateStore(file: root.appendingPathComponent("state.json"), ownership: .exclusive), cipher = BackendOSVoiceFixtureCipher()
        let old = try cipher.encrypt(BackendOSVoiceRules.encodeKey(provider: "groq", key: "old-fixture-key"), existingVault: false)
        try old.write(to: root.appendingPathComponent("voice-key.bin")); cipher.resetCount()
        let voice = try BackendOSVoiceService(userData: root, store: store, cipher: cipher, http: BackendOSVoiceFixtureHTTP(status: 401, body: "{\"error\":\"bad fixture-only-secret\"}"), authorize: { _, _ in })
        try await voice.activate(oldVoiceOwnerDisabled: true)
        let answer = try await voice.save(providerID: "groq", key: "fixture-only-secret")
        XCTAssertEqual(answer["ok"].bool, false); XCTAssertFalse(answer.compact.contains("fixture-only-secret"))
        XCTAssertEqual(cipher.encryptions(), 0); XCTAssertEqual(try Data(contentsOf: voice.file), old)
        await store.close()
    }
    func testOldWriterMustBeDisabledBeforeAKeyCheckOrMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendOSVoice-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NativeStateStore(file: root.appendingPathComponent("state.json"), ownership: .exclusive), http = BackendOSVoiceFixtureHTTP(status: 200, body: "{\"text\":\"\"}")
        let voice = try BackendOSVoiceService(userData: root, store: store, cipher: BackendOSVoiceFixtureCipher(), http: http, authorize: { _, _ in })
        do { try await voice.activate(oldVoiceOwnerDisabled: false); XCTFail("Cannot activate a second voice writer") } catch {}
        do { _ = try await voice.save(providerID: "groq", key: "fixture-only-secret"); XCTFail("Cannot check/save before cutover") } catch {}
        let count = await http.count(); XCTAssertEqual(count, 0)
        await store.close()
    }
}

private final class BackendOSVoiceFixtureCipher: BackendOSVoiceEncrypting, @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    private let password = Data("BackendOSVoice fixed fixture password".utf8)
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { lock.withLock { count += 1 }; return try ChromiumSafeStorageCipher.encrypt(text, password: password) }
    func decrypt(_ blob: Data) throws -> String { try ChromiumSafeStorageCipher.decrypt(blob, password: password) }
    func encryptions() -> Int { lock.withLock { count } }
    func resetCount() { lock.withLock { count = 0 } }
}
private actor BackendOSVoiceFixtureHTTP: BackendOSVoiceRequesting {
    let status: Int, body: String; var requests = 0
    init(status: Int, body: String) { self.status = status; self.body = body }
    func count() -> Int { requests }
    func post(provider: BackendOSVoiceRules.Provider, key: String, audio: Data, filename: String) async throws -> (status: Int, body: String) { requests += 1; return (status, body) }
}
