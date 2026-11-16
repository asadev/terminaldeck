import XCTest
import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore

struct CloudSyncFixtureAuth: CloudAuthenticationPort {
  var allowDevice = true
  static let key = try! P256.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
  static let device = "33333333-3333-4333-8333-333333333333"
  func credentials() async throws -> CloudAuthSession {
    .init(accessToken: "fixture-only-access", refreshToken: "fixture-only-refresh", expiresAt: CloudSyncBytes.now() + 3_600_000,
      user: .init(id: "11111111-1111-4111-8111-111111111111", displayName: "Fixture"), capabilities: .init(features: ["cloud"]))
  }
  func deviceRegistration() async throws -> CloudDeviceRegistration {
    guard allowDevice else { throw CloudFailure.unavailable }
    let sign = Data(Self.key.publicKey.x963Representation.dropFirst())
    let wrap = Data(try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32)).publicKey.x963Representation.dropFirst())
    return .init(deviceId: Self.device, label: "Fixture", platform: .macos, appVersion: "fixture",
      signPublicJwk: .init(kty: "EC", crv: "P-256", x: CloudSyncBytes.base64(sign.prefix(32)), y: CloudSyncBytes.base64(sign.suffix(32))),
      wrapPublicJwk: .init(kty: "EC", crv: "P-256", x: CloudSyncBytes.base64(wrap.prefix(32)), y: CloudSyncBytes.base64(wrap.suffix(32))))
  }
  func signRequest(method: String, pathAndQuery: String, body: Data, timestamp: Int64, requestId: String) async throws -> CloudRequestProof {
    guard allowDevice else { throw CloudFailure.unavailable }
    let message = "TD-CLOUD-1\n\(method)\n\(pathAndQuery)\n\(timestamp)\n\(requestId)\n\(CloudSyncBytes.hash(body))"
    return .init(deviceId: Self.device, time: timestamp, requestId: requestId,
      signature: CloudSyncBytes.base64(try Self.key.signature(for: Data(message.utf8)).rawRepresentation))
  }
}

private final class CloudSyncFixtureHTTP: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  /// 14 Nov: the app keeps no request count any more, so the fixture counts what reaches it, per test run
  /// (`X-Fixture-Run`, set on the test's session).
  static let tally = NSLock()
  nonisolated(unsafe) static var counts: [String: Int] = [:]
  static func count(_ run: String) -> Int { tally.lock(); defer { tally.unlock() }; return counts[run] ?? 0 }
  override func startLoading() {
    if let run = request.value(forHTTPHeaderField: "X-Fixture-Run") {
      Self.tally.lock(); Self.counts[run, default: 0] += 1; Self.tally.unlock()
    }
    do {
      guard let url = request.url, url.host?.hasSuffix(".test") == true else { throw CloudFailure.unsafeConfiguration }
      var body = request.httpBody ?? Data()
      if let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let n = stream.read(&buffer, maxLength: buffer.count)
          if n == 0 { break }
          guard n > 0 else { throw CloudFailure.invalidRequest }
          body.append(contentsOf: buffer.prefix(n))
        }
      }
      if url.path == "/v1/capabilities" {
        let status = url.host == "paused.test" ? 429 : 200
        struct Failure: Encodable { let error: CloudErrorDetail }
        let data = status == 200
          ? try CloudSyncCanonical.encode(CloudGate(features: ["cloud"], storageEntitled: true))
          : try CloudSyncCanonical.encode(Failure(error: .init(code: "budget_paused", message: "Fixture quota.", retryable: true, requestId: request.value(forHTTPHeaderField: "X-TD-Request")!)))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
        return
      }
      guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only-access",
        request.value(forHTTPHeaderField: "X-TD-Device") == CloudSyncFixtureAuth.device,
        let time = request.value(forHTTPHeaderField: "X-TD-Time"),
        let id = request.value(forHTTPHeaderField: "X-TD-Request"),
        let signature = request.value(forHTTPHeaderField: "X-TD-Signature") else { throw CloudFailure.invalidRequest }
      if let host = url.host, ["skewed.test", "always-skewed.test", "badproof.test"].contains(host) {
        // Like the service: the request's time is judged BEFORE its signature. skewed.test runs ten minutes
        // ahead of this Mac and accepts a time within a minute of its own; always-skewed.test never agrees;
        // badproof.test refuses the signature.
        struct Refusal: Encodable {
          struct Detail: Encodable { let code: String; let message: String; let retryable: Bool; let serverTime: Int64?; let requestId: String }
          let error: Detail
        }
        let serverNow = CloudSyncBytes.now() + 600_000, sent = Int64(time) ?? 0
        var refusal: (Int, Refusal.Detail)? = nil
        if host == "badproof.test" {
          refusal = (401, .init(code: "bad_device_proof", message: "Fixture proof refused.", retryable: false, serverTime: nil, requestId: id))
        } else if host == "always-skewed.test" {
          refusal = (400, .init(code: "clock_skew", message: "Fixture clock.", retryable: true, serverTime: sent + 600_000, requestId: id))
        } else if abs(sent - serverNow) > 60_000 {
          refusal = (400, .init(code: "clock_skew", message: "Fixture clock.", retryable: true, serverTime: serverNow, requestId: id))
        }
        if let (code, detail) = refusal {
          let data = try CloudSyncCanonical.encode(Refusal(error: detail))
          client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
          client?.urlProtocol(self, didLoad: data)
          client?.urlProtocolDidFinishLoading(self)
          return
        }
      }
      let path = url.path + (url.query.map { "?" + $0 } ?? "")
      let message = "TD-CLOUD-1\n\(request.httpMethod!)\n\(path)\n\(time)\n\(id)\n\(CloudSyncBytes.hash(body))"
      let proof = try P256.Signing.ECDSASignature(rawRepresentation: CloudSyncBytes.unbase64(signature))
      guard CloudSyncFixtureAuth.key.publicKey.isValidSignature(proof, for: Data(message.utf8)) else { throw CloudFailure.checksumMismatch }
      let status: Int
      let result: Data
      if url.host == "paused.test" {
        status = 429
        struct Failure: Encodable { let error: CloudErrorDetail }
        result = try CloudSyncCanonical.encode(Failure(error: .init(code: "budget_paused", message: "Fixture quota.", retryable: true, retryAfterMs: 1000, requestId: id)))
      } else if request.httpMethod == "GET", url.path == "/v1/changes", url.query == "after=9007199254740993&limit=17" {
        status = 200
        result = try CloudSyncCanonical.encode(CloudChangePage(segments: [], headSeq: CloudSequence(9_007_199_254_740_993), nextAfter: CloudSequence(9_007_199_254_740_993), hasMore: false))
      } else if request.httpMethod == "POST", url.path == "/v1/applied" {
        struct Applied: Decodable { let brainSeq: CloudSequence; let secretsSeq: CloudSequence }
        let value = try CloudWire.decode(Applied.self, from: body, allowedKeys: ["brainSeq", "secretsSeq", "checkpointId"])
        status = 200
        result = try CloudSyncCanonical.encode(CloudAppliedReceipt(brainSeq: value.brainSeq, secretsSeq: value.secretsSeq))
      } else if request.httpMethod == "POST", url.path == "/v1/blobs/read" {
        struct IDs: Decodable { let blobIds: [String] }
        struct Items: Encodable { let items: [CloudBlobDownload] }
        let ids = try CloudWire.decode(IDs.self, from: body).blobIds
        let bytes = Data([1])
        status = 200
        result = try CloudSyncCanonical.encode(Items(items: ids.map {
          .init(blob: .init(blobId: $0, sha256: CloudSyncBytes.hash(bytes), md5: Data(Insecure.MD5.hash(data: bytes)).base64EncodedString(), bytes: 1,
            storageClass: .brain, purpose: .brain, keyEpoch: 1), getUrl: URL(string: "https://cloud.test/v1/transfers/" + $0 + "?request=" + id)!, expiresAt: CloudSyncBytes.now() + 60_000)
        }))
      } else if request.httpMethod == "POST", url.path == "/v1/brain-key" {
        struct Key: Encodable { let epoch: Int; let key: String }
        status = 200
        result = try CloudSyncCanonical.encode(Key(epoch: 1, key: CloudSyncBytes.base64(Data(0..<32))))
      } else if request.httpMethod == "GET", url.path == "/v1/capabilities" {
        status = 200
        result = try CloudSyncCanonical.encode(CloudGate(features: ["cloud"], storageEntitled: true))
      } else if url.path == "/v1/secrets/echo" {
        // Saved-password control route: reached only after the token and device proof above checked for exactly
        // these bytes. Says what arrived.
        struct Echo: Encodable { let method: String; let requestId: String; let bodyHash: String }
        status = 200
        result = try CloudSyncCanonical.encode(Echo(method: request.httpMethod!, requestId: id, bodyHash: CloudSyncBytes.hash(body)))
      } else if url.path == "/v1/secrets/locked" || url.path == "/v1/secrets/refused" {
        struct Failure: Encodable { let error: CloudErrorDetail }
        status = 403
        result = try CloudSyncCanonical.encode(Failure(error: .init(code: url.path.hasSuffix("locked") ? "secrets_locked" : "not_approved",
          message: "Fixture refusal.", retryable: false, requestId: id)))
      } else if url.path == "/v1/secrets/spare/add" {
        // 14 Nov: service 7ff81baac refusing a passkey check on the spare route (after the device proof passed).
        struct Failure: Encodable { let error: CloudErrorDetail }
        status = 401
        result = try CloudSyncCanonical.encode(Failure(error: .init(code: "bad_device_proof", message: "Fixture passkey refusal.",
          retryable: false, requestId: id)))
      } else if url.path == "/v1/secrets/gone" || url.path == "/v1/secrets/bare404" {
        // N1: a saved-password route's "not there" (an approval, challenge or device that is not there).
        struct Failure: Encodable { let error: CloudErrorDetail }
        status = 404
        if url.path.hasSuffix("gone") {
          result = try CloudSyncCanonical.encode(Failure(error: .init(code: "not_found", message: "Fixture: no such approval.", retryable: false, requestId: id)))
        } else { result = Data() }
      } else { throw CloudFailure.invalidRequest }
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Retry-After": "1"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: result)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

