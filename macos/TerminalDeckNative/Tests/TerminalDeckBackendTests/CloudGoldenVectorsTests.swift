import XCTest
import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// GOLDEN VECTORS (13 Nov 2026, Tester seat): byte-for-byte proof for the Windows (C#) and Android (Kotlin) ports of
// the Cloud core. The test builds every vector from the fixed inputs below, writes them as one JSON file and asserts
// it equals the committed copy at Tests/Fixtures/cloud-golden-vectors.json, so the format can never drift silently.
//
// Lives in the Backend test target (not Core) because the 80-bit device code and the account helpers are Backend
// code; the target imports the Core too, so every Core function is reached directly.
//
// Outputs that CryptoKit makes random on every call (P-256 ECDSA signatures) cannot be recomputed. The first run
// records them under "randomOutputs"; later runs reuse the recorded value only after checking it still verifies.
// Missing file: written, then the run fails once so a person commits it. Different file: an `.actual.json` is
// written beside it and the test fails.

/// TEST-ONLY key material, generated once for this file. Never used by the app; not secret.
private enum GoldenTestOnlyKeys {
    static let subject = "38fdae8d-01e6-432d-b2c9-d40fe9996b5f"
    static let deviceA = "e3c75f30-363e-4323-a592-cf07fe14c4a6"
    static let deviceB = "8acf76f0-cb57-4f6e-b2fb-cef16fa3697e"
    static let deviceC = "7f306256-7209-4b63-962b-14a7b01b12ee"
    static let opId1 = "dca7d011-0cd3-4477-b17d-0e8fa56ed7d6"
    static let opId2 = "b919e08b-c7a0-4232-a95c-7ff37ab0dffe"
    static let segmentId = "a96ee0bd-d0f2-4504-a072-2893db4e03b9"
    static let requestId = "010f8711-493e-4fd0-bc8b-d0e173b954a2"
    static let secretBlobId = "fdb77519-d131-41ce-876c-af1e72318c25"
    static let approvalId = "6e8e663f-07a8-4f9e-b45b-2946cab4278a"
    static let createdAt: Int64 = 1_763_000_000_000
    static let brainRootHex = "4bdff7222adbea4e528a32a74da613179cfccb4e75125cc398de22fb1a5ed75c"
    static let secretsRootHex = "fde6ecf243eef7720922578c5a003fdec11b3c8ba06e9cb10dd889b1924a6d71"
    static let signAHex = "7111ce810a88d633693a92c43ec8c87c7d5d6159d2c7a2da3ca10e7b7bf778c1"
    static let signBHex = "e37ecad29cfda4fcf0b6252fe421aaf112e101d65147dcc69e2f8e7423058a7b"
    static let signCHex = "8f310222e8c47399caa554f9ae9d40a95716c4080b3fa4e9d051bf730bc9b9d0"
    static let wrapBHex = "e3d2c4a4c1d28eb3a800a5803ab224c30ea5d56c1baf887b1206767df7385396"
    static let wrongWrapHex = "1096764f4ff4df344803f2d979c17068dde71e66764f9f7120f274eaa03edc6e"
    static let ephemeralHex = "d1cc0552e5dde49a0db7a52657665234639696bdbb830b5ba627bd7f3829fd3a"
    static let saltHex = "452238cdc99f0df2ce5a42324c68fd6c504247ee407b59bd29da87b5c266aa2d"
    static let canaryHex = "fc575658af679729875fe766cc2f5511a392819affdb88d8c5674000cd7056f1"
    static let nonceBrainHex = "fab6d7b15f8de0ecc14e2fb2"
    static let nonceBrainZipHex = "aaf4d970dde1b55315ff3213"
    static let nonceSecretHex = "b45f4ba545846a8997efa66d"
    static let nonceWrapHex = "90d0a9c10f3ab05beac9ec64"
    static let pkceVerifier = "golden-test-only-verifier-0123456789abcdefghijklmnop"
}

private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
private func unhex(_ text: String) -> Data {
    var out = Data(); var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        out.append(UInt8(text[index..<next], radix: 16)!); index = next
    }
    return out
}
private func b64u(_ data: Data) -> String { CloudSyncBytes.base64(data) }
private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

