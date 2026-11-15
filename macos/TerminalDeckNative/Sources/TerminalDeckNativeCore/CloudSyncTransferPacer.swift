import Foundation

/// X5 (13 Nov). The ONE place for the service's per-device rate limits and this app's pace under them.
/// The service (lane/cloud-service-prod2 a47fc022, per signed-in device, per SLIDING minute) allows:
///   60 control calls (account, devices, state, prepare/finalize, …): not paced here, as before;
///   600 bulk reads (feed pages GET /v1/changes, transfer and pack downloads, POST /v1/applied);
///   240 sends (POST /v1/changes, transfer and pack uploads).
/// Every 429 carries Retry-After and `rate_limited`. The app keeps clearly under: bulk reads at most 8 a second
/// (480 a minute), sends at most 3 a second (180 a minute), spread EVENLY (never a burst, then a wait for the
/// minute). A 429 is honoured by its Retry-After (the budget waits exactly that) and halves the pace for a minute, so
/// the app also behaves against a service that still has the older 60-a-minute rule.
public enum CloudSyncServicePace {
  public static let serviceBulkReadsPerMinute = 600, serviceSendsPerMinute = 240, serviceControlCallsPerMinute = 60
  public static let bulkReadsPerSecond = 8.0
  public static let sendsPerSecond = 3.0
  public static let slowDownSeconds: TimeInterval = 60
}

/// Spreads one class of requests evenly at a rate; `slowDown()` halves the rate for a while. Clock and sleep are
/// injected so tests never wait.
public actor CloudSyncTransferPacer {
  private let gap: TimeInterval
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private var next: Date?
  private var slowUntil: Date?
  public init(perSecond: Double,
              now: @escaping @Sendable () -> Date = { Date() },
              sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .milliseconds(Int(($0 * 1000).rounded(.up)))) }) {
    gap = 1 / max(0.001, perSecond); self.now = now; self.sleep = sleep
  }
  /// A pacer that never waits (fixture transports).
  public static func instant() -> CloudSyncTransferPacer { .init(perSecond: 1_000_000, sleep: { _ in }) }
  /// A 429: half the pace for `CloudSyncServicePace.slowDownSeconds`.
  public func slowDown() { slowUntil = now().addingTimeInterval(CloudSyncServicePace.slowDownSeconds) }
  /// Waits until this request's turn; returns how long it waited.
  @discardableResult
  public func take() async throws -> TimeInterval {
    let current = now()
    let step = (slowUntil.map { $0 > current } ?? false) ? gap * 2 : gap
    let slot = max(current, next ?? current)
    next = slot.addingTimeInterval(step)
    let wait = slot.timeIntervalSince(current)
    if wait > 0 { try await sleep(wait) }
    return wait
  }
}