final class CloudSyncTransportTests: XCTestCase, @unchecked Sendable {
  /// A transport on the URLProtocol fixture for `host`, with its own scratch store and budget.
  func fixtureTransport(host: String = "cloud.test", root: URL) throws -> (CloudSyncTransport, CloudSyncStore, CloudSyncBudget) {
    let store = try CloudSyncStore(root: root, subject: .init(issuer: "https://identity.test", sub: "11111111-1111-4111-8111-111111111111"))
    let budget = CloudSyncBudget(store: store)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CloudSyncFixtureHTTP.self]
    config.httpAdditionalHeaders = ["X-Fixture-Run": root.lastPathComponent]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://" + host + "/v1")!, environment: .test, objectHosts: ["objects.test"])
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store, budget: budget,
      fixtureSession: URLSession(configuration: config))
    return (transport, store, budget)
  }
  /// Requests that reached the fixture for the run in `root`.
  func sent(_ root: URL) -> Int { CloudSyncFixtureHTTP.count(root.lastPathComponent) }

  /// The service answers `400 clock_skew` with its own time when this Mac's clock is more than a minute off. The
  /// transport corrects the time it signs with from that answer and sends the same request once more; the
  /// correction is kept (also across a restart) and is what `serviceTime()` reports.
  func testClockSkewAnswerCorrectsTheSigningTimeAndRetriesOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-skew-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (transport, store, budget) = try fixtureTransport(host: "skewed.test", root: root)
    let page = try await transport.changes(after: CloudSequence(9_007_199_254_740_993), limit: 17)
    XCTAssertEqual(page.nextAfter.rawValue, "9007199254740993", "the corrected retry was accepted")
    var state = try await budget.status()
    XCTAssertEqual(sent(root), 2, "the refused request and ONE corrected retry")
    XCTAssertEqual(state.failures, 0, "a corrected clock is not a failure")
    XCTAssertNil(state.blocked)
    let offset: Int64 = try XCTUnwrap(store.value("signingClockOffset"))
    XCTAssertLessThan(abs(offset - 600_000), 5_000)
    let serviceNow = try XCTUnwrap(CloudSyncServiceClock.serviceTime(store))
    XCTAssertLessThan(abs(serviceNow - CloudSyncBytes.now() - 600_000), 5_000)
    XCTAssertNil(try store.value("clockSkew") as String?)
    // The correction is kept: the next request is signed right the first time.
    _ = try await transport.changes(after: CloudSequence(9_007_199_254_740_993), limit: 17)
    XCTAssertEqual(sent(root), 3)
    await transport.stop()
    // Also after a restart.
    let (restarted, _, sameBudget) = try fixtureTransport(host: "skewed.test", root: root)
    _ = try await restarted.changes(after: CloudSequence(9_007_199_254_740_993), limit: 17)
    _ = sameBudget
    XCTAssertEqual(sent(root), 4)
    await restarted.stop()
  }

  /// A service that refuses the clock again after the correction is "no answer": one retry and no more, an
  /// ordinary failed request with back-off, a reason lane A can show, and never a sign-in failure.
  func testRepeatedClockSkewIsNoAnswerWithAReasonNeverALoopOrASignOut() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-skew-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (transport, store, budget) = try fixtureTransport(host: "always-skewed.test", root: root)
    do { _ = try await transport.changes(after: CloudSequence(9_007_199_254_740_993), limit: 17); XCTFail("A refused clock was answered") }
    catch {
      guard case .remote(let detail)? = error as? CloudFailure else { return XCTFail("\(error)") }
      XCTAssertEqual(detail.code, "clock_skew")
    }
    let state = try await budget.status()
    XCTAssertEqual(sent(root), 2, "one corrected retry, then it stops")
    XCTAssertEqual(state.failures, 1)
    XCTAssertNil(state.blocked, "a wrong clock is never treated as a sign-in or device failure")
    XCTAssertEqual(try store.value("clockSkew") as String?, "Check this Mac's date and time.")
    await transport.stop()
  }

  /// A wrong signature stays `bad_device_proof`: it is not retried as a clock problem and corrects nothing.
  func testWrongSignatureIsNotRetriedAsAClockProblem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-skew-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (transport, store, budget) = try fixtureTransport(host: "badproof.test", root: root)
    do { _ = try await transport.changes(after: CloudSequence(9_007_199_254_740_993), limit: 17); XCTFail("A refused proof was answered") }
    catch {
      guard case .remote(let detail)? = error as? CloudFailure else { return XCTFail("\(error)") }
      XCTAssertEqual(detail.code, "bad_device_proof")
    }
    let state = try await budget.status()
    XCTAssertEqual(sent(root), 1, "no second attempt")
    XCTAssertNil(try store.value("signingClockOffset") as Int64?)
    XCTAssertNil(try store.value("clockSkew") as String?)
    await transport.stop()
  }

  /// Lane V's control port. The caller's exact bytes reach the saved-password route under this transport's own
  /// token and device proof (the fixture refuses anything whose proof does not cover these bytes and this request
  /// id) and count against the same budget. Errors come back as for every control call; a saved-password refusal
  /// does not pause memory; and no path outside `/secrets/…` can be named.
  func testControlSenderSignsTheExactBytesForSavedPasswordRoutesOnly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-control-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (transport, _, budget) = try fixtureTransport(root: root)
    let body = Data("{ \"b\": 1,  \"a\": 2 }".utf8)   // deliberately not canonical: the bytes go out as given
    let id = UUID().uuidString.lowercased()
    let answer = try await transport.control(method: "POST", path: "/secrets/echo", body: body, requestId: id)
    struct Echo: Decodable { let method: String; let requestId: String; let bodyHash: String }
    let echo = try JSONDecoder().decode(Echo.self, from: answer)
    XCTAssertEqual(echo.method, "POST")
    XCTAssertEqual(echo.requestId, id, "X-TD-Request is the caller's request id")
    XCTAssertEqual(echo.bodyHash, CloudSyncBytes.hash(body), "the exact bytes were signed and sent")
    XCTAssertEqual(sent(root), 1, "one request")

    // Nothing outside the saved-password routes, and nothing malformed, leaves this Mac.
    let outside = ["/changes", "/devices", "/secrets", "/secrets/", "/secrets/../devices", "/secrets//x", "/secretsx/y", "/secrets/x#y",
      "/secrets/x y", "https://evil.test/secrets/x", "/secrets/x?next=/devices", "/secrets/x@evil.test", "/secrets/%2e%2e/devices"]
    for path in outside {
      do { _ = try await transport.control(method: "POST", path: path, body: Data("{}".utf8), requestId: UUID().uuidString.lowercased()); XCTFail(path) }
      catch { XCTAssertEqual(error as? CloudFailure, .invalidRequest, path) }
    }
    do { _ = try await transport.control(method: "PATCH", path: "/secrets/echo", body: Data(), requestId: UUID().uuidString.lowercased()); XCTFail("method") }
    catch { XCTAssertEqual(error as? CloudFailure, .invalidRequest) }
    do { _ = try await transport.control(method: "GET", path: "/secrets/echo", body: Data("{}".utf8), requestId: UUID().uuidString.lowercased()); XCTFail("GET body") }
    catch { XCTAssertEqual(error as? CloudFailure, .invalidRequest) }
    do { _ = try await transport.control(method: "POST", path: "/secrets/echo", body: Data(), requestId: "not-a-request-id"); XCTFail("request id") }
    catch { XCTAssertEqual(error as? CloudFailure, .invalidRequest) }
    XCTAssertEqual(sent(root), 1, "a refused call sends nothing")

    // The same error handling as the other control calls.
    do { _ = try await transport.control(method: "POST", path: "/secrets/locked", body: Data("{}".utf8), requestId: UUID().uuidString.lowercased()); XCTFail("locked") }
    catch { XCTAssertEqual(error as? CloudFailure, .secretsLocked) }
    do { _ = try await transport.control(method: "POST", path: "/secrets/refused", body: Data("{}".utf8), requestId: UUID().uuidString.lowercased()); XCTFail("refused") }
    catch {
      guard case .remote(let detail)? = error as? CloudFailure else { return XCTFail("\(error)") }
      XCTAssertEqual(detail.code, "not_approved")
    }
    // A saved-password refusal is lane V's to handle: memory goes on.
    let state = try await budget.status()
    XCTAssertNil(state.blocked)
    XCTAssertEqual(state.failures, 0)
    let page = try await transport.changes(after: CloudSequence(9_007_199_254_740_993), limit: 17)
    XCTAssertEqual(page.nextAfter.rawValue, "9007199254740993")
    await transport.stop()
  }
  /// 14 Nov (the owner's Mac mini, 14:19:27Z): a refused passkey spare add answered 401 bad_device_proof; the
  /// account's back-off then refused the next sync fetch on this Mac ("fetch failed: budgetPaused / http 401
  /// bad_device_proof at POST /v1/secrets/…") and the page could say "sign in again". It is the spare route's answer.
  func testRefusedSpareAddIsTheSpareRoutesAnswerAndNeverPausesSync() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-spare-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (transport, _, budget) = try fixtureTransport(root: root)
    CloudSyncDiagnostics.shared.succeeded()
    do { _ = try await transport.control(method: "POST", path: "/secrets/spare/add", body: Data("{}".utf8), requestId: UUID().uuidString.lowercased()); XCTFail("refused") }
    catch {
      guard case .remote(let detail)? = error as? CloudFailure else { return XCTFail("\(error)") }
      XCTAssertEqual(detail.code, "bad_device_proof")
    }
    let state = try await budget.status()
    XCTAssertNil(state.blocked)
    XCTAssertEqual(state.failures, 0, "no back-off for the account")
    XCTAssertEqual(state.retryAt, 0)
    // The next sync step goes out at once, and a later failure line does not carry the spare route's refusal.
    _ = try await transport.changes(after: CloudSequence(9_007_199_254_740_993), limit: 17)
    let line = CloudSyncDiagnostics.shared.report("fetch", CloudFailure.budgetPaused)
    XCTAssertFalse(line.contains("/v1/secrets"), line)
    XCTAssertFalse(line.contains("budgetPaused"), line)
    XCTAssertNotEqual(CloudSyncDiagnostics.plainReason(CloudFailure.budgetPaused), "Cloud needs you to sign in again on this Mac.")
    await transport.stop()
  }
  func testHTTPSDeviceAuthSignsExactQueryBodyAndLargeSequenceStrings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-http-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CloudSyncStore(root: root, subject: .init(issuer: "https://identity.test", sub: "11111111-1111-4111-8111-111111111111"))
    let budget = CloudSyncBudget(store: store)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CloudSyncFixtureHTTP.self]
    config.httpAdditionalHeaders = ["X-Fixture-Run": root.lastPathComponent]
    let session = URLSession(configuration: config)
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["objects.test"])
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store, budget: budget, fixtureSession: session)
    let page = try await transport.changes(after: CloudSequence(9_007_199_254_740_993), limit: 17)
    XCTAssertEqual(page.nextAfter.rawValue, "9007199254740993")
    let applied = try await transport.applied(brainSeq: CloudSequence(9_007_199_254_740_993), secretsSeq: .zero, checkpointId: nil)
    XCTAssertEqual(applied.brainSeq, page.nextAfter)
    let gate = try await transport.capabilities()
    XCTAssertEqual(gate.features, ["cloud"])
    let key = try await transport.brainKey(epoch: 1)
    XCTAssertEqual(key.epoch, 1)
    XCTAssertEqual(key.key, Data(0..<32))
    let blob = UUID().uuidString.lowercased()
    let firstURL = try await transport.readBlobs(ids: [blob]).first?.getUrl
    let secondURL = try await transport.readBlobs(ids: [blob]).first?.getUrl
    XCTAssertNotEqual(firstURL, secondURL)
    XCTAssertEqual(sent(root), 6)
    await transport.stop()
    let discovery = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(allowDevice: false), signer: { _ in "" },
      store: store, budget: budget, fixtureSession: URLSession(configuration: config))
    let withoutDevice = try await discovery.capabilities()
    XCTAssertEqual(withoutDevice.features, ["cloud"])
    await discovery.stop()
  }
  func testGatewayTransferProofsAreFreshAndSignExactBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-transfer-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CloudSyncStore(root: root, subject: .init(issuer: "https://identity.test", sub: "11111111-1111-4111-8111-111111111111"))
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CloudSyncFixtureHTTP.self]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["objects.test"])
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store,
      budget: CloudSyncBudget(store: store), fixtureSession: URLSession(configuration: config))
    let url = URL(string: "https://cloud.test/v1/transfers/fixture-only?part=a%2Fb")!, bytes = Data([1, 2, 3])
    let first = try await transport.transferRequest(method: "PUT", url: url, bytes: bytes)
    let retry = try await transport.transferRequest(method: "PUT", url: url, bytes: bytes)
    XCTAssertNotEqual(first.value(forHTTPHeaderField: "X-TD-Request"), retry.value(forHTTPHeaderField: "X-TD-Request"))
    for request in [first, retry] {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-only-access")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-TD-Device"), CloudSyncFixtureAuth.device)
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-TD-Content-SHA256"), CloudSyncBytes.hash(bytes))
      let time = try XCTUnwrap(request.value(forHTTPHeaderField: "X-TD-Time"))
      let id = try XCTUnwrap(request.value(forHTTPHeaderField: "X-TD-Request"))
      let signature = try P256.Signing.ECDSASignature(rawRepresentation: CloudSyncBytes.unbase64(XCTUnwrap(request.value(forHTTPHeaderField: "X-TD-Signature"))))
      let message = "TD-CLOUD-1\nPUT\n/v1/transfers/fixture-only?part=a%2Fb\n\(time)\n\(id)\n\(CloudSyncBytes.hash(bytes))"
      XCTAssertTrue(CloudSyncFixtureAuth.key.publicKey.isValidSignature(signature, for: Data(message.utf8)))
    }
    let get = try await transport.transferRequest(method: "GET", url: url, bytes: Data())
    XCTAssertEqual(get.value(forHTTPHeaderField: "X-TD-Content-SHA256"), CloudSyncBytes.hash(Data()))
    await transport.stop()
  }
  /// 14 Nov: an old service's `budget_paused` (429) is an ordinary short "try again later", never a day's stop.
  func testHTTP429PersistsStopBeforeAnotherRequest() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-http-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let subject = CloudSubject(issuer: "https://identity.test", sub: "11111111-1111-4111-8111-111111111111")
    let store = try CloudSyncStore(root: root, subject: subject)
    let budget = CloudSyncBudget(store: store)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CloudSyncFixtureHTTP.self]
    config.httpAdditionalHeaders = ["X-Fixture-Run": root.lastPathComponent]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://paused.test/v1")!, environment: .test, objectHosts: ["objects.test"])
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store, budget: budget, fixtureSession: URLSession(configuration: config))
    do { _ = try await transport.capabilities(); XCTFail("Quota succeeded") }
    catch { guard case CloudFailure.remote(let detail) = error else { return XCTFail("Missing typed quota error") }; XCTAssertEqual(detail.code, "budget_paused") }
    do { _ = try await transport.capabilities(); XCTFail("Repeated quota request") } catch { XCTAssertEqual(error as? CloudFailure, .budgetPaused) }
    let reopened = CloudSyncBudget(store: try CloudSyncStore(root: root, subject: subject))
    let status = try await reopened.status()
    XCTAssertEqual(sent(root), 1)
    XCTAssertEqual(status.blocked, "rate")
    XCTAssertLessThanOrEqual(status.retryAt - CloudSyncBytes.now(), 300_000, "a few minutes at most, never until tomorrow")
    await transport.stop()
  }
  /// 13 Nov: after a refusal pauses sending, the account's status read and device list still reach the service
  /// (they were refused here, so a relaunch showed the signed-out page with "Could not reach Cloud").
  func testStatusReadsStillReachTheServiceWhileSendingWaits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-http-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let subject = CloudSubject(issuer: "https://identity.test", sub: "11111111-1111-4111-8111-111111111111")
    let store = try CloudSyncStore(root: root, subject: subject)
    let budget = CloudSyncBudget(store: store)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CloudSyncFixtureHTTP.self]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://paused.test/v1")!, environment: .test, objectHosts: ["objects.test"])
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store, budget: budget, fixtureSession: URLSession(configuration: config))
    for _ in 0..<2 {
      do { _ = try await transport.state(); XCTFail("fixture pauses") }
      catch { guard case CloudFailure.remote(let detail) = error else { return XCTFail("status read refused locally: \(error)") }; XCTAssertEqual(detail.code, "budget_paused") }
      do { _ = try await transport.devices(); XCTFail("fixture pauses") }
      catch { guard case CloudFailure.remote(let detail) = error else { return XCTFail("device list refused locally: \(error)") }; XCTAssertEqual(detail.code, "budget_paused") }
    }
    do { try await budget.reserve(packs: 1); XCTFail("sending ran past the pause") } catch { XCTAssertEqual(error as? CloudFailure, .budgetPaused) }
    await transport.stop()
  }
  func testUnsafeObjectURLsAndEndpointCredentialsAreRejected() throws {
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["objects.test"])
    XCTAssertThrowsError(try endpoint.permitObject(URL(string: "http://objects.test/blob")!))
    XCTAssertThrowsError(try endpoint.permitObject(URL(string: "https://other.test/blob")!))
    XCTAssertThrowsError(try CloudSyncEndpoint(base: URL(string: "https://user@cloud.test/v1")!, environment: .test, objectHosts: ["objects.test"]))
    XCTAssertNoThrow(try endpoint.permitObject(URL(string: "https://cloud.test/v1/transfers/blob?ticket=fixture-only")!))
    XCTAssertThrowsError(try endpoint.permitObject(URL(string: "https://objects.test/blob")!))
    XCTAssertThrowsError(try endpoint.permitObject(URL(string: "https://cloud.test/v1/changes")!))
  }
}