private struct GoldenKeyPort: CloudDeviceKeyPort {
    let wrap: P256.KeyAgreement.PrivateKey
    func signDevicePayload(_ bytes: Data) async throws -> Data { throw CloudFailure.unavailable }
    func deviceSharedSecret(peer: CloudPublicJWK) async throws -> Data {
        let point = try CloudSecretsCrypto.x963(peer)
        return try wrap.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: point)).withUnsafeBytes { Data($0) }
    }
}

final class CloudGoldenVectorsTests: XCTestCase {
    fileprivate typealias K = GoldenTestOnlyKeys
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cloud-golden-vectors.json")
    }
    private var committed: [String: Any] = [:]
    private var randomOutputs: [String: String] = [:]

    /// A recorded random output (signature) when it still verifies; otherwise a fresh one.
    private func randomOutput(_ id: String, verifies: (Data) -> Bool, make: () throws -> Data) rethrows -> Data {
        if let old = (committed["randomOutputs"] as? [String: String])?[id], let bytes = try? CloudSyncBytes.unbase64(old), verifies(bytes) {
            randomOutputs[id] = old; return bytes
        }
        let bytes = try make(); randomOutputs[id] = b64u(bytes); return bytes
    }

    private func jwk(_ sign: P256.Signing.PrivateKey) throws -> CloudPublicJWK { try CloudSecretsCrypto.publicJWK(sign.publicKey.x963Representation) }
    private func jwk(_ wrap: P256.KeyAgreement.PrivateKey) throws -> CloudPublicJWK { try CloudSecretsCrypto.publicJWK(wrap.publicKey.x963Representation) }
    private func jwkObject(_ key: CloudPublicJWK) throws -> Any { try JSONSerialization.jsonObject(with: CloudSyncCanonical.encode(key)) }

    func testCloudGoldenVectors() async throws {
        if let data = try? Data(contentsOf: fixtureURL), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { committed = object }
        let signA = try P256.Signing.PrivateKey(rawRepresentation: unhex(K.signAHex))
        let signB = try P256.Signing.PrivateKey(rawRepresentation: unhex(K.signBHex))
        let signC = try P256.Signing.PrivateKey(rawRepresentation: unhex(K.signCHex))
        let wrapB = try P256.KeyAgreement.PrivateKey(rawRepresentation: unhex(K.wrapBHex))
        let wrongWrap = try P256.KeyAgreement.PrivateKey(rawRepresentation: unhex(K.wrongWrapHex))
        let ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: unhex(K.ephemeralHex))

        var out: [String: Any] = [
            "format": "td-cloud-golden-1",
            "about": "Byte-exact vectors from the Mac's Swift Cloud core. Produced and checked by Tests/TerminalDeckBackendTests/CloudGoldenVectorsTests.swift. Bytes: hex = lower-case hex; b64u = base64url without padding. All keys here are TEST-ONLY.",
            "testOnlyInputs": [
                "subject": K.subject, "deviceA": K.deviceA, "deviceB": K.deviceB, "deviceC": K.deviceC,
                "brainRootHex": K.brainRootHex, "secretsRootHex": K.secretsRootHex,
                "signAPrivateHex": K.signAHex, "signBPrivateHex": K.signBHex, "signCPrivateHex": K.signCHex,
                "wrapBPrivateHex": K.wrapBHex, "wrongWrapPrivateHex": K.wrongWrapHex, "ephemeralPrivateHex": K.ephemeralHex,
                "saltHex": K.saltHex, "canaryHex": K.canaryHex, "createdAt": K.createdAt,
                "privateKeyForm": "P-256 private keys are the raw 32-byte scalar (CryptoKit rawRepresentation)",
            ] as [String: Any],
        ]

        // a. Canonical form (RFC 8785 style). Input is JSON text; output is the exact bytes.
        let canonicalInputs: [(String, String, String)] = [
            ("key-order", "Members sort by key; nested objects sort too; arrays keep their order.", #"{"b":1,"a":2,"c":{"z":0,"y":[3,2,1]}}"#),
            ("utf16-key-order", "Keys sort by UTF-16 code units, not code points: the emoji key (D83D...) sorts before U+FF5E.", #"{"\uff5e":1,"\ud83d\ude00":2,"z":3,"\u00e9":4,"A":5,"a":6}"#),
            ("nested-arrays-objects", "Objects inside arrays are sorted; arrays are never sorted.", #"[{"b":[{"d":4,"c":3}],"a":null},[[],[{}]]]"#),
            ("integers", "Numbers are IEEE doubles printed like ECMAScript Number.prototype.toString. -0 prints 0. Integers above 2^53 lose precision (9007199254740993 prints 9007199254740992). 1e21 and up use exponent form.", #"{"zero":0,"negzero":-0,"neg":-42,"one":1,"max53":9007199254740991,"over53":9007199254740993,"huge":12345678901234567890,"e20":100000000000000000000,"e21":1e21,"tenPointZero":10.0}"#),
            ("fractions", "Fractions are allowed and print in shortest round-trip form; exponent form below 1e-6.", #"{"half":0.5,"tenth":0.1,"third":0.3333333333333333,"micro":0.000001,"smaller":1e-7,"neg":-1.5e-10,"big":1.5e300,"sum":0.30000000000000004}"#),
            ("string-escapes", "Escapes exactly like JSON.stringify: \\\" \\\\ \\b \\f \\n \\r \\t, other controls as \\u00xx lower-case; '/' and DEL (7F) are NOT escaped.", #"{"s":"quote\" backslash\\ slash/ \b\f\n\r\t nul\u0000 us\u001f del\u007f"}"#),
            ("non-ascii", "Non-ASCII is written as raw UTF-8, never \\u escaped, including U+2028 and U+2029.", #"{"s":"\u2028\u2029 Ü ß 中文 עברית Ελληνικά"}"#),
            ("composed-vs-decomposed-values", "No Unicode normalization: U+00E9 and e+U+0301 stay different bytes.", #"{"composed":"\u00e9","decomposed":"e\u0301"}"#),
            ("composed-key", "Key U+00E9 (composed).", #"{"\u00e9":1}"#),
            ("decomposed-key", "Key e+U+0301 (decomposed): different bytes from composed-key.", #"{"e\u0301":1}"#),
            ("emoji", "Emoji, ZWJ sequence and flag pass through as raw UTF-8, in keys and values.", #"{"\ud83d\udc4d":"\ud83d\udc69\u200d\ud83d\udcbb \ud83c\uddf5\ud83c\uddf0 \ud83d\ude00"}"#),
            ("empty-values", "Empty string, array, object, null, true, false.", #"{"emptyString":"","emptyArray":[],"emptyObject":{},"nul":null,"t":true,"f":false}"#),
            ("top-level-array", "A top-level array of mixed values.", #"[3,"a",null,{},true,-1.25]"#),
            ("top-level-string", "A top-level string.", #""just a string""#),
            ("deep-nesting", "Ten levels of nesting.", #"{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"i":{"j":[1]}}}}}}}}}}"#),
        ]
        var canonical: [[String: Any]] = []
        for (name, description, input) in canonicalInputs {
            let value = CloudValue(try NativeRPCValue.parseJSON(Data(input.utf8)))
            let bytes = try CloudSyncCanonical.encode(value)
            XCTAssertEqual(bytes, try CloudSecretsCanonical.encode(value), "the two canonical encoders disagree on \(name)")
            canonical.append(["name": name, "description": description, "function": "CloudSyncCanonical.encode (== CloudSecretsCanonical.encode)",
                              "input": input, "output": text(bytes), "outputHex": hex(bytes), "outputSha256": CloudSyncBytes.hash(bytes),
                              "cloudWireCanonicalAgrees": (try? CloudWire.canonical(value)) == bytes])
        }
        // Sibling keys that differ only by normalization: Swift treats them as the same key and refuses the object.
        let siblings = CloudValue(.object([.init("\u{e9}", .number(1)), .init("e\u{301}", .number(2))]))
        XCTAssertThrowsError(try CloudSyncCanonical.encode(siblings))
        canonical.append(["name": "normalization-equal-sibling-keys", "function": "CloudSyncCanonical.encode", "expect": "error",
                          "input": #"{"\u00e9":1,"e\u0301":2}"#,
                          "description": "An object whose keys are U+00E9 and e+U+0301 side by side is REFUSED (Swift compares keys by canonical equivalence). A port must refuse it too, never emit both. Parsing such JSON text in Swift keeps only the last one."])
        canonical.append(["name": "non-finite", "function": "CloudSyncCanonical.encode", "expect": "error", "input": "NaN / Infinity",
                          "description": "NaN and Infinity are refused."])
        XCTAssertThrowsError(try CloudSyncCanonical.encode(CloudValue(.number(.infinity))))
        out["canonical"] = canonical

        // f (part). Records: the contract's derived hashes.
        let payload1 = CloudValue(try NativeRPCValue.parseJSON(Data(#"{"title":"Golden note","body":"Café ☕ e\u0301","tags":["a","b"],"n":3}"#.utf8)))
        let payload2 = CloudValue(try NativeRPCValue.parseJSON(Data(#"{"title":"Golden note","body":"edited","tags":[],"n":4}"#.utf8)))
        func op(_ id: String, parents: [String], payload: CloudValue, at: Int64) throws -> CloudOperation {
            .init(v: 1, opId: id, originDevice: K.deviceA, domain: "memory", entityId: "note-1", revision: id, parents: parents, kind: .put,
                  source: .init(sourceId: "memory-notes", recordId: "note-1"), createdAt: at, payload: payload,
                  payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
        }
        let op1 = try op(K.opId1, parents: [], payload: payload1, at: K.createdAt)
        let op2 = try op(K.opId2, parents: [K.opId1], payload: payload2, at: K.createdAt + 1000)

        // b. Pack signature.
        let packBytes = try CloudSyncPack.encode([op1, op2])
        XCTAssertEqual(try CloudSyncPack.decode(packBytes), [op1, op2])
        let brainRoot = unhex(K.brainRootHex)
        let envelope = try CloudSyncContent.seal(packBytes, blobId: K.segmentId, storageClass: .brain, purpose: .brain, epoch: 1, codec: .identity,
                                                 subject: K.subject, rootKey: brainRoot, nonce: unhex(K.nonceBrainHex))
        let envelopeBytes = try CloudSyncCanonical.encode(envelope)
        let content = try CloudSyncContent(subject: K.subject, epoch: 1, keyProvider: { _ in brainRoot })
        let opened = try await content.open(envelope)
        XCTAssertEqual(opened, packBytes)
        let unsigned = CloudSegmentDescriptor(segmentId: K.segmentId, requestId: K.requestId, storageClass: .brain, purpose: .brain,
            domains: ["memory"], keyEpoch: 1, sha256: CloudSyncBytes.hash(envelopeBytes), bytes: Int64(envelopeBytes.count),
            opCount: 2, format: "td-ops-1", signature: "")
        let signingBytes = try unsigned.syncSigningBytes(subject: K.subject)
        let signature = try randomOutput("pack.signature", verifies: { raw in
            (try? signA.publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: raw), for: signingBytes)) ?? false
        }, make: { try signA.signature(for: signingBytes).rawRepresentation })
        func descriptor(_ d: CloudSegmentDescriptor, opCount: Int? = nil, signature: String) -> CloudSegmentDescriptor {
            .init(segmentId: d.segmentId, requestId: d.requestId, storageClass: d.storageClass, purpose: d.purpose, domains: d.domains,
                  keyEpoch: d.keyEpoch, sha256: d.sha256, bytes: d.bytes, opCount: opCount ?? d.opCount, format: d.format, signature: signature)
        }
        let signed = descriptor(unsigned, signature: b64u(signature))
        let keyA = try jwk(signA)
        XCTAssertEqual(signed.syncSignatureCheck(key: keyA, subject: K.subject), .valid)
        var flipped = signature; flipped[10] ^= 0x01
        let tamperedCount = descriptor(unsigned, opCount: 3, signature: b64u(signature))
        let tamperedSig = descriptor(unsigned, signature: b64u(flipped))
        XCTAssertEqual(tamperedCount.syncSignatureCheck(key: keyA, subject: K.subject), .badSignature)
        XCTAssertEqual(tamperedSig.syncSignatureCheck(key: keyA, subject: K.subject), .badSignature)
        XCTAssertEqual(signed.syncSignatureCheck(key: keyA, subject: K.deviceB), .badSignature)
        XCTAssertEqual(signed.syncSignatureCheck(key: try jwk(signB), subject: K.subject), .badSignature)
        // A gzip pack (what the engine sends) is decrypt-only: deflate output depends on the zlib build.
        let zipEnvelope = try CloudSyncContent.seal(packBytes, blobId: K.requestId, storageClass: .brain, purpose: .brain, epoch: 1, codec: .gzip,
                                                    subject: K.subject, rootKey: brainRoot, nonce: unhex(K.nonceBrainZipHex))
        let zipOpened = try await content.open(zipEnvelope)
        XCTAssertEqual(zipOpened, packBytes)
        out["packSignature"] = [
            ["name": "pack-bytes", "function": "CloudSyncPack.encode", "description": "The td-ops-1 pack: canonical array of two records (put, then an edit with the first as parent).",
             "output": text(packBytes), "outputHex": hex(packBytes)],
            ["name": "brain-envelope-identity", "function": "CloudSyncContent.seal (internal nonce seam)",
             "description": "The pack sealed for the brain class with a fixed nonce, no compression. Key = HKDF-SHA256(brainRoot, salt = blobId's 16 UUID bytes, info = \"TD-CLOUD-OBJECT-1\\nbrain\\n1\"); AAD = \"TD-CLOUD-CONTENT-1\\n\" + subject + \"\\n\" + canonical(envelope without nonce, ciphertext, tag). Deterministic: a port must produce these exact bytes.",
             "brainRootHex": K.brainRootHex, "nonceHex": K.nonceBrainHex, "blobId": K.segmentId, "subject": K.subject,
             "envelope": text(envelopeBytes), "envelopeSha256": CloudSyncBytes.hash(envelopeBytes), "envelopeBytes": envelopeBytes.count],
            ["name": "brain-envelope-gzip", "function": "CloudSyncContent.seal / CloudSyncContent.open", "expect": "decrypt-only",
             "description": "Same pack with codec gzip (what the engine sends). Must open to pack-bytes. Do not compare a port's own gzip output: deflate bytes vary by library.",
             "envelope": text(try CloudSyncCanonical.encode(zipEnvelope)), "opensTo": "pack-bytes"],
            ["name": "signing-bytes", "function": "CloudSegmentDescriptor.syncSigningBytes(subject:)",
             "description": "Exact bytes signed: canonical(descriptor without its signature member) + \"\\n\" + subject.",
             "descriptorUnsigned": text(try CloudSyncCanonical.encode(unsigned)), "subject": K.subject,
             "output": text(signingBytes), "outputHex": hex(signingBytes)],
            ["name": "signature-valid", "function": "CloudSegmentDescriptor.syncSignatureCheck(key:subject:)", "expect": "valid",
             "description": "ES256 (P-256, SHA-256) raw r||s, 64 bytes, base64url, over signing-bytes. Verify-only: CryptoKit signatures are randomized.",
             "publicKey": try jwkObject(keyA), "signatureB64u": b64u(signature), "descriptor": text(try CloudSyncCanonical.encode(signed))],
            ["name": "tampered-opcount", "function": "CloudSegmentDescriptor.syncSignatureCheck(key:subject:)", "expect": "bad-signature",
             "description": "opCount changed 2 -> 3, signature kept.", "descriptor": text(try CloudSyncCanonical.encode(tamperedCount))],
            ["name": "tampered-signature", "function": "CloudSegmentDescriptor.syncSignatureCheck(key:subject:)", "expect": "bad-signature",
             "description": "One bit of the signature flipped (byte 10).", "descriptor": text(try CloudSyncCanonical.encode(tamperedSig))],
            ["name": "wrong-subject", "function": "CloudSegmentDescriptor.syncSignatureCheck(key:subject:)", "expect": "bad-signature",
             "description": "The valid descriptor checked for another account subject.", "subject": K.deviceB],
        ] as [[String: Any]]

        // c. Device code (80 bits) for three keys.
        var codes: [[String: Any]] = []
        for (name, device, key) in [("device-a", K.deviceA, signA), ("device-b", K.deviceB, signB), ("device-c", K.deviceC, signC)] {
            let public_ = try jwk(key)
            let result = try XCTUnwrap(BackendCloudDeviceCode.code(deviceId: device, key: public_))
            codes.append(["name": name, "function": "BackendCloudDeviceCode.code(deviceId:key:)", "deviceId": device, "signPublicJwk": try jwkObject(public_),
                          "keyId": result.keyId, "code": result.code,
                          "description": "keyId = sha256 hex of {\"crv\":\"P-256\",\"kty\":\"EC\",\"x\":..,\"y\":..}; code = first 10 bytes of SHA-256(\"TD-CLOUD-DEVICE-CODE-1\\n\" + deviceId + \"\\n\" + keyId), upper-case hex in 5 groups of 4."])
        }
        XCTAssertNil(BackendCloudDeviceCode.code(deviceId: K.deviceA.uppercased(), key: try jwk(signA)))
        codes.append(["name": "upper-case-id-refused", "function": "BackendCloudDeviceCode.code(deviceId:key:)", "expect": "no-code",
                      "deviceId": K.deviceA.uppercased(), "description": "A device id not in lower case has no code."])
        out["deviceCode"] = codes

        // d. Account key wrapped for a device (CloudDeviceKeyEnvelope).
        let secretsRoot = unhex(K.secretsRootHex)
        let target = CloudDeviceRegistration(deviceId: K.deviceB, label: "Golden B", platform: .windows, appVersion: "0.0.0",
                                             signPublicJwk: try jwk(signB), wrapPublicJwk: try jwk(wrapB))
        let version = CloudSequence(7)
        let recordedWrapSig = (committed["randomOutputs"] as? [String: String])?["wrap.signature"].flatMap { try? CloudSyncBytes.unbase64($0) }
        let (wrapped, canaryHash) = try await CloudSecretsCrypto.wrapDevice(root: secretsRoot, sub: K.subject, target: target, epoch: 1,
            recoveryVersion: version, author: K.deviceA, ephemeral: ephemeral, salt: unhex(K.saltHex), nonce: unhex(K.nonceWrapHex),
            canary: unhex(K.canaryHex), sign: { bytes in
                if let old = recordedWrapSig, (try? signA.publicKey.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: old), for: bytes)) == true { return old }
                return try signA.signature(for: bytes).rawRepresentation
            })
        randomOutputs["wrap.signature"] = wrapped.signature
        let wrapAAD = try CloudSecretsCrypto.deviceAAD(wrapped)
        let unwrapped = try await CloudSecretsCrypto.unwrapDevice(wrapped, sub: K.subject, targetDeviceId: K.deviceB, epoch: 1, version: version,
            author: K.deviceA, authorKey: keyA, keys: GoldenKeyPort(wrap: wrapB))
        XCTAssertEqual(try CloudSecretsCrypto.decode(unwrapped.rootKey, count: 32), secretsRoot)
        XCTAssertEqual(unwrapped.canary, CloudSecretsCrypto.encode(unhex(K.canaryHex)))
        do {
            _ = try await CloudSecretsCrypto.unwrapDevice(wrapped, sub: K.subject, targetDeviceId: K.deviceB, epoch: 1, version: version,
                author: K.deviceA, authorKey: keyA, keys: GoldenKeyPort(wrap: wrongWrap))
            XCTFail("a wrong device key must not unwrap")
        } catch {}
        let tamperedWrap = CloudDeviceKeyEnvelope(v: 1, epoch: 1, targetDeviceId: wrapped.targetDeviceId, ephemeralPublicJwk: wrapped.ephemeralPublicJwk,
            salt: wrapped.salt, nonce: wrapped.nonce, ciphertext: (wrapped.ciphertext.first == "A" ? "B" : "A") + wrapped.ciphertext.dropFirst(), tag: wrapped.tag,
            authorDeviceId: wrapped.authorDeviceId, signature: wrapped.signature)
        do {
            _ = try await CloudSecretsCrypto.unwrapDevice(tamperedWrap, sub: K.subject, targetDeviceId: K.deviceB, epoch: 1, version: version,
                author: K.deviceA, authorKey: keyA, keys: GoldenKeyPort(wrap: wrapB))
            XCTFail("a tampered envelope must not unwrap")
        } catch {}
        let plainBody = try CloudSecretsCanonical.encode(CloudSecretsUnwrapped(epoch: 1, rootKey: CloudSecretsCrypto.encode(secretsRoot), recoveryVersion: version,
                                                                              canary: CloudSecretsCrypto.encode(unhex(K.canaryHex))))
        out["accountKeyWrap"] = [
            ["name": "wrap-for-device-b", "function": "CloudSecretsCrypto.wrapDevice (internal seam: fixed ephemeral key, salt, nonce, canary)",
             "description": "The per-account root key wrapped for device B by device A. ECDH(ephemeral, B's wrap key) -> HKDF-SHA256(shared, salt, info = \"TD-CLOUD-DEVICE-1\\n\" + subject + \"\\n\" + targetDeviceId + \"\\n\" + epoch) -> AES-256-GCM over canonical body, AAD = canonical(envelope without ciphertext, tag, signature). ciphertext and tag are deterministic from these inputs; signature (A's ES256 over AAD + ciphertext + tag) is verify-only.",
             "subject": K.subject, "epoch": 1, "recoveryVersion": version.rawValue, "author": K.deviceA, "authorSignPublicJwk": try jwkObject(keyA),
             "target": text(try CloudSyncCanonical.encode(target)), "rootKeyHex": K.secretsRootHex,
             "plainBody": text(plainBody), "aad": text(wrapAAD), "envelope": text(try CloudSecretsCanonical.encode(wrapped)),
             "canaryHash": canaryHash, "opensWith": "wrapBPrivateHex"],
            ["name": "wrong-device-key", "function": "CloudSecretsCrypto.unwrapDevice", "expect": "error",
             "description": "The same envelope opened with wrongWrapPrivateHex instead of B's wrap key must fail (GCM tag)."],
            ["name": "tampered-ciphertext", "function": "CloudSecretsCrypto.unwrapDevice", "expect": "error",
             "description": "First ciphertext character replaced ('A', or 'B' if it was 'A'): the author signature check fails.", "envelope": text(try CloudSecretsCanonical.encode(tamperedWrap))],
        ] as [[String: Any]]

        // e. Saved-password envelope (secrets content envelope).
        let secret = Data(#"{"kind":"password","host":"example.test","user":"golden","password":"p@ss wörd \"1\""}"#.utf8)
        let sealed = try CloudSecretsCrypto.sealContent(secret, root: secretsRoot, sub: K.subject, blobId: K.secretBlobId, purpose: .secret,
                                                        epoch: 1, codec: .identity, nonce: unhex(K.nonceSecretHex))
        XCTAssertEqual(try CloudSecretsCrypto.openContent(sealed, root: secretsRoot, sub: K.subject, epoch: 1), secret)
        var tag = try CloudSecretsCrypto.decode(sealed.tag, count: 16); tag[0] ^= 0x80
        let tampered = CloudContentEnvelope(v: 1, suite: sealed.suite, storageClass: .secrets, purpose: .secret, epoch: 1, blobId: sealed.blobId,
            codec: sealed.codec, plainBytes: sealed.plainBytes, nonce: sealed.nonce, ciphertext: sealed.ciphertext, tag: CloudSecretsCrypto.encode(tag))
        XCTAssertThrowsError(try CloudSecretsCrypto.openContent(tampered, root: secretsRoot, sub: K.subject, epoch: 1))
        XCTAssertThrowsError(try CloudSecretsCrypto.openContent(sealed, root: secretsRoot, sub: K.deviceB, epoch: 1))
        out["savedPasswordEnvelope"] = [
            ["name": "seal-secret", "function": "CloudSecretsCrypto.sealContent (internal nonce seam) / openContent",
             "description": "A saved password sealed under the account root. Key = HKDF-SHA256(root, salt = blobId's 16 UUID bytes, info = \"TD-CLOUD-OBJECT-1\\nsecrets\\n1\"); AAD = \"TD-CLOUD-CONTENT-1\\n\" + subject + \"\\n\" + canonical(envelope without nonce, ciphertext, tag). Deterministic with this nonce and codec identity.",
             "rootKeyHex": K.secretsRootHex, "subject": K.subject, "blobId": K.secretBlobId, "nonceHex": K.nonceSecretHex,
             "plain": text(secret), "plainHex": hex(secret), "envelope": text(try CloudSecretsCanonical.encode(sealed))],
            ["name": "tampered-tag", "function": "CloudSecretsCrypto.openContent", "expect": "error",
             "description": "First tag byte XOR 0x80.", "envelope": text(try CloudSecretsCanonical.encode(tampered))],
            ["name": "wrong-subject", "function": "CloudSecretsCrypto.openContent", "expect": "error",
             "description": "seal-secret opened for subject = deviceB's id (AAD differs).", "subject": K.deviceB],
        ] as [[String: Any]]

        // f. Derived hashes and ids.
        let approval = CloudApproval(approvalId: K.approvalId, targetDeviceId: K.deviceB, targetKeyHash: try CloudSecretsCrypto.keyHash(target),
                                     challenge: "golden-challenge", expiresAt: K.createdAt + 600_000)
        let challenge = BackendCloudAccountIdentity.base64(Data(SHA256.hash(data: Data(K.pkceVerifier.utf8))))
        out["derived"] = [
            ["name": "record-payload-hash", "function": "CloudSyncBytes.hash(CloudSyncCanonical.encode(payload))",
             "description": "A record's payloadHash: sha256 hex of its canonical payload.", "payload": text(try CloudSyncCanonical.encode(payload1)), "output": op1.payloadHash],
            ["name": "record-canonical", "function": "CloudSyncCanonical.encode(CloudOperation)",
             "description": "A whole record in canonical form and its sha256 (optional members projectId/rootId absent, not null).",
             "output": text(try CloudSyncCanonical.encode(op1)), "outputSha256": CloudSyncBytes.hash(try CloudSyncCanonical.encode(op1))],
            ["name": "pack-sha256", "function": "CloudSyncBytes.hash(CloudSyncCanonical.encode(envelope))",
             "description": "The descriptor's sha256: hex of the canonical sealed envelope bytes (brain-envelope-identity).", "output": unsigned.sha256],
            ["name": "device-key-hash", "function": "CloudSecretsCrypto.keyHash",
             "description": "sha256 hex of canonical {signPublicJwk, wrapPublicJwk} of a registration.", "input": text(try CloudSyncCanonical.encode(target)), "output": approval.targetKeyHash],
            ["name": "matching-code", "function": "CloudSecretsCrypto.matchingCode",
             "description": "First 32 hex of SHA-256(\"TD-CLOUD-APPROVAL-TARGET-2\\n\" + targetDeviceId + \"\\n\" + targetKeyHash), upper case, groups of 4.",
             "approval": text(try CloudSyncCanonical.encode(approval)), "output": CloudSecretsCrypto.matchingCode(approval)],
            ["name": "transfer-code", "function": "CloudSecretsCrypto.transferCode",
             "description": "First 20 hex of SHA-256(\"TD-CLOUD-APPROVAL-TRANSFER-2\\n\" + canonical binding), upper case, groups of 4. Uses wrap-for-device-b's envelope.",
             "issuer": CloudWire.issuer, "output": try CloudSecretsCrypto.transferCode(subject: .init(issuer: CloudWire.issuer, sub: K.subject), approval: approval,
                                                                                     target: target, authorKey: keyA, envelope: wrapped)],
            ["name": "callback-pkce-challenge", "function": "BackendCloudAccount.beginSignIn (inline: base64url(SHA256(verifier)))",
             "description": "The sign-in callback's PKCE S256 challenge for a fixed verifier.", "verifier": K.pkceVerifier, "output": challenge],
            ["name": "random-ids", "function": "UUID().uuidString.lowercased()", "expect": "not-derived",
             "description": "opId, segmentId (pack id), requestId and blobId are fresh random v4 UUIDs in lower case, not derived from content. A port must generate them the same way: CloudSyncBytes.transportID refuses anything else."],
        ] as [[String: Any]]
        out["randomOutputs"] = randomOutputs

        let produced = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
        guard let existing = try? Data(contentsOf: fixtureURL) else {
            try FileManager.default.createDirectory(at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try produced.write(to: fixtureURL)
            return XCTFail("Golden vectors written for the first time at \(fixtureURL.path); commit it and run again.")
        }
        if existing != produced {
            try produced.write(to: fixtureURL.deletingPathExtension().appendingPathExtension("actual.json"))
            XCTFail("Golden vectors drifted from the committed copy; see cloud-golden-vectors.actual.json beside it.")
        }
    }
}
