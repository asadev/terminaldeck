import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// 14 Nov (owner: "remove this counter thing completely"): this Mac keeps no daily count and no daily ceiling. What
/// still stops a runaway is the per-minute pacing, the growing back-off and the service's Retry-After (capped).
extension CloudSyncTests {
  /// A failing upload retried for a whole simulated day: every try is allowed at its own time (never a stop for good),
  /// sends never exceed the pacing (and so never the service's per-device minute), and no wait is longer than 15 min.
  /// Clock and sleep are simulated: the test never waits on real time.
  func testAFailingUploadRetriedForADayStaysPacedAndNeverStopsForGood() async throws {
    final class Clock: @unchecked Sendable {
      let lock = NSLock(); var ms: Int64 = 1_794_600_000_000
      func now() -> Int64 { lock.lock(); defer { lock.unlock() }; return ms }
      func advance(to: Int64) { lock.lock(); ms = max(ms, to); lock.unlock() }
    }
    let clock = Clock()
    let store = try makeStore(scratch())
    let budget = CloudSyncBudget(store: store, now: { clock.now() })
    let pacer = CloudSyncTransferPacer(perSecond: CloudSyncServicePace.sendsPerSecond,
      now: { Date(timeIntervalSince1970: Double(clock.now()) / 1000) },
      sleep: { seconds in clock.advance(to: clock.now() + Int64((seconds * 1000).rounded(.up))) })
    let start = clock.now(), end = start + 86_400_000
    var attempts: [Int64] = []
    var longestWait: Int64 = 0
    let busy = CloudFailure.remote(.init(code: "temporarily_unavailable", message: "Fixture busy.", retryable: true,
      requestId: UUID().uuidString.lowercased()))
    let slow = CloudFailure.remote(.init(code: "rate_limited", message: "Fixture slow down.", retryable: true,
      requestId: UUID().uuidString.lowercased()))
    let oldAllowance = CloudFailure.remote(.init(code: "budget_paused", message: "Fixture old allowance.", retryable: true,
      requestId: UUID().uuidString.lowercased()))
    while clock.now() < end {
      // The engine's timers: the next try goes when the stored wait ends (nothing else lifts it).
      let state = try await budget.status()
      XCTAssertNotEqual(state.blocked, "budget")
      XCTAssertNotEqual(state.blocked, "auth", "a busy service never becomes a sign-in block")
      XCTAssertNotEqual(state.blocked, "remote", "a retryable refusal never needs the person")
      if state.retryAt > clock.now() {
        longestWait = max(longestWait, state.retryAt - clock.now())
        clock.advance(to: state.retryAt)
      }
      try await pacer.take()
      do { try await budget.reserve(packs: 1) }
      catch { XCTFail("a try was refused at its own time: \(error)"); break }
      attempts.append(clock.now())
      // Mostly a busy service; now and then a slow-down, a slow-down asking for a day, an old "allowance" answer.
      switch attempts.count % 97 {
      case 13: try await budget.failed(slow, httpStatus: 429, retryAfter: clock.now() + 86_400_000)
      case 41: try await budget.failed(oldAllowance, httpStatus: 429, retryAfter: clock.now() + 86_400_000)
      case 77: try await budget.failed(slow, httpStatus: 429)
      default: try await budget.failed(busy, httpStatus: 503, retryAfter: attempts.count % 50 == 0 ? clock.now() + 86_400_000 : nil)
      }
    }
    // Never stopped for good: tries kept going all day (the back-off settles at about one a minute; a stated wait is at most 15 min).
    XCTAssertGreaterThan(attempts.count, 500, "tries kept going through the day")
    XCTAssertGreaterThan(attempts.last ?? 0, end - 16 * 60_000, "still trying at the end of the day")
    XCTAssertLessThanOrEqual(longestWait, 900_000, "no wait is ever longer than 15 minutes")
    // Paced: no sliding minute holds more sends than the pacing allows (180), far under the service's 240.
    var busiest = 0, low = 0
    for high in attempts.indices {
      while attempts[high] - attempts[low] >= 60_000 { low += 1 }
      busiest = max(busiest, high - low + 1)
    }
    XCTAssertLessThanOrEqual(busiest, Int(CloudSyncServicePace.sendsPerSecond * 60))
    XCTAssertLessThanOrEqual(busiest, CloudSyncServicePace.serviceControlCallsPerMinute, "a failing upload stays even under the control-call minute")
    // Once the service answers, sending goes on at once.
    try await budget.succeeded()
    let healed = try await budget.status()
    if healed.retryAt > clock.now() { clock.advance(to: healed.retryAt) }
    try await budget.reserve(packs: 1)
  }

  /// A block of kind "budget" stored by an earlier build ends at the first read (launch), with its counters; an
  /// allowance of 0 in /state or a hello is information only.
  func testAStoredDailyBlockEndsAtLaunchAndAZeroAllowanceIsIgnored() async throws {
    let root = try scratch(), store = try makeStore(root)
    var old = CloudSyncBudgetSnapshot(day: 20_771)
    old.blocked = "budget"; old.retryAt = 20_772 * 86_400_000; old.http = 6000; old.frames = 10_000; old.packs = 4000; old.failures = 3
    try store.set("budget", old)
    let budget = CloudSyncBudget(store: try makeStore(root), now: { 20_771 * 86_400_000 + 3_600_000 })
    let launched = try await budget.status()
    XCTAssertNil(launched.blocked)
    XCTAssertEqual(launched.retryAt, 0)
    XCTAssertEqual(launched.failures, 0)
    XCTAssertEqual(launched.http + launched.frames + launched.packs, 0)
    let onDisk: CloudSyncBudgetSnapshot? = try makeStore(root).value("budget")
    XCTAssertNil(onDisk?.blocked)
    try await budget.observe(CloudBudgetState(day: "2026-11-14", requestsLeft: 0, writesLeft: 0, bytesLeft: 0))
    try await budget.reserve(http: 1, frames: 1, packs: 1)
    let after = try await budget.status()
    XCTAssertNil(after.blocked)
    XCTAssertNil(try store.value("budgetZeroSeenAt") as Int64?)
  }
}