private struct CloudSyncFixtureHTTPMessage: Sendable {
  let url: URL?
  let httpMethod: String?
  let headers: [String: String]
  func value(forHTTPHeaderField name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
}

private struct CloudSyncFixtureHTTPResponse: Sendable { let status: Int; let bytes: Data }

private extension CloudSyncFixtureServer {
  /// Worker behaviours the plain fixture lacks: a one-shot HTTP refusal per route, and (when enabled)
  /// the Worker's saved final answer per request id, replayed for a repeat of that request.
  func http(_ request: CloudSyncFixtureHTTPMessage, body: Data) async -> CloudSyncFixtureHTTPResponse {
    struct Failure: Encodable { let error: CloudErrorDetail }
    let path = request.url?.path ?? ""
    let routeKey = (request.httpMethod ?? "") + " " + (path.hasPrefix("/v1/transfers/staging/") ? "/v1/transfers/staging" : path)
    let requestId = request.value(forHTTPHeaderField: "X-TD-Request") ?? ""
    if refuseSecretsPrepares, routeKey == "POST /v1/blobs/prepare", body.range(of: Data("\"secrets\"".utf8)) != nil {
      let value = Failure(error: .init(code: "secrets_locked", message: "Fixture protected refusal.", retryable: false, requestId: requestId.isEmpty ? UUID().uuidString.lowercased() : requestId))
      return .init(status: 403, bytes: (try? CloudSyncCanonical.encode(value)) ?? Data())
    }
    if let refusal = takeHTTPRefusal(routeKey) {
      let value = Failure(error: .init(code: refusal.code, message: "Fixture protected refusal.", retryable: false, requestId: requestId.isEmpty ? UUID().uuidString.lowercased() : requestId))
      return .init(status: refusal.status, bytes: (try? CloudSyncCanonical.encode(value)) ?? Data())
    }
    let replayable = replaySavedAnswers && request.httpMethod == "POST" && !path.hasPrefix("/v1/transfers/") && !requestId.isEmpty
    if replayable, let saved = savedAnswers[requestId] { replayedAnswers += 1; return .init(status: saved.status, bytes: saved.bytes) }
    let response = await route(request, body: body)
    if replayable {
      struct Items: Decodable { let items: [CloudBlobResult] }
      let retryableItem = (try? JSONDecoder().decode(Items.self, from: response.bytes))?.items.contains { $0.error?.retryable == true } ?? false
      if ((200..<300).contains(response.status) && !retryableItem) || ((400..<500).contains(response.status) && response.status != 429) {
        savedAnswers[requestId] = (response.status, response.bytes)
      }
    }
    return response
  }
  func route(_ request: CloudSyncFixtureHTTPMessage, body: Data) async -> CloudSyncFixtureHTTPResponse {
    struct Items<T: Codable>: Codable { let items: [T] }
    struct IDs: Decodable { let blobIds: [String] }
    struct Checkpoint: Encodable { let checkpoint: CloudCheckpoint? }
    struct Verify: Decodable { let checkpointId: String; let inventoryDigest: String; let counts: CloudCounts }
    struct Verified: Encodable { let checkpointId: String; let verifiedBy: [String] }
    struct Applied: Decodable { let brainSeq: CloudSequence; let secretsSeq: CloudSequence; let checkpointId: String? }
    struct Failure: Encodable { let error: CloudErrorDetail }
    do {
      guard let url = request.url, ["cloud.test", "objects.test"].contains(url.host ?? "") else { throw CloudFailure.unsafeConfiguration }
      if url.path == "/v1/capabilities" { return .init(status: 200, bytes: try CloudSyncCanonical.encode(await capabilities())) }
      guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only-access",
        let time = request.value(forHTTPHeaderField: "X-TD-Time"),
        let requestId = request.value(forHTTPHeaderField: "X-TD-Request"),
        let signature = request.value(forHTTPHeaderField: "X-TD-Signature") else { throw CloudFailure.invalidRequest }
      let path = url.path + (url.query.map { "?" + $0 } ?? "")
      let message = "TD-CLOUD-1\n\(request.httpMethod!)\n\(path)\n\(time)\n\(requestId)\n\(CloudSyncBytes.hash(body))"
      guard CloudSyncFixtureAuth.key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: CloudSyncBytes.unbase64(signature)), for: Data(message.utf8)) else { throw CloudFailure.checksumMismatch }
      if url.path.hasPrefix("/v1/transfers/") {
        guard request.value(forHTTPHeaderField: "X-TD-Content-SHA256") == CloudSyncBytes.hash(body),
          request.value(forHTTPHeaderField: "X-TD-Device") == CloudSyncFixtureAuth.device else { throw CloudFailure.invalidRequest }
        if request.httpMethod == "PUT" {
          guard request.value(forHTTPHeaderField: "Content-MD5") == CloudSyncBytes.md5(body),
            request.value(forHTTPHeaderField: "Content-Length") == String(body.count) else { throw CloudFailure.checksumMismatch }
        }
      }
      if url.path.hasPrefix("/v1/transfers/") {
        if request.httpMethod == "PUT", url.path.hasPrefix("/v1/transfers/staging/") {
          let id = url.lastPathComponent
          guard let upload = disk.uploads[id] else { throw CloudFailure.invalidRequest }
          try await self.upload(body, ticket: .init(uploadId: id, blobId: upload.blobId, putUrl: url, headers: [:], ticket: "fixture-only:" + id, expiresAt: CloudSyncBytes.now() + 300_000, alreadyPresent: false))
          return .init(status: 200, bytes: Data())
        }
        return .init(status: 200, bytes: try await download(url, maximumBytes: CloudWire.maximumBlobBytes))
      }
      let result: Data
      switch (request.httpMethod, url.path) {
      case ("GET", "/v1/capabilities"): result = try CloudSyncCanonical.encode(await capabilities())
      case ("GET", "/v1/state"): result = try CloudSyncCanonical.encode(await state())
      case ("GET", "/v1/checkpoints/current"): result = try CloudSyncCanonical.encode(Checkpoint(checkpoint: await checkpoint()))
      case ("GET", "/v1/changes"):
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.count == 2, query.map(\.name) == ["after", "limit"], let after = query[0].value, let limit = query[1].value.flatMap(Int.init) else { throw CloudFailure.invalidRequest }
        result = try CloudSyncCanonical.encode(await changes(after: CloudSequence(rawValue: after), limit: limit))
      case ("POST", "/v1/changes"):
        let segment = try CloudWire.decode(CloudSegment.self, from: body, allowedKeys: ["descriptor", "ciphertext"])
        let proof = try P256.Signing.ECDSASignature(rawRepresentation: CloudSyncBytes.unbase64(segment.descriptor.signature))
        guard CloudSyncFixtureAuth.key.publicKey.isValidSignature(proof, for: try segment.descriptor.syncSigningBytes(subject: "11111111-1111-4111-8111-111111111111")) else { throw CloudFailure.checksumMismatch }
        result = try CloudSyncCanonical.encode(await commit(segment))
      case ("POST", "/v1/blobs/prepare"):
        result = try CloudSyncCanonical.encode(Items(items: await prepareBlobs(CloudWire.decode(Items<CloudBlobUpload>.self, from: body, allowedKeys: ["items"]).items)))
      case ("POST", "/v1/blobs/finalize"):
        result = try CloudSyncCanonical.encode(Items(items: await finalizeBlobs(CloudWire.decode(Items<CloudBlobFinalize>.self, from: body, allowedKeys: ["items"]).items)))
      case ("POST", "/v1/blobs/read"):
        result = try CloudSyncCanonical.encode(Items(items: await readBlobs(ids: CloudWire.decode(IDs.self, from: body, allowedKeys: ["blobIds"]).blobIds)))
      case ("POST", "/v1/checkpoints"):
        result = try CloudSyncCanonical.encode(await publishCheckpoint(CloudWire.decode(CloudCheckpointRequest.self, from: body, allowedKeys: ["checkpointId", "throughSeq", "root", "secretsRoot", "inventoryDigest", "counts", "parentCheckpointId"])))
      case ("POST", "/v1/checkpoints/verify"):
        let value = try CloudWire.decode(Verify.self, from: body, allowedKeys: ["checkpointId", "inventoryDigest", "counts"])
        result = try CloudSyncCanonical.encode(Verified(checkpointId: value.checkpointId, verifiedBy: await verifyCheckpoint(id: value.checkpointId, inventoryDigest: value.inventoryDigest, counts: value.counts)))
      case ("POST", "/v1/applied"):
        let value = try CloudWire.decode(Applied.self, from: body, allowedKeys: ["brainSeq", "secretsSeq", "checkpointId"])
        result = try CloudSyncCanonical.encode(await applied(brainSeq: value.brainSeq, secretsSeq: value.secretsSeq, checkpointId: value.checkpointId))
      default: throw CloudFailure.unsupportedFormat
      }
      return .init(status: 200, bytes: result)
    } catch {
      let code: String
      let status: Int
      if case CloudFailure.remote(let detail) = error {
        code = detail.code
        if ["baseline_changed", "version_changed", "id_reused"].contains(code) { status = 409 }
        else if ["bad_device_proof", "sign_in_required"].contains(code) { status = 401 }
        else if ["budget_paused", "rate_limited"].contains(code) { status = 429 }
        else { status = detail.retryable ? 503 : 400 }
      } else if error as? CloudFailure == .idReused { code = "id_reused"; status = 409 }
      else if error as? CloudFailure == .unavailable { code = "temporarily_unavailable"; status = 503 }
      else { code = "invalid_request"; status = 400 }
      let value = Failure(error: .init(code: code, message: "Fixture request refused.", retryable: status == 503, requestId: request.value(forHTTPHeaderField: "X-TD-Request") ?? UUID().uuidString.lowercased()))
      return .init(status: status, bytes: (try? CloudSyncCanonical.encode(value)) ?? Data())
    }
  }
}

