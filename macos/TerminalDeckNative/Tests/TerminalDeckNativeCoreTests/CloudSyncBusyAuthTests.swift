import Foundation
import XCTest
@testable import TerminalDeckNativeCore

/// MAC-NEXT-12 (13 Nov, the MacBook from 15:53Z): a 401 that the service gave while its database was busy was stored
/// as a sign-in block ("auth") that nothing but a new device id lifted, so the Mac never synced again although every
/// status read answered 200. Only `device_revoked` is a sign-in block now, and a device-proven answer ends it.
extension CloudSyncTests {
  private func remote(_ code: String, retryable: Bool = false) -> CloudFailure {
    .remote(.init(code: code, message: "Fixture.", retryable: retryable, requestId: "fixture"))
  }

  func testMacNext12BusyOrExpiredRefusalsAreTimedRetriesNeverASignInBlock() async throws {
    for (code, status) in [("sign_in_required", 401), ("token_expired", 401), ("bad_device_proof", 401), ("storage_required", 403), ("not_found", 404)] {
      let store = try makeStore(scratch()), budget = CloudSyncBudget(store: store)
      try await budget.failed(remote(code), httpStatus: status)
      let state = try await budget.status()
      XCTAssertNil(state.blocked, code)
      XCTAssertGreaterThan(state.retryAt, CloudSyncBytes.now(), code)
      XCTAssertLessThanOrEqual(state.retryAt, CloudSyncBytes.now() + 2_000, code)
    }
    let store = try makeStore(scratch()), budget = CloudSyncBudget(store: store)
    try await budget.failed(remote("device_revoked"), httpStatus: 403)
    let revoked = try await budget.status()
    XCTAssertEqual(revoked.blocked, "auth")
    do { try await budget.reserve(http: 1); XCTFail("a removed device kept sending") }
    catch { XCTAssertEqual(error as? CloudFailure, .budgetPaused) }
  }

  func testMacNext12AStoredSignInBlockLiftsAtTheFirstDeviceProvenAnswerOnly() async throws {
    let store = try makeStore(scratch()), budget = CloudSyncBudget(store: store)
    // The MacBook's stored state, byte for byte in meaning: {"blocked":"auth","failures":1,"http":977,"retryAt":0}.
    var stuck = CloudSyncBudgetSnapshot(day: CloudSyncBytes.now() / 86_400_000)
    stuck.blocked = "auth"; stuck.failures = 1; stuck.http = 977; stuck.frames = 252; stuck.packs = 10
    try store.set("budget", stuck)
    // Neither the launch attempt, "Sync now", nor an answer without this Mac's proof (capabilities) lifts it.
    try await budget.resume(networkOrWake: false, launch: true)
    try await budget.served()
    let still = try await budget.status()
    XCTAssertEqual(still.blocked, "auth")
    // A status read answered for this device's proof: the service checked session, device row and signature.
    try await budget.served(deviceProven: true)
    let lifted = try await budget.status()
    XCTAssertNil(lifted.blocked)
    XCTAssertEqual(lifted.failures, 0)
    XCTAssertEqual(lifted.http, 0, "14 Nov: no counters any more; an older build's are dropped")
    try await budget.reserve(http: 1)
  }

  func testMacNext12TheStatusReadOverHTTPEndsTheMacBooksStoredBlock() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    CloudSyncFullHTTP.registry.set(server)
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let store = try makeStore(root), budget = CloudSyncBudget(store: store)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudSyncFullHTTP.self]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["cloud.test"])
    let signer: CloudSyncSigner = { CloudSyncBytes.base64(try CloudSyncFixtureAuth.key.signature(for: $0).rawRepresentation) }
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: signer, store: store,
      budget: budget, fixtureSession: URLSession(configuration: configuration))
    var stuck = CloudSyncBudgetSnapshot(day: CloudSyncBytes.now() / 86_400_000)
    stuck.blocked = "auth"; stuck.failures = 1
    try store.set("budget", stuck)
    do { _ = try await transport.changes(after: .zero, limit: 1); XCTFail("the block did not hold before the answer") }
    catch { XCTAssertEqual(error as? CloudFailure, .budgetPaused) }
    _ = try await transport.state()
    let after = try await budget.status()
    XCTAssertNil(after.blocked)
    _ = try await transport.changes(after: .zero, limit: 1)
  }
}
