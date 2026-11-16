import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// Never answers: a request stays in flight until its task is cancelled.
private final class CloudSyncHangingHTTP: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {}
  override func stopLoading() {}
}

/// Answers POST /devices with an active receipt for the fixture device, and nothing else.
private final class CloudSyncRegisterHTTP: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let ok = request.httpMethod == "POST" && request.url?.path == "/v1/devices"
    let body = ok ? Data(#"{"deviceId":"33333333-3333-4333-8333-333333333333","status":"active","secretsApproved":false,"headSeq":"0","vaultState":"unset","role":"peer"}"#.utf8)
                  : Data(#"{"error":{"code":"not_found","message":"Not found.","retryable":false,"requestId":"x"}}"#.utf8)
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: ok ? 201 : 404, httpVersion: "HTTP/1.1",
      headerFields: ["Content-Length": String(body.count)])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

extension CloudSyncTests {
  private func transport(_ protocolClass: AnyClass, store: CloudSyncStore, budget: CloudSyncBudget) throws -> CloudSyncTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [protocolClass]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["cloud.test"])
    return try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store,
      budget: budget, fixtureSession: URLSession(configuration: configuration))
  }

  /// 13 Nov, the owner's third failed sign-in: the Cloud page cancelled its own in-flight saved-passwords read while
  /// the sign-in was registering this Mac. The cancelled request was counted as a network failure, its back-off
  /// refused the sign-in's first /state locally (`budgetPaused`) and the sign-in was rolled back. A request this Mac
  /// cancelled is no failure: it leaves no back-off, and the very next request goes out.
  func testCancelledRequestLeavesNoBackOffForTheNextRequest() async throws {
    let root = try scratch(), store = try makeStore(root), budget = CloudSyncBudget(store: store)
    let transport = try transport(CloudSyncHangingHTTP.self, store: store, budget: budget)
    for request in 0..<2 {
      let task = Task { () -> Error? in
        do { if request == 0 { _ = try await transport.capabilities() } else { _ = try await transport.state() }; return nil }
        catch { return error }
      }
      try await Task.sleep(for: .milliseconds(200))
      task.cancel()
      let error = await task.value
      XCTAssertTrue(error is CancellationError, "a cancelled request is a cancellation, not \(String(describing: error))")
      let state = try await budget.status()
      XCTAssertEqual(state.failures, 0)
      XCTAssertNil(state.blocked)
      XCTAssertLessThanOrEqual(state.retryAt, CloudSyncBytes.now())
      try await budget.reserve(http: 1)
    }
  }

  /// A back-off left by an earlier failed request of the same sign-in no longer stands between a successful device
  /// registration and the sign-in's first status read.
  func testSuccessfulRegistrationClearsATransientBackOff() async throws {
    let root = try scratch(), store = try makeStore(root), budget = CloudSyncBudget(store: store)
    try await budget.failed(URLError(.timedOut))
    let failing = try await budget.status()
    XCTAssertEqual(failing.failures, 1)
    XCTAssertGreaterThan(failing.retryAt, CloudSyncBytes.now())
    // The registration request itself waits the first back-off (at most 1.5 s) out.
    while try await budget.status().retryAt > CloudSyncBytes.now() { try await Task.sleep(for: .milliseconds(100)) }
    let transport = try transport(CloudSyncRegisterHTTP.self, store: store, budget: budget)
    let receipt = try await transport.registerDevice(CloudSyncFixtureAuth().deviceRegistration())
    XCTAssertEqual(receipt.status, .active)
    let state = try await budget.status()
    XCTAssertEqual(state.failures, 0)
    XCTAssertNil(state.blocked)
    XCTAssertEqual(state.retryAt, 0)
  }
}