final class CloudSyncFullHTTP: URLProtocol, @unchecked Sendable {
  final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var server: CloudSyncFixtureServer?
    func set(_ server: CloudSyncFixtureServer?) { lock.lock(); defer { lock.unlock() }; self.server = server }
    func get() -> CloudSyncFixtureServer? { lock.lock(); defer { lock.unlock() }; return server }
  }
  private final class Delivery: @unchecked Sendable {
    let owner: CloudSyncFullHTTP
    init(_ owner: CloudSyncFullHTTP) { self.owner = owner }
    func finish(_ response: CloudSyncFixtureHTTPResponse, url: URL) {
      owner.client?.urlProtocol(owner, didReceive: HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": String(response.bytes.count)])!, cacheStoragePolicy: .notAllowed)
      owner.client?.urlProtocol(owner, didLoad: response.bytes)
      owner.client?.urlProtocolDidFinishLoading(owner)
    }
  }
  static let registry = Registry()
  private var fixtureTask: Task<Void, Never>?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let server = Self.registry.get(), let url = request.url, ["cloud.test", "objects.test"].contains(url.host ?? "") else {
      client?.urlProtocol(self, didFailWithError: CloudFailure.unsafeConfiguration)
      return
    }
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n == 0 { break }
        guard n > 0 else { client?.urlProtocol(self, didFailWithError: CloudFailure.invalidRequest); return }
        body.append(contentsOf: buffer.prefix(n))
      }
    }
    let bytes = body
    let message = CloudSyncFixtureHTTPMessage(url: url, httpMethod: request.httpMethod, headers: request.allHTTPHeaderFields ?? [:])
    let delivery = Delivery(self)
    fixtureTask = Task { @Sendable [server, bytes, url, message, delivery] in
      let response = await server.http(message, body: bytes)
      guard !Task.isCancelled else { return }
      delivery.finish(response, url: url)
    }
  }
  override func stopLoading() { fixtureTask?.cancel() }
}

