import Foundation

/// 13 Nov blocker (two-Mac proof): the first saved copy never finished and NOTHING said why. Every sync failure now
/// writes ONE plain line to the app's log, `cloud sync: <what> failed: <kind / status / the service's refusal code>`,
/// and keeps a plain-words reason for the Cloud page. Never a token, key, content, address query or e-mail: only the
/// failure's kind, the HTTP status, the service's refusal code and the request's method and path (no query).
public final class CloudSyncDiagnostics: @unchecked Sendable {
  public static let shared = CloudSyncDiagnostics()
  private let lock = NSLock()
  private var sink: (@Sendable (String) -> Void)?
  private var refusal: (at: Int64, text: String, status: Int, code: String?)?
  private var lastLine: (at: Int64, text: String)?
  private var lastKind: (at: Int64, kind: String)?
  private var reason: String?
  private var now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

  /// Where the lines go (the app's engine.log). Lines written before a sink is set are dropped.
  public func setSink(_ sink: (@Sendable (String) -> Void)?) { lock.withLock { self.sink = sink } }
  /// For tests: a fixed clock.
  public func setClock(_ now: @escaping @Sendable () -> Int64) { lock.withLock { self.now = now } }
  /// The plain reason of the newest failure that is not settled yet (nil after a success).
  public var lastReason: String? { lock.withLock { reason } }

  /// The transport saw a refusal (non-2xx) or a network failure: kept for the step's one line.
  func noteRefusal(method: String, url: URL?, status: Int, code: String?) {
    let path = url.map { Self.plainPath($0) } ?? "?"
    lock.withLock { refusal = (now(), method + " " + path, status, code) }
  }
  /// A step refused on this Mac before any request (busy, paused, setup still running).
  func noteLocal(_ why: String) { lock.withLock { refusal = (now(), why, -1, nil) } }
  /// Proof 3 (13 Nov): a step refused only because this Mac's own sync was busy with another step (its first copy
  /// most of all). That is not a failure: it writes no line and leaves the page's reason as it was.
  func noteBusy(_ why: String) { lock.withLock { refusal = (now(), why, -2, nil) } }
  private var busyRefusal = false
  /// The newest `report` met a busy refusal (no line written, no reason kept).
  public var lastRefusalWasBusy: Bool { lock.withLock { busyRefusal } }
  /// One plain information line (never a failure): `cloud sync: <line>`.
  public func info(_ line: String) {
    let sinkNow = lock.withLock { sink }
    sinkNow?("cloud sync: " + line)
  }
  func noteNetwork(method: String, url: URL?, error: any Error) {
    let path = url.map { Self.plainPath($0) } ?? "?"
    let ns = error as NSError
    let what = ns.domain == NSURLErrorDomain ? "network \(ns.code)" : String(describing: type(of: error))
    lock.withLock { refusal = (now(), method + " " + path + " (" + what + ")", 0, nil) }
  }

  /// One line for one failed step. The same line again within a minute is not repeated (automatic retries).
  @discardableResult
  public func report(_ what: String, _ error: any Error) -> String {
    let (line, sinkNow): (String, (@Sendable (String) -> Void)?) = lock.withLock {
      let at = now()
      let kind = Self.kind(error)
      // Proof 3: busy with another step of this Mac's own (the first copy) is not a failure; it continues by itself.
      // Only the same refusal passing up (unavailable, within seconds); a later, real failure is never swallowed.
      if let seen = refusal, seen.status == -2, kind == "unavailable", at - seen.at < 5_000 {
        refusal = nil; busyRefusal = true
        return ("", nil)
      }
      busyRefusal = false
      if refusal?.status == -2 { refusal = nil }
      // The same failure passing up through the wiring (engine, then activation, then setup) is one line, not three.
      if let seen = lastKind, seen.kind == kind || kind == "unavailable", at - seen.at < 5_000, refusal == nil {
        lastKind = (at, seen.kind); return ("", nil)
      }
      lastKind = (at, kind)
      var detail = kind
      var status: Int? = nil, code: String? = nil
      if case .remote(let remote)? = error as? CloudFailure { code = remote.code }
      if let seen = refusal, at - seen.at < 120_000 {
        detail += seen.status < 0 ? " / " + seen.text
          : " / " + (seen.status > 0 ? "http \(seen.status)" : "no answer") + (seen.code.map { " " + $0 } ?? "") + " at " + seen.text
        status = seen.status; code = code ?? seen.code
        refusal = nil
      }
      reason = Self.plainReason(error, status: status, code: code)
      let line = "cloud sync: " + what + " failed: " + detail
      if let last = lastLine, last.text == line, at - last.at < 60_000 { return (line, nil) }
      lastLine = (at, line)
      return (line, sink)
    }
    sinkNow?(line)
    return line
  }
  /// A step finished: the page's reason is cleared.
  public func succeeded() { lock.withLock { reason = nil; refusal = nil } }

