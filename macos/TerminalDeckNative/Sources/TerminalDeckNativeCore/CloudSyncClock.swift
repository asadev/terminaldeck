import Foundation

/// The service's time as best this Mac knows it: this Mac's clock plus an offset learned only from authenticated
/// service answers (the `committedAt` the service states in the authenticated body of a pack commit receipt;
/// never an HTTP Date header a proxy could change). The offset is persisted in sync.sqlite. A jump of more than a
/// day against the last known offset is adopted only when a second answer agrees with it. Never blocks.
enum CloudSyncServiceClock {
  static let implausibleJump: Int64 = 86_400_000
  static let agreement: Int64 = 60_000
  /// One authenticated observation: the service said `serverTime` for a request sent at `sentAt` and answered at
  /// `receivedAt` (this Mac's clock). The midpoint is the best local estimate of that instant.
  static func observe(_ store: CloudSyncStore, serverTime: Int64, sentAt: Int64, receivedAt: Int64) throws {
    guard serverTime > 0, receivedAt >= sentAt, receivedAt - sentAt < 120_000 else { return }
    let sample = serverTime - (sentAt + (receivedAt - sentAt) / 2)
    try store.transaction {
      guard let current: Int64 = try store.value("serviceClockOffset") else {
        try store.set("serviceClockOffset", sample)
        return
      }
      if abs(sample - current) <= implausibleJump {
        try store.set("serviceClockOffset", sample)
        try store.execute("DELETE FROM metadata WHERE key=?", [Data("serviceClockCandidate".utf8)])
        return
      }
      if let candidate: Int64 = try store.value("serviceClockCandidate"), abs(sample - candidate) <= agreement {
        try store.set("serviceClockOffset", sample)
        try store.execute("DELETE FROM metadata WHERE key=?", [Data("serviceClockCandidate".utf8)])
      } else {
        try store.set("serviceClockCandidate", sample)
      }
    }
  }
  static func serviceTime(_ store: CloudSyncStore, now: Int64 = CloudSyncBytes.now()) -> Int64? {
    guard let offset = try? store.value("serviceClockOffset") as Int64? else { return nil }
    return now + offset
  }
}