extension CloudSyncTransportTests {
  func testRealTransportBootstrapUploadReadbackRestoreAndLostACK() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-full-http-" + UUID().uuidString)
    defer { CloudSyncFullHTTP.registry.set(nil); try? FileManager.default.removeItem(at: root) }
    let subject = CloudSubject(issuer: "https://identity.test", sub: "11111111-1111-4111-8111-111111111111")
    let server = try CloudSyncFixtureServer(root: root.appendingPathComponent("server"), device: CloudSyncFixtureAuth.device)
    CloudSyncFullHTTP.registry.set(server)
    let key = Data(0..<32)
    func client(_ name: String) async throws -> (CloudSyncEngine, CloudSyncStore, CloudSyncBudget, CloudSyncFixtureAdapter) {
      let store = try CloudSyncStore(root: root.appendingPathComponent(name), subject: subject)
      let budget = CloudSyncBudget(store: store)
      let config = URLSessionConfiguration.ephemeral
      config.protocolClasses = [CloudSyncFullHTTP.self]
      let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["objects.test"])
      let signer: CloudSyncSigner = { CloudSyncBytes.base64(try CloudSyncFixtureAuth.key.signature(for: $0).rawRepresentation) }
      let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: signer, store: store, budget: budget, fixtureSession: URLSession(configuration: config))
      let content = try CloudSyncContent(subject: subject.sub, epoch: 1, keyProvider: { _ in key })
      let engine = try CloudSyncEngine(store: store, transport: transport, objects: transport, content: content, budget: budget,
        subject: subject.sub, deviceId: CloudSyncFixtureAuth.device, epoch: 1, brainDomains: ["memory"], signer: signer,
        verifySignature: { descriptor, _ in
          let signature = try P256.Signing.ECDSASignature(rawRepresentation: CloudSyncBytes.unbase64(descriptor.signature))
          guard CloudSyncFixtureAuth.key.publicKey.isValidSignature(signature, for: try descriptor.syncSigningBytes(subject: subject.sub)) else { throw CloudFailure.checksumMismatch }
        }, firstUpload: true)
      let adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent(name + "-domain"))
      try await engine.register(adapter: adapter)
      return (engine, store, budget, adapter)
    }
    func operation(_ text: String) throws -> CloudOperation {
      let id = UUID().uuidString.lowercased(), payload = CloudValue(.string(text))
      return .init(v: 1, opId: id, originDevice: CloudSyncFixtureAuth.device, domain: "memory", entityId: id, revision: id, parents: [], kind: .append,
        source: .init(sourceId: "fixture-source", recordId: id), createdAt: 1, payload: payload, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
    }
    let baseline = try (0..<32).map { try operation("fixture-\($0)") }
    let (first, firstStore, budget, _) = try await client("a")
    let snapshot = CloudDomainSnapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1, watermarks: ["fixture-source": "32"]), operations: baseline, files: [],
      coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 32, bytes: 0, blockedReasons: [])])
    let checkpoint = try await first.bootstrap([snapshot])
    XCTAssertTrue(checkpoint.published)
    let (second, secondStore, _, adapter) = try await client("b")
    _ = try await second.pull()
    let count = await adapter.count()
    XCTAssertEqual(count, 32)
    XCTAssertEqual(Set(try secondStore.operations().map(\.payloadHash)), Set(baseline.map(\.payloadHash)))
    await server.setLostACK()
    _ = try await first.enqueue([operation("offline addition")])
    do { _ = try await first.flush(); XCTFail("Lost ACK was not surfaced") } catch { XCTAssertNotNil(error as? CloudFailure) }
    XCTAssertEqual(try firstStore.pending().count, 1)
    try await budget.resume(networkOrWake: true)
    _ = try await first.flush()
    _ = try await second.pull()
    let all = await adapter.count(), segments = await server.segmentCount()
    XCTAssertEqual(all, 33)
    XCTAssertEqual(segments, 1)
    XCTAssertTrue(try firstStore.pending().isEmpty)
    let requests = await server.calls
    XCTAssertLessThan(requests, 150)
    await first.stop(); await second.stop()
  }
}

