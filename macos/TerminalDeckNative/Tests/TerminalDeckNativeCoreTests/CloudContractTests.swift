import Foundation
import Testing
@testable import TerminalDeckNativeCore

@Suite("Cloud contract — the shared wire boundary")
struct CloudContractTests {
    @Test func sequenceNeverUsesJSONNumbers() throws {
        let values = ["0", "1", "9007199254740993", "18446744073709551615"]
        let sequences = try values.map { try CloudSequence(rawValue: $0) }
        #expect(sequences.sorted().map { $0.rawValue } == values)
        for value in sequences {
            let data = try CloudWire.canonical(value)
            #expect(String(decoding: data, as: UTF8.self) == "\"\(value.rawValue)\"")
            #expect(try CloudWire.decode(CloudSequence.self, from: data) == value)
        }
    }
    @Test(arguments: ["", "01", "-1", "1.0", "18446744073709551616", " 1", "١"])
    func badSequenceIsRefused(_ value: String) {
        #expect(throws: CloudFailure.invalidRequest) { try CloudSequence(rawValue: value) }
    }
    @Test func numericSequenceFromServerIsRefused() {
        #expect(throws: (any Error).self) { try CloudWire.decode(CloudSequence.self, from: Data("1".utf8)) }
    }
    @Test func duplicateKeysCannotChangeSignedMeaning() {
        #expect(throws: CloudFailure.invalidRequest) {
            try CloudWire.decode(CloudGate.self, from: Data(#"{"features":[],"features":["cloud"]}"#.utf8))
        }
        #expect(throws: CloudFailure.invalidRequest) {
            try CloudWire.decode(CloudValue.self, from: Data(#"{"nested":{"a":1,"a":2}}"#.utf8))
        }
    }
    @Test func requestUnknownFieldsFailClosed() {
        #expect(throws: CloudFailure.invalidRequest) {
            try CloudWire.decode(CloudGate.self, from: Data(#"{"features":[],"userId":"other"}"#.utf8), allowedKeys: ["features"])
        }
    }
    @Test func oversizedAndMalformedJSONAreRefused() {
        #expect(throws: CloudFailure.invalidRequest) { try CloudWire.decode(CloudGate.self, from: Data("{".utf8)) }
        #expect(throws: CloudFailure.invalidRequest) { try CloudWire.decode(CloudGate.self, from: Data(#"{"features":[]}"#.utf8), maximumBytes: 2) }
    }
    @Test func excessiveDepthIsRefusedBeforeTheExistingParserRuns() {
        let deeplyNested = Data((String(repeating: "[", count: 129) + "0" + String(repeating: "]", count: 129)).utf8)
        #expect(throws: CloudFailure.invalidRequest) { try CloudWire.decode(CloudValue.self, from: deeplyNested) }
    }
    @Test func canonicalObjectOrderAndScalarTypesMatch() throws {
        let value = CloudValue(.object([.init("z", .number(1)), .init("a", .array([.bool(true), .string("1"), .null]))]))
        #expect(String(decoding: try CloudWire.canonical(value), as: UTF8.self) == #"{"a":[true,"1",null],"z":1}"#)
        let decoded = try CloudWire.decode(CloudValue.self, from: Data(#"{"z":1,"a":true}"#.utf8))
        #expect(decoded.raw["a"] == .bool(true))
        #expect(decoded.raw["z"] == .number(1))
    }
    @Test func payloadIdentitySurvivesPersistenceWithDifferentFieldOrder() throws {
        let original = CloudValue(.object([.init("z", .number(1)), .init("a", .string("same content"))]))
        let restored = try CloudWire.decode(CloudValue.self, from: CloudWire.canonical(original))
        #expect(original == restored)
        #expect(original != CloudValue(.object([.init("a", .string("different")), .init("z", .number(1))])))
    }
    @Test func nonJSONValuesAreNotSigned() {
        #expect(throws: (any Error).self) { try CloudWire.canonical(CloudValue(.bytes(Data([1])))) }
        #expect(throws: (any Error).self) { try CloudWire.canonical(CloudValue(.number(.infinity))) }
        #expect(throws: (any Error).self) { try CloudWire.canonical(CloudValue(.missing)) }
    }
    @Test func gateRequiresCurrentExplicitEntitlement() {
        let now: Int64 = 1_800_000_000_000
        #expect(!CloudGate.closed.permitsCloud(at: now))
        #expect(!CloudGate(features: ["cloud"], storageEntitled: false, expiresAt: now + 100).permitsCloud(at: now))
        #expect(!CloudGate(features: ["cloud"], storageEntitled: true, expiresAt: now).permitsCloud(at: now))
        #expect(!CloudGate(features: ["cloud"], storageEntitled: true, expiresAt: now + 300_001).permitsCloud(at: now))
        #expect(CloudGate(features: ["cloud"], storageEntitled: true, expiresAt: now + 300_000).permitsCloud(at: now))
    }
    @Test func workSurvivesWithoutSecretsButSecretsNeverBecomeBrain() {
        for purpose in [CloudPurpose.backup, .artifact, .database] {
            #expect(purpose.permits(.brain))
            #expect(purpose.permits(.secrets))
        }
        for purpose in [CloudPurpose.secret, .browser, .aiSubscription] { #expect(!purpose.permits(.brain)) }
        #expect(!CloudPurpose.brain.permits(.secrets))
    }
    @Test func storageClassUsesExistingWireName() throws {
        let blob = CloudBlobRef(blobId: "blob", sha256: "hash", md5: "md5", bytes: 1, storageClass: .brain, purpose: .backup, keyEpoch: 1)
        let json = String(decoding: try CloudWire.canonical(blob), as: UTF8.self)
        #expect(json.contains(#""class":"brain""#))
        #expect(!json.contains("storageClass"))
        #expect(try CloudWire.decode(CloudBlobRef.self, from: Data(json.utf8)) == blob)
    }
    @Test func sealedFileReferenceIsKnownBeforeUploadWithoutRewritingBytes() throws {
        let local = CloudLocalBlob(blobId: "fixture-blob", sourceId: "fixture-source", localURL: URL(fileURLWithPath: "/fixture/sealed-envelope.json"), bytes: 50, sha256: "cipher-sha", md5: "cipher-md5", keyEpoch: 3, storageClass: .brain, purpose: .backup)
        #expect(local.reference.blobId == local.blobId)
        #expect(local.reference.sha256 == local.sha256)
        #expect(local.reference.md5 == "cipher-md5")
        #expect(local.reference.keyEpoch == 3)
        #expect(local.reference.bytes == 50)
        #expect(try CloudWire.decode(CloudLocalBlob.self, from: CloudWire.canonical(local)) == local)
    }
    @Test func ownDeviceKeysAreAvailableForApprovalWithoutPrivateMaterial() throws {
        let wire = Data(#"{"devices":[{"deviceId":"fixture-device","label":"Fixture Mac","platform":"macos","appVersion":"test","status":"active","secretsApproved":false,"lastSeenAt":0,"signPublicJwk":{"kty":"EC","crv":"P-256","x":"fixture-sign-x","y":"fixture-sign-y"},"wrapPublicJwk":{"kty":"EC","crv":"P-256","x":"fixture-wrap-x","y":"fixture-wrap-y"}}],"receiverDeviceId":null}"#.utf8)
        let list = try CloudWire.decode(CloudDeviceList.self, from: wire)
        #expect(list.devices.count == 1)
        #expect(list.devices[0].signPublicJwk.x == "fixture-sign-x")
        #expect(list.devices[0].wrapPublicJwk.x == "fixture-wrap-x")
        #expect(!String(decoding: try CloudWire.canonical(list), as: UTF8.self).contains(#""d":"#))
    }
    @Test func recoveryCounterIsAStringAndFormatAndEpochAreNumbers() throws {
        let publicKey = CloudPublicJWK(kty: "OKP", crv: "Ed25519", x: "fixture-public")
        let envelope = CloudRecoveryEnvelope(v: 1, version: CloudSequence(1), epoch: 1, suite: "A256GCM", nonce: "fixture-nonce", ciphertext: "fixture-ciphertext", tag: "fixture-tag", publicSigningJwk: publicKey)
        let json = String(decoding: try CloudWire.canonical(envelope), as: UTF8.self)
        #expect(json.contains(#""version":"1""#))
        #expect(json.contains(#""epoch":1"#))
        #expect(!json.contains(#""y""#))
    }
    @Test func fixtureCoversTheSharedSchemaAndThirtyInventoryRows() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("design-2026-11-12-cloud/fixtures/cloud-contract-v1.json")
        let fixture = try CloudWire.decode(CloudValue.self, from: Data(contentsOf: file))
        #expect(fixture.raw["v"].number == 1)
        #expect(fixture.raw["base"].string?.contains("example.invalid") == true)
        let operation = try CloudWire.decode(CloudOperation.self, from: fixture.raw["operation"].encodedJSON(), allowedKeys: CloudFixtureSchema.requiredOperationKeys)
        #expect(operation.kind == .put)
        #expect(operation.source.recordId == "note-1")
        #expect(CloudFixtureSchema.inventoryRows.count == 30)
        #expect(CloudFixtureSchema.forbiddenSourceTables.count == 4)
    }
}
