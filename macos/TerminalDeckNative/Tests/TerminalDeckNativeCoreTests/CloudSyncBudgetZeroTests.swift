import XCTest
import Foundation
@testable import TerminalDeckNativeCore

extension CloudSyncTests {
  /// Service review round 8 M1: a remaining allowance of 0 in a hello (or /state) is not a pause. Eight hellos
  /// reporting 0, with no `budget_paused` answer, leave the app syncing (no block, no retry time).
  func testZeroRemainingAllowanceInHellosNeverPausesSync() async throws {
    let root = try scratch(), store = try makeStore(root), budget = CloudSyncBudget(store: store)
    struct Hello: Encodable {
      let socketId = "fixture-only-zero-allowance"
      let headSeq = CloudSequence.zero
      let authExpiresAt = CloudSyncBytes.now() + 3_600_000
      let budget = CloudBudgetState(day: "fixture", requestsLeft: 0, writesLeft: 0, bytesLeft: 0)
    }
    let hello = try CloudSyncCanonical.encode(CloudEvent(v: 1, type: "hello", id: UUID().uuidString.lowercased(),
      payload: .init(NativeRPCValue.parseJSON(CloudSyncCanonical.encode(Hello())))))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudSyncFullHTTP.self]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["cloud.test"])
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store,
      budget: budget, fixtureSession: URLSession(configuration: configuration), fixtureSocketFactory: { _ in CloudSyncRound3DroppingSocket(hello: hello) },
      fixtureSocketRetryBase: .milliseconds(2))
    let watchdog = Task { do { try await Task.sleep(for: .seconds(20)); await transport.stop() } catch {} }
    defer { watchdog.cancel() }
    var hellos = 0
    for try await event in await transport.events() where event.type == "hello" {
      hellos += 1
      if hellos == 8 { break }
    }
    await transport.stop()
    XCTAssertEqual(hellos, 8)
    let state = try await budget.status()
    XCTAssertNil(state.blocked)
    XCTAssertLessThanOrEqual(state.retryAt, CloudSyncBytes.now())
    try await budget.reserve(http: 1)
  }
}