extension CloudSyncTransportTests {
  func testRemoteTESTServiceAuthBoundaryOnceWith150RequestCeiling() async throws {
    // Only the agreed TEST URL may enable this check. There is no production or credential fallback.
    let urlFile = URL(fileURLWithPath: "/Users/imatch/Deck Dev/code/td-native-shell/macos/night/codex/cloud-server-test-url.txt")
    guard FileManager.default.fileExists(atPath: urlFile.path) else { throw XCTSkip("Lane C has not supplied its TEST URL.") }
    let line = try String(contentsOf: urlFile, encoding: .utf8).split(separator: "\n").first { $0.hasPrefix("https://") }
    let base = try XCTUnwrap(line.flatMap { URL(string: String($0)) })
    guard base.scheme == "https", base.host == "td-cloud-test.terminaldeck.workers.dev", base.path == "/v1",
      base.query == nil, base.fragment == nil, base.user == nil, base.password == nil else { throw CloudFailure.unsafeConfiguration }
    let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let report = macos.appendingPathComponent("night/codex/cloud-sync-test-server-result.json")
    guard !FileManager.default.fileExists(atPath: report.path) else { throw XCTSkip("The one bounded TEST run is already recorded.") }
    struct Result: Encodable {
      let status: String
      let requests: Int
      let requestLimit: Int
      let scope: String
    }
    func save(_ status: String, _ requests: Int) throws {
      try JSONEncoder().encode(Result(status: status, requests: requests, requestLimit: 150,
        scope: "Anonymous discovery and rejected sign-in; authenticated upload fixtures were not supplied by lane C.")).write(to: report, options: .atomic)
    }
    try save("started", 0)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-remote-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CloudSyncStore(root: root, subject: .init(issuer: base.deletingLastPathComponent().absoluteString, sub: "11111111-1111-4111-8111-111111111111"))
    let budget = CloudSyncBudget(store: store)
    let endpoint = try CloudSyncEndpoint(base: base, environment: .test, objectHosts: [base.host!])
    let transport = try CloudSyncTransport(endpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store, budget: budget)
    do {
      let gate = try await transport.capabilities()
      XCTAssertEqual(gate.features, [])
      do { _ = try await transport.state(); XCTFail("Synthetic invalid credentials were accepted") }
      catch {
        guard case CloudFailure.remote(let detail) = error else { throw error }
        XCTAssertEqual(detail.code, "sign_in_required")
      }
      let status = try await budget.status()
      XCTAssertNil(status.blocked, "MAC-NEXT-12: a 401 is a timed retry, never a stored sign-in block")
      XCTAssertGreaterThan(status.retryAt, CloudSyncBytes.now())
      do { _ = try await transport.state(); XCTFail("Auth failure did not stop automatic requests") }
      catch { XCTAssertEqual(error as? CloudFailure, .budgetPaused) }
      try save("completed-auth-boundary-only", 2)
      await transport.stop()
    } catch {
      try save("failed", 0)
      await transport.stop()
      throw error
    }
  }
}