  static func plainPath(_ url: URL) -> String {
    // Upload/download links point at the object store: only say which kind of address it was.
    let path = url.path
    // X3 (13 Nov): the route name only. What follows it (a transfer ticket, an id) is never written: a transfer
    // path is base64 that names this device ("GET /v1/transfers/eyJ…" was in the log).
    let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    let keep: Int
    if parts.first == "v1" { keep = 2 } else if parts.first == "auth", parts.count > 1, parts[1] == "v1" { keep = 3 } else { return "storage link" }
    let plain = parts.prefix(keep).map { $0.count <= 32 && $0.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) ? $0 : "…" }
    return "/" + plain.joined(separator: "/") + (parts.count > keep ? "/…" : "")
  }
  /// The error's kind in one short word or two: `remote <code>`, a CloudFailure case, or the error's type name.
  public static func kind(_ error: any Error) -> String {
    if let failure = error as? CloudFailure {
      switch failure {
      case .remote(let detail): return "remote " + detail.code + (detail.retryable ? " (will retry)" : "")
      // 14 Nov: not the account's budget (there is none): this Mac's own short wait after an earlier refusal.
      case .budgetPaused: return "short wait on this Mac"
      default: return "\(failure)"
      }
    }
    if error is CancellationError { return "cancelled" }
    if let transfer = error as? CloudSyncTransferFailure { return "\(transfer)" }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain { return "network \(ns.code)" }
    return String(describing: type(of: error))
  }
  /// What the Cloud page says, in plain words with what the person can do.
  public static func plainReason(_ error: any Error, status: Int? = nil, code: String? = nil) -> String {
    let code = code ?? { if case .remote(let d)? = error as? CloudFailure { return d.code }; return nil }()
    switch code {
    case "viewer_read_only": return "Cloud treats this Mac as view-only, so it cannot send. Sign out and sign in again on this Mac."
    // 14 Nov: no daily allowance any more; every "too much / too fast" answer is the plain busy wait.
    case "storage_full": return "Your Cloud storage is full. Free space or upgrade; nothing on this Mac is lost."
    case "budget_exceeded", "budget_paused", "quota_exceeded", "rate_limited", "too_many_requests":
      return "Cloud asked this Mac to wait before sending again. It continues by itself; nothing is lost."
    case "sign_in_required", "token_expired", "bad_device_proof": return "Cloud needs you to sign in again on this Mac."
    case "device_revoked": return "This Mac was removed from your account. Sign in again to use Cloud here."
    case "storage_required", "cloud_not_enabled": return "Cloud storage is not switched on for this account."
    case .some(let other) where status.map({ $0 >= 500 }) == true: return "Cloud did not answer properly (\(other)). It tries again by itself."
    case .some(let other): return "Cloud refused an upload (\(other)). It tries again by itself; if this stays, tell support."
    case nil: break
    }
    if let status, status < 0 { return "This Mac is still busy with another Cloud step. It continues by itself." }
    if let status, status >= 500 { return "Cloud did not answer properly. It tries again by itself." }
    if let status, status == 0 { return "Cloud could not be reached. Check the internet connection; it tries again by itself." }
    switch error as? CloudFailure {
    case .budgetPaused?: return "Cloud asked this Mac to wait before sending again. It continues by itself."
    case .gateClosed?: return "Cloud is not switched on for this account."
    case .storageRequired?: return "Cloud storage is not switched on for this account."
    case .secretsLocked?: return "Saved passwords are locked on this Mac. Unlock them on this page; memory keeps going."
    case .deviceRevoked?: return "This Mac was removed from your account. Sign in again to use Cloud here."
    case .unavailable?: return "Cloud could not be reached or is busy. It tries again by itself."
    default: break
    }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain { return "Cloud could not be reached. Check the internet connection; it tries again by itself." }
    return "Something on this Mac stopped the upload (\(kind(error))). It tries again by itself; if this stays, tell support."
  }
}
