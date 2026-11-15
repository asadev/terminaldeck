import Foundation

/// This Mac's stored sync wait (metadata key "budget"). 14 Nov (owner: "remove this counter thing completely"): there
/// is NO daily count and NO daily ceiling any more. `day`, `http`, `frames` and `packs` stay only so a block written by
/// an earlier build still decodes; nothing counts into them and nothing reads them.
public struct CloudSyncBudgetSnapshot: Codable, Sendable, Equatable {
  public var day: Int64
  public var http = 0
  public var frames = 0
  public var packs = 0
  public var failures = 0
  public var retryAt: Int64 = 0
  /// "rate" (a slow-down that ends at retryAt), "network" (a failure pause that ends at retryAt), "auth" (only
  /// `device_revoked`), "remote" (a refusal the person retries). "budget" is never stored again: one an earlier build
  /// stored is dropped on the first read.
  public var blocked: String?
}

/// Shared by HTTP, sockets and the engine; asked before every network effect. It holds only short, timed waits: what
/// keeps this Mac from hammering the service is the per-minute pacing (`CloudSyncTransferPacer`, the transport's
/// `pace`), the growing back-off here and the service's own Retry-After, never a count per day.
public actor CloudSyncBudget {
  private let store: CloudSyncStore
  private let now: @Sendable () -> Int64
  public init(store: CloudSyncStore, now: @escaping @Sendable () -> Int64 = CloudSyncBytes.now) {
    self.store = store
    self.now = now
  }
  private func read() throws -> CloudSyncBudgetSnapshot {
    var state = try store.value("budget") ?? CloudSyncBudgetSnapshot(day: 0)
    // 14 Nov: a day's-allowance block ("budget", until the next UTC day) from an earlier build ends here, at once,
    // with the old counters; `status()` at launch writes the cleared state back.
    if state.blocked == "budget" { state.blocked = nil; state.retryAt = 0; state.failures = 0 }
    // Any other kind this build does not know (an older or newer build's) is no block: a stored kind may never stop
    // sync for good just because nothing here knows how it ends.
    if let kind = state.blocked, !Self.knownBlocks.contains(kind) { state.blocked = nil }
    // No stored wait is ever longer than 15 minutes from now (a clock change, an older build's long time).
    if state.retryAt > now() + Self.rateWaitCapMs { state.retryAt = now() + Self.rateWaitCapMs }
    if state.day != 0 || state.http != 0 || state.frames != 0 || state.packs != 0 {
      state.day = 0; state.http = 0; state.frames = 0; state.packs = 0
    }
    // 13 Nov (owner's first upload): a "slow down" (429 rate_limited) is a short wait that ends BY ITSELF at its
    // time. Before, only a wake, a network change or a new sign-in cleared it, so after the service's one-minute
    // window had passed every send was still refused here, for ever, and the account looked signed out.
    if state.blocked == "rate" && now() >= state.retryAt { state.blocked = nil; state.retryAt = 0 }
    // MAC-NEXT-12b: five failed tries in a row (half a minute of a busy service) are a pause with its own end, not a
    // stop until a wake or a network change: at its time one more try goes (a failure sets it again, 60 s).
    if state.blocked == "network" && now() >= state.retryAt { state.blocked = nil }
    return state
  }
  /// Writes only when the read changed what is stored (an ended wait, an old block dropped).
  private func readAndKeep() throws -> CloudSyncBudgetSnapshot {
    let stored: CloudSyncBudgetSnapshot? = try store.value("budget")
    let state = try read()
    if stored != state { try store.set("budget", state) }
    return state
  }
  public func status() throws -> CloudSyncBudgetSnapshot {
    // E (13 Nov): the Cloud page reads this every 2 s (twice per tick); it is written only when the read changed it,
    // never as a no-op write per read.
    try store.transaction { try readAndKeep() }
  }
  /// May a request (or a socket frame, or a pack) go now? Only a stored short wait says no; nothing is counted.
  /// The arguments stay for the callers' sake and must not be negative.
  public func reserve(http: Int = 0, frames: Int = 0, packs: Int = 0) throws {
    guard http >= 0, frames >= 0, packs >= 0 else { throw CloudFailure.invalidRequest }
    let allowed = try store.transaction {
      let state = try readAndKeep()
      return state.blocked == nil && now() >= state.retryAt
    }
    guard allowed else { throw CloudFailure.budgetPaused }
  }
  /// The account's own reads (status, device list, this Mac's registration) never wait on the upload's local
  /// blocks: the Cloud page and the sign-in depend on them, and they are few (launch, wake, sign-in, a back-off of
  /// 30 s to 30 min). The service still answers for its own limits.
  public func reserveAccount() throws {
    try store.transaction { _ = try readAndKeep() }
  }
  /// The wait after a 429 `rate_limited` (13 Nov): the service's stated time (Retry-After), at least a second and at
  /// most 15 minutes; without one a back-off of 2 s doubling to 5 min.
  static let rateBackoffMs: [Int64] = [2_000, 4_000, 8_000, 15_000, 30_000, 60_000, 120_000, 300_000]
  static let rateWaitCapMs: Int64 = 900_000
  /// The block kinds this build stores and knows how to end.
  static let knownBlocks: Set<String> = ["rate", "network", "auth", "remote"]
  /// 14 Nov: a service that still answers with an old "allowance" code (`budget_paused`, Cloudflare's 1102/1027, a
  /// database quota) gets an ordinary "try again later": its Retry-After, never more than 5 minutes.
  static let allowanceCodes: Set<String> = ["budget_paused", "1102", "1027", "sql_quota_exceeded"]
  static let allowanceWaitCapMs: Int64 = 300_000
  func rateWait(failures: Int, retryAfter: Int64?) -> Int64 {
    if let retryAfter { return min(max(retryAfter - now(), 1_000), Self.rateWaitCapMs) }
    return Self.rateBackoffMs[max(0, min(failures - 1, Self.rateBackoffMs.count - 1))] + Int64.random(in: 0...500)
  }
  /// The only answers that mean "this Mac's place in the account is gone"; see `failed`.
  static let revocationCodes: Set<String> = ["device_revoked"]
  /// Account answers that are NOT a revocation (a token to renew, a proof the account layer re-registers, a busy
  /// session check): a timed retry like a lost answer, never the person's "Try again" block.
  static let accountRetryCodes: Set<String> = ["sign_in_required", "token_expired", "bad_device_proof", "not_found"]
  public func failed(_ error: Error, httpStatus: Int? = nil, retryAfter: Int64? = nil) throws {
    // These are comparison outcomes that the caller can reconcile immediately, not network failures.
    if case CloudFailure.remote(let detail) = error, ["baseline_changed", "version_changed", "id_reused"].contains(detail.code) { return }
    // This Mac's own "wait" (a stored short wait refused the request before it left): no answer, so no new failure.
    if error as? CloudFailure == .budgetPaused, httpStatus == nil { return }
    try store.transaction {
      var state = try read()
      state.failures = min(state.failures + 1, 1000)
      var code = ""
      if case CloudFailure.remote(let detail) = error { code = detail.code }
      if Self.allowanceCodes.contains(code) {
        state.blocked = "rate"
        state.retryAt = now() + min(rateWait(failures: state.failures, retryAfter: retryAfter), Self.allowanceWaitCapMs)
      } else if httpStatus == 429 || code == "rate_limited" {
        state.blocked = "rate"
        state.retryAt = now() + rateWait(failures: state.failures, retryAfter: retryAfter)
      } else if Self.revocationCodes.contains(code) {
        // MAC-NEXT-12 (13 Nov, the MacBook from 15:53Z): ONLY the service's definite "this device is removed" is a
        // sign-in block. A 401 sign_in_required came from a busy Store database (an export) for a good session and,
        // stored as "auth", stopped this Mac for good: nothing but a new device id lifted it. Every other 401/403
        // (an expired token, a proof the account layer re-registers, a busy service) is an ordinary timed retry.
        state.blocked = "auth"
      } else if case CloudFailure.remote(let detail) = error, !detail.retryable,
        !(httpStatus == 401 || httpStatus == 403 || Self.accountRetryCodes.contains(code)) {
        state.blocked = "remote"
        state.retryAt = 0
      } else {
        if state.failures >= 5 { state.blocked = "network" }
        let delays: [Int64] = [1000, 2000, 4000, 8000, 16000, 30000, 60000]
        state.retryAt = max(min(retryAfter ?? 0, now() + Self.rateWaitCapMs),
                            now() + delays[min(state.failures - 1, delays.count - 1)] + Int64.random(in: 0...500))
      }
      try store.set("budget", state)
    }
  }
  /// MAC-NEXT-12: `deviceProven` = the answered request carried this Mac's device proof. The service serves such a
  /// request only for a live session, an ACTIVE device row of that session and a good signature (user.ts handle), so
  /// it also ends a stored sign-in block ("auth", including one an earlier build stored for a busy 401) and a network
  /// pause: the engine then starts again by itself at the next step. Writes only when a block was lifted.
  public func served(deviceProven: Bool = false) throws {
    guard deviceProven else { return }
    let stored: CloudSyncBudgetSnapshot? = try store.value("budget")
    let lifts: (String?) -> Bool = { $0 == "auth" || $0 == "network" || $0 == "budget" }
    guard lifts(stored?.blocked) else { return }
    try store.transaction {
      var state = try read()
      if state.blocked == "auth" || state.blocked == "network" { state.blocked = nil; state.retryAt = 0; state.failures = 0 }
      try store.set("budget", state)
    }
  }
  /// The `budget {requestsLeft, writesLeft}` in a hello or GET /state is informational only (14 Nov: the service
  /// always sends 1). Nothing on this Mac pauses or waits because of it.
  public func observe(_ remote: CloudBudgetState) throws {}
  public func succeeded() throws {
    try store.transaction {
      var state = try read()
      state.failures = 0
      if state.blocked == nil { state.retryAt = 0 }
      try store.set("budget", state)
    }
  }
  public func registered(deviceId: String) throws {
    try store.transaction {
      let changed: String? = try store.value("changedOutboxRegistration")
      guard changed == deviceId else { return }
      // A new successful registration may clear the old key's auth failure, once, durably.
      try resume(networkOrWake: false, signedIn: true)
      try store.execute("DELETE FROM metadata WHERE key=?", [Data("changedOutboxRegistration".utf8)])
    }
  }
  /// `userRetry` ("Sync now") and `launch` (the first step after start) try once past a network pause; if the
  /// service still refuses, the wait comes back with its answer.
  public func resume(networkOrWake: Bool, signedIn: Bool = false, userRetry: Bool = false, launch: Bool = false) throws {
    try store.transaction {
      var state = try read()
      if ((networkOrWake || userRetry || launch) && state.blocked == "network") || (signedIn && state.blocked == "auth") ||
        ((networkOrWake || signedIn || userRetry) && state.blocked == "rate" && now() >= state.retryAt) ||
        ((signedIn || userRetry) && state.blocked == "remote") || state.blocked == nil {
        state.blocked = nil; state.failures = 0; state.retryAt = 0
      }
      try store.set("budget", state)
    }
  }
}