extension CloudSyncTransportTests {
  func testAccountSwitchCannotSendAnotherSubjectsQueue() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-account-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CloudSyncStore(root: root, subject: .init(issuer: "https://identity.test", sub: "44444444-4444-4444-8444-444444444444"))
    let budget = CloudSyncBudget(store: store)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CloudSyncFixtureHTTP.self]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["objects.test"])
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store,
      budget: budget, fixtureSession: URLSession(configuration: config))
    do { _ = try await transport.state(); XCTFail("Mismatched account was sent") }
    catch { XCTAssertEqual(error as? CloudFailure, .unsafeConfiguration) }
    await transport.stop()
  }
}

private final class CloudSyncFixtureSocket: CloudSyncSocketConnection, @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [Data]
  private var waiter: CheckedContinuation<Data, Error>?
  private var closed = false
  private var sent: [String] = []
  private var afterPing: Data?
  init(messages: [Data], afterPing: Data? = nil) { self.messages = messages; self.afterPing = afterPing }
  func start() {}
  func cancel() {
    lock.lock(); closed = true; let waiter = self.waiter; self.waiter = nil; lock.unlock()
    waiter?.resume(throwing: CancellationError())
  }
  func receive() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if closed { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
      if !messages.isEmpty { let first = messages.removeFirst(); lock.unlock(); continuation.resume(returning: first); return }
      waiter = continuation; lock.unlock()
    }
  }
  func send(_ text: String) async throws { record(text) }
  private func record(_ text: String) {
    lock.lock(); sent.append(text)
    let message = afterPing; afterPing = nil
    let waiting = waiter
    if message != nil { waiter = nil }
    if let message, waiting == nil { messages.append(message) }
    lock.unlock()
    if let message { waiting?.resume(returning: message) }
  }
  func sentFrames() -> [String] { lock.lock(); defer { lock.unlock() }; return sent }
}

