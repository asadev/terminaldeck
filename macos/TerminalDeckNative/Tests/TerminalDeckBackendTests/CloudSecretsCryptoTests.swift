import XCTest
import CryptoKit
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class CloudSecretsCryptoTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudSecretsCryptoTests assertions=\(assertions)") }
    func check(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertions += 1; XCTAssertTrue(condition, "Cryptographic assertion", file: file, line: line)
    }
    func vectors() throws -> NativeRPCValue {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("design-2026-11-12-cloud/vectors/secrets-v1.json")
        return try NativeRPCValue.parseJSON(Data(contentsOf: file))
    }
    func decoded<T: Decodable>(_ type: T.Type, _ raw: NativeRPCValue) throws -> T { try JSONDecoder().decode(type, from: raw.encodedJSON()) }
    func testSecretCanonicalJSONMatchesRFC8785NumbersAndUTF16KeyOrder() throws {
        let value = CloudValue(.object([
            .init("2", .number(0.000001)), .init("10", .number(1e21)),
            .init("small", .number(0.0000001)), .init("zero", .number(-0.0)),
            .init("text", .string("fixture/line\n"))]))
        let expected = #"{"10":1e+21,"2":0.000001,"small":1e-7,"text":"fixture/line\n","zero":0}"#
        check(try CloudSecretsCanonical.encode(value) == Data(expected.utf8))
        let supplementary = String(UnicodeScalar(0x1f600)!), bmp = String(UnicodeScalar(0xe000)!)
        let ordered = CloudValue(.object([.init(bmp, .number(2)), .init(supplementary, .number(1))]))
        let expectedOrder = "{\"" + supplementary + "\":1,\"" + bmp + "\":2}"
        check(try CloudSecretsCanonical.encode(ordered) == Data(expectedOrder.utf8))
    }
    func testKnownAnswerContentHKDFECDHAndSignatures() async throws {
        let v = try vectors()
        func bytes(_ field: String) throws -> Data { try CloudSecretsCrypto.decode(v[field].requireString(field)) }
        let sub = try v["sub"].requireString("subject"), root = try bytes("root"), plain = try bytes("plain")
        let expected = try decoded(CloudContentEnvelope.self, v["content"])
        let actual = try CloudSecretsCrypto.sealContent(plain, root: root, sub: sub, blobId: expected.blobId,
            purpose: .secret, epoch: 1, nonce: bytes("nonce"))
        check(actual == expected)
        check(try CloudSecretsCrypto.derive(root, salt: CloudSecretsCrypto.uuidBytes(expected.blobId), info: "TD-CLOUD-OBJECT-1\nsecrets\n1") == bytes("objectKey"))
        check(try CloudSecretsCrypto.openContent(expected, root: root, sub: sub, epoch: 1) == plain)
        let keys = try CloudSecretsFixtureKeys(sign: bytes("signPrivate"), wrap: bytes("wrapPrivate"))
        let target = try keys.registration(v["target"].requireString("target"))
        let deviceEnvelope = try decoded(CloudDeviceKeyEnvelope.self, v["deviceEnvelope"])
        let shared = try await keys.deviceSharedSecret(peer: deviceEnvelope.ephemeralPublicJwk)
        check(try shared == bytes("sharedSecret"))
        check(try CloudSecretsCrypto.derive(shared, salt: bytes("salt"), info: "TD-CLOUD-DEVICE-1\n\(sub)\n\(target.deviceId)\n1") == bytes("deviceKey"))
        let body = try await CloudSecretsCrypto.unwrapDevice(deviceEnvelope, sub: sub, targetDeviceId: target.deviceId,
            epoch: 1, version: CloudSequence(1), author: v["author"].requireString("author"), authorKey: target.signPublicJwk, keys: keys)
        check(try CloudSecretsCrypto.decode(body.rootKey) == root)
        check(try CloudSecretsCrypto.hash(CloudSecretsCrypto.decode(body.canary)) == v["canaryHash"].string)
        let recovery = try CloudRecoveryKeys(entropy: bytes("entropy"), sub: sub)
        check(try recovery.encryption == bytes("recoveryEncryptionKey"))
        check(try recovery.signing.rawRepresentation == bytes("recoverySigningSeed"))
        let expectedRecovery = try decoded(CloudRecoveryEnvelope.self, v["recovery"])
        check(try recovery.seal(root: root, sub: sub, version: CloudSequence(1), epoch: 1, nonce: bytes("nonce")) == expectedRecovery)
        check(try recovery.open(expectedRecovery, sub: sub, epoch: 1, version: CloudSequence(1)) == root)
        let expectedWrapped = try decoded(CloudDeviceKeyEnvelope.self, v["recoveryDeviceEnvelope"])
        let wrapped = try await CloudSecretsCrypto.wrapDevice(root: root, sub: sub, target: target, epoch: 1, recoveryVersion: CloudSequence(1), author: "recovery",
            ephemeral: .init(rawRepresentation: bytes("ephemeralPrivate")), salt: bytes("salt"), nonce: bytes("nonce"), canary: bytes("canary"), sign: recovery.sign)
        // CryptoKit randomizes Ed25519 nonces; verify the signature rather than
        // requiring the deterministic RFC signature bytes (WICG secure-curves #28).
        let actualBody = try NativeRPCValue.parseJSON(JSONEncoder().encode(wrapped.0)).removing("signature")
        let expectedBody = try NativeRPCValue.parseJSON(JSONEncoder().encode(expectedWrapped)).removing("signature")
        check(try CloudSecretsCanonical.encode(CloudValue(actualBody)) == CloudSecretsCanonical.encode(CloudValue(expectedBody)))
        try CloudSecretsCrypto.verify(wrapped.0.signature,
            bytes: CloudSecretsCrypto.deviceAAD(wrapped.0) + CloudSecretsCrypto.decode(wrapped.0.ciphertext) + CloudSecretsCrypto.decode(wrapped.0.tag),
            key: recovery.publicKey)
        check(true)
        let recovered = try await CloudSecretsCrypto.unwrapDevice(expectedWrapped, sub: sub, targetDeviceId: target.deviceId, epoch: 1,
            version: CloudSequence(1), author: "recovery", authorKey: recovery.publicKey, keys: keys)
        check(try CloudSecretsCrypto.decode(recovered.rootKey) == root)
        let approval = try decoded(CloudApproval.self, v["approval"])
        // The shared vector now carries the 128-bit first code (spec correction
        // 5e2978d4), confirmed independently by lane C at 10f683fc; the retired
        // 40-bit v1 value is kept under its own name.
        check(CloudSecretsCrypto.matchingCode(approval) == v["matchingCode"].string)
        check(v["retiredMatchingCode40BitV1"].string == "92EDD 62F30")
    }
    func testContentRefusesTagAADUserEpochAndFormatTampering() throws {
        let v = try vectors(), sub = try v["sub"].requireString("subject")
        let root = try CloudSecretsCrypto.decode(v["root"].requireString("root"))
        let original = try decoded(CloudContentEnvelope.self, v["content"])
        let changes: [(String, NativeRPCValue)] = [
            ("tag", .string(CloudSecretsCrypto.encode(Data(repeating: 0, count: 16)))),
            ("epoch", .number(2)), ("purpose", .string("browser")), ("plainBytes", .number(1)),
            ("blobId", .string(UUID().uuidString.lowercased())), ("class", .string("brain")), ("codec", .string("gzip")), ("v", .number(2))
        ]
        for (field, value) in changes {
            let changed = try decoded(CloudContentEnvelope.self, v["content"].setting(field, value))
            do { _ = try CloudSecretsCrypto.openContent(changed, root: root, sub: sub, epoch: 1); check(false) }
            catch { check(true) }
        }
        do { _ = try CloudSecretsCrypto.openContent(original, root: root, sub: UUID().uuidString.lowercased(), epoch: 1); check(false) }
        catch { check(true) }
        do { _ = try CloudSecretsCrypto.openContent(original, root: Data(repeating: 0, count: 32), sub: sub, epoch: 1); check(false) }
        catch { check(true) }
        do { _ = try CloudSecretsCrypto.decode("AA=="); check(false) } catch { check(true) }
    }
    func testGzipBoundedRoundTripAndTrailingDataRefusal() throws {
        let bytes = Data(repeating: 7, count: 65536)
        let encoded = try CloudSecretsCompression.encode(bytes, codec: .gzip)
        check(encoded.count < bytes.count)
        check(try CloudSecretsCompression.decode(encoded, codec: .gzip, expected: Int64(bytes.count)) == bytes)
        do { _ = try CloudSecretsCompression.decode(encoded, codec: .gzip, expected: 1); check(false) } catch { check(true) }
        do { _ = try CloudSecretsCompression.decode(encoded + Data([0]), codec: .gzip, expected: Int64(bytes.count)); check(false) } catch { check(true) }
        let envelope = try CloudSecretsCrypto.sealContent(bytes, root: Data(repeating: 1, count: 32), sub: CloudSecretsFixtureServer.sub,
            blobId: UUID().uuidString.lowercased(), purpose: .secret, epoch: 1, codec: .gzip)
        check(try CloudSecretsCrypto.openContent(envelope, root: Data(repeating: 1, count: 32), sub: CloudSecretsFixtureServer.sub, epoch: 1) == bytes)
    }
    func testDeviceEnvelopeRefusesSubstitutionAndBindingChanges() async throws {
        let v = try vectors(), expected = try decoded(CloudDeviceKeyEnvelope.self, v["deviceEnvelope"])
        let keys = try CloudSecretsFixtureKeys(sign: CloudSecretsCrypto.decode(v["signPrivate"].requireString("sign")),
            wrap: CloudSecretsCrypto.decode(v["wrapPrivate"].requireString("wrap")))
        let publicKey = try decoded(CloudPublicJWK.self, v["signPublic"])
        for field in ["salt", "nonce", "ciphertext", "tag", "signature", "authorDeviceId", "targetDeviceId"] {
            let changed = try decoded(CloudDeviceKeyEnvelope.self, v["deviceEnvelope"].setting(field, .string("invalid")))
            do {
                _ = try await CloudSecretsCrypto.unwrapDevice(changed, sub: CloudSecretsFixtureServer.sub,
                    targetDeviceId: expected.targetDeviceId, epoch: 1, version: CloudSequence(1), author: expected.authorDeviceId, authorKey: publicKey, keys: keys)
                check(false)
            } catch { check(true) }
        }
        do {
            _ = try await CloudSecretsCrypto.unwrapDevice(expected, sub: UUID().uuidString.lowercased(), targetDeviceId: expected.targetDeviceId,
                epoch: 1, version: CloudSequence(1), author: expected.authorDeviceId, authorKey: publicKey, keys: keys)
            check(false)
        } catch { check(true) }
    }
}
