import XCTest
import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore

final class CloudSyncContentTests: XCTestCase, @unchecked Sendable {
  struct Vector: Decodable {
    let subject: String
    let rootKeyHex: String
    let blobId: String
    let nonceHex: String
    let plainBase64url: String
    let derivedKeyHex: String
    let aadUTF8: String
    let envelope: CloudContentEnvelope
    let serializedUTF8: String
    let sha256: String
    let md5: String
  }
  func hex(_ value: String) -> Data {
    Data(stride(from: 0, to: value.count, by: 2).map {
      let start = value.index(value.startIndex, offsetBy: $0)
      return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
    })
  }
  func testIndependentAESGCMHKDFSharedVector() async throws {
    let source = URL(fileURLWithPath: #filePath)
    let macos = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: macos.appendingPathComponent("design-2026-11-12-cloud/vectors/brain-envelope.json")))
    let root = hex(vector.rootKeyHex), nonce = hex(vector.nonceHex)
    let plain = try CloudSyncBytes.unbase64(vector.plainBase64url)
    let envelope = try CloudSyncContent.seal(plain, blobId: vector.blobId, storageClass: .brain, purpose: .brain, epoch: 1,
      codec: .identity, subject: vector.subject, rootKey: root, nonce: nonce)
    XCTAssertEqual(envelope, vector.envelope)
    let derived = try CloudSyncContent.objectKey(root, blobId: vector.blobId, epoch: 1)
    XCTAssertEqual(derived.withUnsafeBytes { Data($0) }, hex(vector.derivedKeyHex))
    XCTAssertEqual(try CloudSyncContent.aad(envelope, subject: vector.subject), Data(vector.aadUTF8.utf8))
    let serialized = try CloudSyncCanonical.encode(envelope)
    XCTAssertEqual(serialized, Data(vector.serializedUTF8.utf8))
    XCTAssertEqual(CloudSyncBytes.hash(serialized), vector.sha256)
    XCTAssertEqual(CloudSyncBytes.blob(serialized, envelope: envelope).md5, vector.md5)
    let content = try CloudSyncContent(subject: vector.subject, epoch: 1, keyProvider: { _ in root })
    let opened = try await content.open(envelope)
    XCTAssertEqual(opened, plain)
  }
  func testGzipOnlyWhenSmallerBoundedAndAuthenticated() async throws {
    let key = Data(repeating: 9, count: 32)
    let content = try CloudSyncContent(subject: "11111111-1111-4111-8111-111111111111", epoch: 1, keyProvider: { _ in key })
    let plain = Data(repeating: 65, count: 100_000)
    let id = UUID().uuidString.lowercased()
    let envelope = try await content.seal(plain, blobId: id, storageClass: .brain, purpose: .brain, epoch: 1, codec: .gzip)
    XCTAssertEqual(envelope.codec, .gzip)
    let opened = try await content.open(envelope)
    XCTAssertEqual(opened, plain)
    let tiny = try await content.seal(Data([1]), blobId: UUID().uuidString.lowercased(), storageClass: .brain, purpose: .brain, epoch: 1, codec: .gzip)
    XCTAssertEqual(tiny.codec, .identity)
    do { _ = try await content.seal(plain, blobId: id, storageClass: .brain, purpose: .brain, epoch: 1, codec: .gzip); XCTFail("Blob id reused") }
    catch { XCTAssertEqual(error as? CloudFailure, .idReused) }
    let modified = CloudContentEnvelope(v: 1, suite: envelope.suite, storageClass: .brain, purpose: .brain, epoch: 1, blobId: id,
      codec: .gzip, plainBytes: 1, nonce: envelope.nonce, ciphertext: envelope.ciphertext, tag: envelope.tag)
    do { _ = try await content.open(modified); XCTFail("Header tamper accepted") } catch { XCTAssertEqual(error as? CloudFailure, .checksumMismatch) }
    let compressed = try CloudSyncGzip.transform(plain, compress: true)
    XCTAssertThrowsError(try CloudSyncGzip.transform(compressed, compress: false, limit: 10))
    XCTAssertThrowsError(try CloudSyncGzip.transform(compressed + Data([0]), compress: false))
  }
  func testCanonicalRFC8785NumericAndUTF16Order() throws {
    let payload = CloudValue(.object([
      .init("z", .number(0.000001)), .init("a", .number(Double("1000000000000000100")!)),
      .init("negativeZero", .number(-0.0)), .init("large", .number(1e30)),
      .init("😀", .number(1)), .init("\u{E000}", .number(2))
    ]))
    let encoded = try CloudSyncCanonical.encode(payload)
    XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "{\"a\":1000000000000000100,\"large\":1e+30,\"negativeZero\":0,\"z\":0.000001,\"😀\":1,\"\u{E000}\":2}")
    XCTAssertThrowsError(try CloudWire.decode(CloudValue.self, from: Data("{\"x\":1,\"x\":2}".utf8)))
    XCTAssertThrowsError(try CloudSyncCanonical.encode(CloudValue(.number(.infinity))))
    XCTAssertThrowsError(try CloudSyncBytes.unbase64("not/padded=="))
  }
  func testWrongAccountAndSecretClassCannotOpenBrain() async throws {
    let key = Data(repeating: 7, count: 32)
    let content = try CloudSyncContent(subject: "11111111-1111-4111-8111-111111111111", epoch: 1, keyProvider: { _ in key })
    let other = try CloudSyncContent(subject: "44444444-4444-4444-8444-444444444444", epoch: 1, keyProvider: { _ in key })
    let envelope = try await content.seal(Data("fixture".utf8), blobId: UUID().uuidString.lowercased(), storageClass: .brain, purpose: .brain, epoch: 1, codec: .identity)
    do { _ = try await other.open(envelope); XCTFail("Cross-account decryption") } catch { XCTAssertEqual(error as? CloudFailure, .checksumMismatch) }
    do { _ = try await content.seal(Data(), blobId: UUID().uuidString.lowercased(), storageClass: .secrets, purpose: .secret, epoch: 1, codec: .identity); XCTFail("Brain accepted secrets") }
    catch { XCTAssertEqual(error as? CloudFailure, .invalidRequest) }
    let state = await content.state(storageClass: .secrets)
    XCTAssertFalse(state.available)
  }
}