extension CloudSyncTransportTests {
  func testSleepingSocketSignedHelloChangedAndHeartbeat() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-socket-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CloudSyncStore(root: root, subject: .init(issuer: "https://identity.test", sub: "11111111-1111-4111-8111-111111111111"))
    func event(_ type: String, _ payload: CloudValue) throws -> Data {
      try CloudSyncCanonical.encode(CloudEvent(v: 1, type: type, id: UUID().uuidString.lowercased(), payload: payload))
    }
    struct Hello: Encodable {
      let socketId = "fixture-only-socket"
      let headSeq = CloudSequence(7)
      let authExpiresAt = CloudSyncBytes.now() + 3_600_000
      let budget = CloudBudgetState(day: "fixture", requestsLeft: 6000, writesLeft: 12000, bytesLeft: 1024)
    }
    let hello = try event("hello", .init(NativeRPCValue.parseJSON(CloudSyncCanonical.encode(Hello()))))
    let changed = try event("changed", .init(.object([.init("headSeq", .string("7")), .init("classes", .array([.string("brain")]))])))
    let socket = CloudSyncFixtureSocket(messages: [hello, Data("td-pong".utf8)], afterPing: changed)
    let upgrades = CloudSyncSocketUpgradeCapture()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudSyncFixtureHTTP.self]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["cloud.test"])
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store,
      budget: CloudSyncBudget(store: store), fixtureSession: URLSession(configuration: configuration), fixtureSocketFactory: { request in
        upgrades.append(request); return socket
      }, fixtureHeartbeat: .milliseconds(2))
    let stream = await transport.events()
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(10)); await transport.stop() } catch {}
    }
    defer { watchdog.cancel() }
    let task = Task { () throws -> [String] in
      var types: [String] = []
      for try await event in stream {
        types.append(event.type)
        if types.count == 2 { break }
      }
      return types
    }
    let types = try await task.value
    XCTAssertEqual(types, ["hello", "changed"])
    XCTAssertFalse(socket.sentFrames().isEmpty)
    let upgrade = try XCTUnwrap(upgrades.requests().first)
    XCTAssertEqual(upgrade.url?.scheme, "wss")
    XCTAssertEqual(upgrade.url?.path, "/v1/events")
    XCTAssertEqual(upgrade.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-only-access")
    XCTAssertEqual(upgrade.value(forHTTPHeaderField: "X-TD-Device"), CloudSyncFixtureAuth.device)
    XCTAssertNotNil(upgrade.value(forHTTPHeaderField: "X-TD-Signature"))
    XCTAssertTrue(socket.sentFrames().allSatisfy { $0 == "td-ping" })
    await transport.stop()
  }
  func testSleepingSocketRejectsUnknownSchemaAndOversizeFrames() throws {
    let invalid = Data("{\"v\":2,\"type\":\"changed\",\"id\":\"fixture-only\",\"payload\":{}}".utf8)
    XCTAssertThrowsError(try CloudSyncSocketFrames.event(invalid))
    XCTAssertThrowsError(try CloudSyncSocketFrames.event(Data(repeating: 0, count: 409_601)))
    XCTAssertNil(try CloudSyncSocketFrames.event(Data("td-pong".utf8)))
  }
}

private final class CloudSyncSocketUpgradeCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [URLRequest] = []
  func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; values.append(request) }
  func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

extension CloudSyncTransportTests {
  /// 14 Nov: no daily allowance; a hello's `budget` is information only and nothing is counted or paused.
  func testReview08HeartbeatsDoNotReserveNonHeartbeatDailyAllowance() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-heartbeat-budget-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try CloudSyncStore(root: root, subject: .init(issuer: "https://identity.test", sub: "11111111-1111-4111-8111-111111111111"))
    let budget = CloudSyncBudget(store: store)
    struct Hello: Encodable {
      let socketId = "fixture-only-budget-socket"
      let headSeq = CloudSequence.zero
      let authExpiresAt = CloudSyncBytes.now() + 3_600_000
      let budget = CloudBudgetState(day: "fixture", requestsLeft: 6000, writesLeft: 12000, bytesLeft: 1024)
    }
    let hello = try CloudSyncCanonical.encode(CloudEvent(v: 1, type: "hello", id: UUID().uuidString.lowercased(),
      payload: .init(NativeRPCValue.parseJSON(CloudSyncCanonical.encode(Hello())))))
    let changed = try CloudSyncCanonical.encode(CloudEvent(v: 1, type: "changed", id: UUID().uuidString.lowercased(),
      payload: .init(.object([.init("headSeq", .string("0")), .init("classes", .array([.string("brain")]))]))))
    let socket = CloudSyncFixtureSocket(messages: [hello, Data("td-pong".utf8)], afterPing: changed)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudSyncFixtureHTTP.self]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["cloud.test"])
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store,
      budget: budget, fixtureSession: URLSession(configuration: configuration), fixtureSocketFactory: { _ in socket }, fixtureHeartbeat: .milliseconds(2))
    let watchdog = Task { do { try await Task.sleep(for: .seconds(10)); await transport.stop() } catch {} }
    defer { watchdog.cancel() }
    var types: [String] = []
    for try await event in await transport.events() {
      types.append(event.type)
      if types.count == 2 { break }
    }
    XCTAssertEqual(types, ["hello", "changed"])
    XCTAssertFalse(socket.sentFrames().isEmpty)
    let state = try await budget.status()
    XCTAssertNil(state.blocked)
    XCTAssertEqual(state.retryAt, 0)
    try await budget.reserve(http: 1)
    await transport.stop()
  }
}
