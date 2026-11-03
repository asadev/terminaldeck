import Foundation

// 1 Nov 2026 (This Mac on the phone), kept for the video on the direct link (3 Nov, m5-direct-only: the JPEG picture
// encoder that lived beside it is gone with the pictures).

/// How fast one viewer's video may go (1 Nov): a bitrate that climbs back quickly while acks come back on time and
/// steps down when they queue up, judged against the link's own best round trip (so a far relay is not "slow" by
/// itself, which is what kept the old rule at its floor), and the bytes that may be on the way at once.
public struct BackendPhoneScreenPacer: Sendable, Equatable {
    public static let floor = 400_000.0, ceiling = 16_000_000.0, start = 4_000_000.0
    public var bitrate = BackendPhoneScreenPacer.start
    /// The best (lowest) recent round trip with the transfer time taken out, ms.
    public private(set) var base: Double?
    private var samples: [Double] = []
    private var lastCut = -Double.infinity
    /// When frames were last lost on the way (M5): the bitrate does not climb again for `lossHold` ms after that.
    private var lastLoss = -Double.infinity
    public static let lossHold = 1_500.0
    public init() {}

    /// Frames that went on the link's `td.rt` were never acked (M5): they were given up on the way (a lossy or slow
    /// path). A missing ack is the clearest sign the link carries less than believed, and a slow path gives no slow acks
    /// to learn from (the frames simply never arrive), so: step down hard, at most once a round trip, and hold.
    /// M5: no more than `value` bits a second (what the link was measured to deliver while frames queued up), and no
    /// climbing for `lossHold` ms.
    public mutating func cap(_ value: Double, now: Double) {
        guard value < bitrate else { return }
        bitrate = max(Self.floor, value)
        lastCut = now; lastLoss = now
    }

    public mutating func lost(now: Double) {
        lastLoss = now
        guard now - lastCut > max(250, base ?? 250) else { return }
        bitrate = max(Self.floor, bitrate * 0.6)
        lastCut = now
    }

    /// A picture of `bytes` came back acked `took` ms after it went.
    public mutating func acked(took: Double, bytes: Int, now: Double) {
        // The link's own round trip: the quickest recent ack of a small picture (a big one also carries transfer time).
        if bytes <= 64_000 || samples.isEmpty {
            samples.append(took)
            if samples.count > 20 { samples.removeFirst() }
        }
        let best = samples.min() ?? took
        base = best
        // What is left after the round trip and the time these bytes need at the bitrate believed now: a queue when
        // it grows (the bitrate is too high), nothing or less when the link is faster than believed.
        let excess = took - best - Double(bytes) * 8_000 / bitrate
        if excess > max(150, best * 0.6) {
            // Queued up: step down, at most once a round trip.
            if now - lastCut > max(250, best) { bitrate = max(Self.floor, bitrate * 0.7); lastCut = now }
        } else if excess < max(80, best * 0.3), now - lastLoss > Self.lossHold {
            bitrate = min(Self.ceiling, bitrate * 1.15)
        }
    }

    /// Bytes that may be on the way at once: the link's bitrate over its round trip and a bit, at least one picture.
    public var inFlightBytes: Int { Int(max(250_000, bitrate / 8 * ((base ?? 300) + 500) / 1_000)) }
}
